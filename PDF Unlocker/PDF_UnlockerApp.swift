import SwiftUI
import LaunchAtLogin
import FileWatcher
import PDFKit
import SettingsAccess
import AppKit
import Security
import CryptoKit

private let monitoredFolderBookmarkKey = "monitoredFolderBookmark"
private let openUnencryptedPDFsKey = "openUnencryptedPDFs"
let iCloudSyncEnabledKey = "iCloudKeychainSyncEnabled"

enum PasswordStore {
    private static let service = "com.rtcamp.PDFUnlocker"
    private static let legacyBlobAccount = "passwordList"
    private static let legacyDefaultsKey = "passwordList"

    static var isSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
    }

    static func setSyncEnabled(_ enabled: Bool) {
        let was = isSyncEnabled
        UserDefaults.standard.set(enabled, forKey: iCloudSyncEnabledKey)
        guard was != enabled else { return }
        migrateBetweenScopes(toSync: enabled)
    }

    static func load() -> [String] {
        runMigrationsIfNeeded()
        let scope = isSyncEnabled
        return readAll(sync: scope).sorted()
    }

    static func save(_ passwords: [String]) {
        let scope = isSyncEnabled
        deleteAll(sync: scope)
        for pwd in passwords where !pwd.isEmpty {
            addItem(password: pwd, sync: scope)
        }
    }

    private static func readAll(sync: Bool) -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecAttrSynchronizable: sync,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { item in
            if item[kSecAttrAccount] as? String == legacyBlobAccount { return nil }
            guard let data = item[kSecValueData] as? Data,
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
    }

    private static func addItem(password: String, sync: Bool) {
        guard let data = password.data(using: .utf8) else { return }
        let account = sha256Hex(password)
        let dq: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: sync,
        ]
        SecItemDelete(dq as CFDictionary)
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrSynchronizable: sync,
            kSecAttrAccessible: sync ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func deleteAll(sync: Bool) {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: sync,
        ]
        SecItemDelete(q as CFDictionary)
    }

    private static func migrateBetweenScopes(toSync: Bool) {
        let from = readAll(sync: !toSync)
        for pwd in from { addItem(password: pwd, sync: toSync) }
        deleteAll(sync: !toSync)
    }

    private static func runMigrationsIfNeeded() {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: legacyBlobAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8) {
            let list = str.components(separatedBy: "\n").filter { !$0.isEmpty }
            for pwd in list { addItem(password: pwd, sync: false) }
            let del: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: legacyBlobAccount,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            ]
            SecItemDelete(del as CFDictionary)
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey) {
            let list = legacy.components(separatedBy: "\n").filter { !$0.isEmpty }
            for pwd in list { addItem(password: pwd, sync: false) }
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@main
struct PDFUnlockerApp: App {
    @StateObject private var fileWatcherManager = FileWatcherManager()


    var body: some Scene {
        MenuBarExtra {
            SettingsLink {
                Text("Settings")
            } preAction: {
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                }
            } postAction: {
            }.keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(self)
            }
            .padding()
        } label: {
            Image(nsImage: Self.menuBarIcon(monitoring: fileWatcherManager.isMonitoring))
                .accessibilityLabel("PDF Unlocker")
        }

        Settings {
            SettingsView(fileWatcherManager: fileWatcherManager)
        }
    }

    private static func menuBarIcon(monitoring: Bool) -> NSImage {
        let symbolName = "lock.doc"
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(.init(paletteColors: [.labelColor]))
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) ?? NSImage()
        let symbolSize = symbol.size
        let dotDiameter: CGFloat = 7
        let canvas = NSSize(width: symbolSize.width + 3, height: symbolSize.height + 1)
        let img = NSImage(size: canvas)
        img.lockFocus()
        symbol.draw(in: NSRect(x: 0, y: 1, width: symbolSize.width, height: symbolSize.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
        let dotRect = NSRect(
            x: canvas.width - dotDiameter,
            y: canvas.height - dotDiameter,
            width: dotDiameter, height: dotDiameter
        )
        (monitoring ? NSColor.systemGreen : NSColor.systemRed).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setStroke()
        let stroke = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.25, dy: 0.25))
        stroke.lineWidth = 0.5
        stroke.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

class FileWatcherManager: ObservableObject {
    @Published var isMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(isMonitoring, forKey: "isMonitoring")
        }
    }

    @Published var monitoredFolderURL: URL?

    private var fileWatcher: FileWatcher?
    private var securityScopedURL: URL?

    private var recentlyProcessed: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 10
    private let dedupeQueue = DispatchQueue(label: "pdfunlocker.dedupe")

    init() {
        self.isMonitoring = UserDefaults.standard.bool(forKey: "isMonitoring")
        self.monitoredFolderURL = Self.resolveMonitoredFolder()
        if isMonitoring {
            startFileWatcher()
        }
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    private static func resolveMonitoredFolder() -> URL {
        if let bookmarkData = UserDefaults.standard.data(forKey: monitoredFolderBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        return defaultDownloadsURL()
    }

    static func defaultDownloadsURL() -> URL {
        let realHome = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return URL(fileURLWithPath: realHome).appendingPathComponent("Downloads")
    }

    func setMonitoredFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: monitoredFolderBookmarkKey)
        } catch {
            return
        }

        let wasMonitoring = isMonitoring
        if wasMonitoring {
            stopFileWatcher()
        }
        monitoredFolderURL = url
        if wasMonitoring {
            startFileWatcher()
        }
    }

    private func shouldProcess(path: String) -> Bool {
        return dedupeQueue.sync {
            let now = Date()
            recentlyProcessed = recentlyProcessed.filter { now.timeIntervalSince($0.value) < dedupeWindow }
            if let last = recentlyProcessed[path], now.timeIntervalSince(last) < dedupeWindow {
                return false
            }
            recentlyProcessed[path] = now
            return true
        }
    }

    func markProcessed(path: String) {
        dedupeQueue.sync {
            recentlyProcessed[path] = Date()
        }
    }

    func setupFileWatcher() -> FileWatcher {
        let folderURL = monitoredFolderURL ?? Self.defaultDownloadsURL()

        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        if folderURL.startAccessingSecurityScopedResource() {
            securityScopedURL = folderURL
        }

        return FileWatcher([folderURL.path])
    }

    func startFileWatcher() {
        fileWatcher = setupFileWatcher()
        fileWatcher?.callback = { [weak self] event in
            guard let self = self else { return }
            guard event.fileCreated else { return }

            let path = event.path
            let url = URL(fileURLWithPath: path)
            let lastComponent = url.lastPathComponent

            if lastComponent.hasPrefix(".") { return }
            if url.pathExtension.lowercased() != "pdf" { return }

            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            guard let type = attrs?[.type] as? FileAttributeType, type == .typeRegular else { return }

            if !self.shouldProcess(path: path) { return }

            processPDF(fileName: path, manager: self)
        }

        fileWatcher?.start()
        DispatchQueue.main.async {
            self.isMonitoring = true
        }
    }

    func stopFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        DispatchQueue.main.async {
            self.isMonitoring = false
        }
    }
}

func processPDF(fileName: String, manager: FileWatcherManager? = nil) {
    let passwords = PasswordStore.load()

    let fileURL = URL(fileURLWithPath: fileName)
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    guard let pdfDocument = PDFDocument(url: fileURL) else { return }

    let openUnencrypted = UserDefaults.standard.object(forKey: openUnencryptedPDFsKey) as? Bool ?? true

    guard pdfDocument.isEncrypted else {
        if openUnencrypted {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(fileURL)
            }
        }
        return
    }

    if pdfDocument.unlock(withPassword: "") {
        if saveUnlockedPDF(originalURL: fileURL, unlockedDocument: pdfDocument) {
            manager?.markProcessed(path: fileURL.path)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(fileURL)
            }
        }
        return
    }

    for password in passwords {
        if pdfDocument.unlock(withPassword: password) {
            if saveUnlockedPDF(originalURL: fileURL, unlockedDocument: pdfDocument) {
                manager?.markProcessed(path: fileURL.path)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(fileURL)
                }
            }
            break
        }
    }
}

func saveUnlockedPDF(originalURL: URL, unlockedDocument: PDFDocument) -> Bool {
    let newDocument = PDFDocument()

    for pageIndex in 0..<unlockedDocument.pageCount {
        if let page = unlockedDocument.page(at: pageIndex) {
            newDocument.insert(page, at: pageIndex)
        }
    }

    guard newDocument.pageCount == unlockedDocument.pageCount else { return false }

    let directory = originalURL.deletingLastPathComponent()
    let tempURL = directory.appendingPathComponent(".\(originalURL.lastPathComponent).unlocked-\(UUID().uuidString).tmp")

    guard newDocument.write(to: tempURL) else { return false }

    do {
        _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tempURL)
        return true
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        return false
    }
}

struct SettingsView: View {
    @ObservedObject var fileWatcherManager: FileWatcherManager
    @State private var passwordList: String = PasswordStore.load().joined(separator: "\n")
    @State private var openUnencrypted: Bool = (UserDefaults.standard.object(forKey: openUnencryptedPDFsKey) as? Bool) ?? true
    @State private var iCloudSync: Bool = PasswordStore.isSyncEnabled
    @State private var saveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter passwords, one on each line.")
                .padding(.top, 16)
                .padding(.horizontal, 20)

            TextEditor(text: $passwordList)
                .border(Color.gray.opacity(0.5), width: 1)
                .frame(minWidth: 220, minHeight: 220)
                .font(.system(size: 13))
                .lineSpacing(1)
                .padding([.top, .bottom], 5)
                .padding([.leading, .trailing], 20)

            HStack {
                Button("Save Passwords") {
                    let cleaned = Array(Set(self.passwordList.components(separatedBy: "\n")))
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .sorted()
                    PasswordStore.save(cleaned)
                    self.passwordList = cleaned.joined(separator: "\n")
                    saveConfirmation = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        saveConfirmation = false
                    }
                }
                Button("Sync Now") {
                    passwordList = PasswordStore.load().joined(separator: "\n")
                }
                .help("Reload passwords from Keychain (pull latest from iCloud)")
                if saveConfirmation {
                    Text("Saved \u{2713}")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Button(fileWatcherManager.isMonitoring ? "Stop PDF Monitoring" : "Start PDF Monitoring") {
                if fileWatcherManager.isMonitoring {
                    fileWatcherManager.stopFileWatcher()
                } else {
                    fileWatcherManager.startFileWatcher()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 4) {
                Text("Monitored folder:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(fileWatcherManager.monitoredFolderURL?.path ?? "—")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(fileWatcherManager.monitoredFolderURL?.path ?? "")
                Button("Choose Folder\u{2026}") {
                    chooseFolder()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Toggle("Open PDFs even if not encrypted", isOn: $openUnencrypted)
                .onChange(of: openUnencrypted) { newValue in
                    UserDefaults.standard.set(newValue, forKey: openUnencryptedPDFsKey)
                }
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Sync passwords via iCloud Keychain", isOn: $iCloudSync)
                    .onChange(of: iCloudSync) { newValue in
                        PasswordStore.setSyncEnabled(newValue)
                        passwordList = PasswordStore.load().joined(separator: "\n")
                    }
                Text("Encrypted end-to-end. Requires iCloud Keychain enabled in System Settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)

            LaunchAtLogin.Toggle()
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 320, height: 540)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = fileWatcherManager.monitoredFolderURL {
            panel.directoryURL = current
        }
        if panel.runModal() == .OK, let url = panel.url {
            fileWatcherManager.setMonitoredFolder(url)
        }
    }
}

#Preview {
    SettingsView(fileWatcherManager: FileWatcherManager())
}

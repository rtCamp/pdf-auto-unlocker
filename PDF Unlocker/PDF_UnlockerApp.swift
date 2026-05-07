import SwiftUI
import LaunchAtLogin
import FileWatcher
import PDFKit
import SettingsAccess
import AppKit
import Security

private let monitoredFolderBookmarkKey = "monitoredFolderBookmark"
private let openUnencryptedPDFsKey = "openUnencryptedPDFs"

enum PasswordStore {
    private static let service = "com.rtcamp.PDFUnlocker"
    private static let account = "passwordList"
    private static let legacyDefaultsKey = "passwordList"

    static func load() -> [String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let str = String(data: data, encoding: .utf8) {
            return str.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey) {
            let list = legacy.components(separatedBy: "\n").filter { !$0.isEmpty }
            if !list.isEmpty {
                save(list)
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                return list
            }
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        return []
    }

    static func save(_ passwords: [String]) {
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard !passwords.isEmpty,
              let blob = passwords.joined(separator: "\n").data(using: .utf8) else { return }
        var add = baseQuery
        add[kSecValueData] = blob
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }
}

@main
struct PDFUnlockerApp: App {
    @StateObject private var fileWatcherManager = FileWatcherManager()


    var body: some Scene {
        MenuBarExtra("PDF Unlocker", systemImage: "lock.open.rotation") {
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
        }

        Settings {
            SettingsView(fileWatcherManager: fileWatcherManager)
        }
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
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
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
        let folderURL = monitoredFolderURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

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
                if saveConfirmation {
                    Text("Saved \u{2713}")
                        .foregroundColor(.secondary)
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

            Button(fileWatcherManager.isMonitoring ? "Stop PDF Monitoring" : "Start PDF Monitoring") {
                if fileWatcherManager.isMonitoring {
                    fileWatcherManager.stopFileWatcher()
                } else {
                    fileWatcherManager.startFileWatcher()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

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

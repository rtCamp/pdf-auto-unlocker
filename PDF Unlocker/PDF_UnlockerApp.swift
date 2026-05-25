import SwiftUI
import LaunchAtLogin
import FileWatcher
import PDFKit
import SettingsAccess
import AppKit
import Security
import CryptoKit
import Combine

private let monitoredFolderBookmarkKey = "monitoredFolderBookmark"
private let openUnencryptedPDFsKey = "openUnencryptedPDFs"
private let legacyiCloudSyncEnabledKey = "iCloudKeychainSyncEnabled"
private let keychainMigrationDoneKey = "keychainMigrationCompleted_v2"

enum PasswordStore {
    private static let service = "com.rtcamp.PDFUnlocker"
    private static let legacyBlobAccount = "passwordList"
    private static let legacyDefaultsKey = "passwordList"

    static func load() -> [String] {
        if !UserDefaults.standard.bool(forKey: keychainMigrationDoneKey) {
            runMigrationsIfNeeded()
            UserDefaults.standard.set(true, forKey: keychainMigrationDoneKey)
        }
        return readAll(sync: true).sorted()
    }

    static func save(_ passwords: [String]) {
        deleteAll(sync: true)
        for pwd in passwords where !pwd.isEmpty {
            addItem(password: pwd, sync: true)
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
            for pwd in list { addItem(password: pwd, sync: true) }
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
            for pwd in list { addItem(password: pwd, sync: true) }
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        let localItems = readAll(sync: false)
        if !localItems.isEmpty {
            for pwd in localItems { addItem(password: pwd, sync: true) }
            deleteAll(sync: false)
        }
        UserDefaults.standard.removeObject(forKey: legacyiCloudSyncEnabledKey)
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

}

final class StatusBarController: NSObject, ObservableObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let watcher: FileWatcherManager
    private var cancellable: AnyCancellable?
    private weak var dotView: NSView?
    private var settingsWindow: NSWindow?

    init(watcher: FileWatcherManager) {
        self.watcher = watcher
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureMenu()
        refresh()
        cancellable = watcher.$isMonitoring
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        let symbolName = "lock.doc"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PDF Auto Unlocker")
        img?.isTemplate = true
        button.image = img

        if dotView == nil {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 3
            v.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(v)
            NSLayoutConstraint.activate([
                v.widthAnchor.constraint(equalToConstant: 6),
                v.heightAnchor.constraint(equalToConstant: 6),
                v.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                v.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            ])
            dotView = v
        }
        dotView?.layer?.backgroundColor = NSColor.systemRed.cgColor
        dotView?.isHidden = watcher.isMonitoring
    }

    private func configureMenu() {
        let menu = NSMenu()
        let s = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "PDF Auto Unlocker Settings"
            window.contentView = NSHostingView(rootView: SettingsView(fileWatcherManager: watcher))
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}

@main
struct PDFAutoUnlockerApp: App {
    @StateObject private var fileWatcherManager: FileWatcherManager
    @StateObject private var statusBar: StatusBarController

    init() {
        let w = FileWatcherManager()
        _fileWatcherManager = StateObject(wrappedValue: w)
        _statusBar = StateObject(wrappedValue: StatusBarController(watcher: w))
        _ = PasswordStore.load()
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class FileWatcherManager: ObservableObject {
    @Published var isMonitoring: Bool {
        didSet {
            guard oldValue != isMonitoring else { return }
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
                if isStale {
                    _ = url.startAccessingSecurityScopedResource()
                    if let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil) {
                        UserDefaults.standard.set(fresh, forKey: monitoredFolderBookmarkKey)
                    }
                    url.stopAccessingSecurityScopedResource()
                }
                return url
            }
        }
        return defaultDownloadsURL()
    }

    static func defaultDownloadsURL() -> URL {
        if let pw = getpwuid(getuid()), let cstr = pw.pointee.pw_dir {
            let realHome = String(cString: cstr)
            return URL(fileURLWithPath: realHome).appendingPathComponent("Downloads")
        }
        if let url = try? FileManager.default.url(for: .downloadsDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: false) {
            return url
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    func setMonitoredFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: monitoredFolderBookmarkKey)
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't use that folder"
                alert.informativeText = "PDF Auto Unlocker can't get permission to watch \"\(url.lastPathComponent)\". Try a different folder.\n\n\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
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
        manager?.markProcessed(path: fileURL.path)
        if saveUnlockedPDF(originalURL: fileURL, unlockedDocument: pdfDocument) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(fileURL)
            }
        }
        return
    }

    for password in passwords {
        if pdfDocument.unlock(withPassword: password) {
            manager?.markProcessed(path: fileURL.path)
            if saveUnlockedPDF(originalURL: fileURL, unlockedDocument: pdfDocument) {
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

final class AlwaysEmphasizedLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                          count rectCount: Int,
                                          forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        super.fillBackgroundRectArray(rectArray,
                                      count: rectCount,
                                      forCharacterRange: charRange,
                                      color: NSColor.systemBlue.withAlphaComponent(0.3))
    }
}

final class AlwaysEmphasizedTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var selectedTextAttributes: [NSAttributedString.Key: Any] {
        get {
            [
                .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.3),
                .foregroundColor: NSColor.selectedTextColor
            ]
        }
        set { super.selectedTextAttributes = newValue }
    }
}

struct PasswordTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = AlwaysEmphasizedTextView()
        textView.textContainer?.replaceLayoutManager(AlwaysEmphasizedLayoutManager())
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.insertionPointColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasswordTextEditor
        init(_ parent: PasswordTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
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

            PasswordTextEditor(text: $passwordList)
                .border(Color.gray.opacity(0.5), width: 1)
                .frame(minWidth: 220, minHeight: 220)
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

            LaunchAtLogin.Toggle()
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 320, height: 540)
        .onAppear {
            passwordList = PasswordStore.load().joined(separator: "\n")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = fileWatcherManager.monitoredFolderURL {
            panel.directoryURL = current
        } else if let downloads = try? FileManager.default.url(for: .downloadsDirectory,
                                                               in: .userDomainMask,
                                                               appropriateFor: nil,
                                                               create: false) {
            panel.directoryURL = downloads
        }
        if panel.runModal() == .OK, let url = panel.url {
            fileWatcherManager.setMonitoredFolder(url)
        }
    }
}

#Preview {
    SettingsView(fileWatcherManager: FileWatcherManager())
}

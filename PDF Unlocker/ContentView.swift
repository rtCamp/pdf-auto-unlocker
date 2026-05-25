import SwiftUI

@main
struct PDFAutoUnlockerApp: App {
    @State private var isOpen = false

    var body: some Scene {
        MenuBarExtra("PDF Auto Unlocker", image: "lock.fill", isInserted: $isOpen) {
            VStack {
                Button("Unlock PDF") {
                    // Action to unlock PDF
                }
                Divider()
                Button("Preferences") {
                    // Action to open preferences
                }
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
        }
    }
}


import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // System Settings' "Quit & Reopen" (and scripts) send a Quit Apple Event. Handle it ourselves so an
        // open sheet can never cancel it.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        DebugSnapshot.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.closeSheets()
        return .terminateNow
    }

    @objc func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        AppDelegate.forceQuit()
    }

    /// Closes any open sheet, quits normally, and exits outright if something still blocks quitting.
    static func forceQuit() {
        closeSheets()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }

    static func closeSheets() {
        Task { @MainActor in Permissions.shared.showSheet = false }
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
    }
}

@main
struct AppSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var catalog = AppCatalog()

    var body: some Scene {
        WindowGroup("AppSweep") {
            ContentView()
                .environmentObject(catalog)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh App List") { Task { await catalog.reload() } }
                    .keyboardShortcut("r")
            }
        }
    }
}

import AppKit

/// Developer aid: launch with APPSWEEP_SNAPSHOT_DIR=/some/dir and AppSweep saves PNGs of its own
/// window in both modes, then quits. Capturing your own window needs no screen-recording permission.
@MainActor
enum DebugSnapshot {
    static var directory: String? { ProcessInfo.processInfo.environment["APPSWEEP_SNAPSHOT_DIR"] }

    static func runIfRequested() {
        // Developer aid: APPSWEEP_AM_PROBE=/file writes the App Management test result, then quits.
        if let out = ProcessInfo.processInfo.environment["APPSWEEP_AM_PROBE"] {
            let r = Permissions.probeAppManagement()
            try? "appManagement=\(r.map { String($0) } ?? "unknown") fullDiskAccess=\(Permissions.checkFullDiskAccess())\n"
                .write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        // Developer aid: APPSWEEP_TCC_DUMP=/file writes AppSweep's privacy-permission records, then quits.
        if let out = ProcessInfo.processInfo.environment["APPSWEEP_TCC_DUMP"] {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var text = ""
            for db in [home + "/Library/Application Support/com.apple.TCC/TCC.db", "/Library/Application Support/com.apple.TCC/TCC.db"] {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                p.arguments = ["-readonly", db, "SELECT service, client, client_type, auth_value, auth_reason, auth_version FROM access WHERE service LIKE '%AppBundles%' OR lower(client) LIKE '%appsweep%';"]
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                try? p.run(); p.waitUntilExit()
                text += "== \(db)\n" + (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "") + "\n"
            }
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        guard let dir = directory else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let catalog = AppCatalog.current else { return }
            if let first = catalog.apps.first(where: { $0.name == "VLC" }) ?? catalog.apps.first {
                catalog.selectedAppID = first.id
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            save(to: dir + "/1-apps.png")

            catalog.selectedAppID = AppCatalog.orphansID
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            catalog.orphans.selectAll()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            save(to: dir + "/2-orphans.png")

            if let app = catalog.apps.first(where: { $0.name == "VLC" }) { catalog.selectedAppID = app.id }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            save(to: dir + "/3-back-to-apps.png")
            catalog.selectedAppID = AppCatalog.memoryID
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            save(to: dir + "/4-memory.png")
            Permissions.shared.showSheet = true
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let sheet = NSApp.windows.compactMap(\.attachedSheet).first, let v = sheet.contentView {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/5-permissions.png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    static func save(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

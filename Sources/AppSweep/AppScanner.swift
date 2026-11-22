import Foundation

enum AppScanner {
    static var searchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    static func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        for root in searchRoots {
            collect(in: root, depth: 0, into: &found)
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func collect(in dir: URL, depth: Int, into found: inout [String: InstalledApp]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for item in items {
            if item.pathExtension.lowercased() == "app" {
                if let app = makeApp(at: item) { found[app.id] = app }
                continue
            }
            // Descend into vendor folders like "/Applications/Adobe Photoshop 2025/"
            let v = try? item.resourceValues(forKeys: Set(keys))
            if depth < 2, v?.isDirectory == true, v?.isSymbolicLink != true {
                collect(in: item, depth: depth + 1, into: &found)
            }
        }
    }

    static func makeApp(at url: URL) -> InstalledApp? {
        var info = (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) ?? [:]
        if info["CFBundleIdentifier"] == nil {
            // iPhone/iPad apps on Mac: /Applications/X.app/Wrapper/X.app/Info.plist
            let wrapper = url.appendingPathComponent("Wrapper")
            if let inner = (try? FileManager.default.contentsOfDirectory(atPath: wrapper.path))?.first(where: { $0.hasSuffix(".app") }),
               let d = NSDictionary(contentsOf: wrapper.appendingPathComponent(inner).appendingPathComponent("Info.plist")) as? [String: Any] {
                info = d
            }
        }
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt").path
        return InstalledApp(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: info["CFBundleIdentifier"] as? String,
            version: version,
            executableName: info["CFBundleExecutable"] as? String,
            bundleName: info["CFBundleName"] as? String,
            isProtected: isSystemProtected(url),
            isAppStore: FileManager.default.fileExists(atPath: receipt)
        )
    }

    /// Apps guarded by System Integrity Protection (e.g. Safari) can't be removed.
    static func isSystemProtected(_ url: URL) -> Bool {
        if url.resolvingSymlinksInPath().path.hasPrefix("/System/") { return true }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let SF_RESTRICTED_FLAG: UInt32 = 0x0008_0000
        return (st.st_flags & SF_RESTRICTED_FLAG) != 0
    }
}

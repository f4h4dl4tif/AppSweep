import Foundation

/// Finds files an app has scattered around the system (prefs, caches, containers, launch agents…).
enum LeftoverFinder {
    enum MatchMode { case standard, namePrefix }

    struct Location {
        let path: String
        let category: FileCategory
        var mode: MatchMode = .standard
    }

    static var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lib = home + "/Library"
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
        return [
            Location(path: lib + "/Application Support", category: .appSupport),
            Location(path: lib + "/Application Scripts", category: .appSupport),
            Location(path: lib + "/Preferences", category: .preferences),
            Location(path: lib + "/Preferences/ByHost", category: .preferences),
            Location(path: lib + "/Containers", category: .containers),
            Location(path: lib + "/Group Containers", category: .containers),
            Location(path: lib + "/Caches", category: .caches),
            Location(path: tmp.appendingPathComponent("C").path, category: .caches),
            Location(path: tmp.appendingPathComponent("T").path, category: .caches),
            Location(path: lib + "/HTTPStorages", category: .webData),
            Location(path: lib + "/WebKit", category: .webData),
            Location(path: lib + "/Cookies", category: .webData),
            Location(path: lib + "/Saved Application State", category: .savedState),
            Location(path: lib + "/Logs", category: .logs),
            Location(path: lib + "/Logs/DiagnosticReports", category: .crashReports, mode: .namePrefix),
            Location(path: lib + "/Application Support/CrashReporter", category: .crashReports, mode: .namePrefix),
            Location(path: lib + "/LaunchAgents", category: .launchItems),
            Location(path: lib + "/Internet Plug-Ins", category: .other),
            Location(path: lib + "/Services", category: .other),
            Location(path: lib + "/PreferencePanes", category: .other),

            Location(path: "/Library/Application Support", category: .appSupport),
            Location(path: "/Library/Preferences", category: .preferences),
            Location(path: "/Library/Caches", category: .caches),
            Location(path: "/Library/Logs", category: .logs),
            Location(path: "/Library/Logs/DiagnosticReports", category: .crashReports, mode: .namePrefix),
            Location(path: "/Library/LaunchAgents", category: .launchItems),
            Location(path: "/Library/LaunchDaemons", category: .launchItems),
            Location(path: "/Library/PrivilegedHelperTools", category: .launchItems),
            Location(path: "/Library/Internet Plug-Ins", category: .other),
            Location(path: "/Library/PreferencePanes", category: .other),
            Location(path: "/private/var/db/receipts", category: .receipts),
        ]
    }

    struct Tokens {
        let bundleIDs: [String]
        let names: Set<String>
        /// Bundle IDs of *other* installed apps that extend ours (com.foo.app.pro) — never match those.
        let excludedBundleIDs: [String]
    }

    static func tokens(for app: InstalledApp, allBundleIDs: [String]) -> Tokens {
        var ids: [String] = []
        var excluded: [String] = []
        if let b = app.bundleID?.lowercased(), b.count >= 5 {
            ids.append(b)
            excluded = allBundleIDs.map { $0.lowercased() }.filter { $0 != b && $0.hasPrefix(b + ".") }
        }
        var names = Set<String>()
        for raw in [app.name, app.executableName, app.bundleName].compactMap({ $0 }) {
            let n = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard n.count >= 3 else { continue }
            names.insert(n)
            names.insert(n.replacingOccurrences(of: " ", with: ""))
        }
        return Tokens(bundleIDs: ids, names: names, excludedBundleIDs: excluded)
    }

    static func matches(_ filename: String, tokens: Tokens, mode: MatchMode) -> Bool {
        let lower = filename.lowercased()
        if tokens.excludedBundleIDs.contains(where: { containsBounded(lower, $0) }) { return false }
        if tokens.bundleIDs.contains(where: { containsBounded(lower, $0) }) { return true }

        let stem = (lower as NSString).deletingPathExtension
        if tokens.names.contains(lower) || tokens.names.contains(stem) { return true }

        if mode == .namePrefix {
            for n in tokens.names where lower.hasPrefix(n + "_") || lower.hasPrefix(n + "-") || lower.hasPrefix(n + ".") {
                return true
            }
        }
        return false
    }

    /// `token` appears in `s` without being glued to other letters/digits on either side.
    static func containsBounded(_ s: String, _ token: String) -> Bool {
        var range = s.startIndex..<s.endIndex
        while let r = s.range(of: token, range: range) {
            let before = r.lowerBound == s.startIndex ? nil : s[s.index(before: r.lowerBound)]
            let after = r.upperBound == s.endIndex ? nil : s[r.upperBound]
            let okBefore = before.map { !($0.isLetter || $0.isNumber) } ?? true
            let okAfter = after.map { !($0.isLetter || $0.isNumber) } ?? true
            if okBefore && okAfter { return true }
            range = r.upperBound..<s.endIndex
        }
        return false
    }

    static func find(for app: InstalledApp, allBundleIDs: [String]) -> [RelatedFile] {
        let fm = FileManager.default
        var results: [RelatedFile] = []
        var seen = Set<String>()

        func add(_ url: URL, _ category: FileCategory) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), !path.hasPrefix("/System/") else { return }
            seen.insert(path)
            let parent = url.deletingLastPathComponent().path
            let needsAdmin = !fm.isWritableFile(atPath: parent)
            results.append(RelatedFile(url: url, category: category, size: FileSize.of(url), requiresAdmin: needsAdmin))
        }

        add(app.url, .application)

        let tokens = tokens(for: app, allBundleIDs: allBundleIDs)
        let appPath = app.url.standardizedFileURL.path

        for loc in locations {
            guard let items = try? fm.contentsOfDirectory(atPath: loc.path) else { continue }
            for item in items where matches(item, tokens: tokens, mode: loc.mode) {
                let url = URL(fileURLWithPath: loc.path).appendingPathComponent(item)
                // Never pick up another .app bundle or anything inside the app itself.
                if url.pathExtension.lowercased() == "app" { continue }
                if url.standardizedFileURL.path.hasPrefix(appPath + "/") { continue }
                add(url, loc.category)
            }
        }

        // Vendor sub-folders, e.g. ~/Library/Application Support/Google/Chrome for com.google.Chrome
        let parts = (app.bundleID ?? "").lowercased().split(separator: ".").map(String.init)
        if parts.count >= 3, parts[1].count >= 3, parts[1] != "apple" {
            let vendor = parts[1]
            var vendorNames = tokens.names
            if let product = parts.last, product.count >= 3 { vendorNames.insert(product) }
            let vendorTokens = Tokens(bundleIDs: tokens.bundleIDs, names: vendorNames, excludedBundleIDs: tokens.excludedBundleIDs)
            let vendorCategories: Set<FileCategory> = [.appSupport, .caches, .logs, .preferences]
            for loc in locations where vendorCategories.contains(loc.category) {
                guard let items = try? fm.contentsOfDirectory(atPath: loc.path),
                      let vendorDir = items.first(where: { $0.lowercased() == vendor }) else { continue }
                let base = URL(fileURLWithPath: loc.path).appendingPathComponent(vendorDir)
                guard let children = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
                for child in children where matches(child, tokens: vendorTokens, mode: .standard) {
                    add(base.appendingPathComponent(child), loc.category)
                }
            }
        }

        return results.sorted {
            $0.category != $1.category ? $0.category < $1.category : $0.url.path < $1.url.path
        }
    }
}

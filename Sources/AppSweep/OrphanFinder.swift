import AppKit

/// Finds leftover files whose app is no longer on this Mac.
///
/// It's deliberately conservative. It only considers items named with a reverse-DNS ID
/// (com.vendor.product), skips anything from Apple, and treats an item as owned if *any* app
/// on the Mac shares its vendor (e.g. com.google.* is kept while Chrome is installed).
/// Launch agents and daemons are flagged when the program they run no longer exists.
enum OrphanFinder {
    struct Location {
        let path: String
        let category: FileCategory
        var isLaunchItem = false
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
            Location(path: lib + "/HTTPStorages", category: .webData),
            Location(path: lib + "/WebKit", category: .webData),
            Location(path: lib + "/Cookies", category: .webData),
            Location(path: lib + "/Saved Application State", category: .savedState),
            Location(path: lib + "/Logs", category: .logs),
            Location(path: lib + "/LaunchAgents", category: .launchItems, isLaunchItem: true),
            Location(path: "/Library/LaunchAgents", category: .launchItems, isLaunchItem: true),
            Location(path: "/Library/LaunchDaemons", category: .launchItems, isLaunchItem: true),
            Location(path: "/Library/PrivilegedHelperTools", category: .launchItems),
            Location(path: "/Library/Application Support", category: .appSupport),
            Location(path: "/Library/Caches", category: .caches),
            Location(path: "/private/var/db/receipts", category: .receipts),
        ]
    }

    static let tlds: Set<String> = [
        "com", "org", "net", "io", "co", "de", "uk", "fr", "it", "nl", "se", "ch", "jp", "cn", "ru", "us", "ca",
        "au", "me", "tv", "cc", "app", "dev", "ai", "info", "biz", "eu", "at", "be", "dk", "no", "fi", "pl",
        "es", "pt", "br", "kr", "in", "tw", "hk", "sg", "nz", "ie", "cz", "hu", "gr", "il", "za", "mx", "ar",
        "xyz", "pro", "so", "to", "ly", "is", "sh", "gg", "im", "fm", "am", "ws", "tech", "studio", "games",
    ]

    /// Vendors that ship parts of macOS or common system components — never flagged.
    static let protectedVendors: Set<String> = [
        "com.apple", "org.cups", "com.openssh", "org.openssh", "org.ntp", "edu.mit", "org.openldap",
        "org.ruby-lang", "org.python", "org.swift", "org.llvm", "com.oracle", "org.mozilla.updater",
        "is.workflow",                       // Apple Shortcuts (legacy Workflow IDs)
        // SDKs embedded in many apps — their caches/prefs can't be tied to one app
        "com.firebase", "com.google.firebase", "com.onevcat", "com.crashlytics", "io.sentry",
        "com.microsoft.appcenter", "com.segment", "io.realm", "com.squareup",
    ]

    /// App-group IDs and Team IDs from the code signatures of installed apps.
    static func signingInfo(for apps: [InstalledApp]) -> (groups: Set<String>, teams: Set<String>) {
        var groups = Set<String>()
        var teams = Set<String>()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            proc.arguments = ["-dv", "--entitlements", "-", "--xml", apps[i].url.path]
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            guard (try? proc.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let info = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            proc.waitUntilExit()
            var g: [String] = []
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                g = (plist["com.apple.security.application-groups"] as? [String]) ?? []
            }
            let team = info.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
                .map { String($0.dropFirst("TeamIdentifier=".count)) }
            lock.lock()
            g.forEach { groups.insert($0.lowercased()) }
            if let team, team != "not set" { teams.insert(team.lowercased()) }
            lock.unlock()
        }
        return (groups, teams)
    }

    /// True if an installed app's signature claims this group container / script folder.
    static func isClaimedGroup(_ name: String, groups: Set<String>, teams: Set<String>) -> Bool {
        let lower = name.lowercased()
        if groups.contains(lower) { return true }
        if name.range(of: "^[A-Z0-9]{10}\\.", options: .regularExpression) != nil,
           teams.contains(String(lower.prefix(10))) { return true }
        return false
    }

    // MARK: Known software

    static func knownBundleIDs(installed: [InstalledApp]) -> Set<String> {
        var ids = Set(installed.compactMap { $0.bundleID?.lowercased() })
        var appPaths = Set(installed.map(\.url.path))

        let spotlight = run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"])
        for line in spotlight.split(separator: "\n") where !line.contains("/.Trash/") {
            appPaths.insert(String(line))
        }
        let fm = FileManager.default
        for root in ["/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices",
                     "/Applications/Utilities", "/Library/Application Support"] {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where item.hasSuffix(".app") {
                appPaths.insert(root + "/" + item)
            }
        }

        let nested = ["Contents/PlugIns", "Contents/Library/LoginItems", "Contents/Library/LaunchServices",
                      "Contents/XPCServices", "Contents/Helpers", "Contents/Library/SystemExtensions",
                      "Contents/Library/QuickLook", "Contents/Library/Spotlight", "Wrapper"]
        for path in appPaths {
            if let id = bundleID(at: path) { ids.insert(id) }
            for sub in nested {
                let dir = path + "/" + sub
                for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                    if let id = bundleID(at: dir + "/" + item) { ids.insert(id) }
                    else if sub == "Contents/Library/LaunchServices" { ids.insert(item.lowercased()) }
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier?.lowercased() { ids.insert(id) }
        }
        return ids
    }

    private static func bundleID(at path: String) -> String? {
        for plist in ["/Contents/Info.plist", "/Info.plist"] {
            if let d = NSDictionary(contentsOfFile: path + plist), let id = d["CFBundleIdentifier"] as? String {
                return id.lowercased()
            }
        }
        return nil
    }

    // MARK: Matching

    /// Pulls a reverse-DNS identifier out of a file name, or nil if it isn't one.
    static func rdnsKey(from filename: String) -> String? {
        var s = filename
        if let plus = s.lastIndex(of: "+") { s = String(s[s.index(after: plus)...]) }   // com.apple.WebKit.GPU+com.foo.bar
        if s.range(of: "^[A-Z0-9]{10}\\.", options: .regularExpression) != nil {          // TEAMID.com.foo.bar
            s = String(s.dropFirst(11))
        }
        s = s.lowercased()
        if s.hasPrefix("group.") { s = String(s.dropFirst(6)) }
        for suffix in [".plist", ".savedstate", ".binarycookies", ".bom", ".log"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        let parts = s.split(separator: ".")
        guard parts.count >= 3, tlds.contains(String(parts[0])), parts[1].count >= 2 else { return nil }
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
        return s
    }

    static func vendor(of key: String) -> String {
        key.split(separator: ".").prefix(2).joined(separator: ".")
    }

    static func isOwned(_ key: String, known: Set<String>, vendors: Set<String>) -> Bool {
        let v = vendor(of: key)
        if protectedVendors.contains(v) || protectedVendors.contains(where: { key.hasPrefix($0 + ".") }) { return true }
        if v.hasSuffix(".apple") || key.contains(".apple.") { return true }
        if vendors.contains(v) { return true }
        if known.contains(key) { return true }
        return known.contains { key.hasPrefix($0 + ".") || $0.hasPrefix(key + ".") }
    }

    // MARK: Scan

    static func find(installed: [InstalledApp]) -> [RelatedFile] {
        let fm = FileManager.default
        let known = knownBundleIDs(installed: installed)
        let vendors = Set(known.map { vendor(of: $0) })
        let signing = signingInfo(for: installed)
        var results: [RelatedFile] = []
        var seen = Set<String>()

        func add(_ url: URL, _ category: FileCategory, note: String) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            let needsAdmin = !fm.isWritableFile(atPath: url.deletingLastPathComponent().path)
            results.append(RelatedFile(url: url, category: category, size: FileSize.of(url),
                                       requiresAdmin: needsAdmin, note: note))
        }

        for loc in locations {
            guard let items = try? fm.contentsOfDirectory(atPath: loc.path) else { continue }
            for item in items where !item.hasPrefix(".") {
                let url = URL(fileURLWithPath: loc.path).appendingPathComponent(item)

                if loc.isLaunchItem, item.hasSuffix(".plist") {
                    if let note = launchItemOrphanReason(url, known: known, vendors: vendors) {
                        add(url, loc.category, note: note)
                    }
                    continue
                }

                if isClaimedGroup(item, groups: signing.groups, teams: signing.teams) { continue }
                guard let key = rdnsKey(from: item), !isOwned(key, known: known, vendors: vendors) else { continue }
                let note = loc.category == .receipts
                    ? "Installer record for “\(key)”. The software it installed isn't on this Mac as an app."
                    : "No installed app uses “\(key)”."
                add(url, loc.category, note: note)
            }
        }

        return results.sorted {
            $0.category != $1.category ? $0.category < $1.category : $0.size > $1.size
        }
    }

    /// Returns a reason if a launch agent/daemon belongs to software that's gone, else nil.
    private static func launchItemOrphanReason(_ url: URL, known: Set<String>, vendors: Set<String>) -> String? {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
        let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        if label.lowercased().hasPrefix("com.apple.") { return nil }

        let program = (dict["Program"] as? String) ?? (dict["ProgramArguments"] as? [String])?.first
        if let program, program.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: program)
                ? nil
                : "Starts a program that no longer exists: \(program)"
        }

        var associated: [String] = []
        if let s = dict["AssociatedBundleIdentifiers"] as? String { associated = [s] }
        if let a = dict["AssociatedBundleIdentifiers"] as? [String] { associated = a }
        if !associated.isEmpty {
            let anyOwned = associated.contains { isOwned($0.lowercased(), known: known, vendors: vendors) }
            return anyOwned ? nil : "Belongs to an app that's no longer installed (\(associated.joined(separator: ", ")))."
        }

        if let key = rdnsKey(from: label), !isOwned(key, known: known, vendors: vendors) {
            return "No installed app uses “\(key)”."
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

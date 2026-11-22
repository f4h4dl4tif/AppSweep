import AppKit

enum RemovalMode: Sendable {
    case trash
    case permanent
}

struct RemovalFailure: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let reason: String
}

struct RemovalResult: Sendable {
    var removed: [URL] = []
    var failed: [RemovalFailure] = []
    var blockedByPrivacy: Bool { failed.contains { $0.reason == Uninstaller.privacyReason } }
}

enum Uninstaller {
    static let privacyReason = "macOS blocked this. Turn on Full Disk Access and App Management for AppSweep (toolbar ▸ Permissions)."

    /// Removes everything in one pass. User-owned items go directly; anything that needs root is batched
    /// into a single administrator prompt.
    static func remove(_ files: [RelatedFile], mode: RemovalMode) async -> RemovalResult {
        let adminFirst = files.filter(\.requiresAdmin).map(\.url)
        let direct = files.filter { !$0.requiresAdmin }.map(\.url)

        let (done, retry, errors) = await Task.detached(priority: .userInitiated) {
            removeDirect(direct, mode: mode)
        }.value

        var result = RemovalResult(removed: done)
        let needAdmin = adminFirst + retry
        var adminError: String?
        if !needAdmin.isEmpty {
            adminError = await runPrivileged(needAdmin, mode: mode)
        }
        for url in needAdmin {
            if pathExists(url.path) {
                result.failed.append(RemovalFailure(url: url, reason: explain(adminError ?? errors[url.path])))
            } else {
                result.removed.append(url)
            }
        }
        return result
    }

    // MARK: Direct (no password)

    private static func removeDirect(_ urls: [URL], mode: RemovalMode) -> ([URL], [URL], [String: String]) {
        var removed: [URL] = []
        var retry: [URL] = []
        var errors: [String: String] = [:]
        let fm = FileManager.default
        for url in urls {
            unloadUserLaunchAgent(url)
            do {
                switch mode {
                case .trash: try fm.trashItem(at: url, resultingItemURL: nil)
                case .permanent: try fm.removeItem(at: url)
                }
                removed.append(url)
            } catch {
                if pathExists(url.path) {
                    retry.append(url)
                    errors[url.path] = (error as NSError).localizedDescription
                } else {
                    removed.append(url)
                }
            }
        }
        return (removed, retry, errors)
    }

    private static func unloadUserLaunchAgent(_ url: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard url.deletingLastPathComponent().path == home + "/Library/LaunchAgents" else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(getuid())", url.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: Privileged (one password prompt)

    /// Runs in-process via NSAppleScript, so macOS attributes the privileges to AppSweep and caches the
    /// password for a few minutes. Returns an error message, or nil on success.
    @MainActor
    private static func runPrivileged(_ urls: [URL], mode: RemovalMode) async -> String? {
        let uid = getuid()
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        var used = Set<String>()
        var cmds: [String] = []

        for url in urls {
            let p = url.path
            let parent = url.deletingLastPathComponent().path
            if parent == "/Library/LaunchDaemons" {
                cmds.append("/bin/launchctl bootout system \(q(p)) >/dev/null 2>&1")
            } else if parent.hasSuffix("/Library/LaunchAgents") {
                cmds.append("/bin/launchctl bootout gui/\(uid) \(q(p)) >/dev/null 2>&1")
            }
            switch mode {
            case .permanent:
                cmds.append("/bin/rm -rf \(q(p))")
            case .trash:
                var dest = trash.appendingPathComponent(url.lastPathComponent)
                var n = 2
                while pathExists(dest.path) || used.contains(dest.path) {
                    let base = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    dest = trash.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                    n += 1
                }
                used.insert(dest.path)
                // Hand ownership back to you so emptying the Trash doesn't ask for a password again.
                cmds.append("/bin/mv -f \(q(p)) \(q(dest.path)) && /usr/sbin/chown -R \(uid) \(q(dest.path))")
            }
        }

        let shell = "{ " + cmds.joined(separator: "; ") + "; } 2>&1; exit 0"
        switch await AdminAuth.shared.run(shell, reason: "remove system files belonging to the selected apps") {
        case .cancelled:
            return "You cancelled the administrator prompt."
        case .failed(let message):
            return message
        case .success(let output):
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    private static func explain(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Couldn't be removed." }
        let lower = raw.lowercased()
        if lower.contains("not permitted") || lower.contains("permission") && lower.contains("operation") {
            return privacyReason
        }
        return raw
    }

    // MARK: Quitting

    /// Asks running instances to quit; waits up to ~8 seconds, then force-quits.
    static func quit(_ app: InstalledApp) async {
        let instances = app.runningInstances
        guard !instances.isEmpty else { return }
        instances.forEach { $0.terminate() }
        for _ in 0..<40 {
            if instances.allSatisfy({ $0.isTerminated }) { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        instances.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

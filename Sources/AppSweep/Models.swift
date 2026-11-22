import AppKit

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let executableName: String?
    let bundleName: String?
    let isProtected: Bool
    let isAppStore: Bool

    var isRunning: Bool { !runningInstances.isEmpty }

    var runningInstances: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            if let bundleURL = running.bundleURL, bundleURL.standardizedFileURL == url.standardizedFileURL { return true }
            if let bundleID, let other = running.bundleIdentifier, other == bundleID { return true }
            return false
        }
    }
}

enum FileCategory: Int, CaseIterable, Comparable, Sendable {
    case application
    case launchItems
    case appSupport
    case preferences
    case containers
    case caches
    case webData
    case savedState
    case logs
    case crashReports
    case receipts
    case other

    static func < (lhs: FileCategory, rhs: FileCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .application: return "Application"
        case .launchItems: return "Launch Agents, Daemons & Helpers"
        case .appSupport: return "Application Support"
        case .preferences: return "Preferences"
        case .containers: return "Containers"
        case .caches: return "Caches"
        case .webData: return "Cookies & Web Data"
        case .savedState: return "Saved Application State"
        case .logs: return "Logs"
        case .crashReports: return "Crash Reports"
        case .receipts: return "Installer Receipts"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .application: return "app.dashed"
        case .launchItems: return "bolt.horizontal.circle"
        case .appSupport: return "folder"
        case .preferences: return "slider.horizontal.3"
        case .containers: return "shippingbox"
        case .caches: return "internaldrive"
        case .webData: return "globe"
        case .savedState: return "macwindow.on.rectangle"
        case .logs: return "doc.text"
        case .crashReports: return "exclamationmark.triangle"
        case .receipts: return "doc.plaintext"
        case .other: return "puzzlepiece.extension"
        }
    }
}

struct RelatedFile: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let category: FileCategory
    let size: Int64
    let requiresAdmin: Bool
    /// Why this item was flagged (used for orphans).
    var note: String? = nil

    var name: String { url.lastPathComponent }
    var location: String { url.deletingLastPathComponent().path }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    var id: String { rawValue }
}

enum FileSize {
    static func of(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? v?.fileSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in e {
            if let v = try? child.resourceValues(forKeys: keys) {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            }
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// RAM sizes in the same units Activity Monitor uses (1 GB = 1024³ bytes).
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// lstat-based existence check (doesn't follow symlinks, so broken links still count as present).
func pathExists(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

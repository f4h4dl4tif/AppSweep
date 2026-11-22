import AppKit
import Darwin

/// A snapshot of system memory, using the same breakdown as Activity Monitor.
struct MemoryStats: Sendable {
    enum Pressure: Sendable { case normal, warning, critical }

    var total: UInt64 = 0
    var free: UInt64 = 0
    var appMemory: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File-backed and purgeable pages: memory macOS can drop at once when it's needed.
    var cachedFiles: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Pressure = .normal

    var used: UInt64 { appMemory + wired + compressed }
    var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    static func current() -> MemoryStats {
        var s = MemoryStats()
        s.total = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let anonymous = UInt64(info.internal_page_count)
            let purgeable = UInt64(info.purgeable_count)
            s.appMemory = (anonymous > purgeable ? anonymous - purgeable : 0) * page
            s.wired = UInt64(info.wire_count) * page
            s.compressed = UInt64(info.compressor_page_count) * page
            s.cachedFiles = (UInt64(info.external_page_count) + purgeable) * page
            s.free = UInt64(info.free_count) * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { s.swapUsed = swap.xsu_used }

        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            s.pressure = level >= 4 ? .critical : (level >= 2 ? .warning : .normal)
        }
        return s
    }
}

/// One running app and the memory it uses, including its helper processes
/// (e.g. Chrome's renderers live inside Chrome.app, so they count toward Chrome).
struct AppMemoryUsage: Identifiable, Sendable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundlePath: String
    let bytes: UInt64
    let processCount: Int
}

enum ProcessMemory {
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func allPIDs() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, got)))).filter { $0 > 0 }
    }

    /// Memory per visible app, biggest first.
    static func topApps(_ apps: [(pid: pid_t, name: String, bundlePath: String)]) -> [AppMemoryUsage] {
        var totals = [String: (bytes: UInt64, count: Int)]()
        let prefixes = apps.map { $0.bundlePath + "/" }
        for pid in allPIDs() {
            guard let path = path(of: pid),
                  let i = prefixes.firstIndex(where: { path.hasPrefix($0) }),
                  let bytes = footprint(of: pid) else { continue }
            let key = apps[i].bundlePath
            totals[key, default: (0, 0)].bytes += bytes
            totals[key, default: (0, 0)].count += 1
        }
        return apps.compactMap { app in
            guard let t = totals[app.bundlePath] else { return nil }
            return AppMemoryUsage(pid: app.pid, name: app.name, bundlePath: app.bundlePath, bytes: t.bytes, processCount: t.count)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    struct FreeResult {
        let freed: Int64
        let message: String
    }

    @Published var stats = MemoryStats.current()
    @Published var history: [Double] = []
    @Published var topApps: [AppMemoryUsage] = []
    @Published var isFreeing = false
    @Published var lastResult: FreeResult?

    private var timer: Timer?
    private var refreshing = false

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .compactMap { app -> (pid_t, String, String)? in
                guard let url = app.bundleURL else { return nil }
                return (app.processIdentifier, app.localizedName ?? url.deletingPathExtension().lastPathComponent, url.path)
            }
        Task {
            let (s, top) = await Task.detached(priority: .utility) {
                (MemoryStats.current(), ProcessMemory.topApps(apps.map { (pid: $0.0, name: $0.1, bundlePath: $0.2) }))
            }.value
            stats = s
            topApps = top
            history.append(s.usedFraction)
            if history.count > 90 { history.removeFirst(history.count - 90) }
            refreshing = false
        }
    }

    /// Runs macOS's `purge`, which drops cached file data from RAM. Needs an administrator password.
    func freeUpMemory() async {
        isFreeing = true
        lastResult = nil
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the UI show progress before the password prompt
        let before = MemoryStats.current()

        switch await AdminAuth.shared.run("/usr/sbin/purge", reason: "free up cached memory") {
        case .cancelled:
            lastResult = FreeResult(freed: 0, message: "Cancelled. Memory wasn't changed.")
        case .failed(let message):
            lastResult = FreeResult(freed: 0, message: message)
        case .success:
            try? await Task.sleep(nanoseconds: 500_000_000)
            let after = MemoryStats.current()
            let freed = Int64(after.free) - Int64(before.free)
            lastResult = FreeResult(freed: max(0, freed), message: freed > 0
                ? "Freed \(FileSize.memory(UInt64(freed))) of cached memory."
                : "Done. There was little cached memory to free.")
        }
        isFreeing = false
        refresh()
    }

    func quit(_ app: AppMemoryUsage) {
        NSRunningApplication(processIdentifier: app.pid)?.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            refresh()
        }
    }
}

import AppKit
import Combine
import SwiftUI

/// Tracks the macOS privacy permissions AppSweep needs. macOS doesn't let any app grant these to itself —
/// the user flips them once in System Settings, and AppSweep detects the change.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published var fullDiskAccess = false
    /// nil = can't tell yet (we can only read the permission database once Full Disk Access is on).
    @Published var appManagement: Bool?
    @Published var showSheet = false
    @Published var dontRemind: Bool = UserDefaults.standard.bool(forKey: "dontRemindPermissions") {
        didSet { UserDefaults.standard.set(dontRemind, forKey: "dontRemindPermissions") }
    }

    let bundleID = Bundle.main.bundleIdentifier ?? "local.appsweep.AppSweep"
    var allGranted: Bool { fullDiskAccess && appManagement == true }
    var isInApplicationsFolder: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// `probeAppManagement` is false for the frequent timer refresh: each failed App Management test makes
    /// macOS post a "prevented from modifying apps" notice, so that test only runs at launch, when AppSweep
    /// becomes active again, and when the permissions screen opens.
    func refresh(probeAppManagement: Bool = true) {
        let fda = Self.checkFullDiskAccess()
        if fda != fullDiskAccess { fullDiskAccess = fda }
        guard probeAppManagement, appManagement != true else { return }
        let am = Self.probeAppManagement()
        if am != appManagement { appManagement = am }
    }

    func promptIfNeeded() {
        refresh()
        if DebugSnapshot.directory != nil { return }
        if !allGranted && !dontRemind { showSheet = true }
    }

    // MARK: Checks

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func checkFullDiskAccess() -> Bool {
        let probes = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
        for p in probes {
            let fd = Darwin.open(p, O_RDONLY)
            if fd >= 0 { Darwin.close(fd); return true }
        }
        return false
    }

    /// Tests App Management directly. macOS doesn't expose this permission through any API, and the
    /// database it lives in is locked even against Full Disk Access, so AppSweep creates and immediately
    /// deletes an empty marker file inside an app you own. macOS blocks that with EPERM unless
    /// App Management is on. Returns nil if there's no suitable app to test with.
    nonisolated static func probeAppManagement() -> Bool? {
        let fm = FileManager.default
        let me = Bundle.main.bundleURL.standardizedFileURL.path
        let uid = getuid()
        let candidates = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasSuffix(".app") }
            .map { "/Applications/" + $0 }
            .filter { path in
                guard path != me, !AppScanner.isSystemProtected(URL(fileURLWithPath: path)) else { return false }
                var st = stat()
                return lstat(path + "/Contents", &st) == 0 && st.st_uid == uid && (st.st_mode & S_IFMT) == S_IFDIR
            }
        for app in candidates.prefix(3) {
            let probe = app + "/Contents/.appsweep-permission-check-\(getpid())"
            let fd = Darwin.open(probe, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if fd >= 0 {
                Darwin.close(fd)
                unlink(probe)
                return true
            }
            if errno == EPERM { return false }
            // EACCES or anything else: ordinary file permissions got in the way. Try another app.
        }
        return nil
    }

    // MARK: Actions

    func openFullDiskAccessSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func openAppManagementSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Starts a tiny helper that waits for this process to exit, then reopens AppSweep, and quits.
    func relaunch(at path: String = Bundle.main.bundlePath) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path, String(pid)]
        // Don't pass developer/debug settings on to the relaunched copy.
        proc.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("APPSWEEP_") }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }
        AppDelegate.forceQuit()
    }

    /// Copies AppSweep into /Applications so permissions stick to a stable location, then relaunches from there.
    func installToApplications() {
        let dest = "/Applications/AppSweep.app"
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest) { try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: nil) }
            try fm.copyItem(atPath: Bundle.main.bundlePath, toPath: dest)
            relaunch(at: dest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't copy AppSweep to Applications"
            alert.informativeText = error.localizedDescription + "\n\nDrag AppSweep.app into your Applications folder in Finder instead."
            alert.runModal()
        }
    }

    private func openURL(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

struct PermissionsView: View {
    @ObservedObject var permissions = Permissions.shared
    @Environment(\.dismiss) private var dismiss
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Give AppSweep access once").font(.title2.bold())
                    Text("macOS only lets you grant these yourself. Switch them on once and AppSweep can remove apps and their files completely.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !permissions.isInApplicationsFolder {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("AppSweep isn't in your Applications folder. Move it there first so permissions stay put.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Move to Applications") { permissions.installToApplications() }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(spacing: 0) {
                PermissionRow(
                    step: 1,
                    title: "Full Disk Access",
                    detail: "Lets AppSweep see and delete app data in protected folders like Containers and Group Containers.",
                    status: permissions.fullDiskAccess ? .granted : .missing,
                    action: ("Open Settings", permissions.openFullDiskAccessSettings)
                )
                Divider().padding(.leading, 44)
                PermissionRow(
                    step: 2,
                    title: "App Management",
                    detail: "Lets AppSweep delete apps from the Applications folder, including App Store apps.",
                    status: permissions.appManagement == true ? .granted : (permissions.appManagement == nil ? .unknown : .missing),
                    action: ("Open Settings", permissions.openAppManagementSettings)
                )
                Divider().padding(.leading, 44)
                AdminAccessRow()
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("How to turn them on").font(.headline)
                Text("In System Settings, click **+** under the list, choose **AppSweep** from Applications, and switch it **on**. If AppSweep is already listed, just switch it on. When both are on, click **Relaunch**.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle("Don't remind me at launch", isOn: $permissions.dontRemind)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Show AppSweep in Finder") { permissions.revealInFinder() }
                Button("Relaunch") { permissions.relaunch() }
                Button(permissions.allGranted ? "Done" : "Continue Anyway") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { permissions.refresh() }
        .onReceive(timer) { _ in permissions.refresh(probeAppManagement: false) }
    }
}

private struct PermissionRow: View {
    enum Status { case granted, missing, unknown, info }
    let step: Int
    let title: String
    let detail: String
    let status: Status
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step)")
                .font(.headline)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.blue.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    statusView.font(.caption.weight(.semibold))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action, status != .granted {
                Button(action.0, action: action.1)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .granted: Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Label("Off", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Label("Couldn't check", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .info: Label("Asked when needed", systemImage: "key.fill").foregroundStyle(.secondary)
        }
    }
}


/// Step 3 of the permissions screen: Touch ID (when the Mac has it) or the standard password prompt.
private struct AdminAccessRow: View {
    @ObservedObject var auth = AdminAuth.shared
    @ObservedObject var bridge = MessageBridge.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("3")
                .font(.headline)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.blue.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(auth.touchIDAvailable ? "Administrator access: Touch ID" : "Administrator password").font(.headline)
                    status.font(.caption.weight(.semibold))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let msg = bridge.message {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if auth.touchIDAvailable {
                if auth.touchIDEnabled {
                    Button("Turn Off") {
                        auth.disableTouchID()
                        bridge.message = "Touch ID is off. AppSweep will use the standard password prompt."
                    }
                } else {
                    Button("Turn On") {
                        Task { bridge.message = await auth.enableTouchID() }
                    }
                }
            }
        }
        .padding(12)
        .onAppear { auth.refresh() }
    }

    private var detail: String {
        if !auth.touchIDAvailable {
            return "System-owned items (App Store apps, launch daemons, helper tools) and Free Up Memory need your password. macOS asks with its standard prompt."
        }
        return auth.touchIDEnabled
            ? "Admin tasks ask for your fingerprint. Choose “Enter Password” in the Touch ID prompt to type your password instead."
            : "Use your fingerprint instead of typing your password. You enter it once and it's kept in your Keychain, readable only by AppSweep."
    }

    @ViewBuilder private var status: some View {
        if auth.touchIDAvailable && auth.touchIDEnabled {
            Label("On", systemImage: "touchid").foregroundStyle(.green)
        } else if auth.touchIDAvailable {
            Label("Off", systemImage: "touchid").foregroundStyle(.secondary)
        } else {
            Label("Asked when needed", systemImage: "key.fill").foregroundStyle(.secondary)
        }
    }
}

@MainActor
private final class MessageBridge: ObservableObject {
    static let shared = MessageBridge()
    @Published var message: String?
}

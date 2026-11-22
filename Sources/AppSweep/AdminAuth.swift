import AppKit
import LocalAuthentication
import Security

/// Runs shell commands as administrator, preferring Touch ID.
///
/// macOS still needs the real password to run anything as root; a fingerprint only proves who you are.
/// So with Touch ID on, AppSweep keeps your password in your login Keychain (readable only by AppSweep)
/// and releases it only after a successful Touch ID check. "Enter Password", or a Mac without Touch ID,
/// falls back to the standard macOS administrator prompt.
@MainActor
final class AdminAuth: ObservableObject {
    static let shared = AdminAuth()

    enum Outcome {
        case success(output: String)
        case cancelled
        case failed(String)
    }

    @Published private(set) var touchIDAvailable = false
    @Published private(set) var touchIDEnabled = false

    private let service = "local.appsweep.AppSweep.admin"
    private var account: String { NSUserName() }

    init() { refresh() }

    func refresh() {
        let ctx = LAContext()
        var err: NSError?
        touchIDAvailable = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            && ctx.biometryType == .touchID
        touchIDEnabled = touchIDAvailable && readPassword() != nil
    }

    // MARK: Running commands

    /// `reason` completes the sentence "AppSweep is trying to …" in the Touch ID prompt.
    func run(_ shell: String, reason: String) async -> Outcome {
        refresh()
        if touchIDAvailable {
            if touchIDEnabled {
                switch await evaluateTouchID(reason: reason) {
                case .ok:
                    if let password = readPassword() {
                        let outcome = execute(shell, password: password)
                        if case .failed(let msg) = outcome, isWrongPassword(msg) {
                            // Saved password is out of date (e.g. you changed it). Forget it and ask again.
                            deletePassword()
                            refresh()
                            return await askAndRun(shell, wrongBefore: true)
                        }
                        return outcome
                    }
                case .usePassword:
                    return execute(shell, password: nil)
                case .cancelled:
                    return .cancelled
                }
            } else {
                return await askAndRun(shell, wrongBefore: false)
            }
        }
        return execute(shell, password: nil)
    }

    /// First use on a Touch ID Mac: ask once, offer to remember it for Touch ID.
    private func askAndRun(_ shell: String, wrongBefore: Bool) async -> Outcome {
        var wrong = wrongBefore
        while true {
            guard let (password, remember) = promptForPassword(wrong: wrong) else { return .cancelled }
            let outcome = execute(shell, password: password)
            if case .failed(let msg) = outcome, isWrongPassword(msg) {
                wrong = true
                continue
            }
            if case .success = outcome, remember {
                savePassword(password)
                refresh()
            }
            return outcome
        }
    }

    /// Runs via in-process AppleScript so macOS attributes the privileges to AppSweep.
    /// With `password` nil, macOS shows its own administrator prompt.
    private func execute(_ shell: String, password: String?) -> Outcome {
        var source = "do shell script \"\(escape(shell))\""
        if let password {
            source += " user name \"\(escape(account))\" password \"\(escape(password))\""
        }
        source += " with administrator privileges"
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
            return .failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "The administrator command failed.")
        }
        return .success(output: result?.stringValue ?? "")
    }

    private func isWrongPassword(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("user name or password was incorrect") || m.contains("password was incorrect")
    }

    // MARK: Touch ID

    private enum TouchIDResult { case ok, usePassword, cancelled }

    private func evaluateTouchID(reason: String) async -> TouchIDResult {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Password"
        ctx.localizedCancelTitle = "Cancel"
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return .ok
        } catch let error as LAError {
            switch error.code {
            case .userFallback, .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
                return .usePassword
            default:
                return .cancelled
            }
        } catch {
            return .cancelled
        }
    }

    /// Turns Touch ID on from Settings: confirms the password works, then stores it.
    func enableTouchID() async -> String? {
        var wrong = false
        while true {
            guard let (password, _) = promptForPassword(wrong: wrong, forSetup: true) else { return nil }
            switch execute("/usr/bin/true", password: password) {
            case .success:
                savePassword(password)
                refresh()
                return "Touch ID is on for administrator tasks."
            case .failed(let msg) where isWrongPassword(msg):
                wrong = true
            case .failed(let msg):
                return msg
            case .cancelled:
                return nil
            }
        }
    }

    func disableTouchID() {
        deletePassword()
        refresh()
    }

    // MARK: Password dialog

    private func promptForPassword(wrong: Bool, forSetup: Bool = false) -> (String, Bool)? {
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        alert.messageText = forSetup ? "Turn On Touch ID for AppSweep" : "AppSweep needs your administrator password"
        alert.informativeText = (wrong ? "That password was incorrect. Try again.\n\n" : "")
            + "Enter the password for “\(account)”. AppSweep keeps it in your Keychain, where only AppSweep can read it, and uses it only after you confirm with Touch ID."
        alert.addButton(withTitle: forSetup ? "Turn On" : "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        field.placeholderString = "Password"
        let remember = NSButton(checkboxWithTitle: "Use Touch ID next time", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        remember.state = .on
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: forSetup ? 54 : 56))
        box.addSubview(field)
        if !forSetup { box.addSubview(remember) } else { field.frame.origin.y = 15 }
        alert.accessoryView = box
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return (field.stringValue, forSetup || remember.state == .on)
    }

    // MARK: Keychain (login keychain; access limited to AppSweep's signature)

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readPassword() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func savePassword(_ password: String) {
        deletePassword()
        var query = baseQuery
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrLabel as String] = "AppSweep administrator access"
        query[kSecAttrDescription as String] = "Used by AppSweep after Touch ID"
        SecItemAdd(query as CFDictionary, nil)
    }

    private func deletePassword() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

# AppSweep

A native macOS app uninstaller (SwiftUI). It lists every app in `/Applications` and `~/Applications`, and when you pick one it finds every related file on your Mac. You choose which files to remove.

## Build & run

```bash
./build.sh
open build/AppSweep.app
```

To install: `cp -R build/AppSweep.app /Applications/`

## How it works

- **App list**: icon, version, size, search, and sorting by name or size. Badges show App Store, running, and macOS-protected apps.
- **Related files**: searches about 30 locations, including Application Support, Preferences, Containers, Group Containers, Caches (also `/var/folders`), HTTPStorages/WebKit/Cookies, Saved State, Logs, Crash Reports, LaunchAgents/LaunchDaemons, PrivilegedHelperTools, plug-ins, and installer receipts. Files match on the bundle ID (with word boundaries), the app or executable name, and vendor folders such as `Application Support/Google/Chrome`.
- **Removal**: choose **Move to Trash** (restorable) or **Delete Permanently** each time. Everything that needs root (🔒: App Store apps, launch daemons, helper tools, receipts) goes into **one** administrator password prompt per cleanup. Launch agents and daemons are unloaded before removal, and running apps are quit first (force-quit after 8 seconds).
- **Orphan Files** (sidebar toggle): leftovers from apps that are no longer installed. Only reverse-DNS-named items are considered, Apple and shared-SDK items are skipped, and anything claimed by an installed app (by bundle ID, vendor, app group or team ID in its signature) is kept. Launch items whose program no longer exists are flagged too. All items start ticked; untick anything you want to keep.

- **Memory** (sidebar ▸ Cleanup): live RAM breakdown matching Activity Monitor (app memory, wired, compressed, cached files, free, swap, memory pressure), a 3-minute usage graph, and the apps using the most memory, with their helper processes included and a Quit button for each. **Free Up Memory** runs macOS's `purge` (admin password) to drop cached file data from RAM and reports how much was freed.

## Permissions (one time)

macOS doesn't let apps grant themselves privacy permissions. On first launch AppSweep shows a setup screen with buttons that open the right System Settings pages:

1. **Full Disk Access**: needed to see and delete sandboxed app containers.
2. **App Management**: needed to delete apps from /Applications, especially root-owned App Store apps.
3. **Administrator access**: needed for system-owned items and Free Up Memory. On Macs with **Touch ID**, you enter your password once (with "Use Touch ID next time" ticked) and it's stored in your login Keychain, readable only by AppSweep. After that, admin tasks ask for your fingerprint, and **Enter Password** in that prompt brings up the standard macOS password dialog. Turn this on or off in the permissions screen (toolbar shield). Macs without Touch ID use the standard prompt.

Run AppSweep from `/Applications` (the setup screen offers to move it). `build.sh` signs AppSweep with a local self-signed certificate ("AppSweep Local Signing"), stored in `signing/appsweep.keychain-db` rather than your login keychain. Because the signature identity stays the same, permissions survive rebuilds. If you delete the `signing/` folder, builds fall back to ad-hoc signing and permissions reset each time.

## Tips

- Use **Select ▸ Leftovers Only** to clear an app's caches and settings without removing the app itself.

## Installer package for other Macs

```bash
./package.sh
```

This creates `dist/AppSweep-<version>.pkg`, a standard macOS installer that puts AppSweep in `/Applications`. The app inside is **universal** (Apple Silicon and Intel) and needs **macOS 14 Sonoma or later**.

## DMG for Apple Silicon

```bash
./dmg.sh
```

This creates `dist/AppSweep-<version>-AppleSilicon.dmg`, containing AppSweep.app, a shortcut to Applications to drag it onto, and `How to Install.txt`. The app is arm64 only and needs macOS 14 or later.

## Opening on another Mac (Gatekeeper)

AppSweep isn't notarized by Apple, so on another Mac macOS says it *"could not verify … is free of malware"*. To get past it:

1. Click **Done** in the warning. Don't move the file to the Bin.
2. Go to **System Settings ▸ Privacy & Security**, scroll to **Security**, and click **Open Anyway**. Enter your password, then click **Open Anyway** again.

Right-click ▸ Open no longer skips this on macOS 15 and later. Alternatively, in Terminal: `xattr -dr com.apple.quarantine /Applications/AppSweep.app` (or the path to the .pkg/.dmg). The only way to remove the warning for everyone is to sign and notarize with a paid Apple Developer ID.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var catalog: AppCatalog
    @ObservedObject var permissions = Permissions.shared

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            if catalog.showingMemory {
                MemoryView()
            } else if catalog.showingOrphans {
                OrphanView(model: catalog.orphans)
            } else if let app = catalog.selectedApp {
                AppDetailView(app: app)
                    .id(app.id)
            } else {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "trash.square",
                    description: Text("Pick an app on the left to see every file it has on your Mac, or open Orphan Files to clean up leftovers from apps you already removed.")
                )
            }
        }
        .searchable(text: $catalog.searchText, placement: .sidebar,
                    prompt: catalog.showingOrphans ? "Search orphan files" : "Search apps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    permissions.showSheet = true
                } label: {
                    Label("Permissions", systemImage: permissions.allGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                }
                .foregroundStyle(permissions.allGranted ? .green : .orange)
                .help(permissions.allGranted ? "All permissions granted" : "Some permissions are off. Click to set up.")
            }
        }
        .sheet(isPresented: $permissions.showSheet) { PermissionsView() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .task {
            permissions.promptIfNeeded()
            if catalog.apps.isEmpty { await catalog.reload() }
        }
    }
}

/// One stable list: "Orphan Files" pinned at the top, every installed app below it.
struct SidebarView: View {
    @EnvironmentObject var catalog: AppCatalog

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $catalog.selectedAppID) {
                Section("Cleanup") {
                    MemorySidebarRow()
                        .tag(AppCatalog.memoryID)
                    OrphanSidebarRow(model: catalog.orphans)
                        .tag(AppCatalog.orphansID)
                }
                Section("Applications") {
                    ForEach(catalog.visibleApps) { app in
                        AppRow(app: app, size: catalog.sizes[app.id])
                            .tag(app.id)
                    }
                    if catalog.isLoading && catalog.apps.isEmpty {
                        HStack { Spacer(); ProgressView("Scanning Applications…"); Spacer() }
                            .padding(.vertical, 20)
                    } else if !catalog.searchText.isEmpty && catalog.visibleApps.isEmpty {
                        Text("No apps match “\(catalog.searchText)”")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Text("\(catalog.apps.count) apps")
                Spacer()
                Text(FileSize.format(catalog.totalSize))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort", selection: $catalog.sort) {
                    ForEach(SortOrder.allCases) { Text("By \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort apps")

                Button {
                    Task { await catalog.reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Rescan installed apps (⌘R)")
                .disabled(catalog.isLoading)
            }
        }
    }
}

struct OrphanSidebarRow: View {
    @ObservedObject var model: OrphanModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Orphan Files")
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.mini)
            } else if model.hasScanned {
                Text(FileSize.format(model.totalSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        if model.isScanning { return "Scanning…" }
        if !model.hasScanned { return "Leftovers from removed apps" }
        return "\(model.files.count) item\(model.files.count == 1 ? "" : "s") found"
    }
}

struct AppRow: View {
    let app: InstalledApp
    let size: Int64?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.shared.icon(for: app.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                HStack(spacing: 4) {
                    if let v = app.version { Text(v) }
                    if app.isAppStore { Image(systemName: "bag").help("Mac App Store") }
                    if app.isProtected { Image(systemName: "lock.fill").help("Protected by macOS") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let size {
                Text(FileSize.format(size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }
}

import SwiftUI

// MARK: - App detail

struct AppDetailView: View {
    @EnvironmentObject var catalog: AppCatalog
    @StateObject private var model: AppDetailModel

    init(app: InstalledApp) {
        _model = StateObject(wrappedValue: AppDetailModel(app: app))
    }

    var body: some View {
        CleanupView(
            model: model,
            removeLabel: model.includesApp ? "Uninstall" : "Remove Selected",
            emptyTitle: "No files found",
            header: { header }
        )
        .task {
            model.allBundleIDs = catalog.allBundleIDs
            let catalog = catalog, app = model.app
            model.onAppRemoved = { catalog.removeFromList(app) }
            await model.scan()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: IconCache.shared.icon(for: model.app.url.path))
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.app.name).font(.title2.bold())
                    if model.app.isRunning { Badge(text: "Running", color: .green) }
                    if model.app.isAppStore { Badge(text: "App Store", color: .blue) }
                    if model.app.isProtected { Badge(text: "Protected by macOS", color: .gray) }
                }
                Text([model.app.version.map { "Version \($0)" }, model.app.bundleID].compactMap { $0 }.joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(model.app.url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(FileSize.format(model.totalSize)).font(.title3.monospacedDigit().bold())
                Text("\(model.files.count) items found").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

// MARK: - Orphans

struct OrphanView: View {
    @ObservedObject var model: OrphanModel

    var body: some View {
        CleanupView(
            model: model,
            removeLabel: "Remove Selected",
            emptyTitle: "No orphan files found",
            header: { header }
        )
        .task { if !model.hasScanned && !model.isScanning { await model.scan() } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "questionmark.folder.fill")
                .font(.system(size: 52))
                .foregroundStyle(.orange)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Orphan Files").font(.title2.bold())
                Text("Leftovers from apps that are no longer installed. Everything is ticked to start. Untick anything you want to keep, then click Remove Selected.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Picker("Show", selection: $model.categoryFilter) {
                    Text("All categories (\(model.files.count))").tag(Optional("all"))
                    ForEach(model.allGroups, id: \.0) { category, files in
                        Text("\(category.title) (\(files.count))").tag(Optional(category.title))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(FileSize.format(model.totalSize)).font(.title3.monospacedDigit().bold())
                Text("\(model.files.count) items").font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
            }
        }
        .padding(20)
    }
}

// MARK: - Shared list + removal UI

struct CleanupView<Header: View>: View {
    @ObservedObject var model: CleanupModel
    @ObservedObject var permissions = Permissions.shared
    @AppStorage(GlassTheme.key) private var glassTheme = false
    let removeLabel: String
    let emptyTitle: String
    let header: Header

    init(model: CleanupModel, removeLabel: String, emptyTitle: String,
         @ViewBuilder header: () -> Header) {
        self.model = model
        self.removeLabel = removeLabel
        self.emptyTitle = emptyTitle
        self.header = header()
    }

    var body: some View {
        fileList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) {
                header.sweepBar(glass: glassTheme, edge: .top)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer.sweepBar(glass: glassTheme, edge: .bottom)
            }
        .alert(alertTitle, isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { a in
            alertActions(a)
        } message: { a in
            Text(alertMessage(a))
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if model.isScanning {
            VStack { Spacer(); ProgressView("Scanning…"); Spacer() }.frame(maxWidth: .infinity)
        } else if model.visibleFiles.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "checkmark.seal",
                                   description: Text(model.filterText.isEmpty ? "Everything looks clean." : "Nothing matches your search."))
        } else {
            List {
                ForEach(model.groups, id: \.0) { category, files in
                    Section {
                        ForEach(files) { file in
                            FileRow(file: file, isOn: model.binding(for: file), disabled: model.isLocked(file))
                        }
                    } header: {
                        HStack {
                            Toggle(isOn: model.binding(for: files)) {
                                Label(category.title, systemImage: category.symbol)
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            Text("\(files.count) · " + FileSize.format(files.reduce(0) { $0 + $1.size }))
                                .monospacedDigit()
                        }
                        .font(.headline)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Picker("Select:", selection: Binding(get: { model.currentPreset }, set: { model.applyPreset($0) })) {
                ForEach(model.selectionPresets.map(\.title), id: \.self) { Text($0).tag($0) }
                if model.currentPreset == CleanupModel.customPreset {
                    Divider()
                    Text(CleanupModel.customPreset).tag(CleanupModel.customPreset)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Choose which items are ticked")
            if !permissions.allGranted {
                Button {
                    permissions.showSheet = true
                } label: {
                    Label("Some permissions are off", systemImage: "exclamationmark.shield")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(model.selected.count) selected · \(FileSize.format(model.selectedSize))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(role: .destructive) {
                model.alert = .confirm
            } label: {
                if model.isRemoving {
                    ProgressView().controlSize(.small)
                } else {
                    Label(removeLabel, systemImage: "trash")
                }
            }
            .sweepProminentButton(glass: glassTheme)
            .tint(.red)
            .controlSize(.large)
            .disabled(model.selected.isEmpty || model.isScanning || model.isRemoving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Alerts

    private var alertTitle: String {
        switch model.alert {
        case .confirm:
            return "Remove \(model.selected.count) item\(model.selected.count == 1 ? "" : "s") (\(FileSize.format(model.selectedSize)))?"
        case .done(let r, _):
            return r.failed.isEmpty ? "All done" : "\(r.failed.count) item\(r.failed.count == 1 ? "" : "s") couldn't be removed"
        case nil:
            return ""
        }
    }

    private func alertMessage(_ a: CleanupAlert) -> String {
        switch a {
        case .confirm:
            var s = ""
            if let app = model.appToQuit, app.isRunning, model.selected.contains(app.id) {
                s += "\(app.name) is running and will be quit first.\n\n"
            }
            if model.selectionNeedsAdmin {
                s += "Some items belong to the system, so macOS will ask for your administrator password once.\n\n"
            }
            s += "Move to Trash lets you restore items until you empty the Trash. Delete Permanently removes them right away and can't be undone."
            return s
        case .done(let r, let mode):
            var s = "\(r.removed.count) item\(r.removed.count == 1 ? "" : "s") "
                + (mode == .trash ? "moved to the Trash." : "permanently deleted.")
            if !r.failed.isEmpty {
                s += "\n\nNot removed:\n" + r.failed.prefix(5).map { "• \($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
                if r.failed.count > 5 { s += "\n…and \(r.failed.count - 5) more." }
            }
            return s
        }
    }

    @ViewBuilder
    private func alertActions(_ a: CleanupAlert) -> some View {
        switch a {
        case .confirm:
            Button("Move to Trash") { Task { await model.remove(mode: .trash) } }
            Button("Delete Permanently", role: .destructive) { Task { await model.remove(mode: .permanent) } }
            Button("Cancel", role: .cancel) {}
        case .done(let r, _):
            if r.blockedByPrivacy {
                Button("Fix Permissions") {
                    Task {
                        await model.afterRemoval()
                        permissions.showSheet = true
                    }
                }
            }
            Button("OK") { Task { await model.afterRemoval() } }
        }
    }
}

struct FileRow: View {
    let file: RelatedFile
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(disabled)
            Image(nsImage: IconCache.shared.icon(for: file.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if file.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Needs your administrator password to remove")
                    }
                }
                Text(file.location)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(file.url.path)
                if let note = file.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(FileSize.format(file.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if !disabled { isOn.toggle() } }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

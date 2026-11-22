import SwiftUI

@MainActor
final class AppCatalog: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var sizes: [String: Int64] = [:]
    @Published var isLoading = false
    @Published var searchText = "" { didSet { orphans.filterText = searchText } }
    @Published var sort: SortOrder = .name
    @Published var selectedAppID: String? {
        didSet {
            if showingOrphans && !orphans.hasScanned && !orphans.isScanning { Task { await orphans.scan() } }
        }
    }

    static let orphansID = "__orphan_files__"
    static let memoryID = "__memory__"
    var showingOrphans: Bool { selectedAppID == AppCatalog.orphansID }
    var showingMemory: Bool { selectedAppID == AppCatalog.memoryID }

    let orphans = OrphanModel()
    static weak var current: AppCatalog?
    init() { AppCatalog.current = self }
    private var sizeTask: Task<Void, Never>?

    var allBundleIDs: [String] { apps.compactMap(\.bundleID) }

    var selectedApp: InstalledApp? {
        guard let id = selectedAppID else { return nil }
        return apps.first { $0.id == id }
    }

    var visibleApps: [InstalledApp] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        var list = q.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(q) || ($0.bundleID?.localizedCaseInsensitiveContains(q) ?? false)
        }
        if sort == .size {
            list.sort { (sizes[$0.id] ?? -1) > (sizes[$1.id] ?? -1) }
        }
        return list
    }

    var totalSize: Int64 { sizes.values.reduce(0, +) }

    func reload() async {
        isLoading = true
        let list = await Task.detached(priority: .userInitiated) { AppScanner.scan() }.value
        apps = list
        orphans.installed = list
        isLoading = false
        if let id = selectedAppID, id != AppCatalog.orphansID, id != AppCatalog.memoryID, !list.contains(where: { $0.id == id }) { selectedAppID = nil }
        computeSizes(for: list)
    }

    private func computeSizes(for list: [InstalledApp]) {
        sizeTask?.cancel()
        let missing = list.filter { sizes[$0.id] == nil }
        sizeTask = Task { [weak self] in
            for app in missing {
                if Task.isCancelled { return }
                let size = await Task.detached(priority: .utility) { FileSize.of(app.url) }.value
                self?.sizes[app.id] = size
            }
        }
    }

    func removeFromList(_ app: InstalledApp) {
        apps.removeAll { $0.id == app.id }
        orphans.installed = apps
        orphans.hasScanned = false
        sizes[app.id] = nil
        if selectedAppID == app.id { selectedAppID = nil }
    }
}

// MARK: - Shared file-selection + removal model

enum CleanupAlert {
    case confirm
    case done(RemovalResult, RemovalMode)
}

@MainActor
class CleanupModel: ObservableObject {
    @Published var files: [RelatedFile] = []
    @Published var selected: Set<String> = []
    @Published var isScanning = false
    @Published var isRemoving = false
    @Published var alert: CleanupAlert?
    @Published var filterText = ""
    @Published var categoryFilter: String? = "all"

    var appToQuit: InstalledApp? { nil }
    func isLocked(_ file: RelatedFile) -> Bool { false }
    func scan() async {}
    func afterRemoval() async { await scan() }

    var visibleFiles: [RelatedFile] {
        var list = files
        if let c = categoryFilter, c != "all" { list = list.filter { $0.category.title == c } }
        let q = filterText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.url.path.localizedCaseInsensitiveContains(q) } }
        return list
    }

    var groups: [(FileCategory, [RelatedFile])] {
        Dictionary(grouping: visibleFiles, by: \.category).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var allGroups: [(FileCategory, [RelatedFile])] {
        Dictionary(grouping: files, by: \.category).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var selectedFiles: [RelatedFile] { files.filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var selectionNeedsAdmin: Bool { selectedFiles.contains(where: \.requiresAdmin) }

    func binding(for file: RelatedFile) -> Binding<Bool> {
        Binding(
            get: { self.selected.contains(file.id) },
            set: { on in if on { self.selected.insert(file.id) } else { self.selected.remove(file.id) } }
        )
    }

    func binding(for group: [RelatedFile]) -> Binding<Bool> {
        let selectable = group.filter { !isLocked($0) }
        return Binding(
            get: { !selectable.isEmpty && selectable.allSatisfy { self.selected.contains($0.id) } },
            set: { on in
                for f in selectable { if on { self.selected.insert(f.id) } else { self.selected.remove(f.id) } }
            }
        )
    }

    func selectAll() { selected = Set(visibleFiles.filter { !isLocked($0) }.map(\.id)) }
    func selectNone() { selected = [] }

    // MARK: Selection presets (the "Select" picker in the footer)

    static let customPreset = "Custom"

    /// Named selections, in menu order. Subclasses add their own.
    var selectionPresets: [(title: String, ids: Set<String>)] {
        [("All Items", Set(visibleFiles.filter { !isLocked($0) }.map(\.id))), ("None", [])]
    }

    /// The preset matching what's ticked right now, or "Custom" after ticking files by hand.
    var currentPreset: String {
        selectionPresets.first { $0.ids == selected }?.title ?? Self.customPreset
    }

    func applyPreset(_ title: String) {
        if let preset = selectionPresets.first(where: { $0.title == title }) { selected = preset.ids }
    }

    func remove(mode: RemovalMode) async {
        isRemoving = true
        let targets = selectedFiles
        if let app = appToQuit, targets.contains(where: { $0.url == app.url }) {
            await Uninstaller.quit(app)
        }
        let result = await Uninstaller.remove(targets, mode: mode)
        isRemoving = false
        alert = .done(result, mode)
    }
}

@MainActor
final class AppDetailModel: CleanupModel {
    let app: InstalledApp
    var allBundleIDs: [String] = []
    var onAppRemoved: (() -> Void)?

    init(app: InstalledApp) { self.app = app }

    override var appToQuit: InstalledApp? { app }
    override func isLocked(_ file: RelatedFile) -> Bool { app.isProtected && file.category == .application }

    var includesApp: Bool { selected.contains(app.id) }

    override func scan() async {
        isScanning = true
        let app = self.app
        let ids = allBundleIDs
        let found = await Task.detached(priority: .userInitiated) {
            LeftoverFinder.find(for: app, allBundleIDs: ids)
        }.value
        files = found
        selected = Set(found.filter { !isLocked($0) }.map(\.id))
        isScanning = false
    }

    override func afterRemoval() async {
        if !pathExists(app.url.path) { onAppRemoved?() } else { await scan() }
    }

    func selectLeftoversOnly() { selected = Set(files.filter { $0.category != .application }.map(\.id)) }

    override var selectionPresets: [(title: String, ids: Set<String>)] {
        [("All Items", Set(files.filter { !isLocked($0) }.map(\.id))),
         ("Leftovers Only (keep the app)", Set(files.filter { $0.category != .application }.map(\.id))),
         ("None", [])]
    }
}

@MainActor
final class OrphanModel: CleanupModel {
    var installed: [InstalledApp] = []
    @Published var hasScanned = false

    override func scan() async {
        isScanning = true
        let apps = installed
        let found = await Task.detached(priority: .userInitiated) { OrphanFinder.find(installed: apps) }.value
        files = found
        selected = Set(found.map(\.id))   // start with All Items ticked
        isScanning = false
        hasScanned = true
        if let c = categoryFilter, c != "all", !found.contains(where: { $0.category.title == c }) { categoryFilter = "all" }
    }
}

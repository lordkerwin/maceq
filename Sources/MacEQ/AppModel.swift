import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var apps: [AudioProcess] = []
    /// In-memory source of truth. Disk is a debounced mirror of this, never the other
    /// way round, so a save that hasn't landed yet can't be read back stale.
    @Published private(set) var profiles: [String: Profile] = [:]
    /// Which app the panel is editing. This no longer decides what is being
    /// equalised — every enabled profile with a running app gets its own engine.
    @Published var editingBundleID: String?
    @Published var showSystemProcesses: Bool = UserDefaults.standard.bool(forKey: "showSystemProcesses") {
        didSet { UserDefaults.standard.set(showSystemProcesses, forKey: "showSystemProcesses") }
    }

    let pool = EnginePool()

    private var refreshTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var poolObserver: AnyCancellable?

    init() {
        profiles = ProfileStore.loadAll()
        editingBundleID = ProfileStore.lastTarget

        poolObserver = pool.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushSaves()
                self?.pool.stopAll()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Current selection

    var profile: Profile {
        editingBundleID.flatMap { profiles[$0] } ?? .flat
    }

    var targetName: String {
        guard let editingBundleID else { return "Select app…" }
        return apps.first { $0.bundleID == editingBundleID }?.name
            ?? AppInfoCache.info(for: editingBundleID, fallbackPID: 0).name
    }

    /// Apps with an engine actually running right now.
    var activeCount: Int { pool.runningCount }

    func isEqualised(_ bundleID: String) -> Bool {
        profiles[bundleID]?.enabled ?? false
    }

    func status(for bundleID: String?) -> EnginePool.Status? {
        guard let bundleID else { return nil }
        return pool.status[bundleID]
    }

    // MARK: - App list

    /// Real apps, plus anything already configured or selected, so a configured app
    /// never disappears from its own picker.
    var userApps: [AudioProcess] {
        apps.filter { $0.isUserApp || $0.bundleID == editingBundleID || isEqualised($0.bundleID) }
    }

    var systemProcesses: [AudioProcess] {
        apps.filter { !$0.isUserApp && $0.bundleID != editingBundleID && !isEqualised($0.bundleID) }
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        return AppInfoCache.info(for: bundleID, fallbackPID: 0).icon
    }

    func refresh() {
        apps = AudioProcessList.current()
        syncEngines()
    }

    /// An app gets an engine when it is enabled *and* currently running. Tapping an
    /// app that isn't there would just build a graph with nothing on the other end.
    private func syncEngines() {
        let available = Set(apps.map(\.bundleID))
        let desired = Set(profiles.filter { $0.value.enabled }.keys).intersection(available)
        let snapshot = profiles
        pool.reconcile(desired: desired) { snapshot[$0] ?? .flat }
    }

    // MARK: - Selection

    func select(bundleID: String?) {
        editingBundleID = bundleID
        ProfileStore.lastTarget = bundleID

        guard let bundleID else { return }
        if profiles[bundleID] == nil {
            profiles[bundleID] = .flat
            scheduleSave()
            syncEngines()
        }
    }

    // MARK: - Curve edits

    func setGain(band index: Int, to value: Double) {
        mutate { profile in
            guard profile.bands.indices.contains(index) else { return }
            profile.bands[index].gainDB = value
        }
    }

    func setPreamp(_ value: Double) {
        mutate { $0.preampDB = value }
    }

    func setEnabled(_ value: Bool) {
        mutate { $0.enabled = value }
        // Disabling stops the engine outright rather than bypassing it, so the app's
        // audio path goes back to completely untouched.
        syncEngines()
    }

    func apply(preset: Preset) {
        mutate { $0 = preset.applied(to: $0) }
    }

    /// Flatten every band and the preamp, leaving the on/off state alone.
    func resetAll() {
        guard let flat = Preset.all.first(where: { $0.name == "Flat" }) else { return }
        apply(preset: flat)
    }

    func turnOffAll() {
        for key in profiles.keys { profiles[key]?.enabled = false }
        scheduleSave()
        syncEngines()
    }

    func forget(_ bundleID: String) {
        profiles[bundleID] = nil
        if editingBundleID == bundleID {
            editingBundleID = nil
            ProfileStore.lastTarget = nil
        }
        scheduleSave()
        syncEngines()
    }

    var matchingPreset: Preset? {
        Preset.all.first { $0.matches(profile) }
    }

    private func mutate(_ change: (inout Profile) -> Void) {
        guard let bundleID = editingBundleID else { return }
        var updated = profiles[bundleID] ?? .flat
        change(&updated)
        profiles[bundleID] = updated
        pool.apply(updated, to: bundleID)
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = profiles
        let work = DispatchWorkItem { ProfileStore.saveAll(snapshot) }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func flushSaves() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        ProfileStore.saveAll(profiles)
    }

    // MARK: - Misc

    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    func quit() {
        flushSaves()
        pool.stopAll()
        NSApplication.shared.terminate(nil)
    }
}

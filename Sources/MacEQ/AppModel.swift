import AppKit
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var apps: [AudioProcess] = []
    @Published private(set) var profile: Profile = .flat
    @Published var targetBundleID: String?
    @Published var showSystemProcesses: Bool = UserDefaults.standard.bool(forKey: "showSystemProcesses") {
        didSet { UserDefaults.standard.set(showSystemProcesses, forKey: "showSystemProcesses") }
    }

    /// Real apps, plus whatever is currently selected so the target never vanishes
    /// from its own picker.
    var userApps: [AudioProcess] {
        apps.filter { $0.isUserApp || $0.bundleID == targetBundleID }
    }

    var systemProcesses: [AudioProcess] {
        apps.filter { !$0.isUserApp && $0.bundleID != targetBundleID }
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        return AppInfoCache.info(for: bundleID, fallbackPID: 0).icon
    }

    let engine = TapEngine()

    private var refreshTimer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private var engineObserver: AnyCancellable?

    init() {
        // Re-push the curve whenever the graph is rebuilt: coefficients are
        // sample-rate dependent and the rate follows the output device.
        engine.onGraphChanged = { [weak self] in
            guard let self else { return }
            self.engine.apply(self.profile)
        }
        engineObserver = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        refresh()
        if let last = ProfileStore.lastTarget {
            select(bundleID: last, autoStart: true)
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - App selection

    func refresh() {
        apps = AudioProcessList.current()
        engine.reconcileMembers()
    }

    func select(bundleID: String?, autoStart: Bool = true) {
        targetBundleID = bundleID
        ProfileStore.lastTarget = bundleID

        guard let bundleID else {
            engine.stop()
            profile = .flat
            return
        }

        profile = ProfileStore.load(for: bundleID)
        if autoStart {
            engine.start(bundleID: bundleID)
        }
        engine.apply(profile)
    }

    var targetName: String {
        guard let targetBundleID else { return "Select app…" }
        return apps.first { $0.bundleID == targetBundleID }?.name
            ?? AppInfoCache.info(for: targetBundleID, fallbackPID: 0).name
    }

    // MARK: - Curve edits

    func setGain(band index: Int, to value: Double) {
        guard profile.bands.indices.contains(index) else { return }
        profile.bands[index].gainDB = value
        commit()
    }

    func setPreamp(_ value: Double) {
        profile.preampDB = value
        commit()
    }

    func setEnabled(_ value: Bool) {
        profile.enabled = value
        commit()
    }

    func apply(preset: Preset) {
        profile = preset.applied(to: profile)
        commit()
    }

    /// Flatten every band and the preamp, leaving the on/off state alone.
    func resetAll() {
        guard let flat = Preset.all.first(where: { $0.name == "Flat" }) else { return }
        apply(preset: flat)
    }

    var matchingPreset: Preset? {
        Preset.all.first { $0.matches(profile) }
    }

    /// Push to the audio thread immediately, write to disk lazily.
    private func commit() {
        engine.apply(profile)

        saveWorkItem?.cancel()
        guard let bundleID = targetBundleID else { return }
        let snapshot = profile
        let work = DispatchWorkItem { ProfileStore.save(snapshot, for: bundleID) }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
        engine.stop()
        NSApplication.shared.terminate(nil)
    }
}

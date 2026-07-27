import CoreAudio
import Foundation
import OSLog

let engineLog = Logger(subsystem: "dev.seankerwin.maceq", category: "engine")

/// Everything the audio thread is allowed to touch. Immutable after construction,
/// so the IOProc block can capture it without synchronising against the UI.
private final class RenderContext: @unchecked Sendable {
    let kernel: EQKernel
    /// Index of the first `AudioBuffer` in the aggregate's input list that belongs
    /// to the tap rather than to the output sub-device's own inputs.
    let tapBufferOffset: Int

    init(kernel: EQKernel, tapBufferOffset: Int) {
        self.kernel = kernel
        self.tapBufferOffset = tapBufferOffset
    }

    /// Resolve a logical channel to (pointer to its first sample, stride, frame count),
    /// walking the buffer list so interleaved and planar layouts both work.
    @inline(__always)
    private func locate(_ list: UnsafeMutableAudioBufferListPointer,
                        startBuffer: Int,
                        channel: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
        var remaining = channel
        var index = startBuffer

        while index < list.count {
            let buffer = list[index]
            let channels = Int(buffer.mNumberChannels)

            if remaining < channels {
                guard let data = buffer.mData, channels > 0 else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let base = data.assumingMemoryBound(to: Float.self).advanced(by: remaining)
                return (base, channels, frames)
            }

            remaining -= channels
            index += 1
        }
        return nil
    }

    private func channelCount(_ list: UnsafeMutableAudioBufferListPointer, from startBuffer: Int) -> Int {
        var total = 0
        var index = startBuffer
        while index < list.count {
            total += Int(list[index].mNumberChannels)
            index += 1
        }
        return total
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Silence first: any output channel we don't fill must not replay stale audio.
        for buffer in outList {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let tapChannels = channelCount(inList, from: tapBufferOffset)
        let outChannels = channelCount(outList, from: 0)
        guard tapChannels > 0, outChannels > 0 else { return }

        for outChannel in 0..<outChannels {
            // Mono tap feeds every channel; stereo tap feeds the first two only.
            let srcChannel: Int
            if tapChannels == 1 {
                srcChannel = 0
            } else if outChannel < tapChannels {
                srcChannel = outChannel
            } else {
                break
            }

            guard let (dst, dstStride, dstFrames) = locate(outList, startBuffer: 0, channel: outChannel),
                  let (src, srcStride, srcFrames) = locate(inList, startBuffer: tapBufferOffset, channel: srcChannel)
            else { continue }

            let frames = min(dstFrames, srcFrames)
            guard frames > 0 else { continue }

            for frame in 0..<frames {
                dst[frame * dstStride] = src[frame * srcStride]
            }

            kernel.process(channel: outChannel, samples: dst, frameCount: frames, stride: dstStride)
        }
    }
}

/// One app's audio graph: a tap on that app, a private aggregate device pairing the
/// tap with the real output, and an IOProc filtering between them.
///
/// Engines are independent, so several apps can be equalised at once. `EnginePool`
/// owns their lifetimes; nothing here tears itself down on `deinit`, because the
/// CoreAudio teardown has to happen on the main actor.
@MainActor
final class TapEngine {
    let bundleID: String
    let kernel = EQKernel(bandCount: Profile.bandCount)

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var outputDeviceName = ""
    private(set) var sampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var trackedMembers: Set<AudioObjectID> = []
    private var registeredBundleIDs: Set<String> = []
    private var currentProfile: Profile = .flat

    init(bundleID: String) {
        self.bundleID = bundleID
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        stop()
        do {
            try buildGraph()
            isRunning = true
            lastError = nil
            // Coefficients depend on the sample rate, which follows the output
            // device, so always recompute after the graph is (re)built.
            pushToKernel()
            engineLog.info("started \(self.bundleID, privacy: .public) on \(self.outputDeviceName, privacy: .public) @ \(self.sampleRate, privacy: .public) Hz")
            return true
        } catch {
            teardownGraph()
            isRunning = false
            lastError = error.localizedDescription
            engineLog.error("failed \(self.bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func stop() {
        let wasRunning = isRunning
        teardownGraph()
        isRunning = false
        if wasRunning {
            engineLog.info("stopped \(self.bundleID, privacy: .public)")
        }
    }

    /// True when the failure looks like a missing Audio Recording permission rather
    /// than a genuine audio problem.
    var looksLikePermissionFailure: Bool {
        lastError?.contains("AudioHardwareCreateProcessTap") ?? false
    }

    // MARK: - Curve

    func apply(_ profile: Profile) {
        currentProfile = profile
        pushToKernel()
    }

    private func pushToKernel() {
        kernel.update(bands: currentProfile.bands,
                      sampleRate: sampleRate,
                      preampDB: currentProfile.preampDB,
                      bypass: !currentProfile.enabled)
    }

    // MARK: - Graph

    private func buildGraph() throws {
        let outputDevice = try AudioDevices.defaultOutput()
        let outputUID = try AudioDevices.uid(of: outputDevice)
        outputDeviceName = AudioDevices.name(of: outputDevice)
        sampleRate = AudioDevices.sampleRate(of: outputDevice)

        // 1. Tap the target app's output, muting its direct path only while we're
        //    actually reading — if this process dies, the app goes back to normal.
        let members = AudioProcessList.members(ofRoot: bundleID)
        trackedMembers = Set(members.objectIDs)
        registeredBundleIDs = Set(members.bundleIDs)

        let description = CATapDescription(stereoMixdownOfProcesses: members.objectIDs)
        description.name = "MacEQ – \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            description.bundleIDs = members.bundleIDs
            description.isProcessRestoreEnabled = true
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap),
                  "AudioHardwareCreateProcessTap")
        tapID = tap

        guard let tapUID = tap.string(tap.address(kAudioTapPropertyUID)) else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnknownPropertyError),
                                 operation: "Read tap UID")
        }

        // 2. A private aggregate that owns both the tap (input) and the real output
        //    device. Drift compensation on the tap is what keeps the two clocks married.
        //    Several aggregates may name the same output device; the HAL mixes them.
        let aggregateUID = "dev.seankerwin.maceq.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacEQ (\(bundleID))",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        // 3. Sub-device inputs come first in the aggregate's input list, so the tap's
        //    audio starts after however many input buffers the output device itself has.
        let tapBufferOffset = outputDevice.streamBufferCount(scope: kAudioObjectPropertyScopeInput)
        let context = RenderContext(kernel: kernel, tapBufferOffset: tapBufferOffset)
        kernel.reset()

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, inInput, _, outOutput, _ in
            context.render(input: inInput, output: outOutput)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        try check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")
    }

    private func teardownGraph() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        trackedMembers = []
    }

    // MARK: - Membership

    /// Rebuild if the app has spun up an audio process the tap cannot reach.
    ///
    /// Starting a Slack huddle spawns a fresh renderer helper; without this its audio
    /// would bypass the EQ entirely. Rebuilding is a real audible dropout though, so
    /// it has to be rare.
    ///
    /// On macOS 26 the tap is registered with the app's bundle IDs and process
    /// restore, so CoreAudio re-binds new processes of an *already registered* bundle
    /// ID by itself. Only a bundle ID we have never registered needs a rebuild.
    /// Watching raw process object IDs instead means apps that churn short-lived
    /// helpers (Linear does this) rebuild the graph every few seconds for nothing.
    func reconcileMembersIfNeeded() {
        guard isRunning else { return }
        let members = AudioProcessList.members(ofRoot: bundleID)
        guard !members.objectIDs.isEmpty else { return }

        if #available(macOS 26.0, *) {
            let unseen = Set(members.bundleIDs).subtracting(registeredBundleIDs)
            guard !unseen.isEmpty else { return }
            engineLog.info("rebuilding \(self.bundleID, privacy: .public): new bundle IDs \(unseen.sorted().joined(separator: ", "), privacy: .public)")
        } else {
            guard !Set(members.objectIDs).isSubset(of: trackedMembers) else { return }
        }

        start()
    }
}

/// Owns one `TapEngine` per app being equalised.
@MainActor
final class EnginePool: ObservableObject {
    struct Status {
        let isRunning: Bool
        let error: String?
        let isPermissionFailure: Bool
    }

    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var outputDeviceName = ""
    @Published private(set) var sampleRate: Double = 48_000

    private var engines: [String: TapEngine] = [:]
    private var deviceListener: AudioObjectPropertyListenerBlock?

    var runningCount: Int { engines.values.filter(\.isRunning).count }

    init() {
        installDeviceListener()
    }

    /// Start engines for `desired`, stop every engine not in it.
    func reconcile(desired: Set<String>, profile: (String) -> Profile) {
        for (bundleID, engine) in engines where !desired.contains(bundleID) {
            engine.stop()
            engines[bundleID] = nil
        }

        for bundleID in desired where engines[bundleID] == nil {
            let engine = TapEngine(bundleID: bundleID)
            engine.apply(profile(bundleID))
            engine.start()
            engines[bundleID] = engine
        }

        for engine in engines.values {
            engine.reconcileMembersIfNeeded()
        }

        publishStatus()
    }

    func apply(_ profile: Profile, to bundleID: String) {
        engines[bundleID]?.apply(profile)
    }

    func stopAll() {
        for engine in engines.values { engine.stop() }
        engines.removeAll()
        publishStatus()
    }

    private func publishStatus() {
        status = engines.mapValues {
            Status(isRunning: $0.isRunning,
                   error: $0.lastError,
                   isPermissionFailure: $0.looksLikePermissionFailure)
        }
        if let running = engines.values.first(where: \.isRunning) {
            outputDeviceName = running.outputDeviceName
            sampleRate = running.sampleRate
        }
    }

    // MARK: - Output device changes

    /// One listener for the whole pool: when the user switches output (headphones in
    /// or out), every engine's aggregate is pointing at the wrong device.
    private func installDeviceListener() {
        var address = AudioObjectID.system.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                for engine in self.engines.values { engine.start() }
                self.publishStatus()
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main, block)
    }
}

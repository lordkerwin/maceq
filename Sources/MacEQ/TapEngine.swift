import CoreAudio
import Foundation

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

@MainActor
final class TapEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    @Published private(set) var outputDeviceName = ""
    @Published private(set) var sampleRate: Double = 48_000

    let kernel = EQKernel(bandCount: Profile.bandCount)

    /// Fired when the graph is rebuilt, so the caller can push its curve back in
    /// (coefficients depend on the sample rate, which can change with the device).
    var onGraphChanged: (() -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var targetBundleID: String?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var trackedMembers: Set<AudioObjectID> = []

    // MARK: - Lifecycle

    func start(bundleID: String) {
        stop()
        targetBundleID = bundleID

        do {
            try buildGraph(bundleID: bundleID)
            isRunning = true
            lastError = nil
            installDeviceListener()
            onGraphChanged?()
        } catch {
            teardownGraph()
            isRunning = false
            lastError = error.localizedDescription
        }
    }

    func stop() {
        removeDeviceListener()
        teardownGraph()
        targetBundleID = nil
        isRunning = false
    }

    /// True when the failure looks like a missing Audio Recording permission rather
    /// than a genuine audio problem.
    var looksLikePermissionFailure: Bool {
        guard let lastError else { return false }
        return lastError.contains("AudioHardwareCreateProcessTap")
    }

    // MARK: - Graph

    private func buildGraph(bundleID: String) throws {
        let outputDevice = try AudioDevices.defaultOutput()
        let outputUID = try AudioDevices.uid(of: outputDevice)
        outputDeviceName = AudioDevices.name(of: outputDevice)
        sampleRate = AudioDevices.sampleRate(of: outputDevice)

        // 1. Tap the target app's output, muting its direct path only while we're
        //    actually reading — if this process dies, the app goes back to normal.
        let members = AudioProcessList.members(ofRoot: bundleID)
        trackedMembers = Set(members.objectIDs)
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
        let aggregateUID = "dev.seankerwin.maceq.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacEQ",
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
    }

    /// Rebuild if the target app has spun up an audio process we aren't tapping.
    ///
    /// Starting a Slack huddle spawns a fresh renderer helper; without this its audio
    /// would bypass the EQ entirely. Costs a few ms of silence at the moment a call
    /// starts, which is cheaper than a call with no EQ on it.
    func reconcileMembers() {
        guard isRunning, let bundleID = targetBundleID else { return }
        let current = Set(AudioProcessList.members(ofRoot: bundleID).objectIDs)
        guard !current.isEmpty, !current.isSubset(of: trackedMembers) else { return }
        start(bundleID: bundleID)
    }

    // MARK: - Output device changes

    /// Rebuild when the user switches output (headphones in/out), otherwise the
    /// aggregate keeps pointing at a device nobody is listening to.
    private func installDeviceListener() {
        var address = AudioObjectID.system.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let bundleID = self.targetBundleID else { return }
                self.start(bundleID: bundleID)
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main, block)
    }

    private func removeDeviceListener() {
        guard let deviceListener else { return }
        var address = AudioObjectID.system.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main, deviceListener)
        self.deviceListener = nil
    }

    // MARK: - Curve

    func apply(_ profile: Profile) {
        kernel.update(bands: profile.bands,
                      sampleRate: sampleRate,
                      preampDB: profile.preampDB,
                      bypass: !profile.enabled)
    }
}

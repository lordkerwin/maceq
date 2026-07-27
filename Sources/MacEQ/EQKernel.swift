import Foundation
import Synchronization

/// The real-time EQ processor.
///
/// The audio thread never allocates and never takes a lock. It loads one atomic index
/// and dereferences one of two pre-allocated coefficient blocks. The UI thread writes
/// the *inactive* block and only then flips the index, so a render pass either sees the
/// whole old curve or the whole new one, never a torn mix of the two.
final class EQKernel: @unchecked Sendable {
    /// Upper bound on channels we keep filter state for. Output devices beyond this
    /// still pass audio, they just skip the extra channels (which are silent anyway,
    /// since the tap is a stereo mixdown).
    static let maxChannels = 8

    let bandCount: Int

    private let slots: [UnsafeMutablePointer<BiquadCoeffs>]
    private let activeSlot = Atomic<Int>(0)
    private let preampBits: Atomic<UInt64>
    private let bypassed = Atomic<Bool>(false)
    private let state: UnsafeMutablePointer<BiquadState>

    init(bandCount: Int) {
        self.bandCount = bandCount
        self.slots = (0..<2).map { _ in
            let p = UnsafeMutablePointer<BiquadCoeffs>.allocate(capacity: bandCount)
            p.initialize(repeating: .identity, count: bandCount)
            return p
        }
        self.preampBits = Atomic<UInt64>(Double(1).bitPattern)
        let stateCount = Self.maxChannels * bandCount
        self.state = UnsafeMutablePointer<BiquadState>.allocate(capacity: stateCount)
        self.state.initialize(repeating: BiquadState(), count: stateCount)
    }

    deinit {
        for slot in slots {
            slot.deinitialize(count: bandCount)
            slot.deallocate()
        }
        state.deinitialize(count: Self.maxChannels * bandCount)
        state.deallocate()
    }

    // MARK: - Control thread

    /// Recompute the curve and publish it to the audio thread.
    func update(bands: [Band], sampleRate: Double, preampDB: Double, bypass: Bool) {
        let inactive = 1 - activeSlot.load(ordering: .acquiring)
        let dst = slots[inactive]

        for i in 0..<bandCount {
            if i < bands.count {
                let band = bands[i]
                dst[i] = BiquadCoeffs.make(kind: band.kind,
                                           freq: band.freq,
                                           q: band.q,
                                           gainDB: band.gainDB,
                                           sampleRate: sampleRate)
            } else {
                dst[i] = .identity
            }
        }

        preampBits.store(pow(10, preampDB / 20).bitPattern, ordering: .releasing)
        bypassed.store(bypass, ordering: .releasing)
        activeSlot.store(inactive, ordering: .releasing)
    }

    /// Clear the delay lines. Call when the stream restarts so a stale tail can't pop.
    func reset() {
        for i in 0..<(Self.maxChannels * bandCount) {
            state[i] = BiquadState()
        }
    }

    // MARK: - Audio thread

    /// Filter one channel in place.
    ///
    /// - Parameters:
    ///   - channel: channel index, used to pick the delay line.
    ///   - samples: pointer to this channel's first sample.
    ///   - frameCount: frames to process.
    ///   - stride: samples between successive frames (1 when planar, channel count when interleaved).
    func process(channel: Int, samples: UnsafeMutablePointer<Float>, frameCount: Int, stride: Int) {
        guard channel < Self.maxChannels, frameCount > 0, stride > 0 else { return }
        if bypassed.load(ordering: .acquiring) { return }

        let coeffs = slots[activeSlot.load(ordering: .acquiring)]
        let preamp = Double(bitPattern: preampBits.load(ordering: .acquiring))
        let line = state.advanced(by: channel * bandCount)

        for frame in 0..<frameCount {
            let index = frame * stride
            var x = Double(samples[index]) * preamp

            for band in 0..<bandCount {
                let k = coeffs[band]
                var s = line[band]

                var y = k.b0 * x + k.b1 * s.x1 + k.b2 * s.x2 - k.a1 * s.y1 - k.a2 * s.y2
                // Kill NaNs from a bad coefficient and flush denormals, which are
                // ruinously slow to keep multiplying through a feedback path.
                if !y.isFinite || abs(y) < 1e-18 { y = 0 }

                s.x2 = s.x1
                s.x1 = x
                s.y2 = s.y1
                s.y1 = y
                line[band] = s

                x = y
            }

            samples[index] = Float(min(max(x, -1), 1))
        }
    }
}

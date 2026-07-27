import Foundation

/// Filter shapes we build EQ bands from.
enum BandKind: String, Codable, Hashable {
    case lowShelf
    case peaking
    case highShelf
}

/// Direct-form-1 biquad coefficients, already normalised so a0 == 1.
struct BiquadCoeffs {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = BiquadCoeffs()
}

/// Per-channel, per-band delay line.
struct BiquadState {
    var x1: Double = 0
    var x2: Double = 0
    var y1: Double = 0
    var y2: Double = 0
}

extension BiquadCoeffs {
    /// RBJ audio EQ cookbook filters.
    ///
    /// For the shelf kinds `q` is the shelf slope S (1.0 = steepest without overshoot);
    /// for `peaking` it is the usual Q.
    static func make(kind: BandKind,
                     freq: Double,
                     q: Double,
                     gainDB: Double,
                     sampleRate: Double) -> BiquadCoeffs {
        guard sampleRate > 0, gainDB != 0, q > 0 else { return .identity }

        let nyquist = sampleRate / 2
        let f = min(max(freq, 10), nyquist * 0.98)
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)

        let b0: Double, b1: Double, b2: Double
        let a0: Double, a1: Double, a2: Double

        switch kind {
        case .peaking:
            let alpha = sinW / (2 * q)
            b0 = 1 + alpha * a
            b1 = -2 * cosW
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW
            a2 = 1 - alpha / a

        case .lowShelf:
            let alpha = sinW / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            let beta = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + beta)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - beta)
            a0 = (a + 1) + (a - 1) * cosW + beta
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - beta

        case .highShelf:
            let alpha = sinW / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            let beta = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + beta)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - beta)
            a0 = (a + 1) - (a - 1) * cosW + beta
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - beta
        }

        guard a0.isFinite, a0 != 0 else { return .identity }
        let c = BiquadCoeffs(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        guard c.b0.isFinite, c.b1.isFinite, c.b2.isFinite, c.a1.isFinite, c.a2.isFinite else {
            return .identity
        }
        return c
    }
}

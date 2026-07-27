import Foundation

struct Band: Codable, Identifiable, Hashable {
    var label: String
    var kind: BandKind
    var freq: Double
    /// Q for peaking bands, shelf slope for the shelves.
    var q: Double
    var gainDB: Double

    var id: String { label }

    /// "60 Hz" / "12 kHz"
    var freqLabel: String {
        freq >= 1000
            ? "\(Int(freq / 1000)) kHz"
            : "\(Int(freq)) Hz"
    }
}

struct Profile: Codable, Hashable {
    static let bandCount = 5
    static let gainRange: ClosedRange<Double> = -12...12
    static let preampRange: ClosedRange<Double> = -12...6

    var bands: [Band]
    var preampDB: Double
    var enabled: Bool

    static let flat = Profile(
        bands: [
            Band(label: "Bass", kind: .lowShelf, freq: 60, q: 0.9, gainDB: 0),
            Band(label: "Low mid", kind: .peaking, freq: 250, q: 1.0, gainDB: 0),
            Band(label: "Mid", kind: .peaking, freq: 1000, q: 1.0, gainDB: 0),
            Band(label: "Presence", kind: .peaking, freq: 4000, q: 1.0, gainDB: 0),
            Band(label: "Treble", kind: .highShelf, freq: 12000, q: 0.9, gainDB: 0),
        ],
        preampDB: 0,
        enabled: true
    )

    /// Guards against a profile decoded from an older/newer band layout.
    var normalised: Profile {
        guard bands.count == Self.bandCount else { return .flat }
        var copy = self
        copy.preampDB = min(max(preampDB, Self.preampRange.lowerBound), Self.preampRange.upperBound)
        for i in copy.bands.indices {
            copy.bands[i].gainDB = min(max(copy.bands[i].gainDB, Self.gainRange.lowerBound),
                                       Self.gainRange.upperBound)
        }
        return copy
    }
}

struct Preset: Identifiable, Hashable {
    let name: String
    let gains: [Double]
    let preampDB: Double

    var id: String { name }

    /// Bass/low-mid/mid/presence/treble, in the order `Profile.flat` declares them.
    static let all: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0], preampDB: 0),
        // Calls are boomy and muddy; drop the rumble, lift consonants.
        Preset(name: "Voice / calls", gains: [-4, -3, 2, 4, 1], preampDB: 0),
        Preset(name: "Less harsh", gains: [0, 0, -1, -4, -2], preampDB: 0),
        Preset(name: "Warm", gains: [4, 1, 0, -2, -1], preampDB: -2),
        Preset(name: "Bright", gains: [-1, -1, 0, 2, 5], preampDB: -2),
        Preset(name: "Bass boost", gains: [7, 2, 0, 0, 0], preampDB: -5),
    ]

    func applied(to profile: Profile) -> Profile {
        var copy = profile
        for (i, gain) in gains.enumerated() where i < copy.bands.count {
            copy.bands[i].gainDB = gain
        }
        copy.preampDB = preampDB
        return copy
    }

    func matches(_ profile: Profile) -> Bool {
        guard profile.bands.count == gains.count else { return false }
        guard abs(profile.preampDB - preampDB) < 0.01 else { return false }
        return zip(profile.bands, gains).allSatisfy { abs($0.gainDB - $1) < 0.01 }
    }
}

/// Per-app profiles, persisted in UserDefaults.
enum ProfileStore {
    private static let profilesKey = "profiles"
    private static let targetKey = "targetBundleID"

    static func load(for bundleID: String) -> Profile {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let all = try? JSONDecoder().decode([String: Profile].self, from: data),
              let profile = all[bundleID]
        else { return .flat }
        return profile.normalised
    }

    static func save(_ profile: Profile, for bundleID: String) {
        let defaults = UserDefaults.standard
        var all: [String: Profile] = [:]
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([String: Profile].self, from: data) {
            all = decoded
        }
        all[bundleID] = profile
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: profilesKey)
        }
    }

    static var lastTarget: String? {
        get { UserDefaults.standard.string(forKey: targetKey) }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }
}

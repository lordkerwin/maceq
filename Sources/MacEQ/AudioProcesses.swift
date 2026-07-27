import AppKit
import CoreAudio

struct AudioProcess: Identifiable, Hashable {
    /// The app's root bundle ID, e.g. `com.tinyspeck.slackmacgap`.
    let bundleID: String
    let name: String
    let isPlaying: Bool
    /// A real app you might want to EQ, as opposed to a system daemon that merely
    /// happens to be able to make noise.
    let isUserApp: Bool

    var id: String { bundleID }
}

/// Names and icons come from the app bundle on disk, not from the process, because
/// the process that plays audio is usually a helper: resolving `com.tinyspeck.slackmacgap`
/// gives "Slack" and the Slack icon, where the helper's own process name gives
/// "Slack Helper" and a generic one.
@MainActor
enum AppInfoCache {
    struct Info {
        let name: String
        let icon: NSImage?
        let isUserApp: Bool
    }

    private static var cache: [String: Info] = [:]

    private static let applicationDirectories: Set<String> = [
        "/Applications",
        "/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    static func info(for bundleID: String, fallbackPID: pid_t) -> Info {
        if let cached = cache[bundleID] { return cached }

        let info: Info
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let directory = url.deletingLastPathComponent().path
            let isUserApp = applicationDirectories.contains(directory)
                || directory.hasPrefix("/Applications/")

            info = Info(
                name: FileManager.default.displayName(atPath: url.path),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                isUserApp: isUserApp
            )
        } else {
            let running = NSRunningApplication(processIdentifier: fallbackPID)
            info = Info(
                name: running?.localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID,
                icon: running?.icon,
                isUserApp: false
            )
        }

        cache[bundleID] = info
        return info
    }
}

enum AudioProcessList {
    private struct RawProcess {
        let objectID: AudioObjectID
        let bundleID: String
        let pid: pid_t
        let isPlaying: Bool
    }

    private static func rawProcesses() -> [RawProcess] {
        let addr = AudioObjectID.system.address(kAudioHardwarePropertyProcessObjectList)
        guard let ids = try? AudioObjectID.system.objectIDs(addr) else { return [] }

        return ids.compactMap { id in
            guard let bundleID = id.string(id.address(kAudioProcessPropertyBundleID)),
                  !bundleID.isEmpty
            else { return nil }

            let pid = (try? id.value(id.address(kAudioProcessPropertyPID), pid_t(0))) ?? 0
            let playing = ((try? id.value(id.address(kAudioProcessPropertyIsRunningOutput), UInt32(0))) ?? 0) != 0
            return RawProcess(objectID: id, bundleID: bundleID, pid: pid, isPlaying: playing)
        }
    }

    /// Electron apps emit audio from a helper process, not the one that owns the window:
    /// Slack calls come out of `com.tinyspeck.slackmacgap.helper`, Discord out of
    /// `com.hnc.Discord.helper.Renderer`. Fold each of those back onto the shortest
    /// ancestor bundle ID that CoreAudio also knows about, so the picker shows one row
    /// per app and a tap on that row covers every helper behind it.
    private static func rootBundleID(for bundleID: String, known: Set<String>) -> String {
        var parts = bundleID.split(separator: ".")
        var root = bundleID
        while parts.count > 1 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            if known.contains(candidate) { root = candidate }
        }
        return root
    }

    /// One row per app, apps currently making noise first.
    @MainActor
    static func current() -> [AudioProcess] {
        let processes = rawProcesses()
        let known = Set(processes.map(\.bundleID))
        let ownBundleID = Bundle.main.bundleIdentifier

        // Prefer the root process's own PID for the icon/name fallback; a helper's PID
        // resolves to "Slack Helper" rather than "Slack".
        var playing: [String: Bool] = [:]
        var representativePID: [String: pid_t] = [:]

        for process in processes {
            let root = rootBundleID(for: process.bundleID, known: known)
            guard root != ownBundleID else { continue }

            playing[root] = (playing[root] ?? false) || process.isPlaying
            if representativePID[root] == nil || process.bundleID == root {
                representativePID[root] = process.pid
            }
        }

        return playing.map { bundleID, isPlaying in
            let info = AppInfoCache.info(for: bundleID, fallbackPID: representativePID[bundleID] ?? 0)
            return AudioProcess(bundleID: bundleID,
                                name: info.name,
                                isPlaying: isPlaying,
                                isUserApp: info.isUserApp)
        }
        .sorted {
            ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Every CoreAudio process object belonging to an app, helpers included.
    ///
    /// - Returns: object IDs to seed the tap with, and the bundle IDs to register for
    ///   restore so the tap re-binds when the app is quit and reopened.
    static func members(ofRoot rootBundleID: String) -> (objectIDs: [AudioObjectID], bundleIDs: [String]) {
        let matches = rawProcesses().filter {
            $0.bundleID == rootBundleID || $0.bundleID.hasPrefix(rootBundleID + ".")
        }
        var bundleIDs = Set(matches.map(\.bundleID))
        bundleIDs.insert(rootBundleID)
        return (matches.map(\.objectID), bundleIDs.sorted())
    }
}

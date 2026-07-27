import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) failed: \(fourCCDescription(status)) (\(status))"
    }
}

/// CoreAudio error codes are usually packed four-character codes, e.g. '!obj'.
func fourCCDescription(_ value: OSStatus) -> String {
    let raw = UInt32(bitPattern: value)
    let bytes = [
        UInt8((raw >> 24) & 0xff),
        UInt8((raw >> 16) & 0xff),
        UInt8((raw >> 8) & 0xff),
        UInt8(raw & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }),
       let text = String(bytes: bytes, encoding: .ascii) {
        return "'\(text)'"
    }
    return "\(value)"
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw CoreAudioError(status: status, operation: operation)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func address(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func propertySize(_ addr: AudioObjectPropertyAddress) throws -> UInt32 {
        var a = addr
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size),
                  "AudioObjectGetPropertyDataSize(\(fourCCDescription(OSStatus(bitPattern: addr.mSelector))))")
        return size
    }

    /// Read a fixed-layout value (Float64, UInt32, pid_t, AudioStreamBasicDescription…).
    func value<T>(_ addr: AudioObjectPropertyAddress, _ initial: T) throws -> T {
        var a = addr
        var out = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(self, &a, 0, nil, &size, ptr)
        }
        try check(status,
                  "AudioObjectGetPropertyData(\(fourCCDescription(OSStatus(bitPattern: addr.mSelector))))")
        return out
    }

    func objectIDs(_ addr: AudioObjectPropertyAddress) throws -> [AudioObjectID] {
        var size = try propertySize(addr)
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        var a = addr
        let status = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(self, &a, 0, nil, &size, raw.baseAddress!)
        }
        try check(status, "AudioObjectGetPropertyData(list)")
        return ids
    }

    /// CoreAudio hands back a +1 CFString; letting ARC own the local balances it.
    func string(_ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var out: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(self, &a, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return out as String?
    }

    /// Number of `AudioBuffer`s the device contributes on the given scope.
    ///
    /// Needed because an aggregate device lists its sub-devices' buffers before its
    /// taps' buffers, so this is the index the tap audio starts at.
    func streamBufferCount(scope: AudioObjectPropertyScope) -> Int {
        let addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        guard let size = try? propertySize(addr), size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        var a = addr
        var sz = size
        guard AudioObjectGetPropertyData(self, &a, 0, nil, &sz, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }
}

enum AudioDevices {
    static func defaultOutput() throws -> AudioObjectID {
        let addr = AudioObjectID.system.address(kAudioHardwarePropertyDefaultOutputDevice)
        let id = try AudioObjectID.system.value(addr, AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareBadDeviceError),
                                 operation: "Resolve default output device")
        }
        return id
    }

    static func uid(of device: AudioObjectID) throws -> String {
        guard let uid = device.string(device.address(kAudioDevicePropertyDeviceUID)) else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareUnknownPropertyError),
                                 operation: "Read device UID")
        }
        return uid
    }

    static func name(of device: AudioObjectID) -> String {
        device.string(device.address(kAudioObjectPropertyName)) ?? "Unknown output"
    }

    static func sampleRate(of device: AudioObjectID) -> Double {
        (try? device.value(device.address(kAudioDevicePropertyNominalSampleRate), Double(0)))
            .flatMap { $0 > 0 ? $0 : nil } ?? 48_000
    }
}

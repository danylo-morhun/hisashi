import Accelerate
import CoreAudio
import Foundation
import Observation

/// Bar levels for the equalizer, 0...1. Kept apart from NotchModel so only the bars redraw.
@Observable
final class AudioLevels {
    var values: [Float] = [0, 0, 0, 0]
}

/// Listens only to the playing app's own sound through a Core Audio process tap.
/// Nothing is recorded or stored: samples become four numbers and are dropped.
/// Needs the "System Audio Recording Only" permission; runs only while music plays.
final class AudioTap {
    private let levels: AudioLevels
    private let queue = DispatchQueue(label: "hisashi.audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var target: String?

    // Touched only on `queue`.
    private let fft = Spectrum.makeFFT()
    private var pending: [Float] = []
    private var bars: [Float] = [0, 0, 0, 0]
    private var peaks: [Float] = [-60, -60, -60, -60]
    private var lastPublish = Date.distantPast
    private var published: [Float] = [0, 0, 0, 0]

    init(levels: AudioLevels) {
        self.levels = levels
    }

    /// Follows the app whose sound drives the bars; nil stops listening.
    func setTarget(_ app: String?) {
        guard app != target || (app != nil && procID == nil) else { return }
        stop()
        if let app { start(app) }
    }

    private func start(_ app: String) {
        // Not outputting audio yet: try again on the next player update.
        let processes = Self.audioProcesses(of: app)
        guard !processes.isEmpty else { return }
        target = app
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr,
              let outputUID = Self.defaultOutputUID() else { return stop() }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hisashi Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &deviceID) == noErr else { return stop() }

        let rate = Float(Self.sampleRate(of: tapID) ?? 48_000)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input, sampleRate: rate)
        }
        guard status == noErr, AudioDeviceStart(deviceID, procID) == noErr else { return stop() }
    }

    private func stop() {
        target = nil
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.async { self.pending.removeAll(); self.bars = [0, 0, 0, 0]; self.published = [0, 0, 0, 0] }
        DispatchQueue.main.async { self.levels.values = [0, 0, 0, 0] }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>, sampleRate: Float) {
        guard let fft else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in stride(from: 0, to: count, by: channels) { pending.append(samples[i]) }

        // Half-overlapping frames keep the bars responsive.
        while pending.count >= Spectrum.frameSize {
            let frame = Array(pending.prefix(Spectrum.frameSize))
            pending.removeFirst(Spectrum.frameSize / 2)
            let db = Spectrum.bandDecibels(frame, sampleRate: sampleRate, fft: fft)
            (bars, peaks) = Spectrum.step(levels: bars, peaks: peaks, decibels: db)
        }

        // 30 updates a second at most, and none when the change is too small to see.
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 1.0 / 30,
              zip(bars, published).contains(where: { abs($0 - $1) > 0.02 }) else { return }
        lastPublish = now
        published = bars
        let snapshot = bars
        DispatchQueue.main.async { self.levels.values = snapshot }
    }

    /// Core Audio process objects of an app, its helper processes included.
    private static func audioProcesses(of app: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
                  let name = bundle?.takeRetainedValue() as String? else { return false }
            return name == app || name.hasPrefix(app + ".")
        }
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func sampleRate(of tap: AudioObjectID) -> Double? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format.mSampleRate
    }
}

import Accelerate
import CoreAudio
import Foundation
import Observation

/// Bar levels for the equalizer, 0...1. Kept apart from NotchModel so only the bars redraw.
@Observable
final class AudioLevels {
    var values: [Float] = [0, 0, 0, 0]
}

/// Listens to everything the Mac plays through a Core Audio tap (macOS 14.2+).
/// Needs the "System Audio Recording Only" permission; runs only while music plays.
final class AudioTap {
    private let levels: AudioLevels
    private let queue = DispatchQueue(label: "hisashi.audio", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    // Touched only on `queue`.
    private let fft = Spectrum.makeFFT()
    private var pending: [Float] = []
    private var bars: [Float] = [0, 0, 0, 0]
    private var peaks: [Float] = [-60, -60, -60, -60]
    private var lastPublish = Date.distantPast

    init(levels: AudioLevels) {
        self.levels = levels
    }

    func setActive(_ active: Bool) {
        if active { start() } else { stop() }
    }

    private func start() {
        guard procID == nil else { return }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
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
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.async { self.pending.removeAll(); self.bars = [0, 0, 0, 0] }
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

        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 1.0 / 40 else { return }
        lastPublish = now
        let snapshot = bars
        DispatchQueue.main.async { self.levels.values = snapshot }
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

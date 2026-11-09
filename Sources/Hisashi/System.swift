import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics

/// Volume of the default output device, through Core Audio.
enum Volume {
    static func level() -> Float? {
        guard let device = outputDevice() else { return nil }
        var value: Float32 = 0
        return read(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &value) ? value : nil
    }

    static func set(_ level: Float) {
        guard let device = outputDevice() else { return }
        var value = Float32(level)
        write(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &value)
    }

    static func isMuted() -> Bool {
        guard let device = outputDevice() else { return false }
        var value: UInt32 = 0
        return read(device, kAudioDevicePropertyMute, &value) && value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = outputDevice() else { return }
        var value: UInt32 = muted ? 1 : 0
        write(device, kAudioDevicePropertyMute, &value)
    }

    private static func outputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }

    private static func write<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) {
        var address = address(selector)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }
}

/// Brightness of the built-in display, through the private DisplayServices framework.
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    static func level() -> Float? {
        guard let getFn, let display = builtInDisplay() else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ level: Float) {
        guard let setFn, let display = builtInDisplay() else { return }
        _ = setFn(display, level)
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Takes digits, backspace, return and escape from the keyboard while the timer's minutes are
/// typed, without taking focus from the current window. Installed only for that long; every
/// other key, and anything with a modifier, goes on as usual.
final class KeyEntry {
    var onKey: (EntryKey) -> Void = { _ in }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() {
        guard tap == nil else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let made = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, me in
                Unmanaged<KeyEntry>.fromOpaque(me!).takeUnretainedValue().process(type, event)
            },
            userInfo: me)
        else { return }
        let loop = CFMachPortCreateRunLoopSource(nil, made, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .commonModes)
        CGEvent.tapEnable(tap: made, enable: true)
        tap = made
        source = loop
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
              let key = EntryKey(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode))) else { return pass }
        onKey(key)
        return nil
    }
}

/// Catches volume, mute and brightness keys before the system does.
/// The handler returns true when it took care of a key; the system then never
/// sees it and shows no popup. Needs Accessibility; asks once, then waits.
final class KeyTap {
    private let handle: (SystemKey, Bool) -> Bool
    private var tap: CFMachPort?
    private var waiting: Timer?
    private var swallowed: Set<SystemKey> = []

    init(handle: @escaping (_ key: SystemKey, _ fine: Bool) -> Bool) {
        self.handle = handle
    }

    func start() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) { return install() }
        waiting = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.install()
        }
    }

    private func install() {
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: systemDefined,
            callback: { _, type, event, me in
                Unmanaged<KeyTap>.fromOpaque(me!).takeUnretainedValue().process(type, event)
            },
            userInfo: me)
        else { return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
        guard let key = SystemKey(rawValue: (ns.data1 & 0xFFFF_0000) >> 16) else { return pass }
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0xA
        // Swallow the key-up only if its key-down was ours.
        guard isDown else { return swallowed.remove(key) != nil ? nil : pass }
        let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
        guard handle(key, fine) else { return pass }
        swallowed.insert(key)
        return nil
    }
}

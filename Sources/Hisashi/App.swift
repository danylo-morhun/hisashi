import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var model: NotchModel?
    private var screenFrame: CGRect = .zero
    private var monitors: [Any] = []
    private var media: MediaBridge?
    private let levels = AudioLevels()
    private lazy var audio = AudioTap(levels: levels)
    private var keys: KeyTap?
    private let banners = BannerWatch()
    private var store: NoticeStore?
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        launchAtLogin()
        media = MediaBridge { [weak self] players in
            guard let self, let model = self.model else { return }
            model.send(.players(players))
            self.audio.setTarget(model.state.activity?.app)
        }
        model?.sendMedia = { [weak self] command, player in self?.media?.send(command, to: player) }
        media?.start()
        keys = KeyTap { [weak self] key, fine in self?.systemKey(key, fine: fine) ?? false }
        keys?.start()
        startNotices()
        // Dev aid: `open build/Hisashi.app --args --pinned` starts open.
        if CommandLine.arguments.contains("--pinned") { model?.send(.togglePin) }
        // Dev aid: `--hud volume|brightness 0.5` shows the HUD at that level.
        if let i = CommandLine.arguments.firstIndex(of: "--hud"), CommandLine.arguments.count > i + 2,
           let level = Float(CommandLine.arguments[i + 2]) {
            let kind: Hud.Kind = CommandLine.arguments[i + 1] == "brightness" ? .brightness : .volume
            // Re-sent for five seconds so it stays up long enough to look at.
            for tick in 0..<10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(tick)) { [weak self] in
                    self?.model?.send(.showHud(Hud(kind: kind, level: level)))
                }
            }
        }
        // Dev aid: `--notice temporary|persistent [photo.jpg]` shows a sample notice with buttons.
        if let i = CommandLine.arguments.firstIndex(of: "--notice"), CommandLine.arguments.count > i + 1 {
            let persistent = CommandLine.arguments[i + 1] == "persistent"
            let photo = CommandLine.arguments.count > i + 2
                ? try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[i + 2])) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.model?.send(.notify(AppNotice(
                    id: "sample", app: "Messages", title: "Anna", subtitle: "",
                    body: "Are we still on for tonight? I booked the place at eight.",
                    actions: ["Reply", "Mark as Read"], persistent: persistent, image: photo)))
            }
        }
        monitors = MouseMonitors.install(onMove: { [weak self] in self?.mouseMoved($0) },
                                         onOutsideClick: { [weak self] in self?.model?.send(.unpin) })
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        media?.stop()
        audio.setTarget(nil)
        banners.stop()
    }

    /// Takes the system banners into the notch. Without Accessibility the system keeps showing them.
    private func startNotices() {
        guard let model else { return }
        banners.onNotice = { notice in
            model.send(.notify(notice))
            model.send(.remember(HistoryItem(id: notice.id, app: notice.app, title: notice.title,
                                             body: notice.detail, date: Date(), image: notice.image)))
        }
        banners.onExpire = { model.send(.expireNotice($0)) }
        model.noticeEffect = { [weak self] notice, effect in self?.banners.perform(effect, on: notice) }
        model.clearCenter = { [weak self] app in self?.banners.clear(app: app) }
        model.openHistory = { Apps.open($0) }
        // The notifications tab mirrors Notification Center when the store is readable.
        let store = NoticeStore { model.send(.stored($0, at: Date())) }
        if store.start() { self.store = store }
        guard banners.start() else { return }
        // `pkill` and logout send SIGTERM; quit properly so no banner stays hidden.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termination = source
    }

    @objc private func screensChanged() { buildPanel() }

    /// Starts with the Mac. Registered once only: turned off later in Login Items, it stays off.
    private func launchAtLogin() {
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }

    private func buildPanel() {
        guard let screen = NSScreen.notchScreen else { return }
        let notch = screen.notchSize
        screenFrame = screen.frame
        let model = self.model ?? NotchModel(notch: notch)
        model.notch = notch
        self.model = model

        let size = Layout.windowSize(notch: notch)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel?.close()
        let panel = NotchPanel(frame: frame)
        let host = NSHostingView(rootView: NotchView(model: model).environment(levels))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Applies a volume or brightness key and shows it in the notch.
    /// False hands the key back to the system (e.g. an output without volume control).
    private func systemKey(_ key: SystemKey, fine: Bool) -> Bool {
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard let level = Volume.level() else { return false }
            let next = Levels.volume(key, level: level, muted: Volume.isMuted(), fine: fine)
            Volume.set(next.level)
            Volume.setMuted(next.muted)
            model?.send(.showHud(Hud(kind: .volume, level: next.level, muted: next.muted)))
        case .brightnessUp, .brightnessDown:
            guard let level = Brightness.level() else { return false }
            let next = Levels.step(level, up: key == .brightnessUp, fine: fine)
            Brightness.set(next)
            model?.send(.showHud(Hud(kind: .brightness, level: next)))
        }
        return true
    }

    private func mouseMoved(_ point: NSPoint) {
        guard let model, let panel else { return }
        let rect = Layout.visibleRect(model.state, notch: model.notch, screen: screenFrame)
            .insetBy(dx: -Layout.hoverSlack, dy: -Layout.hoverSlack)
        let inside = rect.contains(point)
        if inside != model.state.isHovering {
            let wasCompact = model.state.mode == .compact
            model.send(.hover(inside))
            if wasCompact && model.state.mode == .open { Haptics.tap() }
        }
        panel.ignoresMouseEvents = !inside
    }
}

final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    // Never key: a click in the notch must not take focus from the window being worked in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Keep AppKit from pushing the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum MouseMonitors {
    static func install(onMove: @escaping (NSPoint) -> Void, onOutsideClick: @escaping () -> Void) -> [Any] {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        return [
            NSEvent.addGlobalMonitorForEvents(matching: moves) { _ in onMove(NSEvent.mouseLocation) },
            NSEvent.addLocalMonitorForEvents(matching: moves) { event in onMove(NSEvent.mouseLocation); return event },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in onOutsideClick() },
        ].compactMap { $0 }
    }
}

enum Haptics {
    /// A single light tick on the Force Touch trackpad. Silent with a mouse.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

extension NSScreen {
    /// The built-in display with a camera housing, or the main one as a fallback.
    static var notchScreen: NSScreen? {
        screens.first { $0.safeAreaInsets.top > 0 } ?? main
    }

    var notchSize: CGSize {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea, safeAreaInsets.top > 0 else {
            return CGSize(width: 190, height: NSStatusBar.system.thickness)
        }
        return CGSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }
}

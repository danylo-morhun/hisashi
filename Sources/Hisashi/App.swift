import AppKit
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
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        // Dev aid: `open build/Hisashi.app --args --pinned` starts open.
        if CommandLine.arguments.contains("--pinned") { model?.send(.togglePin) }
        monitors = MouseMonitors.install(onMove: { [weak self] in self?.mouseMoved($0) },
                                         onOutsideClick: { [weak self] in self?.model?.send(.unpin) })
        statusItem = StatusMenu.make(target: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() { buildPanel() }

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
        let host = NSHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func mouseMoved(_ point: NSPoint) {
        guard let model, let panel else { return }
        let rect = Layout.visibleRect(model.state.mode, notch: model.notch, screen: screenFrame)
            .insetBy(dx: -Layout.hoverSlack, dy: -Layout.hoverSlack)
        let inside = rect.contains(point)
        if inside != model.state.isHovering {
            let wasCompact = model.state.mode == .compact
            model.send(.hover(inside))
            if wasCompact && model.state.mode == .open { Haptics.tap() }
        }
        panel.ignoresMouseEvents = !inside
    }

    @objc func simulateTimer() { model?.send(.show(NotchEvent(title: "Focus block done", subtitle: "25:00 finished. Take 5.", tone: .success))) }
    @objc func simulateBuild() { model?.send(.show(NotchEvent(title: "Build failed", subtitle: "kroki · main · 2 tests", tone: .failure))) }
    @objc func simulateClaude() { model?.send(.show(NotchEvent(title: "Claude Code is waiting", subtitle: "kroki · needs your input", tone: .warning))) }
    @objc func quit() { NSApp.terminate(nil) }
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

    override var canBecomeKey: Bool { true }
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

enum StatusMenu {
    static func make(target: AppDelegate) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Hisashi")
        let menu = NSMenu()
        menu.addItem(entry("Simulate: timer done", #selector(AppDelegate.simulateTimer), target))
        menu.addItem(entry("Simulate: build failed", #selector(AppDelegate.simulateBuild), target))
        menu.addItem(entry("Simulate: Claude waiting", #selector(AppDelegate.simulateClaude), target))
        menu.addItem(.separator())
        menu.addItem(entry("Quit", #selector(AppDelegate.quit), target, key: "q"))
        item.menu = menu
        return item
    }

    private static func entry(_ title: String, _ action: Selector, _ target: AnyObject, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
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

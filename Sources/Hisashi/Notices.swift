import AppKit
import ApplicationServices

// Notifications of other apps, taken from the system banners through Accessibility.
// Notification Center builds each banner as an AXGroup (subrole AXNotificationCenterBanner,
// ...Alert for the persistent style, ...AlertStack when alerts pile up) with title, subtitle and body texts and the app's
// buttons as custom actions. It shows up in the tree before the banner slides in, so its
// window can be moved off screen unseen. The notification itself stays in Notification Center.
// Undocumented: checked on macOS 27.2.

/// Watches Notification Center for new banners, hides them and reports them.
/// Event driven: an AXObserver on the Notification Center process, no polling.
final class BannerWatch {
    private static let bundleID = "com.apple.notificationcenterui"
    /// Where hidden banner windows go: far below every screen.
    private static let offscreenY: CGFloat = 20_000

    var onNotice: (AppNotice) -> Void = { _ in }
    var onExpire: (String) -> Void = { _ in }

    private var pid: pid_t = 0
    private var observer: AXObserver?
    /// Live banners by id, kept to press their buttons.
    private var banners: [String: AXUIElement] = [:]
    /// Notifications seen in the open Notification Center; never shown as new.
    private var old = Set<String>()
    private var launchWatch: Any?

    /// False without the Accessibility permission.
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        attach()
        // Notification Center can restart; follow it.
        launchWatch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Self.bundleID { self?.attach() }
        }
        return true
    }

    /// Gives back any banner window still hidden, so nothing stays invisible after the notch quits.
    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        for window in windows() {
            if let p = position(window), p.y >= Self.offscreenY { setPosition(window, CGPoint(x: p.x, y: 0)) }
        }
        banners = [:]
    }

    func perform(_ effect: NoticeEffect, on notice: AppNotice) {
        guard let banner = banners[notice.id], role(banner) != nil else {
            // The banner already expired: opening the app is all that is left.
            if effect == .open { Self.openApp(named: notice.app) }
            return
        }
        switch effect {
        case .open:
            AXUIElementPerformAction(banner, kAXPressAction as CFString)
        case .press(let title):
            if let name = actionNames(banner).first(where: { Notices.buttons([$0]) == [title] }) {
                AXUIElementPerformAction(banner, name as CFString)
            }
        case .close:
            // A persistent alert would wait hidden forever; a temporary banner just runs out.
            if notice.persistent, let name = actionNames(banner).first(where: { $0.hasPrefix("Name:Close") }) {
                AXUIElementPerformAction(banner, name as CFString)
            }
        }
    }

    private func attach() {
        stop()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        pid = app.processIdentifier
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<BannerWatch>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let root = AXUIElementCreateApplication(pid)
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Created fires first, before the window exists; the others catch reused windows and expiry.
        for note in [kAXCreatedNotification, kAXWindowCreatedNotification, kAXLayoutChangedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(created, root, note as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        // A banner window left hidden by an earlier run would keep its banners invisible.
        for window in windows() {
            if let p = position(window), p.y >= Self.offscreenY { setPosition(window, CGPoint(x: p.x, y: 0)) }
        }
    }

    private func changed() {
        let dialogs = windows().filter { string($0, kAXSubroleAttribute) == "AXSystemDialog" }
        // The user opened Notification Center: it lives in the same window as the banners.
        // Give the window back and take nothing from it; what it lists is old.
        let panelOpen = dialogs.contains { isPanel($0, depth: 0) }
        if panelOpen {
            for window in dialogs {
                if let p = position(window), p.y >= Self.offscreenY { setPosition(window, CGPoint(x: p.x, y: 0)) }
            }
        }
        var live = Set<String>()
        for banner in dialogs.flatMap({ scan($0, depth: 0) }) {
            guard let id = string(banner, kAXIdentifierAttribute) else { continue }
            live.insert(id)
            guard banners[id] == nil, !old.contains(id) else { continue }
            if panelOpen {
                old.insert(id)
                continue
            }
            hide(banner)
            banners[id] = banner
            onNotice(notice(banner, id: id))
        }
        // Banners that left the tree took their buttons with them.
        for id in banners.keys where !live.contains(id) {
            banners[id] = nil
            onExpire(id)
        }
    }

    private func notice(_ banner: AXUIElement, id: String) -> AppNotice {
        var texts: [String: String] = [:]
        for child in children(banner) {
            if let key = string(child, kAXIdentifierAttribute), let value = string(child, kAXValueAttribute) {
                texts[key] = value
            }
        }
        let title = texts["title"] ?? ""
        return AppNotice(
            id: id,
            app: Notices.appName(description: string(banner, kAXDescriptionAttribute) ?? "", title: title),
            title: title,
            subtitle: texts["subtitle"] ?? "",
            body: texts["body"] ?? "",
            actions: Notices.buttons(actionNames(banner)),
            persistent: string(banner, kAXSubroleAttribute)?.hasPrefix("AXNotificationCenterAlert") == true)
    }

    /// Moves the banner's window far off screen, before it slides in.
    private func hide(_ banner: AXUIElement) {
        guard let value = attribute(banner, kAXWindowAttribute) else { return }
        let window = value as! AXUIElement
        guard let p = position(window), p.y < Self.offscreenY else { return }
        setPosition(window, CGPoint(x: p.x, y: Self.offscreenY))
    }

    /// The open panel has an Edit Widgets button; a window with only banners does not.
    private func isPanel(_ element: AXUIElement, depth: Int) -> Bool {
        if string(element, kAXIdentifierAttribute) == "widget-editor-button" { return true }
        return depth < 5 && children(element).contains { isPanel($0, depth: depth + 1) }
    }

    /// Banner groups sit a few levels under their window. Several persistent alerts fold into
    /// a stack that shows the newest one; the next comes up when it is handled.
    private func scan(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
        if Self.isBanner(string(element, kAXSubroleAttribute)) { return [element] }
        if depth >= 6 { return [] }
        return children(element).flatMap { scan($0, depth: depth + 1) }
    }

    private static func isBanner(_ subrole: String?) -> Bool {
        ["AXNotificationCenterBanner", "AXNotificationCenterAlert"].contains { subrole?.hasPrefix($0) == true }
    }

    private func windows() -> [AXUIElement] {
        guard pid != 0 else { return [] }
        return attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    // Thin AX helpers.

    private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ e: AXUIElement, _ name: String) -> String? { attribute(e, name) as? String }
    private func role(_ e: AXUIElement) -> String? { string(e, kAXRoleAttribute) }
    private func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    private func actionNames(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(e, &names)
        return names as? [String] ?? []
    }

    private func position(_ e: AXUIElement) -> CGPoint? {
        guard let value = attribute(e, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }

    private func setPosition(_ e: AXUIElement, _ point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, value) }
    }

    // App lookup by display name: the banner names the app, it gives no bundle id.

    private static var appURLs: [String: URL] = [:]

    static func appURL(named name: String) -> URL? {
        if let hit = appURLs[name] { return hit }
        let running = NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        let installed = folders.lazy.map { URL(fileURLWithPath: "\($0)/\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let url = running ?? installed
        appURLs[name] = url
        return url
    }

    static func openApp(named name: String) {
        guard let url = appURL(named: name) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Sender icons, looked up once per app.
enum Senders {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ app: String) -> NSImage? {
        if let hit = cache[app] { return hit }
        guard let url = BannerWatch.appURL(named: app) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[app] = image
        return image
    }
}

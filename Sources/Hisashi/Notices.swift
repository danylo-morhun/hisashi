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
    /// Fires when the watched Notification Center process exits.
    private var exitWatch: DispatchSourceProcess?

    /// False without the Accessibility permission.
    func start() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        attach()
        return true
    }

    /// Notification Center can restart, and launch notices do not cover it.
    /// The kernel says when the process exits; then wait for the new one and attach to it.
    private func watchExit() {
        exitWatch?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.reattach(tries: 20) }
        source.resume()
        exitWatch = source
    }

    private func reattach(tries: Int) {
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let next = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
            guard let next, next.processIdentifier != self.pid else { return self.reattach(tries: tries - 1) }
            // Give it a moment to build its windows before listening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.attach() }
        }
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
        watchExit()
        // A banner window left hidden by an earlier run would keep its banners invisible.
        for window in windows() {
            if let p = position(window), p.y >= Self.offscreenY { setPosition(window, CGPoint(x: p.x, y: 0)) }
        }
    }

    private func changed() {
        let dialogs = windows().filter { string($0, kAXSubroleAttribute) == "AXSystemDialog" }
        let found = dialogs.flatMap { scan($0, depth: 0) }
        // The user opened Notification Center: it lives in the same window as the banners.
        // A call or another banner the notch cannot draw needs the system's own window too.
        // Either way give the window back and take nothing from it while it lasts.
        let panelOpen = dialogs.contains { isPanel($0, depth: 0) }
        // Opened by the notch itself to clear: keep it out of sight and do the job.
        if panelOpen, let job = clearing {
            for window in dialogs { hideWindow(window) }
            if !job.done { finishClear(job, in: dialogs) }
            return
        }
        let yield = panelOpen || found.contains { passesThrough($0) }
        if yield {
            for window in dialogs {
                if let p = position(window), p.y >= Self.offscreenY { setPosition(window, CGPoint(x: p.x, y: 0)) }
            }
        }
        var live = Set<String>()
        for banner in found {
            guard let id = string(banner, kAXIdentifierAttribute) else { continue }
            live.insert(id)
            guard banners[id] == nil, !old.contains(id) else { continue }
            if yield {
                old.insert(id)
                continue
            }
            hide(banner)
            banners[id] = banner
            var next = notice(banner, id: id)
            if children(banner).contains(where: { role($0) == kAXImageRole }) { next.image = Photos.take(for: next) }
            onNotice(next)
        }
        // Banners that left the tree took their buttons with them.
        for id in banners.keys where !live.contains(id) {
            banners[id] = nil
            onExpire(id)
        }
    }

    /// Calls ring through their own interface, and a banner without title and body is drawn
    /// by its app: both stay with the system.
    private func passesThrough(_ banner: AXUIElement) -> Bool {
        let n = notice(banner, id: "")
        return Notices.passesThrough(app: n.app, title: n.title, body: n.body)
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
        hideWindow(value as! AXUIElement)
    }

    private func hideWindow(_ window: AXUIElement) {
        guard let p = position(window), p.y < Self.offscreenY else { return }
        setPosition(window, CGPoint(x: p.x, y: Self.offscreenY))
    }

    // Clearing. Only the open Notification Center panel can clear, and nothing public opens it.
    // Its keyboard shortcut (System Settings, Keyboard Shortcuts, Mission Control, "Show
    // Notification Centre") set to ctrl-option-command-F19 opens it without touching the mouse;
    // the panel is moved off screen as it appears, the stack's Clear All pressed, and the same
    // shortcut closes it again. Without the shortcut nothing opens and only the notch list clears.

    private struct ClearJob {
        /// The app whose stack to clear; nil clears everything.
        let app: String?
        /// The panel was already open, so it must stay open afterwards.
        let wasOpen: Bool
        var done = false
    }

    private var clearing: ClearJob?

    func clear(app: String?) {
        guard pid != 0, clearing == nil else { return }
        let dialogs = windows().filter { string($0, kAXSubroleAttribute) == "AXSystemDialog" }
        if dialogs.contains(where: { isPanel($0, depth: 0) }) {
            // The user has it open: clear in place, in sight.
            finishClear(ClearJob(app: app, wasOpen: true), in: dialogs)
            return
        }
        clearing = ClearJob(app: app, wasOpen: false)
        Self.pressShortcut()
        // Give up after a while: no shortcut set, or nothing to clear. Close what was opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let job = self.clearing, !job.done else { return }
            self.clearing?.done = true
            if self.windows().contains(where: { self.isPanel($0, depth: 0) }) { self.closePanel() } else { self.clearing = nil }
        }
    }

    private func finishClear(_ job: ClearJob, in dialogs: [AXUIElement]) {
        let target: AXUIElement?
        let action: String?
        if let app = job.app {
            let stacks = dialogs.flatMap { scan($0, depth: 0) }
            target = stacks.first { (string($0, kAXDescriptionAttribute) ?? "").hasPrefix(app + ",") }
            action = target.flatMap { actionNames($0).first { $0.hasPrefix("Name:Clear All") || $0.hasPrefix("Name:Close") } }
        } else {
            target = dialogs.lazy.compactMap { self.find($0, description: "Clear All", depth: 0) }.first
            action = target == nil ? nil : kAXPressAction as String
        }
        // The list may still be building; the next layout change tries again.
        guard let target, let action else { return }
        AXUIElementPerformAction(target, action as CFString)
        guard !job.wasOpen else { return }
        clearing?.done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.closePanel() }
    }

    /// Closes the panel the notch opened. Never leaves it open and hidden: if it did not
    /// close, it is handed back in sight.
    private func closePanel() {
        Self.pressShortcut()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.clearing = nil
            for window in self.windows() where self.isPanel(window, depth: 0) {
                if let p = self.position(window), p.y >= Self.offscreenY { self.setPosition(window, CGPoint(x: p.x, y: 0)) }
            }
        }
    }

    private func find(_ element: AXUIElement, description: String, depth: Int) -> AXUIElement? {
        if role(element) == kAXButtonRole as String, string(element, kAXDescriptionAttribute) == description { return element }
        guard depth < 8 else { return nil }
        for child in children(element) {
            if let hit = find(child, description: description, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// ctrl-option-command-F19, the shortcut set for Show Notification Centre.
    private static func pressShortcut() {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 80, keyDown: down) else { continue }
            event.flags = [.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
            event.post(tap: .cghidEventTap)
        }
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
                       NSHomeDirectory() + "/Applications", "/System/Library/CoreServices",
                       // AirDrop, Recents and the like live inside Finder.
                       "/System/Library/CoreServices/Finder.app/Contents/Applications"]
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

/// Pictures apps attach to notifications, such as a messenger's sender photo.
/// Notification Center copies each one into its own folder a moment before the banner
/// shows and deletes it as soon as the app withdraws the notification, so it is read at once.
/// The banner only says a picture exists; the newest file is it. A photo already copied for
/// an earlier notification is not copied again, so the last one per sender is remembered.
/// Needs Full Disk Access; without it notices simply have no photo.
enum Photos {
    private static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/attachments")
    private static var bySender: [String: Data] = [:]

    static func take(for notice: AppNotice) -> Data? {
        let sender = notice.app + "\u{1F}" + notice.title
        if let fresh = newest(within: 2) {
            if bySender.count > 100 { bySender.removeAll() }
            bySender[sender] = fresh
            return fresh
        }
        return bySender[sender]
    }

    private static func newest(within seconds: TimeInterval) -> Data? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
            return (url, date)
        }
        guard let (url, date) = dated.max(by: { $0.1 < $1.1 }), Date().timeIntervalSince(date) < seconds else { return nil }
        return try? Data(contentsOf: url)
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

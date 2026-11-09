import Foundation
import Observation

/// Holds state for the views and runs the one timed effect: auto-dismissing events.
@Observable
final class NotchModel {
    private(set) var state = NotchState()
    var notch: CGSize
    /// Set by the shell; sends a command to the active player.
    var sendMedia: (MediaCommand, NowPlaying) -> Void = { _, _ in }
    /// Set by the shell: what a click, a button and the close mark do to the system notification.
    var noticeEffect: (AppNotice, NoticeEffect) -> Void = { _, _ in }
    /// Set by the shell: clears an app's stack (nil: all) in Notification Center too.
    var clearCenter: (String?) -> Void = { _ in }
    /// Set by the shell: opens the app behind a listed notification.
    var openHistory: (HistoryItem) -> Void = { _ in }
    private var dismissTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    /// Time left on the shown temporary notice; the view draws it as a ring.
    private(set) var noticeClock: Countdown?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var clockID: String?

    init(notch: CGSize) {
        self.notch = notch
    }

    func send(_ action: NotchAction) {
        let next = reduce(state, action)
        // Every notice that just started leaving is removed once its exit has played.
        let leaving = next.notices.filter { n in n.leaving != nil && state.notices.contains { $0.id == n.id && $0.leaving == nil } }
        if next != state { state = next }
        if case .show = action { scheduleDismiss() }
        if case .showHud = action { scheduleHudDismiss() }
        for notice in leaving { finishLeaving(notice.id) }
        syncNoticeClock()
    }

    /// Click, button or close: the system notification gets the same, the notice plays its exit.
    /// A pressed button first turns into a check.
    func act(_ notice: AppNotice, _ effect: NoticeEffect) {
        guard notice.leaving == nil, notice.pressed == nil else { return }
        noticeEffect(notice, effect)
        switch effect {
        case .open: send(.leaveNotice(notice.id, .open))
        case .close: send(.leaveNotice(notice.id, .close))
        case .press(let title):
            send(.pressNotice(notice.id, title))
            after(0.8) { $0.send(.leaveNotice(notice.id, .press)) }
        }
    }

    /// Clears from the list at once; Notification Center follows.
    func clearHistory(_ app: String?) {
        send(.clearHistory(app: app, at: Date()))
        clearCenter(app)
    }

    /// Removes a notice once its exit has played.
    private func finishLeaving(_ id: String) {
        guard state.notices.contains(where: { $0.id == id && $0.leaving != nil }) else { return }
        after(0.6) { $0.send(.dismissNotice(id)) }
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor (NotchModel) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if let self { body(self) }
        }
    }

    /// Sends a command to the shown player.
    func media(_ command: MediaCommand) {
        guard let np = state.nowPlaying else { return }
        // Browsers ignore a bare toggle, so say exactly what to do.
        let explicit: MediaCommand = command == .toggle ? (np.isPlaying ? .pause : .play) : command
        if command == .toggle { send(.togglePlayback(at: Date())) }
        sendMedia(explicit, np)
    }

    /// Each key press restarts the timer, so holding a key keeps the HUD up.
    private func scheduleHudDismiss() {
        hudTask?.cancel()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.send(.dismissHud)
        }
    }

    /// A temporary notice hides after five seconds of being looked at, not counting hover.
    /// Keeps the clock in step with the shown notice and the hover after every action.
    private func syncNoticeClock() {
        let now = Date()
        guard let notice = state.notice, !notice.persistent, notice.leaving == nil, notice.pressed == nil else {
            noticeTask?.cancel()
            noticeTask = nil
            if noticeClock != nil { noticeClock = nil }
            clockID = nil
            return
        }
        if clockID != notice.id {
            clockID = notice.id
            noticeTask?.cancel()
            noticeTask = nil
            noticeClock = Countdown(total: 5)
        }
        guard let clock = noticeClock else { return }
        if state.isHovering, clock.since != nil {
            noticeTask?.cancel()
            noticeTask = nil
            noticeClock = clock.paused(at: now)
        } else if !state.isHovering, clock.since == nil {
            let running = clock.resumed(at: now)
            noticeClock = running
            noticeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(running.left))
                guard !Task.isCancelled else { return }
                self?.send(.leaveNotice(notice.id, .timeout))
            }
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            self?.send(.dismissEvent)
        }
    }
}

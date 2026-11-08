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
    private var dismissTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    /// The notice and hover state the running timer was armed for.
    @ObservationIgnored private var noticeTimer: (id: String, hovering: Bool)?

    init(notch: CGSize) {
        self.notch = notch
    }

    func send(_ action: NotchAction) {
        let next = reduce(state, action)
        if next != state { state = next }
        if case .show = action { scheduleDismiss() }
        if case .showHud = action { scheduleHudDismiss() }
        scheduleNoticeDismiss()
    }

    /// Click, button or close: the notice leaves the notch and the system notification gets the same.
    func act(_ notice: AppNotice, _ effect: NoticeEffect) {
        send(.dismissNotice(notice.id))
        noticeEffect(notice, effect)
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

    /// A temporary notice hides after a while; hovering holds it, leaving gives a shorter grace.
    /// Re-armed after every action, it only restarts when the shown notice or the hover changes.
    private func scheduleNoticeDismiss() {
        guard let notice = state.notice, !notice.persistent else {
            noticeTask?.cancel()
            noticeTimer = nil
            return
        }
        let key = (id: notice.id, hovering: state.isHovering)
        guard noticeTimer?.id != key.id || noticeTimer?.hovering != key.hovering else { return }
        let fresh = noticeTimer?.id != key.id
        noticeTimer = key
        noticeTask?.cancel()
        guard !key.hovering else { return }
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(fresh ? 5 : 2))
            guard !Task.isCancelled else { return }
            self?.send(.dismissNotice(notice.id))
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

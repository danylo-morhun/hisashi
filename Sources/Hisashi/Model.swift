import Foundation
import Observation

/// Holds state for the views and runs the one timed effect: auto-dismissing events.
@Observable
final class NotchModel {
    private(set) var state = NotchState()
    var notch: CGSize
    /// Set by the shell; sends a command to the active player.
    var sendMedia: (MediaCommand, NowPlaying) -> Void = { _, _ in }
    private var dismissTask: Task<Void, Never>?

    init(notch: CGSize) {
        self.notch = notch
    }

    func send(_ action: NotchAction) {
        let next = reduce(state, action)
        if next != state { state = next }
        if case .show = action { scheduleDismiss() }
    }

    /// Sends a command to the shown player.
    func media(_ command: MediaCommand) {
        guard let np = state.nowPlaying else { return }
        // Browsers ignore a bare toggle, so say exactly what to do.
        let explicit: MediaCommand = command == .toggle ? (np.isPlaying ? .pause : .play) : command
        if command == .toggle { send(.togglePlayback(at: Date())) }
        sendMedia(explicit, np)
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

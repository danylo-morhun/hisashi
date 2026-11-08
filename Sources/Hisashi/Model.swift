import Foundation
import Observation

/// Holds state for the views and runs the one timed effect: auto-dismissing events.
@Observable
final class NotchModel {
    private(set) var state = NotchState()
    var notch: CGSize
    private var dismissTask: Task<Void, Never>?

    init(notch: CGSize) {
        self.notch = notch
    }

    func send(_ action: NotchAction) {
        let next = reduce(state, action)
        if next != state { state = next }
        if case .show = action { scheduleDismiss() }
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

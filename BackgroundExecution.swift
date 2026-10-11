import UIKit
import Combine

/// Requests the finite background grace period provided by UIKit.
/// It does not promise continued execution after suspension or force-quit.
final class BackgroundExecution: ObservableObject {
    static let shared = BackgroundExecution()
    @Published private(set) var status = "Foreground"
    private var task: UIBackgroundTaskIdentifier = .invalid

    func leaveForeground() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Debian VM grace period") { [weak self] in
            guard let self = self else { return }
            self.status = "Background time expired; iOS may suspend the VM"
            self.finish()
        }
        status = task == .invalid ? "Background time unavailable" : "Limited background time requested"
    }

    func enterForeground() {
        finish()
        status = "Foreground"
    }

    private func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

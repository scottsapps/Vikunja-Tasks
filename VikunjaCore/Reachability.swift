import Foundation
import Network
import Observation

@Observable
final class Reachability {
    static let shared = Reachability()

    private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vikunja.reachability")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isOnline != online {
                    self.isOnline = online
                }
            }
        }
        monitor.start(queue: queue)
    }
}

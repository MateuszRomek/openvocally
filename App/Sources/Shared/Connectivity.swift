import Network
import Observation

/// Whether the Mac has a network path, read from interface state. It sends no requests.
/// Onboarding starts it while on screen so an offline Mac can retry the model download once it
/// reconnects.
@MainActor @Observable final class Connectivity {
  /// Nil until the first path arrives.
  private(set) var online: Bool?
  @ObservationIgnored private var task: Task<Void, Never>?

  func start() {
    guard task == nil else { return }
    task = Task { [weak self] in
      for await path in NWPathMonitor() {
        self?.online = path.status == .satisfied
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}

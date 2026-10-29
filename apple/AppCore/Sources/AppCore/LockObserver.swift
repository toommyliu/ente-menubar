import AppKit

@MainActor public final class LockObserver: NSObject {
  private weak var model: AppModel?

  public init(model: AppModel) {
    self.model = model
    super.init()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(lock), name: NSWorkspace.willSleepNotification, object: nil)
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(lock), name: NSNotification.Name("com.apple.screenIsLocked"),
      object: nil)
  }

  @objc nonisolated private func lock() {
    Task { @MainActor [weak self] in self?.model?.lock() }
  }
}

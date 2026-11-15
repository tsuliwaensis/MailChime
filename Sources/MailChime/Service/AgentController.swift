import AppKit
import MailChimeKit
import Network

/// Event-driven new-mail catch-up plus bounded read-status checks for displayed notifications.
@MainActor
final class AgentController: NSObject {
  private let checker: CatchUpWorker
  private let monitor = NWPathMonitor()
  private var task: Task<Void, Never>?
  private var clearing: Task<Void, Never>?
  private var clearingLoop: Task<Void, Never>?
  private var pending = false
  private var online = false
  init(checker: CatchUpWorker = CatchUpWorker()) {
    self.checker = checker
    super.init()
  }
  func start() {
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(settingsChanged),
      name: Notification.Name(AppIdentity.settingsChanged), object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      Task { @MainActor in
        guard let self else { return }
        let restored = satisfied && !self.online
        self.online = satisfied
        if !satisfied { self.clearing?.cancel() }
        if restored { self.requestCheck(settle: true) }
      }
    }
    monitor.start(queue: DispatchQueue(label: AppIdentity.dispatchQueueLabel("network")))
    startClearing()
    requestCheck(settle: true)
  }
  func stop() {
    clearing?.cancel(); clearingLoop?.cancel()
    clearingLoop = nil
    task?.cancel()
    task = nil
    monitor.cancel()
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
  @objc private func woke() { requestCheck(settle: true) }
  @objc private func settingsChanged() {
    if (try? checker.store.settings().enabled) != true {
      task?.cancel()
      clearing?.cancel(); clearingLoop?.cancel(); clearingLoop = nil
      PushRegistrar.shared.stop()
      return
    }
    startClearing()
    requestCheck(settle: true)
  }
  private func startClearing() {
    guard clearingLoop == nil, (try? checker.store.settings().enabled) == true else { return }
    clearingLoop = Task { [weak self] in
      while !Task.isCancelled {
        self?.requestClearing()
        do { try await Task.sleep(for: .seconds(30), tolerance: .seconds(5)) } catch { return }
      }
    }
  }
  private func requestClearing() {
    guard online, clearing == nil, (try? checker.store.settings().enabled) == true else { return }
    clearing = Task {
      defer { clearing = nil }
      await ReadNotificationReconciler(store: checker.store).run()
    }
  }
  private func requestCheck(settle: Bool) {
    guard task == nil else {
      pending = true
      return
    }
    guard (try? checker.store.settings().enabled) == true else { return }
    task = Task {
      defer {
        task = nil
        if pending {
          pending = false
          requestCheck(settle: true)
        }
      }
      if settle { do { try await Task.sleep(for: .seconds(5)) } catch { return } }
      guard !Task.isCancelled, (try? checker.store.settings().enabled) == true else { return }
      // Registration uses the same process lock as catch-up and cannot reset offered cursors mid-page.
      do { try await PushRegistrar.shared.refresh() } catch { try? ErrorLog().record(error) }
      guard !Task.isCancelled else { return }
      _ = await checker.run()
      requestClearing()
    }
  }
}

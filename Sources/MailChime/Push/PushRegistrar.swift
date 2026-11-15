import AppKit
import MailChimeKit
import Observation

@MainActor @Observable
final class PushRegistrar: NSObject {
  static let shared = PushRegistrar()
  var apnsStatus = String(localized: "Not registered")
  var workerStatus = String(localized: "Not registered")
  var lastError: MailError?
  private var token: Data?
  private var failed = false
  private var operation: Task<Void, Error>?
  private var retry: Task<Void, Never>?
  private var retryCount = 0
  private let store = AgentStore()
  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(timeZoneChanged),
      name: .NSSystemTimeZoneDidChange, object: nil)
  }
  var environment: PushEnvironment? {
    try? PushEnvironment.current()
  }
  func registered(_ token: Data) {
    let changed = self.token != token
    self.token = token
    failed = false
    lastError = nil
    apnsStatus = String(localized: "Registered")
    // An unsolicited token rotation must update the Worker as well as the UI.
    // An in-flight refresh already consumes the callback and sends this token.
    if changed && operation == nil { startIfEnabled() }
  }
  func registrationFailed(_ error: Error) {
    failed = true
    apnsStatus = String(localized: "Not registered")
    lastError = .pushRegistration
    try? ErrorLog().record(MailError.pushRegistration)
  }
  func startIfEnabled() {
    guard !SingleInstance.isExempt(), (try? store.settings().enabled) == true else { return }
    Task { try? await refresh() }
  }
  @objc private func timeZoneChanged() { startIfEnabled() }
  func stop() {
    lastError = nil
    retry?.cancel()
    retry = nil
    operation?.cancel()
    operation = nil
    NSApp.unregisterForRemoteNotifications()
    token = nil
    apnsStatus = String(localized: "Not registered")
    workerStatus = String(localized: "Not registered")
  }
  func refresh() async throws {
    if let operation { return try await operation.value }
    let task = Task { try await self.performRefresh() }
    operation = task
    defer { operation = nil }
    do {
      try await task.value
      retry?.cancel()
      retry = nil
      retryCount = 0
      lastError = nil
    } catch {
      lastError = (error as? MailError) ?? .relayUnavailable
      workerStatus = String(localized: "Not registered")
      scheduleRetry()
      throw error
    }
  }
  func requestToken() async throws -> Data {
    token = nil
    failed = false
    lastError = nil
    apnsStatus = String(localized: "Registering…")
    NSApp.registerForRemoteNotifications()
    let deadline = Date().addingTimeInterval(20)
    while token == nil && !failed && Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard !failed, let token, !token.isEmpty else { throw MailError.pushRegistration }
    return token
  }
  private func performRefresh() async throws {
    guard try store.settings().enabled else { throw MailError.notifications }
    guard let environment else { throw MailError.pushEnvironment }
    guard let credentials = try CredentialStore.load() else { throw MailError.missingCredentials }
    let token = try await requestToken()
    try Task.checkCancellation()
    let lock = try store.lock()
    defer { withExtendedLifetime(lock) {} }
    // A settings change while APNs was responding must not resurrect the old registration.
    guard try store.settings().enabled, try CredentialStore.load() == credentials else {
      throw MailError.missingCredentials
    }
    let key = try SharedKeychain.payloadKey(identity: credentials.identity, create: true)
    let shared = try store.shared()
    do {
      try await RelayAPI(credentials: credentials).register(
        token: token.map { String(format: "%02x", $0) }.joined(), environment: environment, key: key
      )
      workerStatus = String(localized: "Registered")
      try shared.save(
        RegistrationState(
          identity: credentials.identity, environment: environment, registered: true,
          message: workerStatus), to: "registration.json")
    } catch {
      try? shared.save(
        RegistrationState(
          identity: credentials.identity, environment: environment, registered: false,
          message: ((error as? MailError) ?? .relayUnavailable).localizedDescription),
        to: "registration.json")
      throw error
    }
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(AppIdentity.statusChanged), object: nil,
      userInfo: nil, deliverImmediately: true)
  }
  private func scheduleRetry() {
    guard retry == nil, (try? store.settings().enabled) == true else { return }
    retryCount += 1
    let delay = min(300, 15 * (1 << min(retryCount - 1, 4)))
    retry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      guard let self else { return }
      self.retry = nil
      guard (try? self.store.settings().enabled) == true else { return }
      try? await self.refresh()
    }
  }
}

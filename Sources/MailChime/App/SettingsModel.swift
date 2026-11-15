import AppKit
import MailChimeKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class SettingsModel: NSObject {
  var relayURL = Defaults.relayURL
  var deviceSecret = ""
  var hasCredentials = false
  var enabled = false
  var busy = false
  enum FeedbackSection { case relay, notifications, activity }
  struct Feedback: Equatable {
    let message: String
    let isError: Bool
  }
  var relayFeedback: Feedback?
  var notificationFeedback: Feedback?
  var activityFeedback: Feedback?
  private var relayStatusError: MailError?
  static func section(for error: MailError, fallback: FeedbackSection) -> FeedbackSection {
    switch error {
    case .credentials, .missingCredentials, .keychain, .relayAuthentication, .relayUnavailable, .invalidPayload:
      return .relay
    case .notifications, .pushRegistration, .pushEnvironment, .deviceRegistration, .agent, .agentBundle:
      return .notifications
    default: return fallback
    }
  }
  func messages(in section: FeedbackSection) -> [Feedback] {
    var messages: [Feedback] = []
    let feedback: Feedback?
    switch section {
    case .relay: feedback = relayFeedback
    case .notifications: feedback = notificationFeedback
    case .activity: feedback = activityFeedback
    }
    if let feedback { messages.append(feedback) }
    for error in [relayStatusError, registrar.lastError].compactMap({ $0 }) {
      if Self.section(for: error, fallback: .notifications) == section {
        let message = Feedback(message: error.localizedDescription, isError: true)
        if !messages.contains(message) { messages.append(message) }
      }
    }
    if let status, !status.success,
      Self.section(for: status.failure ?? .storage, fallback: .activity) == section {
      let message = Feedback(message: status.message, isError: true)
      if !messages.contains(message) { messages.append(message) }
    }
    return messages
  }
  func report(_ error: Error, in section: FeedbackSection) {
    let safe = (error as? MailError) ?? .relayUnavailable
    setFeedback(Feedback(message: safe.localizedDescription, isError: true),
      in: Self.section(for: safe, fallback: section))
  }
  private func setFeedback(_ feedback: Feedback?, in section: FeedbackSection) {
    switch section {
    case .relay: relayFeedback = feedback
    case .notifications: notificationFeedback = feedback
    case .activity: activityFeedback = feedback
    }
  }
  private func succeed(_ message: String, in section: FeedbackSection) {
    setFeedback(Feedback(message: message, isError: false), in: section)
  }
  var status: CheckStatus?
  var remoteStatus: RelayStatus?
  var workerStatus = String(localized: "Not registered")
  var agentBundleAvailable = AgentRegistration.bundleIsValid()
  var serviceStatus = SMAppService.Status.notRegistered
  var registrar = PushRegistrar.shared
  private let store: AgentStore
  private let loadCredentials: () throws -> RelayCredentials?
  private let saveCredentialsStore: (RelayCredentials) throws -> Void
  private let service = SMAppService.agent(plistName: AppIdentity.agentLabel + ".plist")
  private var refreshing = false
  init(
    store: AgentStore = AgentStore(),
    loadCredentials: @escaping () throws -> RelayCredentials? = CredentialStore.load,
    saveCredentialsStore: @escaping (RelayCredentials) throws -> Void = CredentialStore.save,
    loadOnInit: Bool = true
  ) {
    self.store = store
    self.loadCredentials = loadCredentials
    self.saveCredentialsStore = saveCredentialsStore
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(refreshStatus),
      name: Notification.Name(AppIdentity.statusChanged), object: nil)
    if loadOnInit { load() }
  }
  func load() {
    do {
      let value = try loadCredentials()
      relayURL = value?.relayURL ?? Defaults.relayURL
      hasCredentials = value != nil
      enabled = try store.settings().enabled
      refreshStatus()
    } catch { report(error, in: .relay) }
  }
  @objc func refreshStatus() {
    do { status = try store.load("status.json", as: CheckStatus.self) } catch { report(error, in: .activity) }
    serviceStatus = service.status
    agentBundleAvailable = AgentRegistration.bundleIsValid()
    guard !SingleInstance.isExempt(), !refreshing else { return }
    refreshing = true
    Task {
      defer { refreshing = false }
      do {
        guard let credentials = try loadCredentials() else { return }
        remoteStatus = try await RelayAPI(credentials: credentials).status()
        relayStatusError = nil
        workerStatus =
          remoteStatus?.device?.deviceId == credentials.deviceId
          ? String(localized: "Registered") : String(localized: "Not registered")
      } catch {
        remoteStatus = nil
        workerStatus = String(localized: "Not registered")
        relayStatusError = (error as? MailError) ?? .relayUnavailable
      }
    }
  }
  func saveCredentials() {
    relayFeedback = nil
    do {
      let lock = try store.lock()
      defer { withExtendedLifetime(lock) {} }
      let old = try loadCredentials()
      let proposed = try RelayCredentials(
        relayURL: relayURL,
        deviceSecret: deviceSecret.isEmpty ? old?.deviceSecret ?? "" : deviceSecret,
        identity: old?.identity ?? UUID())
      if enabled, let old, old.relayURL != proposed.relayURL {
        relayFeedback = Feedback(message: String(localized: "Turn off notifications before changing the relay URL."), isError: true)
        return
      }
      let value = try RelayCredentials(
        relayURL: proposed.relayURL, deviceSecret: proposed.deviceSecret,
        identity: old?.relayURL == proposed.relayURL ? proposed.identity : UUID())
      _ = try SharedKeychain.payloadKey(identity: value.identity, create: true)
      try saveCredentialsStore(value)
      relayURL = value.relayURL
      deviceSecret = ""
      hasCredentials = true
      relayStatusError = nil
      succeed(String(localized: "Relay credentials saved in Keychain."), in: .relay)
      signalSettings()
      registrar.startIfEnabled()
    } catch {
      report((error as? MailError) ?? .keychain, in: .relay)
    }
  }
  func setEnabled(_ requested: Bool) async {
    guard !busy else { return }
    busy = true
    notificationFeedback = nil
    if relayFeedback?.isError == true { relayFeedback = nil }
    defer {
      busy = false
      refreshStatus()
    }
    do {
      guard let credentials = try loadCredentials() else { throw MailError.missingCredentials }
      if requested {
        guard agentBundleAvailable else { throw MailError.agentBundle }
        guard
          try await UNUserNotificationCenter.current().requestAuthorization(options: [
            .alert, .sound,
          ])
        else { throw MailError.notifications }
        do {
          let lock = try store.lock()
          defer { withExtendedLifetime(lock) {} }
          try store.save(AgentSettings(enabled: true), to: "settings.json")
        }
        enabled = true
        try await registrar.refresh()
        try await AgentRegistration.refresh()
        succeed(service.status == .requiresApproval
          ? String(localized: "Approve MailChime in Login Items to check for missed mail after sleep.")
          : String(localized: "Notifications enabled."), in: .notifications)
      } else {
        registrar.stop()
        let lock = try store.lock()
        defer { withExtendedLifetime(lock) {} }
        do { try await RelayAPI(credentials: credentials).remove() } catch MailError
          .deviceRegistration
        { /* Already removed or replaced. */  }
        try store.save(AgentSettings(enabled: false), to: "settings.json")
        enabled = false
        if service.status == .enabled || service.status == .requiresApproval {
          try await service.unregister()
        }
        succeed(String(localized: "Notifications disabled."), in: .notifications)
      }
      signalSettings()
    } catch {
      enabled = (try? store.settings().enabled) ?? false
      report(error, in: .notifications)
      signalSettings()
      if enabled { registrar.startIfEnabled() }
    }
  }
  func restartBackgroundAgent() async {
    guard !busy, enabled else { return }
    busy = true
    notificationFeedback = nil
    defer {
      busy = false
      refreshStatus()
    }
    do {
      guard AgentRegistration.bundleIsValid() else { throw MailError.agentBundle }
      try await AgentRegistration.refresh()
      succeed(
        service.status == .requiresApproval
          ? String(localized: "Approve MailChime in Login Items to restart the background agent.")
          : String(localized: "Background agent restarted"),
        in: .notifications)
    } catch {
      report((error as? MailError) ?? .agent, in: .notifications)
    }
  }
  func retryRegistration() async {
    busy = true
    notificationFeedback = nil
    if relayFeedback?.isError == true { relayFeedback = nil }
    defer {
      busy = false
      refreshStatus()
    }
    do {
      try await registrar.refresh()
      try await AgentRegistration.refresh()
      succeed(String(localized: "Registration refreshed."), in: .notifications)
    } catch { report(error, in: .notifications) }
  }
  func sendTest() async {
    busy = true
    notificationFeedback = nil
    if relayFeedback?.isError == true { relayFeedback = nil }
    defer {
      busy = false
      refreshStatus()
    }
    do {
      guard let credentials = try loadCredentials() else { throw MailError.missingCredentials }
      try await RelayAPI(credentials: credentials).test()
      succeed(String(localized: "APNs accepted the test notification. Check Notification Center."), in: .notifications)
    } catch { report(error, in: .notifications) }
  }
  func runNow() async {
    activityFeedback = nil
    busy = true
    defer {
      busy = false
      refreshStatus()
    }
    _ = await CatchUpWorker(store: store).run()
    await ReadNotificationReconciler(store: store).run()
  }
  private func signalSettings() {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(AppIdentity.settingsChanged), object: nil,
      userInfo: nil, deliverImmediately: true)
  }
  func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
  func viewLogs() {
    activityFeedback = nil
    do {
      try store.prepare()
      guard NSWorkspace.shared.open(store.directory) else { throw MailError.storage }
    } catch { report((error as? MailError) ?? .storage, in: .activity) }
  }

}
/// Validate the embedded definition independently of macOS registration state.
@MainActor
enum AgentRegistration {
  static func refresh() async throws {
    let service = SMAppService.agent(plistName: AppIdentity.agentLabel + ".plist")
    try await refresh(
      status: { service.status },
      unregister: { try await service.unregister() },
      register: { try service.register() })
  }

  /// Registration can remain enabled after the registered app has moved or been deleted.
  /// Rebind explicitly when enabling notifications; do not reset pending user approval.
  static func refresh(
    status: () -> SMAppService.Status,
    unregister: () async throws -> Void,
    register: () throws -> Void
  ) async throws {
    guard status() != .requiresApproval else { return }
    if status() == .enabled { try await unregister() }
    do { try register() } catch {
      if status() != .requiresApproval { throw error }
    }
    guard status() == .enabled || status() == .requiresApproval else { throw MailError.agent }
  }

  static func bundleIsValid(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
    let plistURL = bundleURL.appendingPathComponent(
      "Contents/Library/LaunchAgents/" + AppIdentity.agentLabel + ".plist")
    guard let data = try? Data(contentsOf: plistURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      plist["Label"] as? String == AppIdentity.agentLabel,
      plist["BundleProgram"] as? String == "Contents/MacOS/MailChime",
      plist["ProgramArguments"] as? [String] == ["MailChime", "--agent"]
    else { return false }
    return FileManager.default.isExecutableFile(
      atPath: bundleURL.appendingPathComponent("Contents/MacOS/MailChime").path)
  }

  static func statusText(_ status: SMAppService.Status, bundleAvailable: Bool) -> String {
    guard bundleAvailable else { return String(localized: "Agent missing from app bundle") }
    switch status {
    case .enabled: return String(localized: "Registered")
    case .requiresApproval: return String(localized: "Approval required")
    case .notRegistered, .notFound: return String(localized: "Not registered")
    @unknown default: return String(localized: "Unknown")
    }
  }
}

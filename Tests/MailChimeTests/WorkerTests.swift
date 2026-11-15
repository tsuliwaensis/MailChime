import AppKit
import MailChimeKit
import Foundation
import ServiceManagement
import Testing
import UserNotifications

@testable import MailChime

@Test @MainActor func aboutPresentationUsesMailChimeAndAttributionLinks() {
  #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "MailChime")
  #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "MailChime")
  #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "NewAppIcon")
  #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String == "NewAppIcon")
  #expect(AppPresentation.aboutOptions[.applicationName] as? String == "MailChime")
  let credits = AppPresentation.aboutCredits
  let lines = credits.string.components(separatedBy: "\n")
  #expect(
    lines == [
      "© 2026 RHPT.",
      "Licensed under the MIT License.",
      "Based on MailBell by Marton Paulo and Samzong.",
    ])
  let nsString = credits.string as NSString
  let martonRange = nsString.range(of: "Marton Paulo")
  let samzongRange = nsString.range(of: "Samzong")
  #expect(
    credits.attribute(.link, at: martonRange.location, effectiveRange: nil) as? URL
      == URL(string: "https://github.com/martonpaulo/mailbell"))
  #expect(
    credits.attribute(.link, at: samzongRange.location, effectiveRange: nil) as? URL
      == URL(string: "https://github.com/samzong/"))
}

@Test @MainActor func bundledUnregisteredAgentIsNotReportedMissing() {
  #expect(AgentRegistration.bundleIsValid())
  #expect(AgentRegistration.statusText(.notFound, bundleAvailable: true) == "Not registered")
  #expect(
    AgentRegistration.statusText(.notFound, bundleAvailable: false)
      == "Agent missing from app bundle")
  #expect(
    AgentRegistration.statusText(.requiresApproval, bundleAvailable: true) == "Approval required")
}

@Test @MainActor func missingOrMalformedAgentDefinitionIsDetected() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(!AgentRegistration.bundleIsValid(bundleURL: root))
  let plist = root.appendingPathComponent(
    "Contents/Library/LaunchAgents/" + AppIdentity.agentLabel + ".plist")
  try FileManager.default.createDirectory(
    at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data("invalid".utf8).write(to: plist)
  #expect(!AgentRegistration.bundleIsValid(bundleURL: root))
}

@Test func inaccessibleSettingsAreNotTreatedAsMissingDefaults() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = AgentStore(directory: root)
  try store.save(AgentSettings(enabled: true), to: "settings.json")
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try? FileManager.default.removeItem(at: root)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
  #expect(throws: MailError.storage) { try store.settings() }
}

@Test @MainActor func notificationContainsRequestedFieldsAndTitle() {
  let message = MessageHeaders(
    id: "m10", from: "Sender <sender@example.com>", subject: "Hello",
    receivedAt: Date(timeIntervalSince1970: 1_793_381_400))
  let content = NotificationContent.make(for: message)
  let formatter = DateFormatter()
  formatter.dateStyle = .medium
  formatter.timeStyle = .short
  #expect(content.title == "Here's The Mail!")
  #expect(
    content.body == "From: Sender <sender@example.com>\nSubject: Hello\nReceived: "
      + formatter.string(from: message.receivedAt))
  #expect(content.sound != nil)
}

@Test @MainActor func notificationClickOpensDefaultAppWithoutMailtoDraft() async {
  let app = URL(fileURLWithPath: "/Applications/Example Mail.app")
  var lookup: URL?
  var launches: [URL] = []
  let handler = NotificationResponseHandler(
    resolve: {
      lookup = $0
      return app
    },
    launch: { launches.append($0) }, reportFailure: { _ in Issue.record("Unexpected error") })
  await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier)
  #expect(lookup?.absoluteString == "mailto:")
  #expect(launches == [app])
}

@Test @MainActor func dismissingNotificationDoesNotOpenMail() async {
  let handler = NotificationResponseHandler(
    resolve: { _ in
      Issue.record("Unexpected lookup")
      return nil
    },
    launch: { _ in Issue.record("Unexpected launch") },
    reportFailure: { _ in Issue.record("Unexpected error") })
  await handler.handle(actionIdentifier: UNNotificationDismissActionIdentifier)
  await handler.handle(actionIdentifier: "unknown-action")
}

@Test @MainActor func coldNotificationLaunchTerminatesAfterMailAppOpens() async {
  var events: [String] = []
  let handler = NotificationResponseHandler(
    resolve: { _ in URL(fileURLWithPath: "/Applications/Example Mail.app") },
    launch: { _ in events.append("mail") },
    reportFailure: { _ in Issue.record("Unexpected failure") },
    terminate: { events.append("terminate") })
  handler.terminateAfterResponse = true
  await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier)
  #expect(events == ["mail", "terminate"])
}

@Test @MainActor func responseBeforeLaunchFinishesStillTerminates() async {
  var events: [String] = []
  let handler = NotificationResponseHandler(
    resolve: { _ in URL(fileURLWithPath: "/Applications/Example Mail.app") },
    launch: { _ in events.append("mail") },
    reportFailure: { _ in Issue.record("Unexpected failure") },
    terminate: { events.append("terminate") })
  await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier)
  #expect(handler.receivedDefaultAction)
  #expect(events == ["mail"])
  handler.terminateAfterResponse = true
  #expect(events == ["mail", "terminate"])
}

@Test @MainActor func missingDefaultMailAppShowsSafeError() async {
  var failure: NotificationResponseHandler.MailAppError?
  let handler = NotificationResponseHandler(
    resolve: { _ in nil },
    launch: { _ in Issue.record("Unexpected launch") }, reportFailure: { failure = $0 })
  await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier)
  #expect(failure == .notConfigured)
}

@Test @MainActor func mailAppLaunchFailureIsReportedWithoutSystemErrorDetails() async {
  var failure: NotificationResponseHandler.MailAppError?
  let handler = NotificationResponseHandler(
    resolve: { _ in URL(fileURLWithPath: "/Applications/Example Mail.app") },
    launch: { _ in throw MailError.relayUnavailable }, reportFailure: { failure = $0 })
  await handler.handle(actionIdentifier: UNNotificationDefaultActionIdentifier)
  #expect(failure == .launchFailed)
}

@Test @MainActor func notificationDelegateIsInstalledDuringAppStartup() {
  #expect(UNUserNotificationCenter.current().delegate === NotificationResponseHandler.shared)
}

@Test @MainActor func applyingScheduleRebindsAnEnabledAgent() async throws {
  var status = SMAppService.Status.enabled
  var events: [String] = []
  try await AgentRegistration.refresh(
    status: { status },
    unregister: {
      events.append("unregister")
      status = .notRegistered
    },
    register: {
      events.append("register-current-bundle")
      status = .enabled
    })
  #expect(events == ["unregister", "register-current-bundle"])
  #expect(status == .enabled)
}

@Test @MainActor func applyingSchedulePreservesPendingApproval() async throws {
  try await AgentRegistration.refresh(
    status: { .requiresApproval },
    unregister: { Issue.record("Must preserve pending approval") },
    register: { Issue.record("Must not register again while approval is pending") })
}

@Test @MainActor func applyingScheduleRegistersNewAgent() async throws {
  var status = SMAppService.Status.notRegistered
  try await AgentRegistration.refresh(
    status: { status },
    unregister: { Issue.record("No existing registration to remove") },
    register: { status = .enabled })
  #expect(status == .enabled)
}

@Test @MainActor func scheduleRegistrationFailureIsNotHiddenByEnabledStatus() async {
  do {
    try await AgentRegistration.refresh(
      status: { .enabled }, unregister: { throw MailError.agent },
      register: { Issue.record("Must not register after failed removal") })
    Issue.record("Failed registration refresh must be reported")
  } catch { #expect(error as? MailError == .agent) }
}

@Test @MainActor func scheduleRegistrationCanRequestApproval() async throws {
  var status = SMAppService.Status.notRegistered
  try await AgentRegistration.refresh(
    status: { status }, unregister: {},
    register: {
      status = .requiresApproval
      throw MailError.agent
    })
  #expect(status == .requiresApproval)
}

@Test func errorLogAppendsRotatesAndRestrictsPermissions() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let log = ErrorLog(directory: root, maximumBytes: 650)
  try log.record(MailError.relayUnavailable)
  try log.record(MailError.timeout)
  let file = root.appendingPathComponent("errors.log")
  let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
  #expect(lines.count == 2)
  let entry = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String]
  #expect(entry?["error"] == MailError.relayUnavailable.localizedDescription)
  #expect(entry?["timestamp"] != nil)
  for _ in 0..<6 { try log.record(MailError.relayAuthentication) }
  #expect(
    FileManager.default.fileExists(atPath: root.appendingPathComponent("errors.previous.log").path))
  #expect(try Data(contentsOf: file).count <= 650)
  let permissions =
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
  #expect(permissions == 0o600)
}

@Test @MainActor func bundledNotificationSoundIsValid() throws {
  let url = try #require(Bundle.main.url(forResource: "Notification_A", withExtension: "aiff"))
  let sound = try #require(NSSound(contentsOf: url, byReference: false))
  #expect(sound.duration > 0 && sound.duration < 30)
  #expect(FailureReporter.content().sound != nil)
}

@Test @MainActor func agentOpensSeparateSettingsInstanceWithoutAgentArguments() {
  let configuration = BackgroundAppDelegate.settingsLaunchConfiguration()
  #expect(configuration.createsNewApplicationInstance)
  #expect(configuration.activates)
  #expect(configuration.arguments.isEmpty)
}

@Test func instanceLockAllowsOneHolderAndRecordsItsProcess() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("settings.lock")
  #expect(InstanceLock.holder(at: url) == .none)
  var first = InstanceLock(url: url)
  #expect(first != nil)
  #expect(InstanceLock(url: url) == nil)
  #expect(InstanceLock.holder(at: url) == .process(getpid()))
  first = nil
  #expect(InstanceLock.holder(at: url) == .none)
  #expect(InstanceLock(url: url) != nil)
}

@Test @MainActor func duplicateRolesAreRefusedAcrossBundleCopies() throws {
  let store = AgentStore(
    directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  defer { try? FileManager.default.removeItem(at: store.directory) }
  try store.prepare()
  // Another launch of MailChime holds the settings role through its own open file description.
  let other = try #require(InstanceLock(url: SingleInstance.lockURL(.settings, store: store)))
  #expect(!SingleInstance.acquire(.settings, store: store))
  #expect(SingleInstance.holder(.settings, store: store) == .process(getpid()))
  #expect(SingleInstance.holder(.agent, store: store) == .none)
  withExtendedLifetime(other) {}
}

@Test @MainActor func diagnosticsAndTestHostsBypassTheSingleInstanceGuard() {
  #expect(SingleInstance.isExempt(arguments: ["MailChime", "--diagnose-interface"], environment: [:]))
  #expect(SingleInstance.isExempt(arguments: ["MailChime", "--test-notification"], environment: [:]))
  #expect(SingleInstance.isExempt(arguments: ["MailChime"], environment: ["XCTestBundlePath": "/x"]))
  #expect(!SingleInstance.isExempt(arguments: ["MailChime"], environment: [:]))
  #expect(!SingleInstance.isExempt(arguments: ["MailChime", "--agent"], environment: [:]))
}

@Test @MainActor func agentActivationDoesNotOpenSettingsButExplicitReopenDoes() {
  var requests = 0
  let delegate = BackgroundAppDelegate(settingsRequest: { requests += 1 })
  let policy = NSApp.activationPolicy()
  defer { NSApp.setActivationPolicy(policy) }
  delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
  #expect(requests == 0)
  #expect(NSApp.activationPolicy() == .prohibited)
  #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == false)
  #expect(requests == 1)
}

@Test @MainActor func notificationReopenDoesNotLaunchSettings() {
  var requests = 0
  let delegate = BackgroundAppDelegate(
    settingsRequest: { requests += 1 }, notificationEvent: { true })
  let policy = NSApp.activationPolicy()
  defer { NSApp.setActivationPolicy(policy) }
  #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
  delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
  #expect(requests == 0)
  #expect(NSApp.activationPolicy() == .prohibited)
}

@Test @MainActor func notificationSendersAreDistinctFromNormalAppOpenSenders() {
  #expect(AppOpenOrigin.isNotificationSender("com.apple.usernoted"))
  #expect(AppOpenOrigin.isNotificationSender("com.apple.notificationcenterui"))
  #expect(!AppOpenOrigin.isNotificationSender("com.apple.finder"))
  #expect(!AppOpenOrigin.isNotificationSender("com.apple.dock"))
  #expect(!AppOpenOrigin.isNotificationSender(nil))

}

@MainActor private final class MockRelay: RelayTransport {
  var page: MissedResponse
  var acknowledgements: [Int] = []
  var failAck = false
  var requests = 0
  init(messages: [PushPayload], next: Int = 7) {
    page = MissedResponse(
      v: 1, messages: messages, nextCursor: next, hasMore: false, droppedThrough: 0, gap: false)
  }
  func missed(after: Int) async throws -> MissedResponse {
    requests += 1
    return page
  }
  func acknowledge(_ seq: Int) async throws {
    if failAck { throw MailError.relayUnavailable }
    acknowledgements.append(seq)
  }
}
@Suite @MainActor struct CatchUpTests {
  private func fixture() throws -> (AgentStore, RelayCredentials, PushPayload) {
    let store = AgentStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    return (
      store,
      try RelayCredentials(
        relayURL: "https://relay.example", deviceSecret: String(repeating: "d", count: 64)),
      try fixturePayload()
    )
  }
  @Test func firstIdentitySuppressesHistoricalGapButExistingCursorReportsIt() async throws {
    for existing in [false, true] {
      let (store, credentials, _) = try fixture()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      if existing { try store.shared().save(RelayCursor(identity: credentials.identity), to: "cursor.json") }
      let relay = MockRelay(messages: [], next: 10)
      relay.page = MissedResponse(v: 1, messages: [], nextCursor: 10, hasMore: false,
        droppedThrough: 10, gap: true)
      let worker = CatchUpWorker(store: store, credentials: { credentials },
        payloadKey: { _ in fixtureKey }, transport: { _ in relay }, authorized: { true },
        notify: { _, _ in Issue.record("Empty page must not notify") }, failure: { _ in Issue.record("Unexpected failure") })
      #expect(await worker.run())
      let status = try store.load("status.json", as: CheckStatus.self)
      #expect((status?.message == MailError.retentionGap.localizedDescription) == existing)
      #expect(relay.acknowledgements == [10])
    }
  }
  @Test func deliveredRemoteSequenceIsSkippedAndAcknowledged() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    try store.shared().record(payload.seq, identity: credentials.identity)
    let relay = MockRelay(messages: [payload])
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { true }, notify: { _, _ in Issue.record("Remote delivery must be skipped") },
      failure: { _ in Issue.record("Unexpected failure") })
    #expect(await worker.run())
    #expect(relay.acknowledgements == [7])
    #expect(try store.shared().load("cursor.json", as: RelayCursor.self)?.lastAckedSeq == 7)
  }
  @Test func deniedPermissionDoesNotFetchNotifyOrAcknowledge() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let relay = MockRelay(messages: [payload])
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { false }, notify: { _, _ in Issue.record("Denied permission") },
      failure: { _ in })
    #expect(await worker.run() == false)
    #expect(relay.requests == 0)
    #expect(relay.acknowledgements.isEmpty)
    #expect(try store.shared().load("cursor.json", as: RelayCursor.self) == nil)
  }
  @Test func acceptedNotificationSurvivesAckFailureAndIsNotPostedAgain() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let relay = MockRelay(messages: [payload])
    relay.failAck = true
    var notified: [String] = []
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { true }, notify: { _, id in notified.append(id) }, failure: { _ in })
    #expect(await worker.run() == false)
    #expect(relay.acknowledgements.isEmpty)
    #expect(try store.shared().load("cursor.json", as: RelayCursor.self) == nil)
    relay.failAck = false
    #expect(await worker.run())
    #expect(notified == ["mail-vector-email"])
    #expect(relay.acknowledgements == [7])
  }
  @Test func notificationFailurePreservesCursorAndDeliveryLog() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let relay = MockRelay(messages: [payload])
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { true }, notify: { _, _ in throw MailError.notifications }, failure: { _ in })
    #expect(await worker.run() == false)
    #expect(relay.acknowledgements.isEmpty)
    #expect(try !store.shared().wasDelivered(7, identity: credentials.identity))
  }
  @Test func partialDeliveryResumesWithoutDuplicatingAcceptedMessage() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    // A second ciphertext is deliberately invalid: the first delivery must remain recorded.
    var data =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
    data["seq"] = 8
    let bad = try JSONDecoder().decode(
      PushPayload.self, from: JSONSerialization.data(withJSONObject: data))
    let relay = MockRelay(messages: [payload, bad], next: 8)
    var count = 0
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { true }, notify: { _, _ in count += 1 }, failure: { _ in })
    #expect(await worker.run() == false)
    #expect(await worker.run() == false)
    #expect(count == 1)
    #expect(relay.acknowledgements.isEmpty)
  }
  @Test func malformedPageCannotAcknowledgeBeyondItsContract() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let relay = MockRelay(messages: [payload], next: 6)
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { true }, notify: { _, _ in Issue.record("Invalid page") }, failure: { _ in })
    #expect(await worker.run() == false)
    #expect(relay.acknowledgements.isEmpty)
  }
  @Test func sharedProcessLockPreventsOverlappingChecks() async throws {
    let (store, credentials, payload) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let lock = try store.lock()
    defer { withExtendedLifetime(lock) {} }
    let relay = MockRelay(messages: [payload])
    let worker = CatchUpWorker(
      store: store, credentials: { credentials }, payloadKey: { _ in fixtureKey },
      transport: { _ in relay },
      authorized: { true }, failure: { _ in Issue.record("Busy must not report an error") })
    #expect(await worker.run() == false)
    #expect(relay.requests == 0)
  }
}

@Suite @MainActor struct ReadClearingTests {
  func credentials() throws -> RelayCredentials {
    try RelayCredentials(relayURL: Defaults.relayURL, deviceSecret: String(repeating: "x", count: 32))
  }
  func response(_ ids: [String], _ credentials: RelayCredentials, state: String = "read") throws -> ReadStatusResponse {
    try JSONDecoder().decode(ReadStatusResponse.self, from: JSONSerialization.data(withJSONObject: [
      "v": 1, "deviceId": credentials.deviceId,
      "results": ids.map { ["emailId": $0, "state": state] },
    ]))
  }
  func snapshot(_ id: String, _ credentials: RelayCredentials, date: Date = Date(timeIntervalSince1970: 1)) -> DeliveredMail {
    DeliveredMail.map(identifier: "mail-" + id, date: date, userInfo: [:], credentials: credentials, allowLegacy: true)!
  }
  func store() throws -> AgentStore {
    let store = AgentStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try store.save(AgentSettings(enabled: true), to: "settings.json")
    return store
  }
  @Test func validatesWholeResponse() throws {
    let c = try credentials()
    #expect(try response(["a"], c).readIDs(for: ["a"], deviceId: c.deviceId) == ["a"])
    #expect(throws: (any Error).self) { try response(["a", "a"], c).readIDs(for: ["a", "b"], deviceId: c.deviceId) }
    #expect(throws: (any Error).self) { try response(["a"], c).readIDs(for: ["a"], deviceId: "wrong") }
    #expect(try response(["a"], c, state: "notFound").readIDs(for: ["a"], deviceId: c.deviceId) == ["a"])
    #expect(try response(["a"], c, state: "unread").readIDs(for: ["a"], deviceId: c.deviceId).isEmpty)
  }
  @Test func mappingRejectsUnknownAndConflictingMetadata() throws {
    let c = try credentials()
    #expect(DeliveredMail.map(identifier: "test", date: Date(), userInfo: [:], credentials: c, allowLegacy: true) == nil)
    #expect(DeliveredMail.map(identifier: "mail-a", date: Date(), userInfo: [:], credentials: c, allowLegacy: false) == nil)
    #expect(DeliveredMail.map(identifier: "mail-a", date: Date(), userInfo: ["mailchimeMail": ["v": 2]], credentials: c, allowLegacy: true) == nil)
    let metadata: [AnyHashable: Any] = ["mailchimeMail": ["v": 1, "kind": "local", "emailId": "a", "identity": c.deviceId, "origin": c.relayURL]]
    #expect(DeliveredMail.map(identifier: "mail-a", date: Date(), userInfo: metadata, credentials: c, allowLegacy: false)?.emailId == "a")
  }
  @Test func clearsReadAndPreservesDeliveryHistory() async throws {
    let c = try credentials(); let store = try store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let shared = try store.shared(); try shared.record(7, identity: c.identity)
    let items = [snapshot("a", c), snapshot("b", c), snapshot("c", c)]
    var removed: [String] = []
    let worker = ReadNotificationReconciler(store: store, credentials: { c }, snapshots: { _, _ in items }, query: { _, ids in
      try JSONDecoder().decode(ReadStatusResponse.self, from: JSONSerialization.data(withJSONObject: [
        "v": 1, "deviceId": c.deviceId,
        "results": ids.map { ["emailId": $0, "state": $0 == "a" ? "read" : ($0 == "c" ? "notFound" : "unread")] },
      ]))
    }, remove: { removed += $0 })
    await worker.run()
    #expect(Set(removed) == ["mail-a", "mail-c"])
    #expect(try shared.wasDelivered(7, identity: c.identity))
    #expect(try shared.load("cursor.json", as: RelayCursor.self) == nil)
  }
  @Test func noRequestsForEmptySnapshot() async throws {
    let c = try credentials(); let store = try store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var calls = 0
    await ReadNotificationReconciler(store: store, credentials: { c }, snapshots: { _, _ in [] }, query: { _, ids in
      calls += 1; return try response(ids, c)
    }, remove: { _ in Issue.record("Unexpected removal") }).run()
    #expect(calls == 0)
  }
  @Test func identityChangeAndReplacementPreventRemoval() async throws {
    for changeIdentity in [true, false] {
      let c = try credentials(); let store = try store()
      defer { try? FileManager.default.removeItem(at: store.directory) }
      var current = c; var reads = 0; var removed = false
      await ReadNotificationReconciler(store: store, credentials: { current }, snapshots: { _, _ in
        reads += 1
        return [snapshot("a", c, date: Date(timeIntervalSince1970: Double(reads)))]
      }, query: { _, ids in
        if changeIdentity { current = try credentials() }
        return try response(ids, c)
      }, remove: { _ in removed = true }).run()
      #expect(!removed)
    }
  }
  @Test func malformedResponseBacksOffWithoutRemoval() async throws {
    let c = try credentials(); let store = try store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var calls = 0
    let worker = ReadNotificationReconciler(store: store, credentials: { c }, snapshots: { _, _ in [snapshot("a", c)] }, query: { _, _ in
      calls += 1; return try response(["wrong"], c)
    }, remove: { _ in Issue.record("Unexpected removal") })
    await worker.run(); await worker.run()
    #expect(calls == 1)
    let progress = try store.shared().load("read-status.json", as: ReadNotificationReconciler.Progress.self)
    #expect(progress?.failures == 1)
    #expect(progress?.lastSuccess == nil)
  }
  @Test func remoteMappingUsesActualIdentifierAndExcludesTests() throws {
    let c = try credentials()
    var info: [AnyHashable: Any] = ["v": 1, "seq": 5, "emailId": "a", "receivedAt": "2026-11-07T12:00:00Z",
      "enc": ["alg": "A256GCM", "nonce": Data(repeating: 1, count: 12).base64EncodedString(),
        "ciphertext": Data(repeating: 1, count: 16).base64EncodedString()]]
    #expect(DeliveredMail.map(identifier: "opaque-apns-id", date: Date(), userInfo: info, credentials: c, allowLegacy: true)?.identifier == "opaque-apns-id")
    info["mailchimeMail"] = ["v": 1, "kind": "remote", "emailId": "a", "identity": c.deviceId, "origin": c.relayURL]
    #expect(DeliveredMail.map(identifier: "opaque-apns-id", date: Date(), userInfo: info, credentials: c, allowLegacy: false)?.emailId == "a")
    info["test"] = true; info["seq"] = 0
    #expect(DeliveredMail.map(identifier: "opaque-apns-id", date: Date(), userInfo: info, credentials: c, allowLegacy: true) == nil)
  }
  @Test func rotatesLargeSetsAndLimitsEachRun() async throws {
    let c = try credentials(); let store = try store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let items = (0..<250).map { snapshot(String(format: "m%03d", $0), c) }
    var queried: [String] = []; var batches = 0
    let worker = ReadNotificationReconciler(store: store, credentials: { c }, snapshots: { _, _ in items }, query: { _, ids in
      batches += 1; queried += ids
      #expect(ids.count <= 50)
      return try response(ids, c, state: "unread")
    }, remove: { _ in Issue.record("Unexpected removal") })
    await worker.run()
    #expect(batches == 4); #expect(Set(queried).count == 200)
    let shared = try store.shared()
    var progress = try #require(try shared.load("read-status.json", as: ReadNotificationReconciler.Progress.self))
    progress.nextAttempt = .distantPast; try shared.save(progress, to: "read-status.json")
    await worker.run()
    #expect(Set(queried).count == 250)
  }
  @Test func disableAndConcurrentLockPreventRemoval() async throws {
    let c = try credentials(); let store = try store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    let worker = ReadNotificationReconciler(store: store, credentials: { c }, snapshots: { _, _ in [snapshot("a", c)] }, query: { _, ids in
      try store.save(AgentSettings(enabled: false), to: "settings.json")
      return try response(ids, c)
    }, remove: { _ in Issue.record("Unexpected removal") })
    let shared = try store.shared(); try shared.prepare()
    do {
      let lock = try ProcessLock(url: shared.directory.appendingPathComponent("read-status.lock"))
      await worker.run()
      #expect(try store.settings().enabled)
      withExtendedLifetime(lock) {}
    }
    await worker.run()
    #expect(try !store.settings().enabled)
  }
  @Test func cancellationDoesNotRemoveOrRecordSuccess() async throws {
    let c = try credentials(); let store = try store()
    defer { try? FileManager.default.removeItem(at: store.directory) }
    var started = false
    let worker = ReadNotificationReconciler(store: store, credentials: { c }, snapshots: { _, _ in [snapshot("a", c)] }, query: { _, ids in
      started = true
      try await Task.sleep(for: .seconds(10))
      return try response(ids, c)
    }, remove: { _ in Issue.record("Unexpected removal") })
    let task = Task { await worker.run() }
    while !started { await Task.yield() }
    task.cancel(); await task.value
    #expect(try store.shared().load("read-status.json", as: ReadNotificationReconciler.Progress.self) == nil)
  }

}

@Test @MainActor func settingsFeedbackRoutesByProblemAndKeepsSectionsIndependent() {
  let model = SettingsModel(loadOnInit: false)
  model.report(MailError.relayAuthentication, in: .notifications)
  model.report(MailError.pushRegistration, in: .activity)
  model.report(MailError.storage, in: .activity)
  #expect(model.relayFeedback?.message == MailError.relayAuthentication.localizedDescription)
  #expect(model.notificationFeedback?.message == MailError.pushRegistration.localizedDescription)
  #expect(model.activityFeedback?.message == MailError.storage.localizedDescription)
  #expect(model.relayFeedback?.isError == true)
  model.status = CheckStatus(success: false, message: MailError.invalidPayload.localizedDescription, failure: .invalidPayload)
  #expect(model.messages(in: .relay).contains { $0.message == MailError.invalidPayload.localizedDescription })
  #expect(!model.messages(in: .activity).contains { $0.message == MailError.invalidPayload.localizedDescription })
}

@Test func legacyCheckStatusStillDecodesWithoutFailureCategory() throws {
  let data = Data(#"{"date":0,"success":false,"newMessages":0,"message":"Earlier error"}"#.utf8)
  let status = try JSONDecoder().decode(CheckStatus.self, from: data)
  #expect(status.failure == nil)
  let current = CheckStatus(success: false, message: "Error", failure: .notifications)
  #expect(try JSONDecoder().decode(CheckStatus.self, from: JSONEncoder().encode(current)).failure == .notifications)
}

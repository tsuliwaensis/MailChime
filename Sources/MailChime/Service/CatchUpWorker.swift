import MailChimeKit
import Foundation
import UserNotifications

@MainActor
final class CatchUpWorker {
  let store: AgentStore
  private let credentials: () throws -> RelayCredentials?
  private let payloadKey: (UUID) throws -> Data
  private let transport: (RelayCredentials) -> any RelayTransport
  private let authorized: () async -> Bool
  private let notify: (MessageHeaders, String) async throws -> Void
  private let failure: (Error) async -> Void
  init(
    store: AgentStore = AgentStore(),
    credentials: @escaping () throws -> RelayCredentials? = CredentialStore.load,
    payloadKey: @escaping (UUID) throws -> Data = { try SharedKeychain.payloadKey(identity: $0) },
    transport: @escaping (RelayCredentials) -> any RelayTransport = { RelayAPI(credentials: $0) },
    authorized: @escaping () async -> Bool = CatchUpWorker.authorized,
    notify: @escaping (MessageHeaders, String) async throws -> Void = CatchUpWorker.notify,
    failure: @escaping (Error) async -> Void = FailureReporter.report
  ) {
    self.store = store
    self.credentials = credentials
    self.payloadKey = payloadKey
    self.transport = transport
    self.authorized = authorized
    self.notify = notify
    self.failure = failure
  }
  func run() async -> Bool {
    let lock: ProcessLock
    do { lock = try store.lock() } catch {
      if error as? MailError != .busy { await failure(error) }
      return false
    }
    defer { withExtendedLifetime(lock) {} }
    do {
      guard let credentials = try credentials() else { throw MailError.missingCredentials }
      guard await authorized() else { throw MailError.notifications }
      let shared = try store.shared()
      let key = try payloadKey(credentials.identity)
      let old = try shared.load("cursor.json", as: RelayCursor.self)
      var cursor =
        old?.identity == credentials.identity ? old! : RelayCursor(identity: credentials.identity)
      guard (0...Defaults.maximumSequence).contains(cursor.lastAckedSeq) else {
        throw MailError.storage
      }
      let api = transport(credentials)
      let deadline = Date().addingTimeInterval(Defaults.checkTimeout)
      var count = 0
      var gap = false
      let hadCursor = old?.identity == credentials.identity
      for pageIndex in 0..<25 {
        try Task.checkCancellation()
        guard Date() < deadline else { throw MailError.timeout }
        let page = try await api.missed(after: cursor.lastAckedSeq).validated(
          after: cursor.lastAckedSeq)
        gap = gap || (page.gap && (hadCursor || pageIndex > 0))
        for message in page.messages {
          if try shared.wasDelivered(message.seq, identity: credentials.identity) { continue }
          guard await authorized() else { throw MailError.notifications }
          let headers = try message.decrypt(key: key)
          try await notify(headers, "mail-" + message.emailId)
          // Persist each accepted local notification; retries skip it if a later message or ack fails.
          try shared.record(message.seq, identity: credentials.identity)
          count += 1
        }
        guard await authorized() else { throw MailError.notifications }
        try await api.acknowledge(page.nextCursor)
        cursor.lastAckedSeq = page.nextCursor
        try shared.save(cursor, to: "cursor.json")
        if !page.hasMore { break }
        if pageIndex == 24 { throw MailError.timeout }
      }
      try store.save(
        CheckStatus(
          success: true, newMessages: count,
          message: gap
            ? MailError.retentionGap.localizedDescription
            : String(localized: "Missed mail check completed.")), to: "status.json")
      publishStatus()
      return true
    } catch {
      let safe = (error as? MailError) ?? .relayUnavailable
      try? store.save(
        CheckStatus(success: false, message: safe.localizedDescription, failure: safe), to: "status.json")
      publishStatus()
      await failure(error)
      return false
    }
  }
  private func publishStatus() {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(AppIdentity.statusChanged), object: nil,
      userInfo: nil, deliverImmediately: true)
  }
  static func authorized() async -> Bool {
    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    return status == .authorized || status == .provisional
  }
  static func notify(message: MessageHeaders, identifier: String) async throws {
    guard await authorized() else { throw MailError.notifications }
    do {
      let content = NotificationContent.make(for: message)
      if let credentials = try CredentialStore.load() {
        content.userInfo = ["mailchimeMail": ["v": 1, "kind": "local", "emailId": message.id,
          "identity": credentials.deviceId, "origin": credentials.relayURL]]
      }
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(
          identifier: identifier,
          content: content, trigger: nil))
    } catch { throw MailError.notifications }
  }
}

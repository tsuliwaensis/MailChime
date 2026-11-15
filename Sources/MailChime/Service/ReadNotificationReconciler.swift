import MailChimeKit
import Foundation
import UserNotifications

@MainActor
final class ReadNotificationReconciler {
  struct Progress: Codable {
    var identity: UUID
    var origin: String
    var after: String = ""
    var failures = 0
    var nextAttempt = Date.distantPast
    var lastAttempt: Date?
    var lastSuccess: Date?
    var removalRequests = 0
    var error: String?
  }
  private let store: AgentStore
  private let credentials: () throws -> RelayCredentials?
  private let enumerate: () async -> [UNNotification]
  private let snapshots: ((RelayCredentials, Bool) async -> [DeliveredMail])?
  private let query: (RelayCredentials, [String]) async throws -> ReadStatusResponse
  private let remove: ([String]) -> Void
  init(
    store: AgentStore = AgentStore(),
    credentials: @escaping () throws -> RelayCredentials? = CredentialStore.load,
    enumerate: @escaping () async -> [UNNotification] = {
      await UNUserNotificationCenter.current().deliveredNotifications()
    },
    snapshots: ((RelayCredentials, Bool) async -> [DeliveredMail])? = nil,
    query: @escaping (RelayCredentials, [String]) async throws -> ReadStatusResponse = {
      try await RelayAPI(credentials: $0).readStatus($1)
    },
    remove: @escaping ([String]) -> Void = {
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
    }
  ) {
    self.store = store; self.credentials = credentials; self.enumerate = enumerate
    self.snapshots = snapshots; self.query = query; self.remove = remove
  }
  private func current(_ expected: RelayCredentials) throws {
    try Task.checkCancellation()
    guard try store.settings().enabled, try credentials() == expected else { throw CancellationError() }
  }
  private func delivered(_ credentials: RelayCredentials, legacy: Bool) async -> [DeliveredMail] {
    if let snapshots { return await snapshots(credentials, legacy) }
    return await enumerate().compactMap {
      DeliveredMail.map(identifier: $0.request.identifier, date: $0.date,
        userInfo: $0.request.content.userInfo, credentials: credentials, allowLegacy: legacy)
    }
  }
  private func boundedQuery(_ credentials: RelayCredentials, ids: [String], deadline: Date) async throws -> ReadStatusResponse {
    let operation = Task { try await query(credentials, ids) }
    let timeout = Task {
      do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
      catch { return }
      operation.cancel()
    }
    defer { timeout.cancel() }
    return try await withTaskCancellationHandler {
      try await operation.value
    } onCancel: {
      operation.cancel()
    }
  }
  func run() async {
    // Separate from check.lock: status lookup must never alter or block mail acknowledgments.
    do {
      guard try store.settings().enabled, let credentials = try credentials() else { return }
      let shared = try store.shared()
      try shared.prepare()
      let lock = try ProcessLock(url: shared.directory.appendingPathComponent("read-status.lock"))
      defer { withExtendedLifetime(lock) {} }
      let old = try shared.load("read-status.json", as: Progress.self)
      var progress = old?.identity == credentials.identity && old?.origin == credentials.relayURL
        ? old! : Progress(identity: credentials.identity, origin: credentials.relayURL)
      guard Date() >= progress.nextAttempt else { return }
      // Bind legacy notifications to the first known identity of the shipped single-account relay.
      // Never silently rebind this provenance after credentials change.
      struct Provenance: Codable { let identity: UUID; let origin: String }
      var provenance = try shared.load("read-provenance.json", as: Provenance.self)
      if provenance == nil, credentials.relayURL == Defaults.relayURL {
        provenance = Provenance(identity: credentials.identity, origin: credentials.relayURL)
        try shared.save(provenance, to: "read-provenance.json")
      }
      let legacy = provenance?.identity == credentials.identity && provenance?.origin == credentials.relayURL
      progress.lastAttempt = Date(); progress.removalRequests = 0
      do {
        try current(credentials)
        let original = await delivered(credentials, legacy: legacy)
        let sorted = Set(original.map(\.emailId)).sorted()
        let ids = sorted.filter { $0 > progress.after } + sorted.filter { $0 <= progress.after }
        let deadline = Date().addingTimeInterval(60)
        for offset in stride(from: 0, to: min(ids.count, 200), by: 50) {
          try current(credentials)
          guard Date() < deadline else { throw MailError.timeout }
          let batch = Array(ids[offset..<min(offset + 50, ids.count)])
          let response = try await boundedQuery(credentials, ids: batch, deadline: deadline)
          guard Date() < deadline else { throw MailError.timeout }
          let read = try response.readIDs(for: batch, deviceId: credentials.deviceId)
          try current(credentials)
          let fresh = await delivered(credentials, legacy: legacy)
          try current(credentials)
          let identifiers = original.filter { read.contains($0.emailId) && fresh.contains($0) }.map(\.identifier)
          if !identifiers.isEmpty { remove(identifiers) }
          progress.removalRequests += identifiers.count
          progress.after = batch.last ?? ""
        }
        progress.failures = 0; progress.error = nil; progress.lastSuccess = Date()
        progress.nextAttempt = Date().addingTimeInterval(30)
      } catch is CancellationError {
        if Task.isCancelled { return }
        progress.failures = min(progress.failures + 1, 4)
        progress.error = "timeout"
        progress.nextAttempt = Date().addingTimeInterval(min(300, 60 * pow(2, Double(progress.failures))))
      } catch {
        progress.failures = min(progress.failures + 1, 4)
        progress.nextAttempt = Date().addingTimeInterval(min(300, 60 * pow(2, Double(progress.failures))))
        let safe = (error as? MailError) ?? .relayUnavailable
        progress.error = String(describing: safe)
      }
      try shared.save(progress, to: "read-status.json")
    } catch {
      // Busy means another process is already reconciling. Other failures remain safe diagnostics.
      if error as? MailError != .busy { try? ErrorLog().record(error) }
    }
  }
}

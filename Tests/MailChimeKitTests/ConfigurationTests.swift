import CryptoKit
import Foundation
import Testing

@testable import MailChimeKit

@Test func relayCredentialsRejectUnsafeURLsAndHeaderInjection() throws {
  for url in [
    "http://example.com", "https://user:pass@example.com", "https://example.com/path",
    "https://example.com?q=x", "https://example.com#fragment",
  ] {
    #expect(throws: MailError.credentials) {
      try RelayCredentials(relayURL: url, deviceSecret: String(repeating: "x", count: 64))
    }
  }
  #expect(throws: MailError.credentials) {
    try RelayCredentials(relayURL: "https://example.com", deviceSecret: "bad\r\nsecret")
  }
  let value = try RelayCredentials(
    relayURL: " https://example.com/ ", deviceSecret: String(repeating: "x", count: 64))
  #expect(value.relayURL == "https://example.com")
  #expect(
    try JSONDecoder().decode(RelayCredentials.self, from: JSONEncoder().encode(value)).validated()
      == value)
}
@Test func pushEnvironmentIsExplicit() throws {
  #expect(try PushEnvironment(entitlementValue: "development") == .sandbox)
  #expect(try PushEnvironment(entitlementValue: "production") == .production)
  #expect(throws: MailError.pushEnvironment) { try PushEnvironment(entitlementValue: "sandbox") }
  #expect(throws: MailError.pushEnvironment) { try PushEnvironment(entitlementValue: nil) }
  if let signed = PushEnvironment.signedEntitlementValue() {
    #expect(try PushEnvironment.current() == PushEnvironment(entitlementValue: signed))
  }
}
@Test func headersSanitizeHostileTextAndPreserveUnicode() {
  let message = MessageHeaders(
    id: "m1", from: "\nSender\r\nInjected:\u{202e} text", subject: "\t", receivedAt: Date())
  #expect(message.from == "Sender Injected: text")
  #expect(message.subject == "No subject")
  #expect(MessageHeaders.display("💌 café", fallback: "empty") == "💌 café")
  #expect(
    MessageHeaders.display(String(repeating: "a", count: 1000), fallback: "empty").count == 512)
}
@Test func workerPayloadDecryptsWithExactAADAndRejectsTampering() throws {
  let payload = try fixturePayload()
  let message = try payload.decrypt(key: fixtureKey)
  #expect(message.id == "vector-email")
  #expect(message.from == "Example Sender <sender@example.invalid>")
  #expect(message.subject == "Café 💌 / \"quoted\"")
  #expect(throws: MailError.invalidPayload) {
    try payload.decrypt(key: Data(repeating: 1, count: 32))
  }
  var object =
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
  for (field, value) in [
    ("seq", 8 as Any), ("emailId", "other" as Any), ("receivedAt", "2026-11-04T12:00:00Z" as Any),
  ] {
    var changed = object
    changed[field] = value
    let modified = try JSONDecoder().decode(
      PushPayload.self, from: JSONSerialization.data(withJSONObject: changed))
    #expect(throws: MailError.invalidPayload) { try modified.decrypt(key: fixtureKey) }
  }
  object["v"] = 2
  let modified = try JSONDecoder().decode(
    PushPayload.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(throws: MailError.invalidPayload) { try modified.validated() }
}
@Test func notificationDateUsesSpecifiedTimeZoneAndLocale() {
  let date = Date(timeIntervalSince1970: 1_793_793_600)
  let message = MessageHeaders(id: "m1", from: "Sender", subject: "Hello", receivedAt: date)
  let utc = NotificationContent.make(
    for: message, timeZone: TimeZone(secondsFromGMT: 0)!, locale: Locale(identifier: "en_US_POSIX"))
  let chicago = NotificationContent.make(
    for: message, timeZone: TimeZone(identifier: "America/Chicago")!,
    locale: Locale(identifier: "en_US_POSIX"))
  #expect(utc.title == "Here's The Mail!")
  #expect(utc.body != chicago.body)
  #expect(utc.sound != nil)
}
@Test func deliveredLogIsBoundedAndScopedToCredentialIdentity() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let state = SharedState(directory: directory)
  let identity = UUID()
  try state.save(
    SharedState.Delivery(identity: identity, sequences: Array(1...2048)), to: "delivered.json")
  try state.record(2049, identity: identity)
  #expect(try state.wasDelivered(2049, identity: identity))
  #expect(try !state.wasDelivered(1, identity: identity))
  #expect(try !state.wasDelivered(2049, identity: UUID()))
  let data = try state.load("delivered.json", as: SharedState.Delivery.self)
  #expect(data?.sequences.count == 2048)
  #expect(
    (try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("delivered.json").path)[.posixPermissions] as? Int)
      == 0o600)
}
let fixtureKey = Data(repeating: 107, count: 32)
private final class FixtureBundle: NSObject {}
func fixturePayload() throws -> PushPayload {
  let file = try #require(
    Bundle(for: FixtureBundle.self).url(forResource: "push-vector", withExtension: "json"))
  return try JSONDecoder().decode(PushPayload.self, from: Data(contentsOf: file))
}

import CryptoKit
import Foundation

public struct PushPayload: Codable, Sendable {
  public struct Encryption: Codable, Sendable {
    public let alg: String
    public let nonce: String
    public let ciphertext: String
  }
  public let v: Int
  public let seq: Int
  public let emailId: String
  public let receivedAt: String
  public let enc: Encryption?
  public let test: Bool?
  public static func decode(userInfo: [AnyHashable: Any]) throws -> Self {
    guard JSONSerialization.isValidJSONObject(userInfo) else { throw MailError.invalidPayload }
    let data = try JSONSerialization.data(withJSONObject: userInfo)
    guard data.count <= 8192 else { throw MailError.invalidPayload }
    return try JSONDecoder().decode(Self.self, from: data).validated()
  }
  public func validated() throws -> Self {
    guard v == 1, seq >= 0, seq <= Defaults.maximumSequence,
      test == true ? seq == 0 : seq > 0, Self.validID(emailId), receivedAt.utf8.count <= 64,
      Self.date(receivedAt) != nil
    else { throw MailError.invalidPayload }
    if let enc {
      guard enc.alg == "A256GCM", Data(base64Encoded: enc.nonce)?.count == 12,
        let ciphertext = Data(base64Encoded: enc.ciphertext), (16...4096).contains(ciphertext.count)
      else { throw MailError.invalidPayload }
    } else if test != true {
      throw MailError.invalidPayload
    }
    return self
  }
  public static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255
      && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          || $0 == 95
      }
  }
  public static func date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
  public func associatedData() throws -> Data {
    // IDs and ISO dates are ASCII. withoutEscapingSlashes matches JSON.stringify exactly.
    try JSONSerialization.data(
      withJSONObject: [v, seq, emailId, receivedAt], options: [.withoutEscapingSlashes])
  }
  public func decrypt(key: Data) throws -> MessageHeaders {
    _ = try validated()
    guard key.count == 32, let enc, let nonce = Data(base64Encoded: enc.nonce),
      let ciphertext = Data(base64Encoded: enc.ciphertext), let date = Self.date(receivedAt)
    else { throw MailError.invalidPayload }
    struct Headers: Decodable {
      let from: String
      let subject: String
    }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce),
        ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
      let plain = try AES.GCM.open(
        box, using: SymmetricKey(data: key), authenticating: associatedData())
      guard plain.count <= 16_384 else { throw MailError.invalidPayload }
      let headers = try JSONDecoder().decode(Headers.self, from: plain)
      return MessageHeaders(
        id: emailId, from: headers.from, subject: headers.subject, receivedAt: date)
    } catch { throw MailError.invalidPayload }
  }
}
public struct MissedResponse: Codable, Sendable {
  public let v: Int
  public let messages: [PushPayload]
  public let nextCursor: Int
  public let hasMore: Bool
  public let droppedThrough: Int
  public let gap: Bool
  public init(
    v: Int, messages: [PushPayload], nextCursor: Int, hasMore: Bool, droppedThrough: Int, gap: Bool
  ) {
    self.v = v
    self.messages = messages
    self.nextCursor = nextCursor
    self.hasMore = hasMore
    self.droppedThrough = droppedThrough
    self.gap = gap
  }
  public func validated(after: Int) throws -> Self {
    guard v == 1, messages.count <= 50, nextCursor >= after, nextCursor <= Defaults.maximumSequence,
      droppedThrough >= 0, droppedThrough <= nextCursor, gap == (after < droppedThrough),
      !hasMore || nextCursor > after
    else { throw MailError.invalidPayload }
    var last = after
    for message in messages {
      _ = try message.validated()
      guard message.test != true, message.seq > last, message.seq <= nextCursor else {
        throw MailError.invalidPayload
      }
      last = message.seq
    }
    return self
  }
}
public struct RelayStatus: Decodable, Sendable {
  public struct Device: Decodable, Sendable {
    public let deviceId: String
    public let environment: PushEnvironment
    public let lastAckedSeq: Int
  }
  public let version: Int
  public let device: Device?
  public let baselineEstablished: Bool
  public let subscriptionVerified: Bool
  public let lastPush: Double?
  public let queueLength: Int
}

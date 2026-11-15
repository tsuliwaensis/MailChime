import Foundation

public struct ReadStatusResponse: Codable, Sendable {
  public struct Result: Codable, Sendable {
    public let emailId: String
    public let state: State
  }
  public enum State: String, Codable, Sendable { case read, unread, notFound }
  public let v: Int
  public let deviceId: String
  public let results: [Result]
  public func readIDs(for ids: [String], deviceId: String) throws -> Set<String> {
    guard v == 1, self.deviceId == deviceId, (1...50).contains(ids.count),
      ids.allSatisfy(PushPayload.validID), Set(ids).count == ids.count,
      results.count == ids.count, Set(results.map(\.emailId)) == Set(ids)
    else { throw MailError.invalidPayload }
    return Set(results.filter { $0.state == .read || $0.state == .notFound }.map(\.emailId))
  }
}

/// A snapshot includes the delivery date so a replacement request cannot be removed accidentally.
public struct DeliveredMail: Equatable, Sendable {
  public let identifier: String
  public let emailId: String
  public let date: Date
  public let metadata: Data
  public static func map(
    identifier: String, date: Date, userInfo: [AnyHashable: Any],
    credentials: RelayCredentials, allowLegacy: Bool
  ) -> Self? {
    guard JSONSerialization.isValidJSONObject(userInfo),
      let metadata = try? JSONSerialization.data(withJSONObject: userInfo, options: [.sortedKeys]),
      metadata.count <= 8192 else { return nil }
    let emailId: String
    if let info = userInfo["mailchimeMail"] as? [String: Any] {
      guard info["v"] as? Int == 1, info["identity"] as? String == credentials.deviceId,
        info["origin"] as? String == credentials.relayURL,
        let value = info["emailId"] as? String, PushPayload.validID(value),
        info["kind"] as? String == "local" || info["kind"] as? String == "remote" else { return nil }
      if info["kind"] as? String == "remote" {
        guard let payload = try? PushPayload.decode(userInfo: userInfo), payload.test != true,
          payload.emailId == value else { return nil }
      } else {
        guard identifier == "mail-" + value else { return nil }
      }
      emailId = value
    } else if userInfo["mailchimeMail"] != nil {
      return nil
    } else if let payload = try? PushPayload.decode(userInfo: userInfo) {
      guard allowLegacy, payload.test != true, payload.seq > 0 else { return nil }
      emailId = payload.emailId
    } else {
      guard allowLegacy, userInfo.isEmpty, identifier.hasPrefix("mail-") else { return nil }
      let value = String(identifier.dropFirst(5))
      guard PushPayload.validID(value) else { return nil }
      emailId = value
    }
    return Self(identifier: identifier, emailId: emailId, date: date, metadata: metadata)
  }
}

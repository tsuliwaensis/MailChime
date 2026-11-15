import Foundation
import Security

public enum AppIdentity {
  public static let bundleIdentifier = "com.rhpt.mailchime"
  public static let keychainService = bundleIdentifier + ".relay"
  public static let agentLabel = bundleIdentifier + ".agent"
  public static let settingsChanged = bundleIdentifier + ".settingsChanged"
  public static let statusChanged = bundleIdentifier + ".statusChanged"
  public static func dispatchQueueLabel(_ component: String) -> String {
    bundleIdentifier + "." + component
  }
  public static func sharedValue(_ key: String, bundle: Bundle = .main) throws -> String {
    guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
      !value.isEmpty, !value.contains("$(")
    else { throw MailError.storage }
    return value
  }
}
public enum Defaults {
  public static let relayURL = "https://rhpt.mym5n442j7.workers.dev"
  public static let maximumDisplayCharacters = 512
  public static let checkTimeout: TimeInterval = 60
  public static let maximumResponseBytes = 262_144
  public static let maximumDeliveredEntries = 2048
  public static let maximumSequence = 9_007_199_254_740_991
}
public enum MailError: String, Codable, Error, LocalizedError, Equatable, Sendable {
  case credentials, missingCredentials, relayAuthentication, relayUnavailable, invalidPayload
  case pushRegistration, pushEnvironment, deviceRegistration, retentionGap, timeout
  case busy, storage, keychain, notifications, agent, agentBundle
  public var errorDescription: String? {
    switch self {
    case .credentials: String(localized: "Enter an HTTPS relay URL and a valid device secret.")
    case .missingCredentials:
      String(localized: "Save your relay credentials before checking for mail.")
    case .relayAuthentication:
      String(localized: "The relay rejected the device secret. Check your saved credentials.")
    case .relayUnavailable:
      String(localized: "The relay is unavailable. Check your connection and try again.")
    case .invalidPayload:
      String(localized: "The relay returned invalid or unreadable notification data.")
    case .pushRegistration:
      String(
        localized:
          "APNs registration failed. Check the app's signing and Push Notifications capability.")
    case .pushEnvironment:
      String(localized: "The app has an invalid APNs environment. Check its build configuration.")
    case .deviceRegistration:
      String(
        localized:
          "This Mac is not registered with the relay. Enable notifications or retry registration.")
    case .retentionGap:
      String(localized: "Some mail is no longer in the relay's catch-up history. Check your Inbox.")
    case .timeout: String(localized: "The mail check timed out. Try again later.")
    case .busy: String(localized: "Another mail check is running. Try again shortly.")
    case .storage:
      String(
        localized:
          "Could not read or save shared state. Check signing, App Groups, and file permissions.")
    case .keychain:
      String(localized: "Could not access the shared Keychain. Check signing and unlock your Mac.")
    case .notifications:
      String(localized: "Allow MailChime notifications in System Settings to receive new mail alerts.")
    case .agentBundle:
      String(
        localized:
          "The agent is missing from this app bundle. Rebuild the MailChime app target and run it again.")
    case .agent:
      String(
        localized: "Could not update the background agent. Check Login Items in System Settings.")
    }
  }
}
public struct RelayCredentials: Codable, Sendable, Equatable {
  public let relayURL: String
  public let deviceSecret: String
  public let identity: UUID
  public var deviceId: String { identity.uuidString }
  public init(relayURL: String, deviceSecret: String, identity: UUID = UUID()) throws {
    let text = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var url = URLComponents(string: text), url.scheme == "https", let host = url.host,
      !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/", deviceSecret.utf8.count >= 32,
      deviceSecret.utf8.count <= 1024,
      deviceSecret.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
    else { throw MailError.credentials }
    url.path = ""
    guard let normalized = url.string else { throw MailError.credentials }
    self.relayURL = normalized
    self.deviceSecret = deviceSecret
    self.identity = identity
  }
  public func validated() throws -> Self {
    try Self(relayURL: relayURL, deviceSecret: deviceSecret, identity: identity)
  }
}
public struct AgentSettings: Codable, Sendable, Equatable {
  public var enabled: Bool
  public init(enabled: Bool = false) { self.enabled = enabled }
  public func validated() throws -> Self { self }
}
public struct RelayCursor: Codable, Sendable, Equatable {
  public let identity: UUID
  public var lastAckedSeq: Int
  public init(identity: UUID, lastAckedSeq: Int = 0) {
    self.identity = identity
    self.lastAckedSeq = lastAckedSeq
  }
}
public enum PushEnvironment: String, Codable, Sendable {
  case sandbox, production
  public init(entitlementValue: String?) throws {
    switch entitlementValue {
    case "development": self = .sandbox
    case "production": self = .production
    default: throw MailError.pushEnvironment
    }
  }
  /// Read the code-signed entitlement that apsd actually uses when issuing tokens.
  public static func signedEntitlementValue() -> String? {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    return SecTaskCopyValueForEntitlement(
      task, "com.apple.developer.aps-environment" as CFString, nil) as? String
  }
  public static func current(bundle: Bundle = .main) throws -> Self {
    let raw =
      signedEntitlementValue()
      ?? (bundle.object(forInfoDictionaryKey: "MailChimeAPNsEnvironment") as? String)
    return try Self(entitlementValue: raw)
  }
}
public struct CheckStatus: Codable, Sendable {
  public let date: Date
  public let success: Bool
  public let newMessages: Int
  public let message: String
  public let failure: MailError?
  public init(success: Bool, newMessages: Int = 0, message: String, failure: MailError? = nil) {
    self.failure = failure
    date = Date()
    self.success = success
    self.newMessages = newMessages
    self.message = message
  }
}
public struct RegistrationState: Codable, Sendable {
  public let identity: UUID
  public let environment: PushEnvironment
  public let date: Date
  public let registered: Bool
  public let message: String
  public init(identity: UUID, environment: PushEnvironment, registered: Bool, message: String) {
    self.identity = identity
    self.environment = environment
    self.registered = registered
    self.message = message
    date = Date()
  }
}

import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum SharedKeychain {
  private static func query(account: String) throws -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: AppIdentity.keychainService,
      kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
      kSecAttrAccessGroup as String: try AppIdentity.sharedValue("MailChimeKeychainGroup"),
    ]
  }
  public static func get(account: String) throws -> Data? {
    var query = try query(account: account)
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else { throw MailError.keychain }
    return data
  }
  public static func set(_ data: Data, account: String) throws {
    let query = try query(account: account)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw MailError.keychain }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw MailError.keychain }
  }
  public static func delete(account: String) throws {
    let status = SecItemDelete(try query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw MailError.keychain }
  }
  public static func credentials() throws -> RelayCredentials? {
    guard let data = try get(account: "relay-credentials") else { return nil }
    do { return try JSONDecoder().decode(RelayCredentials.self, from: data).validated() } catch {
      throw MailError.keychain
    }
  }
  public static func payloadKey(identity: UUID, create: Bool = false) throws -> Data {
    let account = "payload-key-" + identity.uuidString
    if let data = try get(account: account) {
      guard data.count == 32 else { throw MailError.keychain }
      return data
    }
    guard create else { throw MailError.keychain }
    // The caller must hold the shared process lock when creating a key.
    let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    try set(data, account: account)
    return data
  }
}

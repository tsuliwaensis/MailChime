import MailChimeKit
import Foundation

enum CredentialStore {
  static func load() throws -> RelayCredentials? { try SharedKeychain.credentials() }
  static func save(_ credentials: RelayCredentials) throws {
    try SharedKeychain.set(
      JSONEncoder().encode(credentials.validated()), account: "relay-credentials")
  }
  static func delete() throws { try SharedKeychain.delete(account: "relay-credentials") }
}

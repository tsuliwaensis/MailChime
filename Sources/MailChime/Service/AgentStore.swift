import MailChimeKit
import Foundation

struct AgentStore: Sendable {
  let directory: URL
  private let sharedDirectory: URL?
  init(directory: URL? = nil, sharedDirectory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/" + AppIdentity.bundleIdentifier + "/Relay", isDirectory: true)
    self.sharedDirectory =
      sharedDirectory ?? directory?.appendingPathComponent("Shared", isDirectory: true)
  }
  func shared() throws -> SharedState {
    if let sharedDirectory { return SharedState(directory: sharedDirectory) }
    return try SharedState.container()
  }
  func prepare() throws { try SharedState(directory: directory).prepare() }
  func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T? {
    try SharedState(directory: directory).load(name, as: type)
  }
  func save<T: Encodable>(_ value: T, to name: String) throws {
    try SharedState(directory: directory).save(value, to: name)
  }
  func settings() throws -> AgentSettings {
    try load("settings.json", as: AgentSettings.self) ?? AgentSettings()
  }
  func lock() throws -> ProcessLock { try shared().lock() }
}

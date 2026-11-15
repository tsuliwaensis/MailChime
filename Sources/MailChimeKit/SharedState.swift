import Darwin
import Foundation

/// Short filesystem locks protect the cross-process delivered log. Never unlink lock files.
public final class ProcessLock: @unchecked Sendable {
  private let descriptor: Int32
  public init(url: URL, wait: Bool = false) throws {
    descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw MailError.storage }
    guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
      close(descriptor)
      throw MailError.busy
    }
  }
  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
public struct SharedState: Sendable {
  public let directory: URL
  public init(directory: URL) { self.directory = directory }
  public static func container(bundle: Bundle = .main) throws -> Self {
    let group = try AppIdentity.sharedValue("MailChimeAppGroup", bundle: bundle)
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    else { throw MailError.storage }
    return Self(directory: url.appendingPathComponent("Relay", isDirectory: true))
  }
  public func prepare() throws {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch { throw MailError.storage }
  }
  public func load<T: Decodable>(_ name: String, as: T.Type) throws -> T? {
    do {
      let url = directory.appendingPathComponent(name)
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 524_288 else { throw MailError.storage }
      return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil } catch {
      throw MailError.storage
    }
  }
  public func save<T: Encodable>(_ value: T, to name: String) throws {
    do {
      try prepare()
      let url = directory.appendingPathComponent(name)
      try JSONEncoder().encode(value).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch { throw MailError.storage }
  }
  public func lock() throws -> ProcessLock {
    try prepare()
    return try ProcessLock(url: directory.appendingPathComponent("check.lock"))
  }
  public struct Delivery: Codable, Sendable {
    public let identity: UUID
    public let sequences: [Int]
  }
  public func wasDelivered(_ seq: Int, identity: UUID) throws -> Bool {
    try prepare()
    let lock = try ProcessLock(url: directory.appendingPathComponent("delivered.lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    let log = try load("delivered.json", as: Delivery.self)
    return log?.identity == identity && log?.sequences.contains(seq) == true
  }
  public func record(_ seq: Int, identity: UUID) throws {
    guard seq > 0, seq <= Defaults.maximumSequence else { throw MailError.invalidPayload }
    try prepare()
    let lock = try ProcessLock(url: directory.appendingPathComponent("delivered.lock"), wait: true)
    defer { withExtendedLifetime(lock) {} }
    let old = try load("delivered.json", as: Delivery.self)
    var sequences = old?.identity == identity ? old?.sequences ?? [] : []
    sequences.append(seq)
    sequences = Array(Set(sequences)).sorted()
    try save(
      Delivery(
        identity: identity, sequences: Array(sequences.suffix(Defaults.maximumDeliveredEntries))),
      to: "delivered.json")
  }
}

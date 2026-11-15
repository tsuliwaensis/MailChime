import AppKit
import Darwin
import MailChimeKit

/// An exclusive per-user role lock that records the owning process identifier.
/// Kernel `flock` locks are released on exit or crash, so a stale file never blocks a launch.
final class InstanceLock: @unchecked Sendable {
  enum Holder: Equatable {
    case none
    case process(pid_t?)
  }

  private let descriptor: Int32

  /// Returns nil when another open file description already holds the lock.
  init?(url: URL) {
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    self.descriptor = descriptor
    let pid = Array(String(getpid()).utf8)
    _ = ftruncate(descriptor, 0)
    _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
  }

  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }

  /// Reports whether a process holds the lock and, when recorded, which one.
  static func holder(at url: URL) -> Holder {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return .none }
    defer { close(descriptor) }
    if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
      flock(descriptor, LOCK_UN)
      return .none
    }
    var buffer = [UInt8](repeating: 0, count: 16)
    let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count > 0, let pid = pid_t(String(decoding: buffer.prefix(count), as: UTF8.self)), pid > 0
    else { return .process(nil) }
    return .process(pid)
  }
}

/// Keeps one settings process and one agent process per user, across every copy of the bundle.
@MainActor
enum SingleInstance {
  enum Role: String {
    case settings
    case agent
  }

  static let showSettings = AppIdentity.bundleIdentifier + ".showSettings"
  private static var held: [Role: InstanceLock] = [:]

  static func lockURL(_ role: Role, store: AgentStore = AgentStore()) -> URL {
    store.directory.appendingPathComponent(role.rawValue + ".lock")
  }

  /// Diagnostics, notification tests and XCTest hosts must run beside a user's live app.
  static func isExempt(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    arguments.contains { $0.hasPrefix("--diagnose") || $0 == "--test-notification" }
      || environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }

  /// Claims a role for this process. A failure to create the directory never blocks launch.
  static func acquire(_ role: Role, store: AgentStore = AgentStore()) -> Bool {
    if held[role] != nil { return true }
    guard (try? store.prepare()) != nil else { return true }
    guard let lock = InstanceLock(url: lockURL(role, store: store)) else { return false }
    held[role] = lock
    return true
  }

  static func holder(_ role: Role, store: AgentStore = AgentStore()) -> InstanceLock.Holder {
    InstanceLock.holder(at: lockURL(role, store: store))
  }

  /// Brings the running settings window forward. Returns false when no settings process exists.
  @discardableResult
  static func showRunningSettings() -> Bool {
    let pid: pid_t?
    switch holder(.settings) {
    case .none: return false
    case .process(let owner): pid = owner
    }
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(showSettings), object: nil, userInfo: nil, deliverImmediately: true)
    let running =
      pid.flatMap { NSRunningApplication(processIdentifier: $0) }
      ?? NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
      .first {
        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
          && $0.activationPolicy == .regular
      }
    running?.activate()
    return true
  }

  /// Called by the settings process when a duplicate launch asks it to come forward.
  static func presentSettingsWindow() {
    NSApp.unhide(nil)
    for window in NSApp.windows where window.canBecomeMain {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    }
    NSApp.activate()
  }
}


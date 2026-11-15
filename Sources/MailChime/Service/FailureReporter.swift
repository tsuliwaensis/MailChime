import MailChimeKit
import Foundation
import OSLog
import UserNotifications

struct ErrorLog {
  let directory: URL
  let maximumBytes: Int

  init(directory: URL = ErrorLog.defaultDirectory, maximumBytes: Int = 1_048_576) {
    self.directory = directory
    self.maximumBytes = maximumBytes
  }

  static var defaultDirectory: URL {
    AgentStore().directory
  }

  func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  func record(_ error: Error) throws {
    try prepare()
    let lock = try ProcessLock(url: directory.appendingPathComponent("logs.lock"))
    defer { withExtendedLifetime(lock) {} }
    let nsError = error as NSError
    // Arbitrary descriptions/userInfo may contain credentials, paths, or mail content.
    // Preserve system error codes; only known safe error types include a description.
    let message: String
    if let mail = error as? MailError {
      message = mail.localizedDescription
    } else if error is URLError {
      message = "Relay network request failed."
    } else {
      message = "Check failed; see error domain and code."
    }
    let entry: [String: String] = [
      "timestamp": ISO8601DateFormatter().string(from: Date()),
      "domain": [NSURLErrorDomain, NSCocoaErrorDomain, NSOSStatusErrorDomain].contains(
        nsError.domain) ? nsError.domain : "MailChime", "code": String(nsError.code),
      "error": message,
    ]
    var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    data.append(0x0a)
    let file = directory.appendingPathComponent("errors.log")
    let manager = FileManager.default
    if manager.fileExists(atPath: file.path) {
      let size = try manager.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
      if size + data.count > maximumBytes {
        let previous = directory.appendingPathComponent("errors.previous.log")
        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
        try manager.moveItem(at: file, to: previous)
      }
    }
    if !manager.fileExists(atPath: file.path) {
      guard
        manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else {
        throw MailError.storage
      }
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }
}

@MainActor
enum FailureReporter {
  static func content() -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "MailChime"
    content.body = String(localized: "There was an error checking for new messages.")
    content.sound = UNNotificationSound(named: UNNotificationSoundName("Notification_A.aiff"))
    return content
  }

  static func report(_ error: Error) async {
    record(error)
    do {
      let notification = content()
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: "MailChime-check-error", content: notification, trigger: nil))
    } catch {
      // Notification denial must not recurse or hide the original check failure.
      record(error)
    }
  }

  private static func record(_ error: Error) {
    do { try ErrorLog().record(error) } catch {
      Logger(subsystem: AppIdentity.bundleIdentifier, category: "errors")
        .error("Could not write the MailChime error log. Check Application Support folder permissions.")
    }
  }
}

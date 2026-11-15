import MailChimeKit
import Foundation
import OSLog
import UserNotifications

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: ((UNNotificationContent) -> Void)?
  private var best: UNNotificationContent?
  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let generic = UNMutableNotificationContent()
    generic.title = "Here's The Mail!"
    generic.body = "New message"
    generic.sound = UNNotificationSound(named: UNNotificationSoundName("Notification_A.aiff"))
    generic.threadIdentifier = "mailchime-inbox"
    generic.userInfo = request.content.userInfo
    lock.lock()
    handler = contentHandler
    best = generic
    lock.unlock()
    do {
      let payload = try PushPayload.decode(userInfo: request.content.userInfo)
      if payload.test == true && payload.enc == nil {
        complete()
        return
      }
      guard let credentials = try SharedKeychain.credentials() else {
        throw MailError.missingCredentials
      }
      let message = try payload.decrypt(
        key: SharedKeychain.payloadKey(identity: credentials.identity))
      let content = NotificationContent.make(for: message)
      content.userInfo = request.content.userInfo
      if payload.test != true {
        content.userInfo["mailchimeMail"] = ["v": 1, "kind": "remote", "emailId": payload.emailId,
          "identity": credentials.deviceId, "origin": credentials.relayURL]
      }
      lock.lock()
      // Expiration may have already handed off the generic notification. Do not mark an unseen rich notification delivered.
      if handler != nil {
        do {
          if payload.test != true {
            try SharedState.container().record(payload.seq, identity: credentials.identity)
          }
          best = content
        } catch {
          Logger(subsystem: AppIdentity.bundleIdentifier, category: "extension").error(
            "Could not record notification sequence.")
          best = content
        }
      }
      lock.unlock()
    } catch {
      Logger(subsystem: AppIdentity.bundleIdentifier, category: "extension").error(
        "Notification could not be decrypted or validated.")
    }
    complete()
  }
  override func serviceExtensionTimeWillExpire() { complete() }
  private func complete() {
    lock.lock()
    let callback = handler
    let content = best
    handler = nil
    best = nil
    lock.unlock()
    if let callback, let content { callback(content) }
  }
}

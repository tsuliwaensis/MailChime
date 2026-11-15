import Foundation
import UserNotifications

public enum NotificationContent {
  public static func make(
    for message: MessageHeaders, timeZone: TimeZone = .current, locale: Locale = .current
  ) -> UNMutableNotificationContent {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Here's The Mail!")
    content.body = [
      String(format: String(localized: "From: %@"), message.from),
      String(format: String(localized: "Subject: %@"), message.subject),
      String(format: String(localized: "Received: %@"), formatter.string(from: message.receivedAt)),
    ].joined(separator: "\n")
    content.sound = UNNotificationSound(named: UNNotificationSoundName("Notification_A.aiff"))
    content.threadIdentifier = "mailchime-inbox"
    return content
  }
}

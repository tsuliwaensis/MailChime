import AppKit
import UserNotifications

/// Retained for the process lifetime in UI, scheduled-agent, and manual-worker modes.
@MainActor
final class NotificationResponseHandler: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationResponseHandler()
  private(set) var receivedDefaultAction = false
  private var completedDefaultAction = false
  var terminateAfterResponse = false {
    didSet { if terminateAfterResponse && completedDefaultAction { terminate() } }
  }
  private let terminate: @MainActor () -> Void
  private let resolve: @MainActor (URL) -> URL?
  private let launch: @MainActor (URL) async throws -> Void
  private let reportFailure: @MainActor (MailAppError) -> Void

  enum MailAppError: Error, Equatable {
    case notConfigured
    case launchFailed

    var message: String {
      switch self {
      case .notConfigured:
        String(
          localized:
            "No default mail app is configured. Choose a default email reader in your mail app's settings, then try again."
        )
      case .launchFailed:
        String(
          localized: "The default mail app could not be opened. Open it manually, then try again.")
      }
    }
  }

  init(
    resolve: @escaping @MainActor (URL) -> URL? = {
      NSWorkspace.shared.urlForApplication(toOpen: $0)
    },
    launch: @escaping @MainActor (URL) async throws -> Void =
      NotificationResponseHandler.launchApplication,
    reportFailure: @escaping @MainActor (MailAppError) -> Void =
      NotificationResponseHandler.showFailure,
    terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
  ) {
    self.resolve = resolve
    self.launch = launch
    self.reportFailure = reportFailure
    self.terminate = terminate
  }

  static func install() {
    // Apple requires the delegate before launch finishes, including notification-triggered launch.
    UNUserNotificationCenter.current().delegate = shared
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    await handle(actionIdentifier: action)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  func handle(actionIdentifier: String) async {
    guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
    receivedDefaultAction = true
    completedDefaultAction = false
    defer {
      completedDefaultAction = true
      if terminateAfterResponse { terminate() }
    }
    // Use mailto only to resolve the user's preference. Opening mailto itself creates a draft.
    guard let application = resolve(URL(string: "mailto:")!), application.isFileURL else {
      reportFailure(.notConfigured)
      return
    }
    do { try await launch(application) } catch { reportFailure(.launchFailed) }
  }

  private static func launchApplication(at application: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.createsNewApplicationInstance = false
    _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
  }

  private static func showFailure(_ error: MailAppError) {
    let previousPolicy = NSApp.activationPolicy()
    if previousPolicy == .prohibited { NSApp.setActivationPolicy(.accessory) }
    defer {
      if previousPolicy == .prohibited { NSApp.setActivationPolicy(previousPolicy) }
    }
    let alert = NSAlert()
    alert.messageText = String(localized: "Could Not Open Mail App")
    alert.informativeText = error.message
    alert.addButton(withTitle: String(localized: "OK"))
    NSApp.activate()
    alert.runModal()
  }
}

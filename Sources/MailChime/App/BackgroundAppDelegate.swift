import AppKit
import MailChimeKit
import Security

/// Launch Services can route an app-open event to the agent because it shares the app bundle.
/// Keep the agent headless and explicitly launch a separate settings instance.
@MainActor
final class BackgroundAppDelegate: NSObject, NSApplicationDelegate {
  private var openingSettings = false
  private let settingsRequest: (@MainActor () -> Void)?
  private let notificationEvent: @MainActor () -> Bool

  init(
    settingsRequest: (@MainActor () -> Void)? = nil,
    notificationEvent: @escaping @MainActor () -> Bool = AppOpenOrigin.isNotificationEvent
  ) {
    self.settingsRequest = settingsRequest
    self.notificationEvent = notificationEvent
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.prohibited)
    PushRegistrar.shared.startIfEnabled()
  }

  func application(
    _ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    PushRegistrar.shared.registered(deviceToken)
  }
  func application(
    _ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    PushRegistrar.shared.registrationFailed(error)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    NSApp.setActivationPolicy(.prohibited)
    if !notificationEvent() { openSettings() }
    return false
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    // Notification clicks also activate this process. Only an explicit reopen event
    // should open settings; notification responses are handled by NotificationResponseHandler.
    NSApp.setActivationPolicy(.prohibited)
  }

  private func openSettings() {
    if let settingsRequest {
      settingsRequest()
      return
    }
    // Finder may promote a prohibited process to regular when reopening its bundle.
    NSApp.setActivationPolicy(.prohibited)
    guard !openingSettings else { return }
    // The settings lock is authoritative; a settings process that is still launching holds it
    // before its activation policy becomes regular.
    if SingleInstance.showRunningSettings() { return }
    openingSettings = true
    Task {
      defer { openingSettings = false }
      do {
        _ = try await NSWorkspace.shared.openApplication(
          at: Bundle.main.bundleURL, configuration: Self.settingsLaunchConfiguration())
      } catch {
        try? ErrorLog().record(error)
      }
    }
  }

  static func settingsLaunchConfiguration() -> NSWorkspace.OpenConfiguration {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.activates = true
    configuration.arguments = []
    return configuration
  }
}

/// Notification Center sends ordinary open/reopen Apple events in addition to the
/// UNNotificationResponse callback. Identify their sender instead of racing the callback.
@MainActor
enum AppOpenOrigin {
  static func isNotificationSender(_ identifier: String?) -> Bool {
    identifier == "com.apple.usernoted" || identifier == "com.apple.notificationcenterui"
  }

  static func isNotificationEvent() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
      pid > 0
    else { return false }
    return isNotificationSender(signingIdentifier(for: pid))
  }

  static func signingIdentifier(for pid: pid_t) -> String? {
    var code: SecCode?
    guard
      SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
        == errSecSuccess,
      let code
    else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String
  }
}

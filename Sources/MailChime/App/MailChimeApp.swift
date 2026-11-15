import AppKit
import MailChimeKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main @MainActor
enum EntryPoint {
  private static var controller: AgentController?
  private static var backgroundDelegate: BackgroundAppDelegate?
  private static var appDelegate: AppDelegate?
  static func main() {
    _ = NSApplication.shared
    NSWindow.allowsAutomaticWindowTabbing = false
    NotificationResponseHandler.install()
    if CommandLine.arguments.contains("--diagnose-delivery") {
      NSApp.setActivationPolicy(.prohibited)
      Task {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let previews: String
        switch settings.showPreviewsSetting {
        case .always: previews = "always"
        case .whenAuthenticated: previews = "when authenticated"
        case .never: previews = "never"
        @unknown default: previews = "unknown"
        }
        print("Preview setting: \(previews)")
        print("Authorization status: \(settings.authorizationStatus.rawValue)")
        let notifications = await center.deliveredNotifications()
        print("Delivered notifications: \(notifications.count)")
        for notification in notifications {
          let content = notification.request.content
          let seq = (content.userInfo["seq"] as? NSNumber)?.intValue ?? -1
          let source = notification.request.trigger is UNPushNotificationTrigger ? "push" : "local"
          let rich = content.body.contains("\nSubject:")
          print("source=\(source) seq=\(seq) richHeaders=\(rich)")
        }
        exit(0)
      }
    } else if CommandLine.arguments.contains("--diagnose-read-clearing") {
      do {
        let progress = try SharedState.container().load("read-status.json", as: ReadNotificationReconciler.Progress.self)
        print("Read clearing attempted: \(progress?.lastAttempt != nil)")
        print("Read clearing succeeded: \(progress?.lastSuccess != nil)")
        print("Last removal requests: \(progress?.removalRequests ?? 0)")
        print("Consecutive failures: \(progress?.failures ?? 0)")
        print("Failure category: \(progress?.error ?? "none")")
      } catch {
        print("Read clearing diagnostics unavailable.")
        exit(1)
      }
      return
    } else if CommandLine.arguments.contains("--diagnose-apns") {
      backgroundDelegate = BackgroundAppDelegate()
      NSApp.delegate = backgroundDelegate
      NSApp.setActivationPolicy(.prohibited)
      Task {
        do {
          let token = try await PushRegistrar.shared.requestToken()
          guard let environment = PushRegistrar.shared.environment else {
            throw MailError.pushEnvironment
          }
          let result = [
            "apnsToken": token.map { String(format: "%02x", $0) }.joined(),
            "environment": environment.rawValue,
          ]
          // Diagnostic output must be captured privately; never use it in application logs.
          let data = try JSONEncoder().encode(result)
          FileHandle.standardOutput.write(data)
          exit(0)
        } catch {
          fputs("APNs registration diagnostic failed.\n", stderr)
          exit(1)
        }
      }
    } else if CommandLine.arguments.contains("--diagnose-shared") {
      do {
        let shared = try SharedState.container()
        let account = "diagnostic-" + UUID().uuidString
        let bytes = Data(UUID().uuidString.utf8)
        try SharedKeychain.set(bytes, account: account)
        defer { try? SharedKeychain.delete(account: account) }
        guard try SharedKeychain.get(account: account) == bytes else { throw MailError.keychain }
        let name = account + ".json"
        try shared.save(["ok": true], to: name)
        defer {
          try? FileManager.default.removeItem(at: shared.directory.appendingPathComponent(name))
        }
        guard try shared.load(name, as: [String: Bool].self)?["ok"] == true else {
          throw MailError.storage
        }
        print("Shared container and data-protection Keychain diagnostic passed.")
      } catch {
        print("Shared container/Keychain diagnostic failed.")
        exit(1)
      }
      return
    } else if CommandLine.arguments.contains("--diagnose") {
      NSApp.setActivationPolicy(.prohibited)
      Task {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        let store = AgentStore(directory: directory)
        let checker = CatchUpWorker(store: store, credentials: { nil }, failure: { _ in })
        let success = await checker.run()
        let status = try? store.load("status.json", as: CheckStatus.self)
        let passed =
          !success && status?.message == MailError.missingCredentials.localizedDescription
        try? FileManager.default.removeItem(at: directory)
        print(passed ? "Credential-free worker diagnostic passed." : "Worker diagnostic failed.")
        exit(passed ? 0 : 1)
      }
    } else if CommandLine.arguments.contains("--diagnose-notification") {
      let message = MessageHeaders(
        id: "test", from: "Example Sender <sender@example.com>", subject: "Test message",
        receivedAt: Date())
      let content = NotificationContent.make(for: message)
      let passed =
        content.title == "Here's The Mail!" && content.body.contains("Subject: Test message")
      print(
        passed ? "Per-message notification diagnostic passed." : "Notification diagnostic failed.")
      exit(passed ? 0 : 1)
    } else if CommandLine.arguments.contains("--diagnose-service") {
      let valid = AgentRegistration.bundleIsValid()
      print("Agent bundle valid: \(valid)")
      let environment =
        PushEnvironment.signedEntitlementValue()
        ?? (Bundle.main.object(forInfoDictionaryKey: "MailChimeAPNsEnvironment") as? String)
        ?? "missing"
      print("APNs environment: \(environment)")
      exit(valid ? 0 : 1)
    } else if CommandLine.arguments.contains("--check-once") {
      NSApp.setActivationPolicy(.prohibited)
      Task {
        let success = await CatchUpWorker().run()
        await ReadNotificationReconciler().run()
        exit(success ? 0 : 1)
      }
    } else if CommandLine.arguments.contains("--agent") {
      guard SingleInstance.acquire(.agent) else { return }
      backgroundDelegate = BackgroundAppDelegate()
      NSApp.delegate = backgroundDelegate
      NSApp.setActivationPolicy(.prohibited)
      controller = AgentController()
      controller?.start()
    } else {
      if !SingleInstance.isExempt(), !SingleInstance.acquire(.settings) {
        SingleInstance.showRunningSettings()
        return
      }
      appDelegate = AppDelegate()
      NSApp.delegate = appDelegate
    }
    NSApp.run()
  }
}

enum Token {
  enum Space {
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
  }
  enum Size {
    static let paneWidth: CGFloat = 620
    static let paneHeight: CGFloat = 680
  }
}
struct SettingsView: View {
  @Bindable var model: SettingsModel
  var body: some View {
    Form {
      Section {
        TextField(String(localized: "Worker URL"), text: $model.relayURL).autocorrectionDisabled()
        SecureField(String(localized: "Device secret"), text: $model.deviceSecret)
        Text(String(localized: "Leave the device secret empty to keep the saved value."))
          .font(.callout).foregroundStyle(.secondary)
        Button(String(localized: "Save Relay")) { model.saveCredentials() }.keyboardShortcut("s")
        sectionFeedback(.relay)
      } header: {
        Label(String(localized: "Relay"), systemImage: "key")
      }
      Section {
        Toggle(
          String(localized: "Enable notifications"),
          isOn: Binding(
            get: { model.enabled },
            set: { value in
              Task { await model.setEnabled(value) }
            })
        ).disabled(!model.hasCredentials)
        LabeledContent(String(localized: "APNs registration"), value: model.registrar.apnsStatus)
        LabeledContent(String(localized: "Worker registration"), value: model.workerStatus)
        #if DEBUG
        LabeledContent(
          String(localized: "Environment"),
          value: model.registrar.environment?.rawValue
            ?? MailError.pushEnvironment.localizedDescription)
        #endif
        LabeledContent(String(localized: "Last push sent")) {
          if let timestamp = model.remoteStatus?.lastPush {
            Text(Date(timeIntervalSince1970: timestamp / 1000), format: .dateTime)
          } else {
            Text(String(localized: "None yet"))
          }
        }
        LabeledContent(
          String(localized: "Background agent"),
          value: AgentRegistration.statusText(
            model.serviceStatus, bundleAvailable: model.agentBundleAvailable))
        if model.serviceStatus == .requiresApproval {
          Button(String(localized: "Open Login Items…")) { model.openLoginItems() }
        }
        HStack {
          Button(String(localized: "Restart Background Agent")) {
            Task { await model.restartBackgroundAgent() }
          }.disabled(!model.enabled || !model.agentBundleAvailable)
          Button(String(localized: "Retry Registration")) { Task { await model.retryRegistration() } }
            .disabled(!model.enabled).keyboardShortcut("r", modifiers: [.command, .shift])
        }
        Text(
          String(
            localized:
              "The background agent checks for missed mail at login, after wake, and when the network returns."
          )
        )
        .font(.callout).foregroundStyle(.secondary)
        sectionFeedback(.notifications)
      } header: {
        Label(String(localized: "Notifications"), systemImage: "bell")
      }
      Section {
        HStack {
          Button(String(localized: "Send Test Notification")) { Task { await model.sendTest() } }
            .keyboardShortcut("t", modifiers: [.command, .shift])
          Button(String(localized: "Check for Missed Mail")) { Task { await model.runNow() } }
            .keyboardShortcut("r")
          if model.busy { ProgressView().controlSize(.small) }
        }.disabled(!model.enabled || !model.hasCredentials)
        if let status = model.status {
          LabeledContent(String(localized: "Last check")) { Text(status.date, format: .dateTime) }
          if status.success { FeedbackMessage(message: status.message, isError: false) }
        }
        sectionFeedback(.activity)
      } header: {
        Label(String(localized: "Activity"), systemImage: "bolt")
      }
      Section {
        Button(String(localized: "Open Application Support Folder")) { model.viewLogs() }
      } header: {
        Label(String(localized: "View logs"), systemImage: "doc.text")
      }
    }.formStyle(.grouped).padding(16)
      .frame(minWidth: Token.Size.paneWidth, minHeight: Token.Size.paneHeight).disabled(model.busy)
  }
  @ViewBuilder private func sectionFeedback(_ section: SettingsModel.FeedbackSection) -> some View {
    ForEach(Array(model.messages(in: section).enumerated()), id: \.offset) { _, feedback in
      FeedbackMessage(message: feedback.message, isError: feedback.isError)
    }
  }

}

/// Shared presentation for action feedback and persisted check failures.
private struct FeedbackMessage: View {
  let message: String
  let isError: Bool
  var body: some View {
    Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
      .font(.system(size: NSFont.systemFontSize * (isError ? 1.5 : 1)))
      .foregroundStyle(isError ? Color.red : Color.primary)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Own window creation explicitly so a notification cold launch cannot create a SwiftUI scene first.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var model: SettingsModel?
  private var notificationLaunch = false
  @objc func showAbout(_ sender: Any?) { AppPresentation.showAbout() }
  func applicationWillFinishLaunching(_ notification: Notification) {
    NotificationResponseHandler.install()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    notificationLaunch =
      notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] != nil
      || AppOpenOrigin.isNotificationEvent()
      || NotificationResponseHandler.shared.receivedDefaultAction
    NotificationResponseHandler.shared.terminateAfterResponse = notificationLaunch
    AppPresentation.configureMenu()
    if notificationLaunch {
      NSApp.setActivationPolicy(.accessory)
      // The notification delegate opens the default mail app. No settings window is constructed.
    } else {
      showSettings()
    }
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(showSettings),
      name: Notification.Name(SingleInstance.showSettings), object: nil)
    if !notificationLaunch { PushRegistrar.shared.startIfEnabled() }
    if CommandLine.arguments.contains("--diagnose-interface") {
      AppPresentation.verifyInterfaceAndExit()
    }
  }
  @objc func showSettings() {
    notificationLaunch = false
    NotificationResponseHandler.shared.terminateAfterResponse = false
    NSApp.setActivationPolicy(.regular)
    if window == nil {
      let model = SettingsModel(loadOnInit: !SingleInstance.isExempt())
      self.model = model
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: Token.Size.paneWidth, height: Token.Size.paneHeight),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = String(localized: "MailChime Settings")
      window.identifier = NSUserInterfaceItemIdentifier("settings")
      window.tabbingMode = .disallowed
      window.delegate = self
      window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
      window.isReleasedWhenClosed = false
      window.center()
      window.setFrameAutosaveName("MailChimeSettings")
      self.window = window
    }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }
  func windowWillClose(_ notification: Notification) {
    guard let closed = notification.object as? NSWindow, closed === window else { return }
    NSApp.terminate(nil)
  }
  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !AppOpenOrigin.isNotificationEvent() { showSettings() }
    return false
  }
  func applicationDidBecomeActive(_ notification: Notification) { model?.refreshStatus() }
  func applicationDidResignActive(_ notification: Notification) { model?.deviceSecret = "" }
  func application(
    _ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) { PushRegistrar.shared.registered(deviceToken) }
  func application(
    _ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) { PushRegistrar.shared.registrationFailed(error) }
}
@MainActor
enum AppPresentation {
  static let martonPauloURL = URL(string: "https://github.com/martonpaulo/mailbell")!
  static let samzongURL = URL(string: "https://github.com/samzong/")!

  static var aboutCredits: NSAttributedString {
    let text = [
      String(localized: "© 2026 RHPT"),
      String(localized: "Released under the MIT License"),
      String(localized: "Based on MailBell by Marton Paulo and Samzong"),
    ].joined(separator: "\n")
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributed = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor.controlTextColor,
        .paragraphStyle: paragraph,
      ])
    let nsText = text as NSString
    let martonRange = nsText.range(of: "Marton Paulo")
    if martonRange.location != NSNotFound {
      attributed.addAttribute(.link, value: martonPauloURL, range: martonRange)
    }
    let samzongRange = nsText.range(of: "Samzong")
    if samzongRange.location != NSNotFound {
      attributed.addAttribute(.link, value: samzongURL, range: samzongRange)
    }
    return attributed
  }

  static var aboutOptions: [NSApplication.AboutPanelOptionKey: Any] {
    [
      .applicationName: "MailChime",
      .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "",
      .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      .credits: aboutCredits,
      NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "",
    ]
  }

  static func showAbout() {
    NSApp.orderFrontStandardAboutPanel(options: aboutOptions)
  }

  static func configureMenu() {
    do {
      // AppKit may already have an empty main menu. Always install the complete menu.
      let menu = NSMenu()
      let appItem = NSMenuItem(title: "MailChime", action: nil, keyEquivalent: "")
      menu.addItem(appItem)
      let app = NSMenu(title: "MailChime")
      appItem.submenu = app
      let about = NSMenuItem(
        title: String(localized: "About MailChime"), action: #selector(AppDelegate.showAbout(_:)),
        keyEquivalent: "")
      about.target = NSApp.delegate
      app.addItem(about)
      app.addItem(.separator())
      let quit = app.addItem(
        withTitle: String(localized: "Quit MailChime"), action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q")
      quit.target = NSApp
      let editItem = NSMenuItem()
      editItem.title = String(localized: "Edit")
      menu.addItem(editItem)
      let edit = NSMenu(title: editItem.title)
      editItem.submenu = edit
      for (title, action, key) in [
        ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
        ("Select All", "selectAll:", "a"),
      ] {
        edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
      }
      let windowItem = NSMenuItem()
      windowItem.title = String(localized: "Window")
      menu.addItem(windowItem)
      let windows = NSMenu(title: windowItem.title)
      windowItem.submenu = windows
      NSApp.windowsMenu = windows
      windows.addItem(
        withTitle: String(localized: "Minimize"),
        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
      windows.addItem(
        withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w")
      NSApp.mainMenu = menu
    }
    guard let menu = NSApp.mainMenu else { return }
    menu.items.first?.title = "MailChime"
    menu.items.first?.submenu?.title = "MailChime"
    // Use an ordinary menu so macOS does not insert the Help search field.
    NSApp.helpMenu = nil
    let title = String(localized: "Help")
    let helpItem: NSMenuItem
    if let existing = menu.items.first(where: { $0.title == title }) {
      helpItem = existing
    } else {
      helpItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      menu.addItem(helpItem)
    }
    let help = NSMenu(title: title)
    let license = NSMenuItem(
      title: String(localized: "License"),
      action: #selector(LicenseWindowController.showLicense(_:)), keyEquivalent: "")
    license.target = LicenseWindowController.shared
    help.addItem(license)
    helpItem.submenu = help
  }

  /// Exercises the composed native menu and About panel without mail or agent actions.
  static func verifyInterfaceAndExit() {
    // Reproduce AppKit providing an existing empty menu before setup.
    NSApp.mainMenu = NSMenu()
    configureMenu()
    let appMenu = NSApp.mainMenu?.items.first?.submenu
    appMenu?.update()
    appMenu?.performActionForItem(at: 0)
    let help = NSApp.mainMenu?.items.first(where: { $0.title == String(localized: "Help") })?
      .submenu
    help?.performActionForItem(at: 0)
    DispatchQueue.main.async {
      @MainActor func text(in view: NSView) -> [String] {
        let field = (view as? NSTextField).map { [$0.stringValue] } ?? []
        let textView = (view as? NSTextView).map { [$0.string] } ?? []
        return field + textView + view.subviews.flatMap { text(in: $0) }
      }
      let labels = NSApp.windows.compactMap(\.contentView).flatMap { text(in: $0) }
      let version = aboutOptions[.applicationVersion] as? String ?? ""
      let build = aboutOptions[.version] as? String ?? ""
      let expectedCredits = aboutCredits.string
      let menu = NSApp.mainMenu
      let license = NSApp.windows.first { $0.identifier?.rawValue == "license" }
      let settings = NSApp.windows.first { $0.identifier?.rawValue == "settings" }
      let quit = appMenu?.items.first { $0.action == #selector(NSApplication.terminate(_:)) }
      let passed =
        menu?.items.first?.title == "MailChime"
        && appMenu?.items.first?.isEnabled == true
        && quit?.isEnabled == true && quit?.target === NSApp && quit?.keyEquivalent == "q"
        && license?.contentView?.bounds.size == NSSize(width: 720, height: 430)
        && license?.tabbingMode == .disallowed && license?.tabbedWindows == nil
        && settings?.tabbingMode == .disallowed
        && help?.items.map(\.title) == [String(localized: "License")]
        && NSApp.helpMenu == nil
        && (try? LicenseWindowController.bundledText()).map { labels.contains($0) } == true
        && NSApp.windows.contains(where: { $0.identifier?.rawValue == "license" && $0.isVisible })
        && labels.contains("MailChime") && !version.isEmpty && !build.isEmpty
        && labels.contains(where: { $0.contains(version) && $0.contains(build) })
        && labels.contains(expectedCredits)
      print(
        passed
          ? "Native MailChime menu and About diagnostic passed." : "Native interface diagnostic failed.")
      guard passed, let settings else { exit(1) }
      // Exercise the real close-button action with License still open. The settings
      // delegate must terminate this diagnostic process, not just hide its window.
      settings.performClose(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        print("Closing Settings did not terminate the app.")
        exit(1)
      }
    }
  }
}

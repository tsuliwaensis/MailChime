import AppKit

/// A single, reusable window displaying the exact license shipped with this app.
@MainActor
final class LicenseWindowController: NSObject {
  static let shared = LicenseWindowController()
  private var window: NSWindow?

  static func bundledText() throws -> String {
    guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  @objc func showLicense(_ sender: Any?) {
    if let window {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 430),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = String(localized: "License")
    window.identifier = NSUserInterfaceItemIdentifier("license")
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentLayoutRect)
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let text = NSTextView(frame: scroll.contentView.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    text.textColor = .textColor
    text.backgroundColor = .textBackgroundColor
    text.textContainerInset = NSSize(width: Token.Space.xl, height: Token.Space.xl)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.setAccessibilityLabel(String(localized: "License"))
    do { text.string = try Self.bundledText() } catch {
      text.string = String(localized: "The bundled license could not be loaded.")
    }
    scroll.documentView = text
    window.contentView = scroll
    window.center()
    self.window = window
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(text)
  }
}

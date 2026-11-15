import Foundation

public struct MessageHeaders: Sendable, Equatable {
  public let id: String
  public let from: String
  public let subject: String
  public let receivedAt: Date
  public init(id: String, from: String, subject: String, receivedAt: Date) {
    self.id = id
    self.from = Self.display(from, fallback: String(localized: "Unknown sender"))
    self.subject = Self.display(subject, fallback: String(localized: "No subject"))
    self.receivedAt = receivedAt
  }
  public static func display(_ value: String, fallback: String) -> String {
    let safe = String(
      String.UnicodeScalarView(
        value.unicodeScalars.map {
          CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
            ? UnicodeScalar(32)! : $0
        })
    ).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return safe.isEmpty ? fallback : String(safe.prefix(Defaults.maximumDisplayCharacters))
  }
}

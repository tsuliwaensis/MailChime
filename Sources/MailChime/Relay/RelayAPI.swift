import MailChimeKit
import Foundation

@MainActor
protocol RelayTransport {
  func missed(after: Int) async throws -> MissedResponse
  func acknowledge(_ seq: Int) async throws
}
/// Refuse redirects so a device secret cannot be forwarded to a different origin.
private final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
@MainActor
final class RelayAPI: RelayTransport {
  let credentials: RelayCredentials
  private let session: URLSession
  init(credentials: RelayCredentials) {
    self.credentials = credentials
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = Defaults.checkTimeout
    config.httpShouldSetCookies = false
    config.urlCache = nil
    session = URLSession(
      configuration: config, delegate: RelaySessionDelegate(), delegateQueue: nil)
  }
  deinit { session.invalidateAndCancel() }
  private func request<Response: Decodable>(
    _ path: String, method: String = "GET", body: Data? = nil,
    query: [URLQueryItem] = [], as: Response.Type
  ) async throws -> Response {
    _ = try credentials.validated()
    guard var url = URLComponents(string: credentials.relayURL) else { throw MailError.credentials }
    url.path = path
    if !query.isEmpty { url.queryItems = query }
    guard let endpoint = url.url else { throw MailError.credentials }
    var request = URLRequest(url: endpoint)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("Bearer " + credentials.deviceSecret, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw MailError.relayUnavailable }
    guard http.statusCode == 200 || http.statusCode == 201 || http.statusCode == 204 else {
      bytes.task.cancel()
      switch http.statusCode {
      case 401, 403: throw MailError.relayAuthentication
      case 409: throw MailError.deviceRegistration
      default: throw MailError.relayUnavailable
      }
    }
    guard response.expectedContentLength <= Defaults.maximumResponseBytes else {
      bytes.task.cancel()
      throw MailError.invalidPayload
    }
    var data = Data()
    do {
      for try await byte in bytes {
        guard data.count < Defaults.maximumResponseBytes else { throw MailError.invalidPayload }
        data.append(byte)
      }
    } catch {
      bytes.task.cancel()
      throw error
    }
    if http.statusCode == 204 { data = Data("{}".utf8) }
    do { return try JSONDecoder().decode(Response.self, from: data) } catch {
      throw MailError.invalidPayload
    }
  }
  func readStatus(_ ids: [String]) async throws -> ReadStatusResponse {
    let body = try JSONSerialization.data(withJSONObject: ["deviceId": credentials.deviceId, "emailIds": ids])
    let result = try await request("/read-status", method: "POST", body: body, as: ReadStatusResponse.self)
    _ = try result.readIDs(for: ids, deviceId: credentials.deviceId)
    return result
  }
  func missed(after: Int) async throws -> MissedResponse {
    let response = try await request(
      "/missed",
      query: [
        .init(name: "deviceId", value: credentials.deviceId),
        .init(name: "after", value: String(after)),
      ], as: MissedResponse.self)
    return try response.validated(after: after)
  }
  func acknowledge(_ seq: Int) async throws {
    struct Response: Decodable { let lastAckedSeq: Int }
    let body = try JSONSerialization.data(withJSONObject: [
      "deviceId": credentials.deviceId, "seq": seq,
    ])
    let result = try await request("/ack", method: "POST", body: body, as: Response.self)
    guard result.lastAckedSeq >= seq, result.lastAckedSeq <= Defaults.maximumSequence else {
      throw MailError.invalidPayload
    }
  }
  func register(token: String, environment: PushEnvironment, key: Data) async throws {
    struct Response: Decodable {
      let deviceId: String
      let lastAckedSeq: Int
      let latestSeq: Int
    }
    let body = try JSONSerialization.data(withJSONObject: [
      "deviceId": credentials.deviceId, "apnsToken": token,
      "environment": environment.rawValue, "timeZone": TimeZone.current.identifier,
      "payloadKey": key.base64EncodedString(),
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "1.0",
    ])
    let response = try await request("/devices", method: "POST", body: body, as: Response.self)
    guard response.deviceId == credentials.deviceId, response.lastAckedSeq >= 0,
      response.latestSeq >= response.lastAckedSeq,
      response.latestSeq <= Defaults.maximumSequence
    else { throw MailError.invalidPayload }
  }
  func remove() async throws {
    struct Empty: Decodable {}
    _ = try await request("/devices/" + credentials.deviceId, method: "DELETE", as: Empty.self)
  }
  func status() async throws -> RelayStatus { try await request("/status", as: RelayStatus.self) }
  func health() async throws {
    struct Health: Decodable {
      let ok: Bool
      let service: String
      let version: Int
    }
    let value = try await request("/health", as: Health.self)
    guard value.ok, value.service == "mailchime-relay", value.version == 1 else {
      throw MailError.relayUnavailable
    }
  }
  func test() async throws {
    struct Result: Decodable {
      let kind: String
      let status: Int
    }
    let result = try await request(
      "/test", method: "POST", body: JSONEncoder().encode(["deviceId": credentials.deviceId]),
      as: Result.self)
    guard result.kind == "sent", result.status == 200 else { throw MailError.pushRegistration }
  }
}

import Foundation

public struct HTTPRequest: Sendable {
  public let method: String
  public let target: String
  public let headers: [String: String]
  public let body: Data

  public init(method: String, target: String, headers: [String: String], body: Data) {
    self.method = method
    self.target = target
    self.headers = headers
    self.body = body
  }

  public var path: String {
    URLComponents(string: target)?.path ?? target
  }

  public var queryItems: [URLQueryItem] {
    URLComponents(string: target)?.queryItems ?? []
  }

  public func queryValue(_ name: String) -> String? {
    queryItems.first(where: { $0.name == name })?.value
  }
}

public struct HTTPResponse: Sendable {
  public let status: Int
  public let reason: String
  public let headers: [String: String]
  public let body: Data

  public init(
    status: Int,
    reason: String,
    headers: [String: String] = [:],
    body: Data = Data()
  ) {
    self.status = status
    self.reason = reason
    self.headers = headers
    self.body = body
  }

  public static func json<T: Encodable>(
    _ value: T,
    status: Int = 200,
    reason: String = "OK"
  ) throws -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return HTTPResponse(
      status: status,
      reason: reason,
      headers: ["Content-Type": "application/json; charset=utf-8"],
      body: try encoder.encode(value)
    )
  }

  public static func text(
    _ value: String,
    status: Int,
    reason: String
  ) -> HTTPResponse {
    HTTPResponse(
      status: status,
      reason: reason,
      headers: ["Content-Type": "text/plain; charset=utf-8"],
      body: Data(value.utf8)
    )
  }

  func serialized() -> Data {
    var combinedHeaders = headers
    combinedHeaders["Content-Length"] = String(body.count)
    combinedHeaders["Connection"] = "close"
    combinedHeaders["Cache-Control"] = combinedHeaders["Cache-Control"] ?? "no-store"
    combinedHeaders["X-Content-Type-Options"] = "nosniff"
    combinedHeaders["X-Frame-Options"] = "DENY"
    combinedHeaders["Referrer-Policy"] = "no-referrer"
    combinedHeaders["Content-Security-Policy"] =
      combinedHeaders["Content-Security-Policy"]
      ?? "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"

    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    for (name, value) in combinedHeaders.sorted(by: { $0.key < $1.key }) {
      head += "\(name): \(value)\r\n"
    }
    head += "\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
  }
}

public struct APIErrorPayload: Codable, Sendable {
  public let error: String

  public init(error: String) {
    self.error = error
  }
}

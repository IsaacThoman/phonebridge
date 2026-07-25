import CryptoKit
import Foundation
import Security

public struct ServerCapabilities: Codable, Sendable {
  public let version: String
  public let callHost: String
  public let services: [CallService]
  public let contacts: Bool
  public let callLaunch: Bool
  public let callControl: Bool
  public let webRTC: Bool
  public let injectedBridge: Bool
}

public struct HealthPayload: Codable, Sendable {
  public let ok: Bool
  public let service: String
  public let version: String
}

public actor PhoneBridgeAPI {
  private let token: String
  private let version: String
  private let contacts: any ContactDirectory
  private let launcher: any CallLaunching

  public init(
    token: String,
    version: String,
    contacts: any ContactDirectory = MacContactDirectory(),
    launcher: any CallLaunching = MacCallLauncher()
  ) {
    self.token = token
    self.version = version
    self.contacts = contacts
    self.launcher = launcher
  }

  public static func generateToken(byteCount: Int = 24) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard result == errSecSuccess else {
      throw PhoneBridgeError.invalidArguments("Could not generate a secure pairing token")
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public func handle(_ request: HTTPRequest) async -> HTTPResponse {
    do {
      if request.method == "GET", request.path == "/api/health" {
        return try .json(HealthPayload(ok: true, service: "phonebridge", version: version))
      }
      if request.method == "GET", request.path == "/" {
        return try webAsset("index", extension: "html", contentType: "text/html; charset=utf-8")
      }
      if request.method == "GET", request.path == "/app.js" {
        return try webAsset("app", extension: "js", contentType: "text/javascript; charset=utf-8")
      }
      if request.method == "GET", request.path == "/styles.css" {
        return try webAsset("styles", extension: "css", contentType: "text/css; charset=utf-8")
      }

      guard isAuthorized(request) else {
        return try .json(
          APIErrorPayload(error: "unauthorized"),
          status: 401,
          reason: "Unauthorized"
        )
      }

      if request.method == "GET", request.path == "/api/capabilities" {
        return try .json(capabilities())
      }
      if request.method == "GET", request.path == "/api/bridge/probe" {
        return try .json(PrivateCallBridgeProbe().inspect())
      }
      if request.method == "GET", request.path == "/api/contacts" {
        let query = request.queryValue("q") ?? ""
        let rawLimit = request.queryValue("limit").flatMap(Int.init) ?? 25
        let results = try await contacts.search(query, limit: max(1, min(rawLimit, 50)))
        return try .json(results)
      }
      if request.method == "POST", request.path == "/api/calls" {
        let decoded = try JSONDecoder().decode(CallLaunchRequest.self, from: request.body)
        let receipt = try await launcher.launch(decoded, dryRun: false)
        return try .json(receipt, status: 202, reason: "Accepted")
      }
      return try .json(
        APIErrorPayload(error: "not_found"),
        status: 404,
        reason: "Not Found"
      )
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      return
        (try? .json(
          APIErrorPayload(error: message),
          status: 400,
          reason: "Bad Request"
        )) ?? .text("bad request", status: 400, reason: "Bad Request")
    }
  }

  private func isAuthorized(_ request: HTTPRequest) -> Bool {
    guard let authorization = request.headers["authorization"],
      authorization.hasPrefix("Bearer ")
    else { return false }
    let supplied = String(authorization.dropFirst("Bearer ".count))
    return constantTimeEqual(supplied, token)
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
    let count = max(left.count, right.count)
    for index in 0..<count {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      difference |= a ^ b
    }
    return difference == 0
  }

  private func capabilities() -> ServerCapabilities {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let callHost = version.majorVersion >= 26 ? "Phone.app" : "FaceTime.app"
    return ServerCapabilities(
      version: self.version,
      callHost: callHost,
      services: CallService.allCases,
      contacts: true,
      callLaunch: true,
      callControl: false,
      webRTC: false,
      injectedBridge: false
    )
  }

  private func webAsset(
    _ name: String,
    extension fileExtension: String,
    contentType: String
  ) throws -> HTTPResponse {
    guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension),
      let data = try? Data(contentsOf: url)
    else {
      return .text("asset not found", status: 404, reason: "Not Found")
    }
    return HTTPResponse(
      status: 200,
      reason: "OK",
      headers: [
        "Content-Type": contentType,
        "Cache-Control": "no-cache",
      ],
      body: data
    )
  }
}

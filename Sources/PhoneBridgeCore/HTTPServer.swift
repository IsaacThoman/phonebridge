import Foundation
@preconcurrency import Network
import Security

public struct HTTPServerConfiguration: Sendable, Equatable {
  public let host: String
  public let port: UInt16
  public let maximumRequestBytes: Int
  public let tlsPKCS12: Data?
  public let tlsPassphrase: String?

  public init(
    host: String = "127.0.0.1",
    port: UInt16 = 8742,
    maximumRequestBytes: Int = 65_536,
    tlsPKCS12: Data? = nil,
    tlsPassphrase: String? = nil
  ) {
    self.host = host
    self.port = port
    self.maximumRequestBytes = maximumRequestBytes
    self.tlsPKCS12 = tlsPKCS12
    self.tlsPassphrase = tlsPassphrase
  }

  public var usesTLS: Bool { tlsPKCS12 != nil }
}

public final class HTTPServer: @unchecked Sendable {
  public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

  private let configuration: HTTPServerConfiguration
  private let handler: Handler
  private let queue = DispatchQueue(label: "phonebridge.http.listener", qos: .userInitiated)
  private var listener: NWListener?

  public init(configuration: HTTPServerConfiguration, handler: @escaping Handler) {
    self.configuration = configuration
    self.handler = handler
  }

  public func start() async throws {
    guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
      throw PhoneBridgeError.invalidArguments("Invalid server port: \(configuration.port)")
    }

    let parameters = try makeParameters()
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host(configuration.host),
      port: port
    )
    let listener = try NWListener(using: parameters)
    self.listener = listener

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let gate = ListenerContinuationGate(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume()
        case .failed(let error):
          gate.resume(throwing: error)
        case .cancelled:
          gate.resume(
            throwing: PhoneBridgeError.callLaunchFailed("HTTP listener was cancelled"))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: queue)
    }
  }

  private func makeParameters() throws -> NWParameters {
    guard let pkcs12 = configuration.tlsPKCS12 else {
      return NWParameters.tcp
    }
    var importedItems: CFArray?
    let passphraseKey = kSecImportExportPassphrase as String
    var importOptions: [String: Any] = [
      passphraseKey: configuration.tlsPassphrase ?? ""
    ]
    if #available(macOS 15.0, *) {
      importOptions[kSecImportToMemoryOnly as String] = kCFBooleanTrue
    }
    let options = importOptions as CFDictionary
    let status = SecPKCS12Import(pkcs12 as CFData, options, &importedItems)
    guard status == errSecSuccess,
      let items = importedItems as? [[String: Any]],
      let first = items.first,
      let identity = first[kSecImportItemIdentity as String] as! SecIdentity?
    else {
      throw PhoneBridgeError.invalidArguments(
        "Could not import the TLS PKCS#12 identity (Security status \(status)).")
    }
    guard let networkIdentity = sec_identity_create(identity) else {
      throw PhoneBridgeError.invalidArguments("Could not create the TLS server identity.")
    }
    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(
      tlsOptions.securityProtocolOptions,
      networkIdentity
    )
    return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
  }

  public func stop() {
    listener?.cancel()
    listener = nil
  }

  public func waitUntilCancelled() async {
    await withTaskCancellationHandler(
      operation: {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(3_600))
        }
      },
      onCancel: {
        stop()
      })
  }

  private func accept(_ connection: NWConnection) {
    let state = ConnectionState(
      connection: connection,
      maximumRequestBytes: configuration.maximumRequestBytes,
      handler: handler
    )
    connection.stateUpdateHandler = { connectionState in
      if case .ready = connectionState {
        state.receive()
      }
    }
    connection.start(queue: queue)
  }
}

private final class ListenerContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?

  init(_ continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func resume() {
    take()?.resume()
  }

  func resume(throwing error: Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Void, Error>? {
    lock.lock()
    defer { lock.unlock() }
    let value = continuation
    continuation = nil
    return value
  }
}

private final class ConnectionState: @unchecked Sendable {
  private let connection: NWConnection
  private let maximumRequestBytes: Int
  private let handler: HTTPServer.Handler
  private var buffer = Data()
  private var finished = false

  init(
    connection: NWConnection,
    maximumRequestBytes: Int,
    handler: @escaping HTTPServer.Handler
  ) {
    self.connection = connection
    self.maximumRequestBytes = maximumRequestBytes
    self.handler = handler
  }

  func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, complete, error in
      guard let self, !self.finished else { return }
      if let data {
        self.buffer.append(data)
      }
      if self.buffer.count > self.maximumRequestBytes {
        self.finish(.text("request too large", status: 413, reason: "Payload Too Large"))
        return
      }
      if let request = try? self.parseRequestIfComplete() {
        Task {
          let response = await self.handler(request)
          self.finish(response)
        }
        return
      }
      if error != nil || complete {
        self.finish(.text("bad request", status: 400, reason: "Bad Request"))
        return
      }
      self.receive()
    }
  }

  private func parseRequestIfComplete() throws -> HTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: delimiter) else { return nil }
    let headerData = buffer[..<headerRange.lowerBound]
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      throw PhoneBridgeError.invalidArguments("HTTP headers are not UTF-8")
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw PhoneBridgeError.invalidArguments("Missing HTTP request line")
    }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/1.") else {
      throw PhoneBridgeError.invalidArguments("Malformed HTTP request line")
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }

    let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
    guard contentLength >= 0, contentLength <= maximumRequestBytes else {
      throw PhoneBridgeError.invalidArguments("Invalid Content-Length")
    }
    let bodyStart = headerRange.upperBound
    guard buffer.count >= bodyStart + contentLength else { return nil }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
    return HTTPRequest(
      method: String(requestParts[0]).uppercased(),
      target: String(requestParts[1]),
      headers: headers,
      body: body
    )
  }

  private func finish(_ response: HTTPResponse) {
    guard !finished else { return }
    finished = true
    connection.send(
      content: response.serialized(),
      completion: .contentProcessed { _ in
        self.connection.cancel()
      })
  }
}

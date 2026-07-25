import Foundation
@preconcurrency import WebRTC

public struct WebRTCOffer: Codable, Sendable, Equatable {
  public let type: String
  public let sdp: String

  public init(type: String, sdp: String) {
    self.type = type
    self.sdp = sdp
  }
}

public struct WebRTCAnswer: Codable, Sendable, Equatable {
  public let sessionID: String
  public let type: String
  public let sdp: String

  public init(sessionID: String, type: String = "answer", sdp: String) {
    self.sessionID = sessionID
    self.type = type
    self.sdp = sdp
  }
}

public protocol WebRTCSignaling: Sendable {
  func createAnswer(for offer: WebRTCOffer) async throws -> WebRTCAnswer
  func close(sessionID: String) async
}

public actor WebRTCSessionManager: WebRTCSignaling {
  private let factory: RTCPeerConnectionFactory
  private var sessions: [String: WebRTCPeerSession] = [:]

  public init() {
    RTCInitializeSSL()
    factory = RTCPeerConnectionFactory()
  }

  public func createAnswer(for offer: WebRTCOffer) async throws -> WebRTCAnswer {
    guard offer.type == "offer", offer.sdp.contains("v=0") else {
      throw PhoneBridgeError.invalidArguments("A valid WebRTC SDP offer is required.")
    }
    let sessionID = UUID().uuidString.lowercased()
    let session = try WebRTCPeerSession(factory: factory)
    do {
      let sdp = try await session.answer(offerSDP: offer.sdp)
      sessions[sessionID] = session
      return WebRTCAnswer(sessionID: sessionID, sdp: sdp)
    } catch {
      session.close()
      throw error
    }
  }

  public func close(sessionID: String) {
    sessions.removeValue(forKey: sessionID)?.close()
  }
}

private final class WebRTCPeerSession: NSObject, @unchecked Sendable {
  private let peerConnection: RTCPeerConnection
  private let audioTrack: RTCAudioTrack

  init(factory: RTCPeerConnectionFactory) throws {
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    configuration.iceTransportPolicy = .all
    configuration.continualGatheringPolicy = .gatherOnce
    let constraints = RTCMediaConstraints(
      mandatoryConstraints: nil,
      optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
    )
    guard
      let peerConnection = factory.peerConnection(
        with: configuration,
        constraints: constraints,
        delegate: nil
      )
    else {
      throw PhoneBridgeError.unsupportedPlatform("Could not create a WebRTC peer connection.")
    }
    self.peerConnection = peerConnection
    let source = factory.audioSource(with: nil)
    audioTrack = factory.audioTrack(with: source, trackId: "phonebridge-audio")
    super.init()
    peerConnection.delegate = self
    guard peerConnection.add(audioTrack, streamIds: ["phonebridge"]) != nil else {
      throw PhoneBridgeError.unsupportedPlatform("Could not attach the WebRTC audio track.")
    }
  }

  func answer(offerSDP: String) async throws -> String {
    try await setRemoteDescription(
      RTCSessionDescription(type: .offer, sdp: offerSDP)
    )
    let answer = try await createAnswer()
    try await setLocalDescription(answer)
    await waitForICEGathering()
    guard let localDescription = peerConnection.localDescription else {
      throw PhoneBridgeError.unsupportedPlatform("WebRTC did not produce a local description.")
    }
    return localDescription.sdp
  }

  func close() {
    peerConnection.close()
  }

  private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      peerConnection.setRemoteDescription(description) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func createAnswer() async throws -> RTCSessionDescription {
    try await withCheckedThrowingContinuation { continuation in
      peerConnection.answer(
        for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      ) {
        description, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let description {
          continuation.resume(returning: description)
        } else {
          continuation.resume(
            throwing: PhoneBridgeError.unsupportedPlatform(
              "WebRTC returned neither an answer nor an error."))
        }
      }
    }
  }

  private func setLocalDescription(_ description: RTCSessionDescription) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      peerConnection.setLocalDescription(description) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func waitForICEGathering() async {
    let deadline = ContinuousClock.now + .seconds(3)
    while peerConnection.iceGatheringState != .complete, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }
}

extension WebRTCPeerSession: RTCPeerConnectionDelegate {
  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange stateChanged: RTCSignalingState
  ) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

  func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceConnectionState
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceGatheringState
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove candidates: [RTCIceCandidate]
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {}
}

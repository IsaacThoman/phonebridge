import AudioToolbox
import Foundation
@preconcurrency import PhoneBridgeWebRTCShim
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

public struct WebRTCMediaStatus: Codable, Sendable, Equatable {
  public let callAudioBundleIdentifier: String
  public let callAudioTapActive: Bool
  public let callAudioTapStarting: Bool
  public let callAudioTapError: String?
  public let callAudioFrameCount: UInt64
  public let callAudioPeak: Double
  public let virtualMicrophoneDevice: String?
  public let virtualMicrophoneError: String?
  public let nativeConnectionState: String
  public let nativeICEConnectionState: String
  public let localCandidateCount: Int
  public let localCandidates: [String]
  public let remoteCandidateCount: Int
  public let remoteCandidates: [String]
  public let browserAudioFrameCount: UInt64
  public let browserAudioPeak: Double
}

public protocol WebRTCSignaling: Sendable {
  func createAnswer(for offer: WebRTCOffer) async throws -> WebRTCAnswer
  func close(sessionID: String) async
  func status() async -> WebRTCMediaStatus
}

public actor WebRTCSessionManager: WebRTCSignaling {
  private let audioDevice: PBRTCAudioDevice
  private let audioSink: WebRTCAudioDeviceSink
  private let metrics = WebRTCMediaMetrics()
  private let virtualMicrophone = VirtualMicrophoneOutput()
  private let factory: RTCPeerConnectionFactory
  private var sessions: [String: WebRTCPeerSession] = [:]
  private var callAudioTap: CallAudioTap?
  private var callAudioTapStarting = false
  private var callAudioTapError: String?
  private var virtualMicrophoneError: String?
  private let callAudioBundleIdentifier: String

  public init() {
    RTCInitializeSSL()
    let audioDevice = PBRTCAudioDevice()
    self.audioDevice = audioDevice
    audioSink = WebRTCAudioDeviceSink(audioDevice: audioDevice)
    factory = PBRTCCreatePeerConnectionFactory(audioDevice)
    callAudioBundleIdentifier =
      ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
      ? "com.apple.mobilephone" : "com.apple.FaceTime"
    let metrics = self.metrics
    let virtualMicrophone = self.virtualMicrophone
    audioDevice.playoutHandler = { data, _, _, frameCount in
      metrics.addBrowserAudio(data, frameCount: UInt64(frameCount))
      virtualMicrophone.enqueuePCM16(data)
    }
  }

  public func createAnswer(for offer: WebRTCOffer) async throws -> WebRTCAnswer {
    guard offer.type == "offer", offer.sdp.contains("v=0") else {
      throw PhoneBridgeError.invalidArguments("A valid WebRTC SDP offer is required.")
    }
    for session in sessions.values {
      session.close()
    }
    sessions.removeAll()
    beginCallAudioTapIfNeeded()
    let sessionID = UUID().uuidString.lowercased()
    let session = try WebRTCPeerSession(factory: factory)
    do {
      let sdp = try await session.answer(offerSDP: offer.sdp)
      sessions[sessionID] = session
      Task {
        try? await Task.sleep(for: .seconds(3))
        ensureVirtualMicrophone()
      }
      return WebRTCAnswer(sessionID: sessionID, sdp: sdp)
    } catch {
      session.close()
      throw error
    }
  }

  public func close(sessionID: String) {
    sessions.removeValue(forKey: sessionID)?.close()
  }

  public func status() -> WebRTCMediaStatus {
    WebRTCMediaStatus(
      callAudioBundleIdentifier: callAudioBundleIdentifier,
      callAudioTapActive: callAudioTap != nil,
      callAudioTapStarting: callAudioTapStarting,
      callAudioTapError: callAudioTapError,
      callAudioFrameCount: metrics.callAudioFrameCount,
      callAudioPeak: metrics.callAudioPeak,
      virtualMicrophoneDevice: virtualMicrophone.device?.name,
      virtualMicrophoneError: virtualMicrophoneError,
      nativeConnectionState: sessions.values.first?.connectionState ?? "none",
      nativeICEConnectionState: sessions.values.first?.iceConnectionState ?? "none",
      localCandidateCount: sessions.values.first?.localCandidateCount ?? 0,
      localCandidates: sessions.values.first?.localCandidates ?? [],
      remoteCandidateCount: sessions.values.first?.remoteCandidateCount ?? 0,
      remoteCandidates: sessions.values.first?.remoteCandidates ?? [],
      browserAudioFrameCount: metrics.browserAudioFrameCount,
      browserAudioPeak: metrics.browserAudioPeak
    )
  }

  private func beginCallAudioTapIfNeeded() {
    guard callAudioTap == nil, !callAudioTapStarting else { return }
    callAudioTapStarting = true
    let bundleIdentifier = callAudioBundleIdentifier
    let audioSink = audioSink
    let metrics = metrics
    Task.detached { [weak self] in
      let tap = CallAudioTap()
      do {
        _ = try tap.start(bundleIdentifier: bundleIdentifier) { frame in
          metrics.addCallAudio(frame)
          let pcm16 = PCM16AudioConverter.convert(frame)
          if !pcm16.isEmpty {
            audioSink.enqueue(pcm16)
          }
        }
        await self?.completeCallAudioTapStart(tap: tap, error: nil)
      } catch {
        let message =
          (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        await self?.completeCallAudioTapStart(tap: nil, error: message)
      }
    }
  }

  private func completeCallAudioTapStart(tap: CallAudioTap?, error: String?) {
    callAudioTapStarting = false
    callAudioTap = tap
    callAudioTapError = error
  }

  private func ensureVirtualMicrophone() {
    guard virtualMicrophone.device == nil else { return }
    do {
      _ = try virtualMicrophone.start()
      virtualMicrophoneError = nil
    } catch {
      virtualMicrophoneError =
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }
}

private final class WebRTCAudioDeviceSink: @unchecked Sendable {
  private let audioDevice: PBRTCAudioDevice

  init(audioDevice: PBRTCAudioDevice) {
    self.audioDevice = audioDevice
  }

  func enqueue(_ pcm16: Data) {
    audioDevice.enqueueRecordedPCM16(pcm16)
  }
}

private final class WebRTCMediaMetrics: @unchecked Sendable {
  private let lock = NSLock()
  private var storedBrowserAudioFrameCount: UInt64 = 0
  private var storedBrowserAudioPeak = 0.0
  private var storedCallAudioFrameCount: UInt64 = 0
  private var storedCallAudioPeak = 0.0

  var callAudioFrameCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return storedCallAudioFrameCount
  }

  var callAudioPeak: Double {
    lock.lock()
    defer { lock.unlock() }
    return storedCallAudioPeak
  }

  var browserAudioFrameCount: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return storedBrowserAudioFrameCount
  }

  var browserAudioPeak: Double {
    lock.lock()
    defer { lock.unlock() }
    return storedBrowserAudioPeak
  }

  func addBrowserAudio(_ data: Data, frameCount: UInt64) {
    let peak = data.withUnsafeBytes {
      $0.bindMemory(to: Int16.self).reduce(0.0) {
        max($0, Double(abs(Int($1))) / Double(Int16.max))
      }
    }
    lock.lock()
    storedBrowserAudioFrameCount += frameCount
    storedBrowserAudioPeak = max(storedBrowserAudioPeak, peak)
    lock.unlock()
  }

  func addCallAudio(_ frame: CapturedAudioFrame) {
    let peak = frame.buffers.reduce(0.0) { current, data in
      let bufferPeak: Double
      if frame.formatFlags & kAudioFormatFlagIsFloat != 0 {
        bufferPeak = data.withUnsafeBytes {
          $0.bindMemory(to: Float.self).reduce(0.0) {
            max($0, Double(abs($1)))
          }
        }
      } else {
        bufferPeak = data.withUnsafeBytes {
          $0.bindMemory(to: Int16.self).reduce(0.0) {
            max($0, Double(abs(Int($1))) / Double(Int16.max))
          }
        }
      }
      return max(current, bufferPeak)
    }
    lock.lock()
    storedCallAudioFrameCount += UInt64(frame.frameCount)
    storedCallAudioPeak = max(storedCallAudioPeak, peak)
    lock.unlock()
  }
}

private enum PCM16AudioConverter {
  static func convert(_ frame: CapturedAudioFrame) -> Data {
    guard frame.frameCount > 0, frame.channelCount > 0, !frame.buffers.isEmpty else {
      return Data()
    }
    let samples = floatSamples(frame)
    let sourceFrameCount = Int(frame.frameCount)
    guard samples.count >= sourceFrameCount * 2 else { return Data() }
    let outputFrameCount = max(
      1,
      Int((Double(sourceFrameCount) * 48_000.0 / frame.sampleRate).rounded())
    )
    var output = [Int16](repeating: 0, count: outputFrameCount * 2)
    for outputFrame in 0..<outputFrameCount {
      let sourcePosition = Double(outputFrame) * frame.sampleRate / 48_000.0
      let lower = min(Int(sourcePosition), sourceFrameCount - 1)
      let upper = min(lower + 1, sourceFrameCount - 1)
      let fraction = Float(sourcePosition - Double(lower))
      for channel in 0..<2 {
        let lowerSample = samples[lower * 2 + channel]
        let upperSample = samples[upper * 2 + channel]
        let interpolated = lowerSample + (upperSample - lowerSample) * fraction
        output[outputFrame * 2 + channel] = Int16(
          max(Float(Int16.min), min(Float(Int16.max), interpolated * Float(Int16.max)))
        )
      }
    }
    return output.withUnsafeBytes { Data($0) }
  }

  private static func floatSamples(_ frame: CapturedAudioFrame) -> [Float] {
    let sourceFrames = Int(frame.frameCount)
    let sourceChannels = Int(frame.channelCount)
    let isFloat = frame.formatFlags & kAudioFormatFlagIsFloat != 0
    let isNonInterleaved = frame.formatFlags & kAudioFormatFlagIsNonInterleaved != 0

    if isNonInterleaved {
      let planes: [[Float]] = frame.buffers.prefix(sourceChannels).map { data in
        if isFloat {
          return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return data.withUnsafeBytes {
          $0.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
        }
      }
      guard !planes.isEmpty else { return [] }
      var stereo = [Float](repeating: 0, count: sourceFrames * 2)
      for index in 0..<sourceFrames {
        stereo[index * 2] = planes[0][safe: index] ?? 0
        stereo[index * 2 + 1] = (planes.count > 1 ? planes[1] : planes[0])[safe: index] ?? 0
      }
      return stereo
    }

    let interleaved: [Float]
    if isFloat {
      interleaved = frame.buffers[0].withUnsafeBytes {
        Array($0.bindMemory(to: Float.self))
      }
    } else {
      interleaved = frame.buffers[0].withUnsafeBytes {
        $0.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
      }
    }
    var stereo = [Float](repeating: 0, count: sourceFrames * 2)
    for index in 0..<sourceFrames {
      let base = index * sourceChannels
      stereo[index * 2] = interleaved[safe: base] ?? 0
      stereo[index * 2 + 1] =
        interleaved[safe: base + min(1, sourceChannels - 1)] ?? 0
    }
    return stereo
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

private final class WebRTCPeerSession: NSObject, @unchecked Sendable {
  private let stateLock = NSLock()
  private let peerConnection: RTCPeerConnection
  private let audioTrack: RTCAudioTrack
  private var storedConnectionState = "new"
  private var storedICEConnectionState = "new"
  private(set) var localCandidateCount = 0
  private(set) var localCandidates: [String] = []
  private(set) var remoteCandidateCount = 0
  private(set) var remoteCandidates: [String] = []

  var connectionState: String {
    stateLock.lock()
    defer { stateLock.unlock() }
    return storedConnectionState
  }

  var iceConnectionState: String {
    stateLock.lock()
    defer { stateLock.unlock() }
    return storedICEConnectionState
  }

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
    let resolvedOfferSDP = SDPMDNSCandidateResolver.resolve(offerSDP)
    remoteCandidateCount = resolvedOfferSDP.components(separatedBy: "a=candidate:").count - 1
    remoteCandidates = resolvedOfferSDP.components(separatedBy: "\r\n").filter {
      $0.hasPrefix("a=candidate:")
    }
    try await setRemoteDescription(
      RTCSessionDescription(type: .offer, sdp: resolvedOfferSDP)
    )
    let answer = try await createAnswer()
    try await setLocalDescription(answer)
    await waitForICEGathering()
    guard let localDescription = peerConnection.localDescription else {
      throw PhoneBridgeError.unsupportedPlatform("WebRTC did not produce a local description.")
    }
    localCandidateCount =
      localDescription.sdp.components(separatedBy: "a=candidate:").count - 1
    localCandidates = localDescription.sdp.components(separatedBy: "\r\n").filter {
      $0.hasPrefix("a=candidate:")
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

private enum SDPMDNSCandidateResolver {
  static func resolve(_ sdp: String) -> String {
    sdp.components(separatedBy: "\r\n").map(resolveCandidate).joined(separator: "\r\n")
  }

  private static func resolveCandidate(_ line: String) -> String {
    guard line.hasPrefix("a=candidate:") else { return line }
    var fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard fields.count > 5 else { return line }
    let hostname = fields[4]
    guard hostname.lowercased().hasSuffix(".local") else { return line }
    let uuidText = String(hostname.dropLast(".local".count))
    guard UUID(uuidString: uuidText) != nil, let address = resolveIPv4(hostname) else {
      return line
    }
    fields[4] = address
    return fields.joined(separator: " ")
  }

  private static func resolveIPv4(_ hostname: String) -> String? {
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG,
      ai_family: AF_INET,
      ai_socktype: SOCK_DGRAM,
      ai_protocol: IPPROTO_UDP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(hostname, nil, &hints, &result) == 0, let result else {
      return nil
    }
    defer { freeaddrinfo(result) }
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let info = current {
      defer { current = info.pointee.ai_next }
      guard info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr else {
        continue
      }
      var socketAddress = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_addr
      }
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      if inet_ntop(AF_INET, &socketAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
        return String(
          decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
          as: UTF8.self
        )
      }
    }
    return nil
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
  ) {
    stateLock.lock()
    storedICEConnectionState = String(describing: newState)
    stateLock.unlock()
  }

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

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    stateLock.lock()
    storedConnectionState = String(describing: newState)
    stateLock.unlock()
  }
}

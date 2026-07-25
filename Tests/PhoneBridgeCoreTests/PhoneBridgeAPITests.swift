import Foundation
import Testing

@testable import PhoneBridgeCore

private actor StubContacts: ContactDirectory {
  func requestAccess() async throws {}

  func search(_ query: String, limit: Int) async throws -> [ContactSummary] {
    [
      ContactSummary(
        id: "rick",
        displayName: "Rick Astley",
        endpoints: [
          ContactEndpoint(
            kind: .phone,
            label: "mobile",
            value: "+15551234567",
            services: [.cellular, .facetimeAudio]
          )
        ]
      )
    ]
  }
}

private actor StubLauncher: CallLaunching {
  func launch(_ request: CallLaunchRequest, dryRun: Bool) async throws -> CallLaunchReceipt {
    let prepared = try CallURLBuilder.prepare(request)
    return CallLaunchReceipt(
      accepted: true,
      service: request.service,
      normalizedTarget: prepared.normalizedTarget,
      url: prepared.url.absoluteString,
      dryRun: dryRun
    )
  }
}

private actor StubWebRTC: WebRTCSignaling {
  func createAnswer(for offer: WebRTCOffer) async throws -> WebRTCAnswer {
    WebRTCAnswer(sessionID: "test-session", sdp: "v=0\r\n")
  }

  func close(sessionID: String) async {}

  func status() async -> WebRTCMediaStatus {
    WebRTCMediaStatus(
      callAudioBundleIdentifier: "com.apple.FaceTime",
      callAudioTapActive: true,
      callAudioTapStarting: false,
      callAudioTapError: nil,
      callAudioFrameCount: 480,
      callAudioPeak: 0.25,
      virtualMicrophoneDevice: "BlackHole 2ch",
      virtualMicrophoneError: nil,
      nativeConnectionState: "connected",
      nativeICEConnectionState: "connected",
      localCandidateCount: 1,
      localCandidates: ["a=candidate:test"],
      remoteCandidateCount: 1,
      remoteCandidates: ["a=candidate:test"],
      browserAudioFrameCount: 480,
      browserAudioPeak: 0.5
    )
  }
}

private actor StubCallController: CallControlling {
  func snapshot() async throws -> CallControlSnapshot {
    CallControlSnapshot(
      available: true,
      calls: [
        ActiveCallSummary(
          id: "test-call",
          displayName: "Rick Astley",
          destination: nil,
          status: 4,
          incoming: true,
          outgoing: false,
          video: false,
          canAnswer: true,
          onHold: false,
          muted: false,
          supportsDTMF: true
        )
      ]
    )
  }

  func perform(_ request: CallControlRequest) async throws -> CallControlReceipt {
    CallControlReceipt(
      accepted: true,
      action: request.action,
      callID: request.callID ?? "test-call"
    )
  }
}

@Suite("PhoneBridge HTTP API")
struct PhoneBridgeAPITests {
  let api = PhoneBridgeAPI(
    token: "correct-token",
    version: "test",
    contacts: StubContacts(),
    launcher: StubLauncher(),
    callController: StubCallController(),
    webRTC: StubWebRTC()
  )

  @Test("Server configuration distinguishes TLS listeners")
  func serverTLSConfiguration() {
    #expect(HTTPServerConfiguration().usesTLS == false)
    #expect(HTTPServerConfiguration(tlsPKCS12: Data([1])).usesTLS == true)
  }

  @Test("DTMF accepts keypad characters and rejects strings")
  func dtmfValidation() throws {
    #expect(try DTMFKey("#").rawValue == Character("#").asciiValue)
    #expect(try DTMFKey("a").rawValue == Character("A").asciiValue)
    #expect(throws: PhoneBridgeError.self) {
      try DTMFKey("12")
    }
    #expect(throws: PhoneBridgeError.self) {
      try DTMFKey("X")
    }
  }

  @Test("Health is public")
  func health() async throws {
    let response = await api.handle(
      HTTPRequest(method: "GET", target: "/api/health", headers: [:], body: Data())
    )
    #expect(response.status == 200)
  }

  @Test("Protected endpoints reject missing tokens")
  func unauthorized() async throws {
    let response = await api.handle(
      HTTPRequest(method: "GET", target: "/api/contacts?q=Rick", headers: [:], body: Data())
    )
    #expect(response.status == 401)
  }

  @Test("Contact search returns minimal contact data")
  func contacts() async throws {
    let response = await api.handle(
      HTTPRequest(
        method: "GET",
        target: "/api/contacts?q=Rick",
        headers: ["authorization": "Bearer correct-token"],
        body: Data()
      )
    )
    #expect(response.status == 200)
    let decoded = try JSONDecoder().decode([ContactSummary].self, from: response.body)
    #expect(decoded.first?.displayName == "Rick Astley")
  }

  @Test("Call requests are decoded and accepted")
  func calls() async throws {
    let body = try JSONEncoder().encode(
      CallLaunchRequest(service: .facetimeAudio, target: "person@example.com"))
    let response = await api.handle(
      HTTPRequest(
        method: "POST",
        target: "/api/calls",
        headers: ["authorization": "Bearer correct-token"],
        body: body
      )
    )
    #expect(response.status == 202)
    let receipt = try JSONDecoder().decode(CallLaunchReceipt.self, from: response.body)
    #expect(receipt.url == "facetime-audio:person@example.com")
  }

  @Test("Incoming calls can be listed and answered")
  func incomingCallControl() async throws {
    let statusResponse = await api.handle(
      HTTPRequest(
        method: "GET",
        target: "/api/calls",
        headers: ["authorization": "Bearer correct-token"],
        body: Data()
      )
    )
    #expect(statusResponse.status == 200)
    let snapshot = try JSONDecoder().decode(CallControlSnapshot.self, from: statusResponse.body)
    #expect(snapshot.calls.first?.canAnswer == true)

    let request = CallControlRequest(action: .answer, callID: "test-call")
    let controlResponse = await api.handle(
      HTTPRequest(
        method: "POST",
        target: "/api/calls/control",
        headers: ["authorization": "Bearer correct-token"],
        body: try JSONEncoder().encode(request)
      )
    )
    #expect(controlResponse.status == 202)
    let receipt = try JSONDecoder().decode(CallControlReceipt.self, from: controlResponse.body)
    #expect(receipt.action == .answer)
  }

  @Test("Private bridge probe is authenticated and structured")
  func bridgeProbe() async throws {
    let response = await api.handle(
      HTTPRequest(
        method: "GET",
        target: "/api/bridge/probe",
        headers: ["authorization": "Bearer correct-token"],
        body: Data()
      )
    )
    #expect(response.status == 200)
    let decoded = try JSONDecoder().decode(PrivateCallBridgeCapabilities.self, from: response.body)
    #expect(decoded.classes.contains { $0.name == "TUCallCenter" })
  }

  @Test("WebRTC offers create authenticated sessions")
  func webRTCOffer() async throws {
    let body = try JSONEncoder().encode(WebRTCOffer(type: "offer", sdp: "v=0\r\n"))
    let response = await api.handle(
      HTTPRequest(
        method: "POST",
        target: "/api/webrtc/sessions",
        headers: ["authorization": "Bearer correct-token"],
        body: body
      )
    )
    #expect(response.status == 201)
    let answer = try JSONDecoder().decode(WebRTCAnswer.self, from: response.body)
    #expect(answer.sessionID == "test-session")
    #expect(answer.type == "answer")
  }
}

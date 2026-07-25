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

@Suite("PhoneBridge HTTP API")
struct PhoneBridgeAPITests {
  let api = PhoneBridgeAPI(
    token: "correct-token",
    version: "test",
    contacts: StubContacts(),
    launcher: StubLauncher()
  )

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
}

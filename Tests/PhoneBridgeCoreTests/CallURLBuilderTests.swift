import Foundation
import Testing

@testable import PhoneBridgeCore

@Suite("Call URL builder")
struct CallURLBuilderTests {
  @Test("Normalizes formatted cellular numbers")
  func cellularNumber() throws {
    let prepared = try CallURLBuilder.prepare(
      CallLaunchRequest(service: .cellular, target: "+1 (415) 555-1212")
    )
    #expect(prepared.normalizedTarget == "+14155551212")
    #expect(prepared.url.scheme == "tel")
    #expect(prepared.url.absoluteString == "tel:+14155551212")
  }

  @Test("Builds FaceTime Audio email URLs")
  func facetimeEmail() throws {
    let prepared = try CallURLBuilder.prepare(
      CallLaunchRequest(service: .facetimeAudio, target: "Person@Example.com")
    )
    #expect(prepared.normalizedTarget == "person@example.com")
    #expect(prepared.url.absoluteString == "facetime-audio:person@example.com")
  }

  @Test("Builds FaceTime Audio phone URLs")
  func facetimePhone() throws {
    let prepared = try CallURLBuilder.prepare(
      CallLaunchRequest(service: .facetimeAudio, target: "+44 20 7946 0958")
    )
    #expect(prepared.normalizedTarget == "+442079460958")
    #expect(prepared.url.absoluteString == "facetime-audio:+442079460958")
  }

  @Test("Rejects email addresses for cellular calls")
  func rejectsCellularEmail() {
    #expect(throws: PhoneBridgeError.self) {
      try CallURLBuilder.prepare(
        CallLaunchRequest(service: .cellular, target: "person@example.com")
      )
    }
  }

  @Test("Rejects URL and control-character injection")
  func rejectsInjection() {
    for target in ["//example.com", "+1415555\n1212", "tel:+14155551212"] {
      #expect(throws: PhoneBridgeError.self) {
        try CallURLBuilder.prepare(
          CallLaunchRequest(service: .cellular, target: target)
        )
      }
    }
  }
}

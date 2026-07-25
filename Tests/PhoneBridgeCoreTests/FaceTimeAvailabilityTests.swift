import Testing

@testable import PhoneBridgeCore

@Suite("FaceTime availability policy")
struct FaceTimeAvailabilityTests {
  @Test("Registered phone numbers prefer FaceTime Audio")
  func registeredPhone() {
    #expect(
      ContactEndpointServicePolicy.services(
        for: .phone,
        availability: .available
      ) == [.facetimeAudio, .cellular]
    )
  }

  @Test("Unregistered phone numbers fall back to cellular")
  func unregisteredPhone() {
    #expect(
      ContactEndpointServicePolicy.services(
        for: .phone,
        availability: .unavailable
      ) == [.cellular]
    )
  }

  @Test("Unknown phone availability preserves both choices")
  func unknownPhone() {
    #expect(
      ContactEndpointServicePolicy.services(
        for: .phone,
        availability: .unknown
      ) == [.facetimeAudio, .cellular]
    )
  }

  @Test("Unregistered email endpoints are omitted")
  func unregisteredEmail() {
    #expect(
      ContactEndpointServicePolicy.services(
        for: .email,
        availability: .unavailable
      ).isEmpty
    )
  }
}

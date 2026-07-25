import Foundation
@preconcurrency import PhoneBridgeWebRTCShim

enum FaceTimeAvailability: Sendable {
  case available
  case unavailable
  case unknown
}

protocol FaceTimeAvailabilityChecking: Sendable {
  func availability(
    for kind: ContactEndpointKind,
    value: String
  ) async -> FaceTimeAvailability
}

struct IDSFaceTimeAvailabilityChecker: FaceTimeAvailabilityChecking {
  func availability(
    for kind: ContactEndpointKind,
    value: String
  ) async -> FaceTimeAvailability {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .unknown }
    let destination: String
    switch kind {
    case .phone:
      let normalized = trimmed.filter { $0.isNumber || $0 == "+" }
      guard !normalized.isEmpty else { return .unknown }
      destination = "tel:\(normalized)"
    case .email:
      destination = "mailto:\(trimmed.lowercased())"
    }

    return await withCheckedContinuation { continuation in
      PBResolveFaceTimeAudioAvailability(destination, 2.0) { status in
        let availability: FaceTimeAvailability
        switch status {
        case 1:
          availability = .available
        case 2:
          availability = .unavailable
        default:
          availability = .unknown
        }
        continuation.resume(returning: availability)
      }
    }
  }
}

enum ContactEndpointServicePolicy {
  static func services(
    for kind: ContactEndpointKind,
    availability: FaceTimeAvailability
  ) -> [CallService] {
    switch (kind, availability) {
    case (.phone, .available), (.phone, .unknown):
      return [.facetimeAudio, .cellular]
    case (.phone, .unavailable):
      return [.cellular]
    case (.email, .available), (.email, .unknown):
      return [.facetimeAudio]
    case (.email, .unavailable):
      return []
    }
  }
}

import Foundation

public enum CallService: String, Codable, CaseIterable, Sendable {
  case cellular
  case facetimeAudio = "facetime_audio"

  public init(cliValue: String) throws {
    switch cliValue.lowercased() {
    case "cellular", "phone", "tel":
      self = .cellular
    case "facetime-audio", "facetime_audio", "facetime", "ft":
      self = .facetimeAudio
    default:
      throw PhoneBridgeError.invalidService(cliValue)
    }
  }

  public var cliValue: String {
    switch self {
    case .cellular: "cellular"
    case .facetimeAudio: "facetime-audio"
    }
  }
}

public enum ContactEndpointKind: String, Codable, Sendable {
  case phone
  case email
}

public struct ContactEndpoint: Codable, Equatable, Sendable {
  public let kind: ContactEndpointKind
  public let label: String
  public let value: String
  public let services: [CallService]

  public init(
    kind: ContactEndpointKind,
    label: String,
    value: String,
    services: [CallService]
  ) {
    self.kind = kind
    self.label = label
    self.value = value
    self.services = services
  }
}

public struct ContactSummary: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let endpoints: [ContactEndpoint]

  public init(id: String, displayName: String, endpoints: [ContactEndpoint]) {
    self.id = id
    self.displayName = displayName
    self.endpoints = endpoints
  }
}

public struct CallLaunchRequest: Codable, Equatable, Sendable {
  public let service: CallService
  public let target: String

  public init(service: CallService, target: String) {
    self.service = service
    self.target = target
  }
}

public struct CallLaunchReceipt: Codable, Equatable, Sendable {
  public let accepted: Bool
  public let service: CallService
  public let normalizedTarget: String
  public let url: String
  public let dryRun: Bool

  public init(
    accepted: Bool,
    service: CallService,
    normalizedTarget: String,
    url: String,
    dryRun: Bool
  ) {
    self.accepted = accepted
    self.service = service
    self.normalizedTarget = normalizedTarget
    self.url = url
    self.dryRun = dryRun
  }
}

public enum PhoneBridgeError: Error, LocalizedError, Equatable, Sendable {
  case invalidService(String)
  case invalidTarget(String)
  case contactsDenied
  case contactsRestricted
  case callLaunchFailed(String)
  case invalidArguments(String)
  case unsupportedPlatform(String)

  public var errorDescription: String? {
    switch self {
    case .invalidService(let value):
      "Unsupported call service: \(value)"
    case .invalidTarget(let reason):
      "Invalid call target: \(reason)"
    case .contactsDenied:
      "Contacts access was denied. Enable it in System Settings → Privacy & Security → Contacts."
    case .contactsRestricted:
      "Contacts access is restricted on this Mac."
    case .callLaunchFailed(let reason):
      "The call could not be handed to macOS: \(reason)"
    case .invalidArguments(let reason):
      reason
    case .unsupportedPlatform(let reason):
      reason
    }
  }
}

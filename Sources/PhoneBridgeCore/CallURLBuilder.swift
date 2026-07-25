import Foundation

public struct PreparedCallURL: Equatable, Sendable {
  public let url: URL
  public let normalizedTarget: String

  public init(url: URL, normalizedTarget: String) {
    self.url = url
    self.normalizedTarget = normalizedTarget
  }
}

public enum CallURLBuilder {
  public static func prepare(_ request: CallLaunchRequest) throws -> PreparedCallURL {
    let target = request.target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      throw PhoneBridgeError.invalidTarget("target is empty")
    }
    guard !target.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw PhoneBridgeError.invalidTarget("control characters are not allowed")
    }

    switch request.service {
    case .cellular:
      return try cellular(target)
    case .facetimeAudio:
      return try facetimeAudio(target)
    }
  }

  private static func cellular(_ raw: String) throws -> PreparedCallURL {
    guard !raw.contains("@") else {
      throw PhoneBridgeError.invalidTarget("cellular calls require a phone number")
    }

    let allowedPunctuation = CharacterSet(charactersIn: "+0123456789 ()-.")
    guard raw.rangeOfCharacter(from: allowedPunctuation.inverted) == nil else {
      throw PhoneBridgeError.invalidTarget("phone number contains unsupported characters")
    }

    let digits = raw.filter(\.isNumber)
    guard digits.count >= 3, digits.count <= 15 else {
      throw PhoneBridgeError.invalidTarget("phone number must contain 3–15 digits")
    }
    let normalized = raw.hasPrefix("+") ? "+\(digits)" : digits
    return try makeURL(scheme: "tel", target: normalized)
  }

  private static func facetimeAudio(_ raw: String) throws -> PreparedCallURL {
    if raw.contains("@") {
      guard isPlausibleEmail(raw) else {
        throw PhoneBridgeError.invalidTarget("invalid FaceTime email address")
      }
      return try makeURL(scheme: "facetime-audio", target: raw.lowercased())
    }

    let allowedPunctuation = CharacterSet(charactersIn: "+0123456789 ()-.")
    guard raw.rangeOfCharacter(from: allowedPunctuation.inverted) == nil else {
      throw PhoneBridgeError.invalidTarget("FaceTime target contains unsupported characters")
    }
    let digits = raw.filter(\.isNumber)
    guard digits.count >= 3, digits.count <= 15 else {
      throw PhoneBridgeError.invalidTarget("FaceTime phone number must contain 3–15 digits")
    }
    let normalized = raw.hasPrefix("+") ? "+\(digits)" : digits
    return try makeURL(scheme: "facetime-audio", target: normalized)
  }

  private static func isPlausibleEmail(_ value: String) -> Bool {
    guard value.count <= 254, !value.contains(" ") else { return false }
    let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
    guard pieces.count == 2, !pieces[0].isEmpty, pieces[1].contains(".") else { return false }
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~-@"))
    return value.rangeOfCharacter(from: allowed.inverted) == nil
  }

  private static func makeURL(scheme: String, target: String) throws -> PreparedCallURL {
    var components = URLComponents()
    components.scheme = scheme
    components.path = target
    guard let url = components.url else {
      throw PhoneBridgeError.invalidTarget("could not encode target")
    }
    return PreparedCallURL(url: url, normalizedTarget: target)
  }
}

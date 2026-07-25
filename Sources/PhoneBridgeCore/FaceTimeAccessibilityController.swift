import AppKit
import ApplicationServices
import Foundation

public enum CallControlAccessibilityAuthorization {
  public static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  @discardableResult
  public static func request() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  public static func openSettings() {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }
}

@MainActor
final class FaceTimeAccessibilityRuntime {
  private struct ElementInfo {
    let element: AXUIElement
    let role: String
    let label: String
    let enabled: Bool
  }

  private let callApplicationBundleIdentifiers = [
    "com.apple.FaceTime",
    "com.apple.mobilephone",
  ]

  func snapshot() -> ActiveCallSummary? {
    guard CallControlAccessibilityAuthorization.isTrusted else { return nil }
    let elements = callElements()
    guard !elements.isEmpty else { return nil }

    let answer = findButton(in: elements, matching: ["answer", "accept"])
    let decline = findButton(in: elements, matching: ["decline", "reject"])
    let hangUp = findButton(
      in: elements,
      matching: ["end call", "hang up", "disconnect"]
    )
    guard answer != nil || decline != nil || hangUp != nil else { return nil }

    let incoming = answer != nil
    let displayName = callerName(in: elements) ?? "Call on this Mac"
    let hasHold = findButton(in: elements, matching: ["hold", "resume", "unhold"]) != nil
    let hasMute = findButton(in: elements, matching: ["mute", "unmute"]) != nil
    let muted = findButton(in: elements, matching: ["unmute"]) != nil
    let onHold = findButton(in: elements, matching: ["resume", "unhold"]) != nil
    let supportsDTMF = findButton(in: elements, matching: ["keypad", "dial pad"]) != nil

    return ActiveCallSummary(
      id: "facetime-accessibility",
      displayName: displayName,
      destination: nil,
      status: incoming ? 0 : 1,
      incoming: incoming,
      outgoing: !incoming,
      video: false,
      canAnswer: answer != nil,
      canHangUp: hangUp != nil || decline != nil,
      canHold: hasHold,
      canMute: hasMute,
      onHold: onHold,
      muted: muted,
      supportsDTMF: supportsDTMF
    )
  }

  func perform(_ request: CallControlRequest) throws -> CallControlReceipt {
    guard CallControlAccessibilityAuthorization.isTrusted else {
      throw PhoneBridgeError.invalidArguments(
        "Call control needs Accessibility access in System Settings."
      )
    }

    var elements = callElements()
    let button: ElementInfo?
    switch request.action {
    case .answer:
      button = findButton(in: elements, matching: ["answer", "accept"])
    case .hangUp:
      button = findButton(
        in: elements,
        matching: ["end call", "hang up", "disconnect", "decline", "reject"]
      )
    case .hold:
      button = findButton(in: elements, matching: ["hold"])
    case .resume:
      button = findButton(in: elements, matching: ["resume", "unhold"])
    case .mute:
      button = findButton(in: elements, matching: ["mute"])
    case .unmute:
      button = findButton(in: elements, matching: ["unmute"])
    case .sendDTMF:
      guard let keypad = findButton(in: elements, matching: ["keypad", "dial pad"]) else {
        throw PhoneBridgeError.invalidArguments("This call does not expose a keypad.")
      }
      try press(keypad)
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      elements = callElements()
      let key = try DTMFKey(request.dtmf ?? "")
      let value = String(UnicodeScalar(key.rawValue))
      guard let digit = findButton(in: elements, exact: value) else {
        throw PhoneBridgeError.invalidArguments("The requested keypad key is unavailable.")
      }
      try press(digit)
      return receipt(for: request)
    }

    guard let button else {
      throw PhoneBridgeError.invalidArguments(
        "The requested call control is not available in the current FaceTime or Phone UI."
      )
    }
    try press(button)
    return receipt(for: request)
  }

  private func receipt(for request: CallControlRequest) -> CallControlReceipt {
    CallControlReceipt(
      accepted: true,
      action: request.action,
      callID: request.callID ?? "facetime-accessibility"
    )
  }

  private func press(_ info: ElementInfo) throws {
    guard info.enabled else {
      throw PhoneBridgeError.invalidArguments("The requested call control is disabled.")
    }
    let result = AXUIElementPerformAction(info.element, kAXPressAction as CFString)
    guard result == .success else {
      throw PhoneBridgeError.callLaunchFailed(
        "Accessibility could not press the FaceTime or Phone control (\(result.rawValue))."
      )
    }
  }

  private func callElements() -> [ElementInfo] {
    let applications = NSWorkspace.shared.runningApplications.filter { application in
      guard let bundleIdentifier = application.bundleIdentifier else { return false }
      return callApplicationBundleIdentifiers.contains(bundleIdentifier)
        || bundleIdentifier.localizedCaseInsensitiveContains("FaceTimeNotification")
        || bundleIdentifier.localizedCaseInsensitiveContains("mobilephone")
    }

    var result: [ElementInfo] = []
    var remaining = 1_000
    for application in applications where remaining > 0 {
      collect(
        AXUIElementCreateApplication(application.processIdentifier),
        depth: 0,
        remaining: &remaining,
        into: &result
      )
    }
    return result
  }

  private func collect(
    _ element: AXUIElement,
    depth: Int,
    remaining: inout Int,
    into result: inout [ElementInfo]
  ) {
    guard depth <= 10, remaining > 0 else { return }
    remaining -= 1

    let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
    let label = [
      stringAttribute(element, kAXTitleAttribute as CFString),
      stringAttribute(element, kAXDescriptionAttribute as CFString),
      stringAttribute(element, kAXHelpAttribute as CFString),
      stringAttribute(element, kAXValueAttribute as CFString),
    ]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    .joined(separator: " · ")
    let enabled = boolAttribute(element, kAXEnabledAttribute as CFString) ?? true
    if !role.isEmpty || !label.isEmpty {
      result.append(ElementInfo(element: element, role: role, label: label, enabled: enabled))
    }

    for child in elementArrayAttribute(element, kAXChildrenAttribute as CFString) {
      collect(child, depth: depth + 1, remaining: &remaining, into: &result)
    }
  }

  private func findButton(
    in elements: [ElementInfo],
    matching candidates: [String]
  ) -> ElementInfo? {
    elements.first { info in
      guard info.role == (kAXButtonRole as String) else { return false }
      let label = normalize(info.label)
      return candidates.contains { candidate in
        label == candidate || label.contains(candidate)
      }
    }
  }

  private func findButton(in elements: [ElementInfo], exact value: String) -> ElementInfo? {
    elements.first { info in
      info.role == (kAXButtonRole as String) && normalize(info.label) == normalize(value)
    }
  }

  private func callerName(in elements: [ElementInfo]) -> String? {
    let ignored = [
      "facetime", "phone", "audio", "video", "mute", "unmute", "hold", "resume",
      "keypad", "end call", "hang up", "answer", "accept", "decline", "reject",
    ]
    return elements
      .filter { info in
        [kAXStaticTextRole as String, kAXHeadingRole as String].contains(info.role)
      }
      .map(\.label)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { value in
        let normalized = normalize(value)
        return value.count >= 2 && value.count <= 100
          && !ignored.contains(where: { normalized == $0 || normalized.contains($0) })
          && normalized.range(of: #"^\d+:\d+$"#, options: .regularExpression) == nil
      }
  }

  private func normalize(_ value: String) -> String {
    value
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? String
  }

  private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? Bool
  }

  private func elementArrayAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
  ) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
      let values = value as? [AXUIElement]
    else { return [] }
    return values
  }
}

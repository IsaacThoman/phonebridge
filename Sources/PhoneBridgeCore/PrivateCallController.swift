import Darwin
import Foundation
import ObjectiveC

public enum CallControlAction: String, Codable, Sendable {
  case answer
  case hangUp = "hang_up"
  case hold
  case resume
  case mute
  case unmute
  case sendDTMF = "send_dtmf"
}

public struct CallControlRequest: Codable, Sendable, Equatable {
  public let action: CallControlAction
  public let callID: String?
  public let dtmf: String?

  public init(action: CallControlAction, callID: String? = nil, dtmf: String? = nil) {
    self.action = action
    self.callID = callID
    self.dtmf = dtmf
  }
}

public struct ActiveCallSummary: Codable, Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let destination: String?
  public let status: Int
  public let incoming: Bool
  public let outgoing: Bool
  public let video: Bool
  public let canAnswer: Bool
  public let onHold: Bool
  public let muted: Bool
  public let supportsDTMF: Bool

  public init(
    id: String,
    displayName: String,
    destination: String?,
    status: Int,
    incoming: Bool,
    outgoing: Bool,
    video: Bool,
    canAnswer: Bool,
    onHold: Bool,
    muted: Bool,
    supportsDTMF: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.destination = destination
    self.status = status
    self.incoming = incoming
    self.outgoing = outgoing
    self.video = video
    self.canAnswer = canAnswer
    self.onHold = onHold
    self.muted = muted
    self.supportsDTMF = supportsDTMF
  }
}

public struct CallControlSnapshot: Codable, Sendable, Equatable {
  public let available: Bool
  public let calls: [ActiveCallSummary]

  public init(available: Bool, calls: [ActiveCallSummary]) {
    self.available = available
    self.calls = calls
  }
}

public struct CallControlReceipt: Codable, Sendable, Equatable {
  public let accepted: Bool
  public let action: CallControlAction
  public let callID: String

  public init(accepted: Bool, action: CallControlAction, callID: String) {
    self.accepted = accepted
    self.action = action
    self.callID = callID
  }
}

public protocol CallControlling: Sendable {
  func snapshot() async throws -> CallControlSnapshot
  func perform(_ request: CallControlRequest) async throws -> CallControlReceipt
}

struct DTMFKey: Equatable, Sendable {
  let rawValue: UInt8

  init(_ value: String) throws {
    guard value.utf8.count == 1,
      let character = value.uppercased().utf8.first,
      "0123456789*#ABCD".utf8.contains(character)
    else {
      throw PhoneBridgeError.invalidArguments(
        "DTMF must be one of 0-9, *, #, or A-D.")
    }
    rawValue = character
  }
}

/// Capability-gated access to the same TelephonyUtilities call model used by FaceTime
/// on Sequoia and Phone on Tahoe. This is intentionally isolated so an Apple ABI change
/// fails closed instead of crashing the HTTP server.
@MainActor
public final class PrivateCallController: CallControlling {
  private let runtime = TelephonyUtilitiesRuntime()

  public nonisolated init() {}

  public func snapshot() throws -> CallControlSnapshot {
    guard let callCenter = runtime.sharedCallCenter() else {
      return CallControlSnapshot(available: false, calls: [])
    }
    return CallControlSnapshot(
      available: true,
      calls: runtime.calls(callCenter).map(runtime.summary)
    )
  }

  public func perform(_ request: CallControlRequest) throws -> CallControlReceipt {
    guard let callCenter = runtime.sharedCallCenter() else {
      throw PhoneBridgeError.unsupportedPlatform(
        "TelephonyUtilities call control is unavailable on this version of macOS.")
    }

    let allCalls = runtime.calls(callCenter)
    let candidates =
      request.action == .answer
      ? runtime.objectArray(callCenter, selector: "incomingCalls") : allCalls
    var selectedCall: AnyObject?
    if let requestedID = request.callID {
      for candidate in candidates where runtime.callID(candidate) == requestedID {
        selectedCall = candidate
        break
      }
    } else {
      selectedCall = candidates.first
    }

    guard let call = selectedCall else {
      let description = request.action == .answer ? "incoming" : "active"
      throw PhoneBridgeError.invalidArguments("There is no \(description) call to control.")
    }

    switch request.action {
    case .answer:
      try runtime.invokeObject(callCenter, selector: "answerCall:", argument: call)
    case .hangUp:
      try runtime.invokeObject(callCenter, selector: "disconnectCall:", argument: call)
    case .hold:
      try runtime.invokeVoid(call, selector: "hold")
    case .resume:
      try runtime.invokeVoid(call, selector: "unhold")
    case .mute:
      try runtime.invokeBool(call, selector: "setUplinkMuted:", argument: true)
    case .unmute:
      try runtime.invokeBool(call, selector: "setUplinkMuted:", argument: false)
    case .sendDTMF:
      let key = try DTMFKey(request.dtmf ?? "")
      try runtime.invokeUInt8(call, selector: "playDTMFToneForKey:", argument: key.rawValue)
    }

    return CallControlReceipt(
      accepted: true,
      action: request.action,
      callID: runtime.callID(call)
    )
  }
}

private final class TelephonyUtilitiesRuntime: @unchecked Sendable {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities"
  private let callCenterClass: AnyClass?

  init() {
    _ = dlopen(Self.frameworkPath, RTLD_NOW | RTLD_LOCAL)
    callCenterClass = NSClassFromString("TUCallCenter")
  }

  func sharedCallCenter() -> AnyObject? {
    guard let callCenterClass,
      let metaClass = object_getClass(callCenterClass),
      let method = class_getInstanceMethod(metaClass, NSSelectorFromString("sharedInstance"))
    else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
    return function(
      callCenterClass as AnyObject,
      NSSelectorFromString("sharedInstance")
    )?.takeUnretainedValue()
  }

  func calls(_ callCenter: AnyObject) -> [AnyObject] {
    objectArray(callCenter, selector: "currentCalls")
  }

  func objectArray(_ object: AnyObject, selector name: String) -> [AnyObject] {
    guard let value = objectValue(object, selector: name) else { return [] }
    guard let array = value as? NSArray else { return [] }
    return array.compactMap { $0 as AnyObject }
  }

  func summary(_ call: AnyObject) -> ActiveCallSummary {
    let destination = stringValue(call, selector: "destinationID")
    let displayName =
      stringValue(call, selector: "displayName")
      ?? stringValue(call, selector: "suggestedDisplayName")
      ?? destination
      ?? "Unknown caller"
    return ActiveCallSummary(
      id: callID(call),
      displayName: displayName,
      destination: destination,
      status: intValue(call, selector: "status") ?? -1,
      incoming: boolValue(call, selector: "isIncoming") ?? false,
      outgoing: boolValue(call, selector: "isOutgoing") ?? false,
      video: boolValue(call, selector: "isVideo") ?? false,
      canAnswer: boolValue(call, selector: "canAnswerCall") ?? false,
      onHold: boolValue(call, selector: "isOnHold") ?? false,
      muted: boolValue(call, selector: "isUplinkMuted") ?? false,
      supportsDTMF: boolValue(call, selector: "supportsDTMFTones") ?? false
    )
  }

  func callID(_ call: AnyObject) -> String {
    if let uuid = objectValue(call, selector: "callUUID") as? UUID {
      return uuid.uuidString.lowercased()
    }
    if let value = stringValue(call, selector: "callUUID") {
      return value.lowercased()
    }
    return String(UInt(bitPattern: Unmanaged.passUnretained(call).toOpaque()), radix: 16)
  }

  func invokeObject(
    _ object: AnyObject,
    selector name: String,
    argument: AnyObject
  ) throws {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "v24@0:8@16")
    else {
      throw PhoneBridgeError.unsupportedPlatform(
        "Required call-control operation \(name) is unavailable.")
    }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
    function(object, selector, argument)
  }

  func invokeBool(
    _ object: AnyObject,
    selector name: String,
    argument: Bool
  ) throws {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "v20@0:8B16")
    else {
      throw PhoneBridgeError.unsupportedPlatform(
        "Required call-control operation \(name) is unavailable.")
    }
    typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
    let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
    function(object, selector, argument)
  }

  func invokeVoid(_ object: AnyObject, selector name: String) throws {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "v16@0:8")
    else {
      throw PhoneBridgeError.unsupportedPlatform(
        "Required call-control operation \(name) is unavailable.")
    }
    typealias Function = @convention(c) (AnyObject, Selector) -> Void
    let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
    function(object, selector)
  }

  func invokeUInt8(
    _ object: AnyObject,
    selector name: String,
    argument: UInt8
  ) throws {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "v20@0:8C16")
    else {
      throw PhoneBridgeError.unsupportedPlatform(
        "Required call-control operation \(name) is unavailable.")
    }
    typealias Function = @convention(c) (AnyObject, Selector, UInt8) -> Void
    let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
    function(object, selector, argument)
  }

  private func objectValue(_ object: AnyObject, selector name: String) -> AnyObject? {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "@16@0:8")
    else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
    return function(object, selector)?.takeUnretainedValue()
  }

  private func stringValue(_ object: AnyObject, selector name: String) -> String? {
    if let value = objectValue(object, selector: name) as? String, !value.isEmpty {
      return value
    }
    return nil
  }

  private func boolValue(_ object: AnyObject, selector name: String) -> Bool? {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "B16@0:8")
    else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector)
  }

  private func intValue(_ object: AnyObject, selector name: String) -> Int? {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector),
      hasEncodingPrefix(method, "i16@0:8")
    else { return nil }
    typealias Function = @convention(c) (AnyObject, Selector) -> Int32
    return Int(
      unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector))
  }

  private func hasEncodingPrefix(_ method: Method, _ prefix: String) -> Bool {
    guard let encoding = method_getTypeEncoding(method) else { return false }
    return String(cString: encoding).hasPrefix(prefix)
  }
}

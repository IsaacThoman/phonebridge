import Darwin
import Foundation
import ObjectiveC

public enum RuntimeSelectorKind: String, Codable, Sendable {
  case instance
  case `class`
}

public struct RuntimeSelectorProbe: Codable, Sendable, Equatable {
  public let name: String
  public let kind: RuntimeSelectorKind
  public let available: Bool
}

public struct RuntimeClassProbe: Codable, Sendable, Equatable {
  public let name: String
  public let available: Bool
  public let selectors: [RuntimeSelectorProbe]
}

public struct PrivateCallBridgeCapabilities: Codable, Sendable, Equatable {
  public let frameworkLoaded: Bool
  public let callHostBundleIdentifier: String
  public let runningInsideCallHost: Bool
  public let injectionRequired: Bool
  public let classes: [RuntimeClassProbe]
}

public struct PrivateCallBridgeProbe: Sendable {
  private static let frameworkPath =
    "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities"

  public init() {}

  public func inspect() -> PrivateCallBridgeCapabilities {
    let handle = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL)
    let hostBundleIdentifier = Bundle.main.bundleIdentifier ?? "unbundled"
    let callHosts = ["com.apple.FaceTime", "com.apple.mobilephone"]

    let specifications: [(String, [String], [String])] = [
      (
        "TUCallCenter",
        [
          "currentCalls", "incomingCalls", "outgoingCalls", "audioOrVideoCallWithStatus:",
          "performDialRequest:", "dialWithRequest:", "answerCall:", "disconnectCall:",
          "disconnectAllCalls",
        ],
        ["sharedInstance", "sharedCallCenter"]
      ),
      (
        "TUCall",
        [
          "status", "isConnected", "isOnHold", "isUplinkMuted", "isDownlinkMuted",
          "disconnect", "answer", "hold", "unhold", "playDTMFToneForKey:",
        ],
        []
      ),
      (
        "TUConversationManager",
        [
          "activeConversation", "conversations", "joinConversationWithRequest:",
          "leaveConversation:", "setUplinkMuted:forConversation:",
        ],
        ["sharedInstance"]
      ),
      (
        "TUJoinConversationRequest",
        [
          "initWithProvider:remoteMembers:", "setVideoEnabled:", "setAudioEnabled:",
          "setPresentationMode:",
        ],
        []
      ),
    ]

    let classProbes = specifications.map { name, instanceSelectors, classSelectors in
      inspectClass(name, instanceSelectors: instanceSelectors, classSelectors: classSelectors)
    }

    // TelephonyUtilities registers Objective-C classes globally after loading. Keep the
    // framework mapped for the lifetime of this process so the returned class metadata
    // remains valid for later capability-gated bridge work.
    _ = handle

    return PrivateCallBridgeCapabilities(
      frameworkLoaded: handle != nil,
      callHostBundleIdentifier: hostBundleIdentifier,
      runningInsideCallHost: callHosts.contains(hostBundleIdentifier),
      injectionRequired: !callHosts.contains(hostBundleIdentifier),
      classes: classProbes
    )
  }

  private func inspectClass(
    _ name: String,
    instanceSelectors: [String],
    classSelectors: [String]
  ) -> RuntimeClassProbe {
    guard let runtimeClass = NSClassFromString(name) else {
      return RuntimeClassProbe(
        name: name,
        available: false,
        selectors:
          instanceSelectors.map {
            RuntimeSelectorProbe(name: $0, kind: .instance, available: false)
          }
          + classSelectors.map {
            RuntimeSelectorProbe(name: $0, kind: .class, available: false)
          }
      )
    }

    let selectors =
      instanceSelectors.map { name in
        RuntimeSelectorProbe(
          name: name,
          kind: .instance,
          available: class_getInstanceMethod(runtimeClass, NSSelectorFromString(name)) != nil
        )
      }
      + classSelectors.map { name in
        RuntimeSelectorProbe(
          name: name,
          kind: .class,
          available: class_getClassMethod(runtimeClass, NSSelectorFromString(name)) != nil
        )
      }
    return RuntimeClassProbe(name: name, available: true, selectors: selectors)
  }
}

import Foundation

#if os(macOS)
  import AppKit
#endif

public protocol CallLaunching: Sendable {
  func launch(_ request: CallLaunchRequest, dryRun: Bool) async throws -> CallLaunchReceipt
}

public struct MacCallLauncher: CallLaunching {
  public init() {}

  @MainActor
  public func launch(
    _ request: CallLaunchRequest,
    dryRun: Bool = false
  ) async throws -> CallLaunchReceipt {
    let prepared = try CallURLBuilder.prepare(request)
    if dryRun {
      return receipt(prepared: prepared, request: request, accepted: true, dryRun: true)
    }

    #if os(macOS)
      let accepted = NSWorkspace.shared.open(prepared.url)
      guard accepted else {
        throw PhoneBridgeError.callLaunchFailed(
          "no application accepted the \(prepared.url.scheme ?? "call") URL")
      }
      return receipt(prepared: prepared, request: request, accepted: true, dryRun: false)
    #else
      throw PhoneBridgeError.unsupportedPlatform("Call launching requires macOS.")
    #endif
  }

  private func receipt(
    prepared: PreparedCallURL,
    request: CallLaunchRequest,
    accepted: Bool,
    dryRun: Bool
  ) -> CallLaunchReceipt {
    CallLaunchReceipt(
      accepted: accepted,
      service: request.service,
      normalizedTarget: prepared.normalizedTarget,
      url: prepared.url.absoluteString,
      dryRun: dryRun
    )
  }
}

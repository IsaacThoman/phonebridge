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
      guard !CallControlAccessibilityAuthorization.hasPendingCallHandoff else {
        throw PhoneBridgeError.callLaunchFailed(
          "another Click to Call confirmation is already pending on the Mac")
      }
      let accepted = NSWorkspace.shared.open(prepared.url)
      guard accepted else {
        throw PhoneBridgeError.callLaunchFailed(
          "no application accepted the \(prepared.url.scheme ?? "call") URL")
      }
      let handoffConfirmed =
        await CallControlAccessibilityAuthorization.confirmPendingCallHandoff()
      return receipt(
        prepared: prepared,
        request: request,
        accepted: true,
        dryRun: false,
        handoffConfirmed: handoffConfirmed
      )
    #else
      throw PhoneBridgeError.unsupportedPlatform("Call launching requires macOS.")
    #endif
  }

  private func receipt(
    prepared: PreparedCallURL,
    request: CallLaunchRequest,
    accepted: Bool,
    dryRun: Bool,
    handoffConfirmed: Bool? = nil
  ) -> CallLaunchReceipt {
    CallLaunchReceipt(
      accepted: accepted,
      service: request.service,
      normalizedTarget: prepared.normalizedTarget,
      url: prepared.url.absoluteString,
      dryRun: dryRun,
      handoffConfirmed: handoffConfirmed
    )
  }
}

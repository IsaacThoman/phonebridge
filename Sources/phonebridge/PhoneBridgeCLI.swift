import AudioToolbox
import Foundation
import PhoneBridgeCore

@main
struct PhoneBridgeCLI {
  static let version = "0.1.0-dev"

  static func main() async {
    do {
      try await run(Array(CommandLine.arguments.dropFirst()))
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      FileHandle.standardError.write(Data("error: \(message)\n".utf8))
      exit(1)
    }
  }

  static func run(_ arguments: [String]) async throws {
    guard let command = arguments.first else {
      printHelp()
      return
    }

    switch command {
    case "version", "--version", "-V":
      print(version)
    case "contacts":
      try await runContacts(Array(arguments.dropFirst()))
    case "call":
      try await runCall(Array(arguments.dropFirst()))
    case "server":
      try await runServer(Array(arguments.dropFirst()))
    case "bridge":
      try runBridge(Array(arguments.dropFirst()))
    case "audio":
      try await runAudio(Array(arguments.dropFirst()))
    case "help", "--help", "-h":
      printHelp()
    default:
      throw PhoneBridgeError.invalidArguments("Unknown command: \(command)")
    }
  }

  private static func runContacts(_ arguments: [String]) async throws {
    guard arguments.first == "search" else {
      throw PhoneBridgeError.invalidArguments(
        "Usage: phonebridge contacts search <query> [--limit N] [--json]")
    }
    let rest = Array(arguments.dropFirst())
    let query = positionalValue(in: rest) ?? ""
    let limit = intOption("--limit", in: rest) ?? 25
    let json = rest.contains("--json")
    let contacts = try await MacContactDirectory().search(query, limit: limit)
    if json {
      try printJSON(contacts)
      return
    }
    for contact in contacts {
      print(contact.displayName)
      for endpoint in contact.endpoints {
        let services = endpoint.services.map(\.cliValue).joined(separator: ", ")
        print("  \(endpoint.label): \(endpoint.value) [\(services)]")
      }
    }
  }

  private static func runCall(_ arguments: [String]) async throws {
    if arguments.first == "status" {
      let snapshot = try await PrivateCallController().snapshot()
      if arguments.contains("--json") {
        try printJSON(snapshot)
      } else if snapshot.calls.isEmpty {
        print("No active calls.")
      } else {
        for call in snapshot.calls {
          print("\(call.id) \(call.displayName) status=\(call.status)")
        }
      }
      return
    }
    if arguments.first == "control" {
      let rest = Array(arguments.dropFirst())
      guard let actionRaw = positionalValue(in: rest),
        let action = CallControlAction(rawValue: actionRaw)
      else {
        throw PhoneBridgeError.invalidArguments(
          "Usage: phonebridge call control <answer|hang_up|hold|resume|mute|unmute> [--id CALL_ID] [--json]"
        )
      }
      let receipt = try await PrivateCallController().perform(
        CallControlRequest(action: action, callID: option("--id", in: rest))
      )
      if rest.contains("--json") {
        try printJSON(receipt)
      } else {
        print("\(receipt.action.rawValue): \(receipt.callID)")
      }
      return
    }
    guard arguments.first == "start" else {
      throw PhoneBridgeError.invalidArguments(
        "Usage: phonebridge call <start|status|control> [options]"
      )
    }
    let rest = Array(arguments.dropFirst())
    guard let serviceRaw = option("--service", in: rest) else {
      throw PhoneBridgeError.invalidArguments("Missing --service")
    }
    guard let target = option("--to", in: rest) else {
      throw PhoneBridgeError.invalidArguments("Missing --to")
    }
    let request = CallLaunchRequest(service: try CallService(cliValue: serviceRaw), target: target)
    let receipt = try await MacCallLauncher().launch(request, dryRun: rest.contains("--dry-run"))
    if rest.contains("--json") {
      try printJSON(receipt)
    } else {
      let mode = receipt.dryRun ? "dry-run" : "opened"
      print("\(mode): \(receipt.service.cliValue) \(receipt.normalizedTarget)")
    }
  }

  private static func runServer(_ arguments: [String]) async throws {
    let host = option("--host", in: arguments) ?? "127.0.0.1"
    let isLoopback = ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    guard isLoopback || arguments.contains("--allow-insecure-lan") else {
      throw PhoneBridgeError.invalidArguments(
        "Refusing a non-loopback HTTP listener. Pass --allow-insecure-lan only on a trusted test network."
      )
    }
    let rawPort = intOption("--port", in: arguments) ?? 8742
    guard (1...65_535).contains(rawPort) else {
      throw PhoneBridgeError.invalidArguments("Port must be between 1 and 65535")
    }
    let token = try option("--token", in: arguments) ?? PhoneBridgeAPI.generateToken()
    let api = PhoneBridgeAPI(token: token, version: version)
    let server = HTTPServer(
      configuration: HTTPServerConfiguration(host: host, port: UInt16(rawPort))
    ) { request in
      await api.handle(request)
    }
    try await server.start()
    print("PhoneBridge listening at http://\(host):\(rawPort)")
    if !isLoopback {
      print("WARNING: HTTP exposes the bearer token to the local network. Development use only.")
    }
    print("Pairing token: \(token)")
    print("Keep this token private. Press Control-C to stop.")
    await server.waitUntilCancelled()
  }

  private static func runBridge(_ arguments: [String]) throws {
    guard arguments.first == "probe" else {
      throw PhoneBridgeError.invalidArguments("Usage: phonebridge bridge probe [--json]")
    }
    let result = PrivateCallBridgeProbe().inspect()
    if arguments.contains("--json") {
      try printJSON(result)
      return
    }
    print("TelephonyUtilities: \(result.frameworkLoaded ? "loaded" : "unavailable")")
    print("Call host: \(result.callHostBundleIdentifier)")
    print("Inside call host: \(result.runningInsideCallHost ? "yes" : "no")")
    for classProbe in result.classes {
      let available = classProbe.available ? "available" : "missing"
      print("\(classProbe.name): \(available)")
      for selector in classProbe.selectors where selector.available {
        print("  \(selector.kind.rawValue): \(selector.name)")
      }
    }
  }

  private static func runAudio(_ arguments: [String]) async throws {
    if arguments.first == "devices" {
      let devices = try VirtualMicrophoneOutput.devices()
      if arguments.contains("--json") {
        try printJSON(devices)
      } else {
        for device in devices {
          print("\(device.name) [\(device.uid)]")
        }
      }
      return
    }
    guard arguments.first == "tap" else {
      throw PhoneBridgeError.invalidArguments(
        "Usage: phonebridge audio <devices|tap> [options]")
    }
    let rest = Array(arguments.dropFirst())
    let host = option("--host", in: rest) ?? "facetime"
    let bundleIdentifier: String
    switch host {
    case "facetime":
      bundleIdentifier = "com.apple.FaceTime"
    case "phone":
      bundleIdentifier = "com.apple.mobilephone"
    default:
      throw PhoneBridgeError.invalidArguments("--host must be facetime or phone")
    }
    let seconds = max(1, min(intOption("--seconds", in: rest) ?? 5, 30))
    let meter = AudioTapMeter()
    let tap = CallAudioTap()
    let description = try tap.start(bundleIdentifier: bundleIdentifier) { frame in
      meter.consume(frame)
    }
    try await Task.sleep(for: .seconds(seconds))
    tap.stop()
    let report = meter.report(description: description, duration: seconds)
    if rest.contains("--json") {
      try printJSON(report)
    } else {
      print(
        "\(report.bundleIdentifier): \(report.callbackCount) callbacks, \(report.frameCount) frames, peak \(report.peak)"
      )
    }
  }

  private static func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func intOption(_ name: String, in arguments: [String]) -> Int? {
    option(name, in: arguments).flatMap(Int.init)
  }

  private static func positionalValue(in arguments: [String]) -> String? {
    var skipNext = false
    for (index, value) in arguments.enumerated() {
      if skipNext {
        skipNext = false
        continue
      }
      if value == "--limit" {
        skipNext = true
        continue
      }
      if value.hasPrefix("-") { continue }
      if index > 0, arguments[index - 1] == "--limit" { continue }
      return value
    }
    return nil
  }

  private static func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func printHelp() {
    print(
      """
      phonebridge \(version)

      Remote control and media bridge for cellular and FaceTime Audio calls on macOS.

      Commands:
        phonebridge contacts search <query> [--limit N] [--json]
        phonebridge call start --service <cellular|facetime-audio> --to <target> [--dry-run] [--json]
        phonebridge call status [--json]
        phonebridge call control <answer|hang_up|hold|resume|mute|unmute> [--id CALL_ID] [--json]
        phonebridge server [--host 127.0.0.1] [--port 8742] [--token TOKEN] [--allow-insecure-lan]
        phonebridge bridge probe [--json]
        phonebridge audio tap --host <facetime|phone> [--seconds N] [--json]
        phonebridge audio devices [--json]
        phonebridge version
      """
    )
  }
}

private struct AudioTapReport: Codable {
  let bundleIdentifier: String
  let durationSeconds: Int
  let sampleRate: Double
  let channelCount: UInt32
  let callbackCount: Int
  let frameCount: UInt64
  let peak: Double
}

private final class AudioTapMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var callbackCount = 0
  private var frameCount: UInt64 = 0
  private var peak = 0.0

  func consume(_ frame: CapturedAudioFrame) {
    let framePeak = frame.buffers.reduce(0.0) { current, data in
      max(current, Self.peak(in: data, formatFlags: frame.formatFlags))
    }
    lock.lock()
    callbackCount += 1
    frameCount += UInt64(frame.frameCount)
    peak = max(peak, framePeak)
    lock.unlock()
  }

  func report(description: CallAudioTapDescription, duration: Int) -> AudioTapReport {
    lock.lock()
    defer { lock.unlock() }
    return AudioTapReport(
      bundleIdentifier: description.bundleIdentifier,
      durationSeconds: duration,
      sampleRate: description.sampleRate,
      channelCount: description.channelCount,
      callbackCount: callbackCount,
      frameCount: frameCount,
      peak: peak
    )
  }

  private static func peak(in data: Data, formatFlags: AudioFormatFlags) -> Double {
    if formatFlags & kAudioFormatFlagIsFloat != 0 {
      return data.withUnsafeBytes { bytes in
        bytes.bindMemory(to: Float.self).reduce(0.0) {
          max($0, Double(abs($1)))
        }
      }
    }
    return data.withUnsafeBytes { bytes in
      bytes.bindMemory(to: Int16.self).reduce(0.0) {
        max($0, Double(abs(Int($1))) / Double(Int16.max))
      }
    }
  }
}

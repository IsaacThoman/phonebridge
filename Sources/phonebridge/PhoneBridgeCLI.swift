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
    guard arguments.first == "start" else {
      throw PhoneBridgeError.invalidArguments(
        "Usage: phonebridge call start --service <cellular|facetime-audio> --to <target> [--dry-run] [--json]"
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
        phonebridge version
      """
    )
  }
}

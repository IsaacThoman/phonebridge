import AppKit
import Foundation
import PhoneBridgeCore

@main
@MainActor
final class PhoneBridgeApplication: NSObject, NSApplicationDelegate {
  private static let version = "0.1.0-dev"

  private var window: NSWindow!
  private var statusLabel: NSTextField!
  private var addressLabel: NSTextField!
  private var tokenField: NSTextField!
  private var contactsButton: NSButton!
  private var callControlButton: NSButton!
  private var server: HTTPServer?
  private var serverTask: Task<Void, Never>?
  private var clientURL: URL?

  static func main() {
    let application = NSApplication.shared
    let delegate = PhoneBridgeApplication()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildWindow()
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    startServer()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    serverTask?.cancel()
    server?.stop()
  }

  private func startServer() {
    do {
      let configuration = try AppConfiguration(arguments: Array(CommandLine.arguments.dropFirst()))
      let token = try configuration.token ?? PhoneBridgeAPI.generateToken()
      let api = PhoneBridgeAPI(token: token, version: Self.version)
      let server = HTTPServer(
        configuration: HTTPServerConfiguration(
          host: configuration.host,
          port: configuration.port,
          tlsPKCS12: configuration.tlsPKCS12,
          tlsPassphrase: configuration.tlsPassphrase
        )
      ) { request in
        await api.handle(request)
      }
      self.server = server
      tokenField.stringValue = token

      let reportedHost =
        configuration.isLoopback ? "127.0.0.1" : ProcessInfo.processInfo.hostName
      let browserHost =
        reportedHost.split(whereSeparator: \.isWhitespace).first.map(String.init)
        ?? "127.0.0.1"
      let scheme = configuration.usesTLS ? "https" : "http"
      var urlComponents = URLComponents()
      urlComponents.scheme = scheme
      urlComponents.host = browserHost
      urlComponents.port = Int(configuration.port)
      guard let url = urlComponents.url else {
        throw PhoneBridgeError.invalidArguments(
          "Could not form a web client URL from the Mac hostname."
        )
      }
      clientURL = url
      addressLabel.stringValue = url.absoluteString

      serverTask = Task { [weak self] in
        do {
          try await server.start()
          await MainActor.run {
            self?.statusLabel.stringValue =
              configuration.isLoopback
              ? "Running privately on this Mac"
              : configuration.usesTLS
                ? "Running securely on the local network"
                : "Running on the local network · development HTTP"
            self?.statusLabel.textColor =
              configuration.isLoopback || configuration.usesTLS
              ? .secondaryLabelColor : .systemOrange
          }
          await server.waitUntilCancelled()
        } catch {
          await MainActor.run {
            self?.statusLabel.stringValue =
              (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            self?.statusLabel.textColor = .systemRed
          }
        }
      }
    } catch {
      statusLabel.stringValue =
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      statusLabel.textColor = .systemRed
    }
  }

  private func buildWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 555),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "PhoneBridge"
    window.center()

    let content = NSView()
    content.translatesAutoresizingMaskIntoConstraints = false
    window.contentView = content

    let mark = NSTextField(labelWithString: "pb")
    mark.alignment = .center
    mark.font = .systemFont(ofSize: 16, weight: .black)
    mark.textColor = .black
    mark.wantsLayer = true
    mark.layer?.backgroundColor = NSColor.systemGreen.cgColor
    mark.layer?.cornerRadius = 12

    let title = NSTextField(labelWithString: "PhoneBridge")
    title.font = .systemFont(ofSize: 34, weight: .bold)

    let subtitle = NSTextField(
      wrappingLabelWithString:
        "Control cellular and FaceTime Audio calls from an authenticated browser."
    )
    subtitle.textColor = .secondaryLabelColor
    subtitle.font = .systemFont(ofSize: 15)

    statusLabel = NSTextField(labelWithString: "Starting…")
    statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
    statusLabel.textColor = .secondaryLabelColor

    let addressTitle = sectionLabel("WEB CLIENT")
    addressLabel = NSTextField(labelWithString: "Preparing address…")
    addressLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    addressLabel.lineBreakMode = .byTruncatingMiddle

    let openButton = NSButton(title: "Open Web Client", target: self, action: #selector(openClient))
    openButton.bezelStyle = .rounded
    openButton.keyEquivalent = "\r"

    let tokenTitle = sectionLabel("PAIRING TOKEN")
    tokenField = NSTextField()
    tokenField.isEditable = false
    tokenField.isSelectable = true
    tokenField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    tokenField.placeholderString = "Generating…"

    let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyToken))
    copyButton.bezelStyle = .rounded

    let contactsTitle = sectionLabel("CONTACTS")
    contactsButton = NSButton(
      title: "Grant Contacts Access",
      target: self,
      action: #selector(requestContacts)
    )
    contactsButton.bezelStyle = .rounded

    let contactsHelp = NSTextField(
      wrappingLabelWithString:
        "Permission is requested by this signed app and can be revoked in System Settings."
    )
    contactsHelp.textColor = .secondaryLabelColor
    contactsHelp.font = .systemFont(ofSize: 12)

    let callControlTitle = sectionLabel("CALL CONTROL")
    callControlButton = NSButton(
      title:
        CallControlAccessibilityAuthorization.isTrusted
        ? "Call Control Access Granted" : "Grant Call Control Access",
      target: self,
      action: #selector(requestCallControl)
    )
    callControlButton.bezelStyle = .rounded

    let callControlHelp = NSTextField(
      wrappingLabelWithString:
        "Allows answer, end, hold, mute, and keypad controls when macOS hides calls from the private call model."
    )
    callControlHelp.textColor = .secondaryLabelColor
    callControlHelp.font = .systemFont(ofSize: 12)

    let views: [NSView] = [
      mark, title, subtitle, statusLabel!, addressTitle, addressLabel!, openButton, tokenTitle,
      tokenField!, copyButton, contactsTitle, contactsButton!, contactsHelp, callControlTitle,
      callControlButton!, callControlHelp,
    ]
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }

    NSLayoutConstraint.activate([
      mark.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
      mark.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
      mark.widthAnchor.constraint(equalToConstant: 48),
      mark.heightAnchor.constraint(equalToConstant: 48),

      title.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 16),
      title.centerYAnchor.constraint(equalTo: mark.centerYAnchor, constant: -7),
      subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),

      statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
      statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      statusLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),

      addressTitle.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
      addressTitle.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 28),
      addressLabel.leadingAnchor.constraint(equalTo: addressTitle.leadingAnchor),
      addressLabel.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
      addressLabel.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -12),
      openButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      openButton.topAnchor.constraint(equalTo: addressTitle.bottomAnchor, constant: 8),

      tokenTitle.leadingAnchor.constraint(equalTo: addressTitle.leadingAnchor),
      tokenTitle.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 28),
      tokenField.leadingAnchor.constraint(equalTo: tokenTitle.leadingAnchor),
      tokenField.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -10),
      tokenField.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
      tokenField.heightAnchor.constraint(equalToConstant: 28),
      copyButton.trailingAnchor.constraint(equalTo: openButton.trailingAnchor),
      copyButton.topAnchor.constraint(equalTo: tokenTitle.bottomAnchor, constant: 8),

      contactsTitle.leadingAnchor.constraint(equalTo: tokenTitle.leadingAnchor),
      contactsTitle.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 28),
      contactsButton.leadingAnchor.constraint(equalTo: contactsTitle.leadingAnchor),
      contactsButton.topAnchor.constraint(equalTo: contactsTitle.bottomAnchor, constant: 8),
      contactsHelp.leadingAnchor.constraint(equalTo: contactsButton.trailingAnchor, constant: 14),
      contactsHelp.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      contactsHelp.centerYAnchor.constraint(equalTo: contactsButton.centerYAnchor),

      callControlTitle.leadingAnchor.constraint(equalTo: contactsTitle.leadingAnchor),
      callControlTitle.topAnchor.constraint(equalTo: contactsButton.bottomAnchor, constant: 26),
      callControlButton.leadingAnchor.constraint(equalTo: callControlTitle.leadingAnchor),
      callControlButton.topAnchor.constraint(equalTo: callControlTitle.bottomAnchor, constant: 8),
      callControlHelp.leadingAnchor.constraint(
        equalTo: callControlButton.trailingAnchor,
        constant: 14
      ),
      callControlHelp.trailingAnchor.constraint(
        equalTo: content.trailingAnchor,
        constant: -32
      ),
      callControlHelp.centerYAnchor.constraint(equalTo: callControlButton.centerYAnchor),
    ])
  }

  private func sectionLabel(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = .systemFont(ofSize: 10, weight: .bold)
    label.textColor = .secondaryLabelColor
    return label
  }

  @objc private func openClient() {
    guard let clientURL else { return }
    NSWorkspace.shared.open(clientURL)
  }

  @objc private func copyToken() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(tokenField.stringValue, forType: .string)
  }

  @objc private func requestContacts() {
    contactsButton.isEnabled = false
    Task {
      do {
        try await MacContactDirectory().requestAccess()
        await MainActor.run {
          contactsButton.title = "Contacts Access Granted"
        }
      } catch {
        await MainActor.run {
          contactsButton.title = "Open Privacy Settings"
          contactsButton.isEnabled = true
          contactsButton.target = self
          contactsButton.action = #selector(openContactsSettings)
        }
      }
    }
  }

  @objc private func requestCallControl() {
    if CallControlAccessibilityAuthorization.isTrusted {
      callControlButton.title = "Call Control Access Granted"
      callControlButton.isEnabled = false
      return
    }
    _ = CallControlAccessibilityAuthorization.request()
    if CallControlAccessibilityAuthorization.isTrusted {
      callControlButton.title = "Call Control Access Granted"
      callControlButton.isEnabled = false
    } else {
      callControlButton.title = "Open Accessibility Settings"
      callControlButton.action = #selector(openAccessibilitySettings)
    }
  }

  @objc private func openAccessibilitySettings() {
    CallControlAccessibilityAuthorization.openSettings()
  }

  @objc private func openContactsSettings() {
    let url = URL(
      string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
    )!
    NSWorkspace.shared.open(url)
  }
}

private struct AppConfiguration {
  let host: String
  let port: UInt16
  let token: String?
  let isLoopback: Bool
  let tlsPKCS12: Data?
  let tlsPassphrase: String?
  var usesTLS: Bool { tlsPKCS12 != nil }

  init(arguments: [String]) throws {
    host = Self.option("--host", in: arguments) ?? "127.0.0.1"
    isLoopback = ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
    if let tlsPath = Self.option("--tls-p12", in: arguments) {
      guard let data = FileManager.default.contents(atPath: tlsPath) else {
        throw PhoneBridgeError.invalidArguments("Could not read TLS identity at \(tlsPath)")
      }
      tlsPKCS12 = data
    } else {
      tlsPKCS12 = nil
    }
    tlsPassphrase = ProcessInfo.processInfo.environment["PHONEBRIDGE_TLS_PASSWORD"]
    guard isLoopback || tlsPKCS12 != nil || arguments.contains("--allow-insecure-lan") else {
      throw PhoneBridgeError.invalidArguments(
        "Refusing non-loopback HTTP without --tls-p12 or --allow-insecure-lan."
      )
    }
    let rawPort = Self.option("--port", in: arguments).flatMap(UInt16.init) ?? 8742
    guard rawPort > 0 else {
      throw PhoneBridgeError.invalidArguments("Port must be between 1 and 65535.")
    }
    port = rawPort
    token = Self.option("--token", in: arguments)
  }

  private static func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1]
  }
}

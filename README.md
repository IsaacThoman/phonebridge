# phonebridge

Remote control and WebRTC audio bridge for cellular and FaceTime Audio calls on macOS.

> [!IMPORTANT]
> PhoneBridge is under active development. Call launching uses supported macOS URL
> handling today; call control, WebRTC media, and the experimental private bridge
> are being implemented and validated on dedicated test hardware.

## Goals

- Search macOS Contacts without uploading the address book.
- Place iPhone-relayed cellular calls and FaceTime Audio calls.
- Answer, end, mute, hold, and send DTMF from an authenticated web client.
- Proxy two-way call audio through WebRTC.
- Provide a streaming JSON-RPC/CLI surface for agents and scripts.
- Support macOS Sequoia's FaceTime call host and macOS Tahoe's Phone app.
- Keep private-framework injection optional and capability-driven.

## Current CLI

```bash
swift build

# Inspect a command without placing a call.
swift run phonebridge call start \
  --service cellular \
  --to "+1 (415) 555-1212" \
  --dry-run \
  --json

# FaceTime Audio accepts a phone number or Apple Account email.
swift run phonebridge call start \
  --service facetime-audio \
  --to "person@example.com" \
  --dry-run

# macOS prompts for Contacts access on first use.
swift run phonebridge contacts search "Rick Astley" --json

# Run the authenticated local web client.
swift run phonebridge server --token "choose-a-long-random-token"
# Open http://127.0.0.1:8742 and enter the token.

# Build a stable signed app bundle for macOS privacy permissions.
sh scripts/build-app.sh
open dist/PhoneBridge.app

# Inspect private call-control classes and selectors without invoking them.
swift run phonebridge bridge probe --json

# Exercise ICE/DTLS/SDP without requesting browser microphone permission.
# This is a transport diagnostic, not a call-audio test.
open "http://127.0.0.1:8742/?transport-only=1"
```

## Current media path

The web client can now establish and tear down an authenticated, audio-only
WebRTC session with the Mac. The current native endpoint uses WebRTC's default
Core Audio device, so it validates browser-to-Mac transport but does not yet
route Phone/FaceTime process audio. The next media layer replaces that device
with a Core Audio process tap for outgoing call audio and a virtual input path
for browser-to-call audio.

## Safety model

- The server binds to loopback unless explicitly configured otherwise.
- The current development server uses bearer authentication over HTTP. It refuses
  non-loopback listeners unless `--allow-insecure-lan` is also supplied. Use that
  escape hatch only on an isolated test network; authenticated TLS is required
  before exposing PhoneBridge remotely.
- The browser receives only minimal contact search results.
- Every call request identifies the exact target and service.
- Experimental injection refuses to run with unknown SIP state and reports
  selector-level capabilities instead of assuming private APIs exist.
- Call audio is never recorded unless a separate, explicit recording feature is
  requested and all legally required consent is obtained.

## Platform strategy

| macOS | Apple call host | PhoneBridge adapter |
|---|---|---|
| Sequoia 15 | FaceTime.app | URL launch, Accessibility, optional injected bridge |
| Tahoe 26 | Phone.app | URL launch, Accessibility, optional injected bridge |

The injected bridge is research-only. It requires reduced system protections,
is not suitable for App Store distribution, and must never be required for basic
call launching or contact search.

## Development

```bash
swift test
swift run phonebridge --help
```

License: MIT.

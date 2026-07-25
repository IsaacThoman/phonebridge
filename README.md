# phonebridge

Remote control and WebRTC audio bridge for cellular and FaceTime Audio calls on macOS.

> [!IMPORTANT]
> PhoneBridge is under active development. Call launching uses supported macOS URL
> handling. Call control and media routing use unsupported Apple/Core Audio
> integration points and are being validated on dedicated test hardware.

## Goals

- Search macOS Contacts without uploading the address book.
- Place iPhone-relayed cellular calls and FaceTime Audio calls, preferring
  FaceTime Audio whenever an endpoint supports both.
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

# Serve a remote browser over HTTPS. The PKCS#12 identity should contain a
# certificate trusted by the client and valid for the hostname it opens.
PHONEBRIDGE_TLS_PASSWORD="p12 passphrase" \
  swift run phonebridge server \
  --host 0.0.0.0 \
  --tls-p12 "/path/to/identity.p12" \
  --token "choose-a-long-random-token"

# Build a stable signed app bundle for macOS privacy permissions.
sh scripts/build-app.sh
open dist/PhoneBridge.app

# Inspect private call-control classes and selectors without invoking them.
swift run phonebridge bridge probe --json

# List active cellular and FaceTime calls.
swift run phonebridge call status --json

# Control the selected call, or the first eligible call when --id is omitted.
swift run phonebridge call control answer
swift run phonebridge call control hold --id CALL_UUID
swift run phonebridge call control resume --id CALL_UUID
swift run phonebridge call control mute --id CALL_UUID
swift run phonebridge call control unmute --id CALL_UUID
swift run phonebridge call control send_dtmf --id CALL_UUID --digit 1
swift run phonebridge call control hang_up --id CALL_UUID

# Inspect installed audio devices and test a call-host process tap.
swift run phonebridge audio devices --json
swift run phonebridge audio tap --host facetime --seconds 5 --json
swift run phonebridge audio tap \
  --bundle-id com.apple.avconferenced \
  --seconds 5 \
  --json

# Exercise ICE/DTLS/SDP without requesting browser microphone permission.
# This is a transport diagnostic, not a call-audio test.
open "http://127.0.0.1:8742/?transport-only=1"
```

Contacts supplies phone numbers and email addresses, but it does not report
whether a particular endpoint is registered for FaceTime. On supported macOS
versions PhoneBridge asks the private Identity Services availability controller:
registered numbers offer FaceTime Audio first, while unregistered numbers fall
back to cellular. If that private query is unavailable or inconclusive, the web
client safely offers both and labels cellular as the fallback.

## Current media path

The native WebRTC endpoint uses a custom 48 kHz stereo audio device:

```text
Phone.app / FaceTime.app call media (com.apple.avconferenced)
  → macOS Core Audio process tap
  → native WebRTC audio input
  → remote browser speaker

Remote browser microphone
  → native WebRTC audio output
  → BlackHole 2ch or Rogue Amoeba Loopback virtual device
  → Phone.app / FaceTime.app microphone selection
```

The Mac must have either BlackHole 2ch or Loopback installed, and that virtual
device must be selected as the microphone in the Apple call host. Core Audio
process capture requires macOS 14.2 or later and user approval for system-audio
capture. WebRTC sessions expose an authenticated diagnostics endpoint at
`GET /api/webrtc/status`; a TURN server is still required for clients whose
network paths cannot form a direct ICE connection.

## Call control

`GET /api/calls` lists the calls known to Apple's call host. The web client polls
this endpoint and exposes Answer, Decline/End, Hold/Resume, and Mute/Unmute.
`POST /api/calls/control` invokes the corresponding operation.

PhoneBridge first uses a capability-gated TelephonyUtilities adapter. It
dynamically verifies every private Objective-C selector and its ABI, runs on the
call center's required main queue, and fails closed when an expected operation
is missing.

Sequoia can expose the private call-center object while filtering its call list
for third-party processes. The signed Mac app therefore has a second adapter
that reads and presses only FaceTime/Phone call controls through macOS
Accessibility. Click **Grant Call Control Access** in the Mac app, approve
PhoneBridge under **System Settings → Privacy & Security → Accessibility**, and
restart the app if macOS requests it. The web client reports “Setup needed”
until that permission is present.

That same scoped Accessibility adapter confirms the `Click to Call` banner
created by an authenticated web launch. The API reports
`handoffConfirmed: true` when it pressed the banner's exact `Call` button.
PhoneBridge refuses to auto-confirm when an older handoff is already pending.

Both TelephonyUtilities and the FaceTime/Phone accessibility hierarchy are
unsupported Apple integration points, so a macOS update can still change or
remove behavior.

## Safety model

- The server binds to loopback unless explicitly configured otherwise.
- The current development server uses bearer authentication over HTTP. It refuses
  non-loopback listeners unless `--allow-insecure-lan` is also supplied. Use that
  escape hatch only on an isolated test network. For normal remote use, supply a
  PKCS#12 server identity with `--tls-p12`; the passphrase is read from
  `PHONEBRIDGE_TLS_PASSWORD`. HTTPS is required for browser microphone access.
- The browser receives only minimal contact search results.
- Every call request identifies the exact target and service.
- Private call control reports selector-level capabilities instead of assuming
  private APIs exist; no SIP changes are made.
- Call audio is never recorded unless a separate, explicit recording feature is
  requested and all legally required consent is obtained.

## Platform strategy

| macOS | Apple call host | PhoneBridge adapter |
|---|---|---|
| Sequoia 15 | FaceTime.app | URL launch, TelephonyUtilities + Accessibility control, process audio tap |
| Tahoe 26 | Phone.app | URL launch, TelephonyUtilities + Accessibility control, process audio tap |

The private call-control adapter is research-only and is not suitable for App
Store distribution. PhoneBridge does not disable SIP or alter other system
protections, and private APIs are never required for contact search or outgoing
call launching.

## Development

```bash
swift test
swift run phonebridge --help
```

License: MIT.

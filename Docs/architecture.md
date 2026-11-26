# Architecture

The app is a thin SwiftUI front end over Swift packages. Back ends and transports know nothing of the
UI, so that other front ends (macOS, visionOS) and other back ends (RDP, SPICE) can be added without
touching each other.

## Layers

Each layer depends only on the ones below it.

| Layer | Where | What it holds |
|---|---|---|
| App | `App/Marionette` | SwiftUI views and UIKit bridges. No logic of its own. |
| Models | `Packages/MarionetteKit` | Observable models (`LibraryModel`, `SessionModel`, `ComputerEditorModel`), saved computers, prompts, the connection ladder, when to ask for a review and a donation (`SupportPrompts`), the simulated scenarios, and platform services behind protocols. |
| Interaction | `Packages/RemoteDesktopInteraction` | Pure Swift: viewport, gesture and pointer interpreters, modifier latching, key translation, the shortcut catalogue. |
| Rendering | `Packages/RemoteDesktopMedia` | Product `RemoteDesktopRender`: the Metal renderer and audio output every back end shares. |
| Contract | `Packages/RemoteDesktopCore` | `RemoteDesktopBackend`, `RemoteSession`, capabilities and the value types that cross the boundary. Also `RemoteDesktopSimulated` (the back end behind UI tests and the built-in demo) and `RemoteDesktopConformance` (the suite every back end passes). |
| Back ends | `Packages/AppleScreenSharing` | Apple's protocol. `ARDProtocol` holds messages and parsers with no I/O, `ARDCrypto` the logins, `AppleScreenSharing` the connection, the media engine and the back end. |
| | `Packages/SwiftVNCClient` | `SwiftVNCClient` wraps LibVNCClient; `VNCBackend` adapts it to the contract. |
| Decoding | `Packages/RemoteDesktopDecode` | VideoToolbox and AudioToolbox decoding for High Performance. |
| Transport | `Packages/RemoteDesktopTransport` | TCP and UDP, SSH tunnels, SOCKS5, SFTP, and the seeded network impairment layer used by tests. |
| Wrappers | `Packages/SwiftSSH2`, `SwiftSRTP`, `COpenSSL` | libssh2, libsrtp and OpenSSL. |

`Tools/marionettectl` drives the back ends from a terminal without the app.

## Decisions a reader would not guess

- **Apple's protocol is written here, not added to LibVNCClient.** It differs from RFB in the login,
  an encrypted record layer that starts mid-stream, about fifteen messages and a separate media path.
  LibVNCClient serves every other VNC server.
- **Connecting is a ladder of reconnections** (`ConnectionLadder`): High Performance, then Standard,
  then plain VNC. A server whose version line is not a Mac's (`RFB 003.889`) is recognised before any
  password is asked for and goes straight to VNC.
- **A fallback never weakens security.** A computer that has proved its identity is never handed to a
  plainer rung, a saved password is given to the VNC rung only for a computer first met as a VNC
  server, and a session without encryption is labelled Not Secure.
- **High Performance needs a direct path.** Its media is SRTP over UDP on ports 5900–5902, the same
  numbers at both ends. A device can therefore hold one High Performance session at a time, and a
  session through an SSH tunnel is Standard, without sound.
- **Reading a secret never shows a prompt by itself.** Passwords and keys that require Face ID are read
  with the context of one `SecretAccess` per session, which asks the owner once, explicitly; the
  saved password, the tunnel's key and its passphrase then open without asking again. A Secure
  Enclave key signs through libssh2's signing callback, so its private half is never in memory.
- **Front ends read capabilities, not back-end identity.** A control exists because the session
  offers the capability, and shows the reason when it does not.
- **The simulated back end ships in the app.** It powers the demo computer, the UI tests and the
  screenshots through named scenarios (`ScenarioCatalog`).
- **C libraries keep to one thread each.** libssh2 runs non-blocking on a serial queue; LibVNCClient
  runs on its own thread and talks to Swift through a socket pair, because it wants a file
  descriptor and blocking reads.
- **Plain VNC adapts in the client.** `SwiftVNCClient` measures the throughput of each update and
  picks the JPEG quality and colour depth; the shim in `CLibVNCClient` keeps one update request
  outstanding, so that a change of pixel format never meets an update already on its way, and
  converts 256-colour pixels back to the 32-bit framebuffer the rest of the app sees.
- **`ARDProtocol` and `ARDCrypto` are compiled optimised in every configuration.** Unoptimised
  big-number arithmetic made a debug login take about 3 s.
- **Two licences.** Anything that links LibVNCClient is GPL-3.0-or-later; everything else is
  Apache-2.0, so the Apple back end can be reused without the GPL.

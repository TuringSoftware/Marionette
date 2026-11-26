# Apple Screen Sharing protocol

macOS's Screen Sharing server speaks RFB (VNC) version `003.889`, an undocumented extension of RFB 3.8
that adds account logins, an encrypted record layer, a video mode ("High Performance") carried over
SRTP, a shared clipboard, file transfer, drag and drop, trackpad gestures, session select and curtain
mode. Apple's viewer is Screen Sharing.app.

This document describes the protocol as far as Marionette depends on it. Everything in it was
checked against real Macs, except where an item says otherwise.

## Sources and evidence

### References

- [andrewtheguy/remotex](https://github.com/andrewtheguy/remotex), `docs/apple-vnc-889.md` (MIT).
  The most complete public description, written against macOS 26 virtual machines.
- [kitknox/rootshell-vnc](https://github.com/kitknox/rootshell-vnc) (MIT): a working client, the
  source for curtain mode, the receive-bandwidth estimator and several timing details.
- [renegadelink/iShareScreen](https://github.com/renegadelink/iShareScreen), `docs/apple_vnc_rfc.md`
  (AGPL; read as documentation only).
- RoyalVNC's `ARDAuthenticationImpl.swift` (MIT), LibVNC issue #696 and pull request #698, and the
  community RFB specification [`rfbproto.rst`](https://github.com/rfbproto/rfbproto).
- Cyrus SASL's SRP mechanism (`plugins/srp.c`) as Apple ships it in `passwordserver_sasl`, and
  corecrypto's `ccsrp`: read as documentation for the SRP login.
- [wayshare](https://github.com/wesleygrimes/wayshare) (Apache-2.0): a Linux server of the same
  protocol.

Where this document and a reference disagree, this document records what a Mac did.

### Machines

- A macOS 27 virtual machine (Apple Virtualization, one display, no GPU, host-only network); macOS
  27.3 for touches.
- A Mac mini with macOS 15.6 and two displays (6016 × 3384 and 5120 × 2880) on a LAN.
- An Ubuntu 24.04 virtual machine running TigerVNC and wayshare.

### Methods

Each statement rests on one or more of these. Unmarked statements were **observed**; the others are
marked.

- **Observed**: Marionette's own client (`marionettectl`) against a Mac, checked on the Mac's screen
  or with the Mac's own tools (`pbpaste`, Finder, `system_profiler`, files on disk).
- **Captured**: Screen Sharing.app recorded through `marionettectl proxy`, a decrypting man in the
  middle (see [Tools](#tools)).
- **Mac log**: the Mac's unified log, which names most protocol steps and every failure:
  `/usr/bin/log show --predicate 'process == "screensharingd" OR process == "ScreensharingAgent"'`;
  the media engine, `avconferenced`, logs the High Performance stream configuration, each RTCP
  report it reads and its rate controller's state.
- **Static analysis**: `otool -tV` of `screensharingd` and `ScreensharingAgent`, and disassembly of
  ScreenSharing.framework from small helpers that load it. Marked where nothing was observed.
- **Reference**: taken from a reference above and not checked independently.
- **Apple's encoder**: UniversalHID.framework, which Screen Sharing.app uses to make touch reports,
  called on a Mac to print its report descriptor and the reports it makes for given fingers (see
  [Tools](#tools)).

Captures of Apple's viewer back the test fixtures in `Packages/AppleScreenSharing/Tests`
(file transfer, drag from the Mac, High Performance offers from macOS 26.6 and 27.0). A conformance
suite runs the same checks against a scripted Mac and, with `Scripts/test.sh --live`, against a
real one.

## Conventions

All multi-byte fields are big-endian unless stated. `u8`, `u16`, `u32`, `u64` are unsigned integers
of that many bits; `f32`, `f64` are IEEE floats. Positions are framebuffer pixels: on a 2x display of
1024 × 768 points, x runs 0…2047.

## Connection

### Version and security types

The Mac sends `RFB 003.889\n`. A viewer that echoes it gets Apple's extensions; one that answers
`003.008` gets plain RFB (see [A Mac as a plain VNC server](#a-mac-as-a-plain-vnc-server)).

The Mac then offers its security types, for example `04 1e 21 24 23`: 30 (Diffie-Hellman), 33
(RSA), 36 (SRP) and 35 (Kerberos). With "VNC viewers may control the screen with password" on, 2
(VNC password) is added: `[30, 33, 36, 2, 35]`. Turning that option off again needs a restart of
`screensharingd` before type 2 disappears.

Only members of `com.apple.access_screensharing` (by default the admin group) may log in. Anyone
else gets result word 1 after the login, exactly as for a wrong password; only the Mac log says why
("not a member of the sacl"). Members are added with
`dseditgroup -o edit -a USER -t user com.apple.access_screensharing`.

After a failed login the Mac delays its next answer, by 1 s, then 2.5 s and more.

### Diffie-Hellman login (type 30)

- The Mac sends generator 5 and a 512-byte (4096-bit) prime.
- The credentials are encrypted with **AES-128-ECB** under `MD5(shared secret)`.
- The result word is 0 on success and 1 on a wrong password, with no reason text.

Type 30 exposes the password to anyone who can impersonate the Mac, since nothing authenticates the
Mac. A viewer should use SRP wherever it is offered, and never fall back to type 30 after a failed
SRP login.

### SRP login (type 36)

The Mac's server is Cyrus SASL's SRP mechanism with corecrypto doing the arithmetic. Each step was
confirmed against the Mac and its log. The `remotex` description has the two names in message 1 the
wrong way round, and leaves out the repeated type byte and the buffer's own length.

| Step | Contents |
|---|---|
| Message 1 (viewer) | Read after the type byte alone: the type byte `36` again, then a `u32` length; read with the type byte: the length at once (see below). Then a SASL buffer `{ utf8(U) utf8(I) utf8(sid) os(cn) }`. **U and I are both the account name**; sid and cn are empty. With either name empty the Mac does not find the account. |
| Message 2 (Mac) | A `u32` length, then `{ 0 mpi(N) mpi(g) os(salt) mpi(B) u64(iterations) utf8(L) }`. N and g are RFC 5054's 4096-bit group. L is `mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2`. |
| Message 3 (viewer) | A `u32` length and `{ mpi(A) os(M1) utf8(o) os(cIV) }`, **without a type byte**. `o` must include `replay_detection` (else "abort: SRP not using replay detection") and `kdf=SALTED-SHA512-PBKDF2` (else "Error initializing security layer"), for example `mda=SHA-512,replay_detection,kdf=SALTED-SHA512-PBKDF2`. |
| Message 4 (Mac) | A `u32` length and `{ os(M2) os(sIV) utf8(sid) u32(ttl) }`, then result word 0. A wrong proof gets result word `1` alone. |

Arithmetic: SRP-6a as corecrypto computes it by default, SHA-512 throughout:

- `k = H(N ‖ PAD(g))`, `u = H(PAD(A) ‖ PAD(B))`, `K = H(PAD(S))`
- `M1 = H(H(N) ⊕ H(PAD(g)) ‖ H("") ‖ salt ‖ PAD(A) ‖ PAD(B) ‖ K)`: the name hashed into M1 is empty.
- `M2 = H(PAD(A) ‖ M1 ‖ K)`
- `x = H(salt ‖ H(":" ‖ PBKDF2-HMAC-SHA512(password, salt, iterations, 128 bytes)))`: RFC 5054's
  x with an empty user name and a stretched password. This was pinned offline before any login: it
  reproduces the verifier macOS stores for an account (`dscl . -read /Users/<name> ShadowHashData`,
  key `SRP-RFC5054-4096-SHA512-PBKDF2`, holding salt, iterations and verifier).

An existing account had 156,250 iterations and a 32-byte salt. An unknown account gets made-up
values (19,417 iterations), so the iteration count reveals whether a name exists.

After the login the rekey is wrapped under the first 16 bytes of `SHA-256(K)` (as the reference
says); the ChaCha20-Poly1305 security layer is not used. Initialisation and the record layer are as
after type 30.

**How message 1 is read depends on what came with the type byte** (Mac log, macOS 15.6 and 27).
`screensharingd` reads whatever has arrived. Reading the type byte `36` alone, it expects message 1 to
start with the type byte again; reading the type byte with bytes behind it, it takes them to start
with message 1's `u32` length. So the type byte and message 1 sent in one write (`36`, the length,
the buffer: the same bytes as the type byte followed by a message 1 without its own type byte) are
always read right, on both systems. Sent apart, `36` and then `36` with the message, they are read
right only if they also arrive apart; together, the second `36` is taken as part of the length:

- macOS 27 logs "Invalid SRP data length 603979776" (`24 00 00 00`), steps one byte on and recovers;
- macOS 15.6 consumes five bytes, lands inside message 1 and loops on "SRP invalid step" without
  consuming anything: over a million log lines, several cores busy, an assertion that keeps the Mac
  awake, and every later login to that daemon closed during authentication until
  `sudo launchctl kickstart -k system/com.apple.screensharing`.

Two writes sent apart arrive together often enough to matter: back to back on a LAN; after any
pause, when the client is too busy to send the first in time (the Mac log then shows the 31 bytes
arriving 0.5–3 s after it offered its logins, against 5–40 ms normally); after a lost segment, which
TCP holds the later one behind; and through an SSH tunnel, whose server may pass both on in one
write. Screen Sharing.app asks for the password between the two, so a Mac rarely sees them together
from it. Types 30 and 2 are not affected: the Mac speaks first after them.

An SRP login costs about 0.9 s from connect to "preparing displays" in optimised code (PBKDF2 with
156,250 rounds and three 4096-bit exponentiations).

### VNC password login (type 2)

The DES response of classic RFB works, and a wrong password is refused. The viewer is then a guest:
the Mac sends a session-select offer with commands `0xd` (ask the console user, a session of one's
own, and an undescribed command 3), and shows the console user "A guest user connecting from address
NAME is requesting permission to share your screen". No login key exists after type 2, so there is no
`SetEncryption` and no session of one's own (its credentials are sealed under that key).

### Initialisation

- ClientInit `0x81` (shared, extended) works. Screen Sharing.app always sends `0xc1` (shared, session
  select, extended) *(captured)*.
- The extended ServerInit has the framebuffer size and pixel format, a "name" of `00 00`, a `u32`
  flags word, a 16-byte bitmap of the messages the server accepts, then the name *(reference for the
  layout; observed values)*. A macOS 27 VM sent 2048 × 1536, 32-bit BGRX, flags `0x00000052`
  (may control, extended, two virtual displays) and a bitmap starting `bf f6 e7 2f ec …`.
- The bitmap lists `0x1c` and `0x1d` when High Performance is offered, which it is on a virtual
  machine too. The bitmap names `0x10` (encrypted input), `0x12` (`SetEncryption`), `0x0c`
  (curtain, only with Remote Management on) and, from macOS 27.3, `0x26` (touches; fifth byte
  `ee`).
- The Mac mini sent 11136 × 3384 (both displays side by side), flags `0x52`, High Performance
  offered.

### Session select

When the account logging in is not the console user, and the viewer set the session-select bit in
ClientInit, ServerInit's flags gain `0x04` and an offer follows ServerInit directly, in clear
*(captured, then observed)*:

```
u16 length (74) | u16 version 1 | u32 commands | u32 0 | char[64] console user's display name
```

Bit *n* of `commands` means command *n* is accepted; macOS 27 sent 5 (commands 0 and 2). Without the
session-select bit the Mac sends no offer and puts the viewer straight into the account's own
session, which was black when the account had none.

The viewer answers, also in clear:

```
u16 length | u16 version | u32 0 | u8 command | u8 0 | char[64] viewer name
```

- **Command 0** asks the console user (version 1, 72 bytes). The console user sees "A guest user
  connecting from address NAME is requesting permission to share your screen" with Cancel and Share
  Screen. NAME is the viewer name field.
- **Command 2** logs in to a session of one's own (version 2, 200 bytes) and appends the type-30
  credential block: name at offset 0 and password at 64, NUL-terminated, random fill, AES-128-ECB
  under the login's wrap key (the SRP key after an SRP login). It starts a login session for an
  account that has none (Setup Assistant appeared in it about three seconds later) and reuses the
  existing one otherwise. That session's display is virtual (layout flags `0x1`); asking the console
  user gives the console's physical display (`0x4`).

The Mac's verdict: `u16 length (80) | u16 version 1 | u8 status | u8 0 | 76 bytes`.

- Status 0: go ahead; the 76 bytes are zero and the viewer's usual prelude follows.
- Status 1: the console user declined. The 76 bytes are the offer again, with its length, and the
  viewer may answer again on the same connection.

A request nobody answers stays open on both ends with no time limit; only the viewer can give up, by
closing the connection.

## Encryption

### Prelude and rekey

After initialisation Apple's viewer sends ViewerInfo, SetMode (control), AutoPasteboard (start),
`SetEncryption 1` and `SetEncryption 2`. A Mac takes all of them in clear and takes the two
`SetEncryption` messages back to back.

The rekey arrives as a one-rectangle framebuffer update with encoding `0x44f` and a 36-byte body;
its key and IV unwrap with AES-ECB under the login key. A Mac sent no new rekey when the shown
display changed.

Apple's viewer sends AutoPasteboard inside the record layer *(captured)*; either works.

### Record layer

Both directions work as the reference describes: AES-128-CBC, one chain per direction, each record
`u16 length ‖ AES-128-CBC(u16 body length ‖ body ‖ filler ‖ SHA-1(sequence number ‖ plaintext))`,
at most 65,520 bytes *(layout: reference; behaviour observed)*. A multi-megabyte update spans many
records.

A Mac always offers `SetEncryption` after a login with a key. Since the bitmap travels after the
login, outside its proof, a Mac's bitmap without it means something on the path removed it.

### Encrypted input (`0x10`)

Screen Sharing.app sends every key and pointer event as `0x10` EncryptedInputEvent: `10`, a flag
byte, and one AES-128-ECB block under the **record layer's key** (not the login key), in Standard
and High Performance alike *(captured, then observed in both modes)*.

- **Pointer block**: six zero bytes, `u32` microseconds since the viewer's previous event, `ff`, the
  button mask, `u16` x, `u16` y. Recorded: `00 00 00 00 00 00 00 02 6d f2 ff 01 07 7a 00 8c` is a
  left press at (1914, 140), 159,218 µs after the last event.
- **Pointer flags are a click count** *(static analysis)*. Bit 0 means "the viewer supplies the
  click count" and bits 1–3 are the count. Apple's viewer sends `01` (count 0) with no button down,
  `03` (count 1) while one is down and `05` for a double click; the release after a click is `01`.
  With bit 0 clear the Mac counts clicks itself, comparing the microseconds field with its own
  double-click interval. That field matters only for double clicks: it is not a timestamp and plays
  no part in suppressing duplicates.
- **Key block**: `ff`, the down flag, `u32` keysym, `u32` microseconds since the previous event,
  `00 00`, `u16` keyboard type (`0x5b` from Apple's viewer), `u16` virtual key code. Recorded:
  `ff 01 00 00 00 63 00 18 57 79 00 00 00 5b 00 08` is "c" going down (key code 8). Apple's viewer
  sends flags `03`.
- **Bit 1 of a key's flags means "use the key code in the block"**. With flags `03` and the last six
  bytes zero, ⌘Space did nothing. With flags `00` or `01` and those bytes zero, typing (Shift,
  digits, punctuation, ⌘Space) worked exactly as with plain `0x04` events: the Mac maps the keysym
  itself.
- Flags `00` on every key and pointer event, with no key code, work for typing, ⌘Space, double
  clicks, and drags in both directions.
- ScreensharingAgent ignores a pointer event whose clamped position and button mask equal the last
  ones it posted ("same event - ignore" in its log); that state outlives a viewer's session
  *(static analysis)*.

A Mac also takes plain `0x04`/`0x05` events. The agent then has no elapsed time or click count (it
times clicks by its own clock) and never marks the viewer as a drag's owner, so file drags in either
direction need `0x10` *(static analysis, matching observed behaviour)*.

## Displays

### Layouts (`0x451`)

The Mac describes its screens in a framebuffer-update rectangle with encoding `0x451`: each display's
position in the desktop, its size in points, density and whether it is the main one, plus flags.
A new layout arrives whenever the session's displays change.

Layout flags *(static analysis of ScreensharingAgent, then observed)*:

| Flag | Meaning |
|---|---|
| `0x01` | A virtual display, or off the console |
| `0x02` | Curtain: with `0x01`, the curtain is up; without it, the curtain may be raised |
| `0x04` | On the console |
| `0x08` | The Login Window's lock screen is up |
| `0x10` | Not logged in |

Seen in practice: `0x4` on the console with only Screen Sharing on; `0x6` with Remote Management on;
`0x3` curtained; `0xc` after the curtain was lowered (locked); `0x5` in High Performance; `0x15` at
the Login Window in High Performance. An ordinary lock (⌃⌘Q) changes no flag; only the keyboard's
secure-input flag comes on, as it does for any password field.

**A layout ends the Mac's update arming.** `AutoFrameBufferUpdate` must be sent again after every
layout.

### Choosing displays in Standard mode (`SetDisplay`, `0x0d`)

Standard mode shows all physical displays side by side unless the viewer picks one. On the Mac mini
the smaller display sat at (0, 0) and the main one at x = 5120. After `SetDisplay` naming one
display, the next layout lists that display alone at its own size at (0, 0), and pictures of exactly
that size follow. The first switch took 2.7 s, later ones about 10 ms. Screen Sharing.app always
starts a session with `SetDisplay` all (`0d 01 00…`) *(captured)*.

### Virtual displays (`SetDisplayConfiguration`, `0x1d`)

High Performance runs on virtual displays the viewer asks for with `SetDisplayConfiguration`
(sizes in points, a scale of 1 or 2, and whether the configuration may change later).

What a macOS 27 VM made of requests:

| Asked (points @ scale) | Made (pixels) |
|---|---|
| 200 × 200 to 1000 × 2000 @1x, including portrait phone shapes | As asked: there is no lower limit at 1x |
| 3840 × 2160 @1x | As asked |
| 1206 × 2622, 3840 × 2400, 4096 × 2160 @1x | Nothing: no layout and no answer, so the session hangs |
| 700 × 1000, 800 × 1080, 1000 × 1080, 1024 × 600 @2x | As asked |
| 440 × 956 @2x, 800 × 1734 @2x | 1600 × 1200: a mode of the Mac's choosing |
| 800 × 500 @2x | 1920 × 1200 |
| 2560 × 1440 @2x | 1920 × 1080 |
| 1080 × 2340 @2x | Nothing |

The Mac mini has the same ceiling but answers every request:

| Asked (points @ scale) | Made |
|---|---|
| 1920 × 1080 @2x, 3840 × 2160 @1x | As asked (the latter at 62 pictures/s, 33 Mbit/s) |
| 1920 × 1152 @2x | 1920 × 1152 *pixels* at 2x (960 × 576 points) |
| 2144 × 1536, 2560 × 1440, 3008 × 1692 @2x | The point size at **1x** |
| 4288 × 3072 @1x | Nothing new: the opening 3840 × 2160 @2x stays |

So a viewer should never ask for more than 3840 × 2160 pixels, should ask for 2x only from about
800 × 600 points, and can serve a smaller 2x request at 1x with the same pixels. Sizes of
3840 × 2304 and 4288 × 3072 reported for other Macs were not made by either machine.

- **Retina** is said in the display descriptor: a mode whose pixel size is twice its point size. A
  Mac makes no 2x mode taller than 2160 pixels, so a phone held upright has no Retina shape.
- **The number of displays is fixed per session.** A session started with one virtual display and
  then asked for two got two picture ports (`[5901, 5902]`), but its layout kept listing one screen,
  so no offer for two legs could be made. Going back to one ended the session. Two displays work only
  when the first configuration asks for two. A Mac makes at most two.
- **Matching the Mac's own displays.** Sending `SetPixelFormat` and Standard mode's encoding list
  first makes the Mac answer at once with its layout (sizes in points, density, main flag); High
  Performance's list then replaces Standard's. A list naming only `0x451` got no answer from macOS
  15.6 within 2 s. While another viewer's High Performance session runs, the layout lists only that
  session's virtual display.
- While a virtual display exists, the Mac's own displays are taken offline (`system_profiler
  SPDisplaysDataType` lists only "Screen Sharing Virtual Display"). On the Mac mini they came back
  after every session, also when they had been asleep before it.
- At the Login Window the Mac makes a virtual display too, and High Performance works there.

## Standard mode

Standard mode is RFB framebuffer updates over the TCP connection, inside the record layer.

### Update arming (`AutoFrameBufferUpdate`, `0x09`)

Instead of classic update requests, the viewer arms the Mac with `AutoFrameBufferUpdate` over an area
and an interval in microseconds; `0xffffffff` turns it off (Apple's viewer does that when it goes to
the background). Apple's viewer arms the whole framebuffer at interval 0, `09 00 00 01 …`, in every
mode *(captured)*.

Arm at interval 0 in High Performance too: no picture comes this way there, but the Mac paces cursor
shapes through the same gate. Armed at one pixel a second, a cursor change once came 1.8 s after the
move that caused it; armed at 0, every change came within 20 ms.

### Full quality

`SetEncodings` with zlib first: after the layout, one zlib rectangle of the whole screen (2048 × 1536
was 5.8 MB compressed), pixel-exact, then changed areas.

### Adaptive quality (`0x3f3`)

Encoding `0x3f3` codes the screen as 8 × 8 tiles, as the remotex reference describes; a port of its
decoder was checked against a Mac's own stream.

| Observation | Detail |
|---|---|
| What to list | `0x3f3`, then zlib, after the usual metadata encodings. The Mac sent only `0x3f3`. |
| Order of arrival | A 129-byte table message in an empty rectangle at 0,0; one full update of the whole 2048 × 1536 screen in 93 KB (precisions 3 and 5); partial updates as strips 256 rows high, top to bottom; later, full updates of changed areas at precisions 15 and 25. |
| Stream ends | Every rectangle of a 12-second session decoded with both of a full update's streams ending on `0x6d` and each partial update on `mvs`. |
| Accuracy | Against the same screen at Full quality: 22–31 dB after the first full update, 36–41 dB once refined; mean error about one level per channel. |
| Decoding cost | 79 ms for a full 2048 × 1536 update and 15–20 ms per strip on Apple silicon, optimised. Unoptimised code took 4.2 s and 0.7–0.9 s, enough to make the Mac's strips look 0.9 s apart. |
| Switching | `SetEncodings` with the other list switches a running session either way; ask for the whole screen afterwards. |

Tiles are coded as copies of their neighbours and as refinements of what is already there, so the
decoder must paint onto exactly the pixels the Mac assumes. If decoding fails, nothing
resynchronises the two sides; the way out is Full quality and a whole-screen update.

When the refinement comes, measured over menus, Finder windows, Spotlight typing and scrolling:

- Small changes (under 100,000 pixels) were refined 0–20 ms after their coarse update.
- Large areas, once they stopped changing, were refined a median 20–70 ms after their last coarse
  update; the 90th percentile was 110–130 ms and the longest 730 ms.
- While an area keeps changing the Mac sends only coarse updates; 78–93 % were replaced by another
  coarse update before any refinement.

Holding coarse updates back until refined would add that delay to every frame of an animation.

### Missed changes

On the macOS 27 VM, Standard mode can miss parts of the screen that change. After a click on the
Finder menu the Mac sent the menu bar's highlight but no rectangle for the menu that dropped down,
for 5 s and more. Plain VNC from the same Mac showed the same, asking for updates after every update
changed nothing, and High Performance showed the menu at once, so this is the Mac's change detection
on that VM. Untested on a physical Mac.

### The Mac's own pointer (`0x44c`)

A rectangle with encoding `0x44c` (w = h = 0) carries the Mac's pointer position in desktop
coordinates, when the viewer listed `0x44c`. Only hardware mouse input at the Mac is reported: not a
pointer warped by a program, not events posted by an app with Accessibility permission, and not
another viewer's moves.

- On the VM, positions came at about 50 a second whenever the host's pointer moved over the VM's
  window, and once at the start of each Standard session; none in High Performance.
- Screen Sharing.app on the Mac mini got about 60 a second *(captured)*. Marionette's client got
  them only when the session started with the Mac asleep (1,064 positions in 30 s, across both
  displays); sessions started on an awake Mac got none. See [Open questions](#open-questions).

## High Performance mode

### Setup

1. `SetDisplayConfiguration`, then `SetEncodings` with `0x3f2` first.
2. The Mac sends a layout (flags `0x5`; about 2 s after the first request), then a port message
   naming the UDP ports: 5900 for sound, 5901 (and 5902 for a second display) for pictures.
3. The viewer sends its offer, message `0x1c`: a session identifier and, per leg and direction, SRTP
   keys (32-byte key and 14-byte salt) *(layout: reference; behaviour observed)*.
4. The Mac answers within 0.3 s.

Rules:

- Offer only after both a port message and the layout of the display being offered, and only one
  offer at a time. The Mac may repeat its port message while an offer is outstanding (seen at the
  Login Window, and once in a normal session); ignore it.
- A resize is a new `SetDisplayConfiguration` (marked dynamic), then a layout (about 1.7 s later),
  a port message, a new offer and an answer (30 ms).
- The Mac's `avconferenced` log shows the stream configured from the offer:
  `vcMediaStreamIsRTXEnabled = 0`, `IsFECEnabled = 0`, `IsltrpEnabled = 1`, `TilesPerFrame = 1`.

### Pictures

- SRTP `AES_CM_256_HMAC_SHA1_80`, RTCP on the same port.
- Payload type 100: HEVC Range Extensions, 8-bit 4:4:4, level 5.1, full range, BT.709 matrix, sRGB
  transfer, Display P3 primaries; 10-bit with PQ for an HDR display (see [HDR](#hdr)). With one tile
  per frame it arrives as standard RFC 7798 packets on one SSRC; ffmpeg decodes a dump without error.
- Each picture packet's header extension, with flag `0x01`, carries a word with the picture's packet
  count and its running number. Over 723 pictures that arrived whole the count matched every time,
  so a picture right after a gap is whole if its count is met.
- Keyframes are large: 342 KB (about 250 packets) at 1280 × 800 @1x; later ones 500–730 KB, as the
  encoder's target climbs to 58 Mbit/s and a still screen is coded at a quantizer of 6.
- **Every offer gets new SSRCs from the Mac**, even with the same keys and viewer SSRCs, so a packet
  under an SSRC the leg has moved on from is a straggler and can be dropped. When the screen saver
  starts the Mac also recreates its streams with new SSRCs, without a new offer.

**H.264** (payload type 123, offered alone with one tile) is the fallback for devices that cannot
decode HEVC 4:4:4:

- A keyframe opens with a packet whose first byte is `0x92` (forbidden bit set, NAL type 18), four
  bytes, and an MP4 `avc1` sample description; the parameter sets are in its `avcC` box. The IDR
  follows as FU-A fragments; later pictures come one per packet, or as FU-A when large.
- At 1280 × 800: first keyframe 166 KB, the next 250 KB; 14–18 pictures a second during a full-screen
  animation at about 0.4–0.5 Mbit/s.
- It has no refresh pictures, so every lost packet costs a keyframe. At 1 % loss each way the picture
  froze at the first loss and stayed frozen.

**Strips** (`tilesPerFrame` 4) are, according to the reference, one HEVC stream cut into four strips
that predict from each other, with no refresh pictures *(reference; not used)*. They allow a keyframe
every 10 ms, which makes a lossy start possible by brute force but every later loss expensive.

### Sound

Payload type 101 on port 5900: 100 packets a second, 4-byte frames while the Mac is silent, 4–400
bytes otherwise. It is **plain AAC-ELD without SBR**, 480 samples a frame: a 1 kHz and a 15 kHz tone
played on the Mac came out of a plain AAC-ELD decoder at the right frequency and amplitude (an
ELD-with-SBR decoder at 960 samples gives half the frequency). Sound played on the Mac mini arrived
whole.

### RTCP and rate reports

- The Mac sends SRTCP on both legs about once a second; every packet authenticated.
- **The Mac reads RTCP only when the first packet's sender SSRC is the one in the viewer's offer.**
- **It reads a report block out of every receiver report.** Sent an empty one it logged garbage
  (`VRTCP: Fraction=043, Lost=8348569, Jitter=2785230307`); with a real block it logs the right loss.
  Its round-trip figure stayed at 0.250 s whatever was echoed.
- Rate reports (`RCTL`) and picture acknowledgements must each be alone in their datagram.
- **The `RCTL` bandwidth field is a ceiling.** Held at 60,000 kbit/s the encoder target sat at
  58,448; at 30,000 it fell to 27,915; at 10,000 it stayed at the stream's 20,771 floor. The Mac's
  log shows the value it read as `RemoteBWE`. A packet-train estimate of the path (rootshell-vnc's
  estimator) read 60,001 on the VM's host-only link.
- **The burst nibble is read.** With seeded loss of 0.5 % in bursts of up to 7 packets, a nibble
  carrying the longest run lost drove the target to its floor within 5 s; with the nibble at 0 it
  stayed at 58,448.
- The sound leg takes a 58-byte report (a receiver report with a block and an empty-CNAME source
  description) without an RTCP timeout. The Mac does not adapt its sound.

### Loss and recovery

- **The Mac resends nothing.** Eighteen generic NACKs in one session brought no packet a second time.
- **One restart a second.** A picture-loss indication or refresh request within a second of the last
  keyframe or refresh picture is discarded ("Request key frame too soon, discard") and never made up
  for. A request a second or more later is answered in 30–60 ms.
- **A refresh request needs an acknowledged picture.** With one, it brings a picture of 0.1–2 KB
  predicted from it. With none (at the start of a stream) it brings ordinary pictures and never a
  keyframe, so a start needs picture-loss indications. (The reference reports a small keyframe here.)

What follows for a viewer:

- **A lossy path cannot start a stream.** A 250-packet keyframe arrives whole 8 % of the time at 1 %
  loss, with one try a second. Ask at the first moment the Mac will listen and every half second
  after, and give up on High Performance if pictures are still broken a few seconds in.
- **A running stream rides loss out.** Each loss costs one refresh picture, asked for as soon as the
  Mac's second is up. A full-screen animation at 15–23 pictures a second clean ran at 14–23 at 1 %
  loss and 4–17 at 5 %.
- **Reordering is not loss.** Waiting up to 15 ms for the packets behind a gap, and 8 ms at the start
  of a stream, separates the two.
- **A 6 Mbit/s downlink is not enough to start the full profile**; a cap of 4 Mbit/s imposed
  mid-session dropped datagrams at once.

### Profiles

The offer names a negotiator mode per picture leg *(reference)*. Mode 7 is the full profile. Mode 5,
the constrained profile, is accepted: the Mac configured `TXMinBitrate = 333000`,
`TXMaxBitrate = 6000000` and a 6000 kbit/s cap. It pads each picture to a multiple of 16 points (a
1440 × 900 pt display came as 2880 × 1824 pixels), so displays in that profile should be multiples of
16 points. Behind a 3 Mbit/s cap with a 400 ms queue the full profile's keyframes never arrived whole;
switching the same connection to the constrained profile (a new display configuration and offer) gave
a first picture 2 s later, then no loss. On the Mac mini the constrained profile ran at 2880 × 1792,
42 pictures/s.

### HDR

Both machines, macOS 27 and macOS 15.6, send 10-bit HDR pictures for a virtual display asked for in
HDR.

- **Asking.** Each mode in a display descriptor ends with a `u32` HDR word (offset `0x18` of the
  mode). Apple's viewer sets it to 1 on every mode of an HDR display, the four presets included
  *(static analysis: `-[SSSession stConfigureVirtualDisplaysWithDimensions:]`)*.
- **The Mac's answer.** In the port message, bit 1 (`0x2`) of a picture port's flags word says its
  display is HDR. It was clear for the SDR opening display and set once the display had been asked
  for in HDR. Apple's viewer offers HDR pictures for a leg only when that bit is set, the second
  leg by its own word *(static analysis: `-[SSSession handleAVCMediaEncoding:]`)*.
- **Offering.** Field 9 of the offer's stream message is a bitmap of the HDR modes the viewer takes:
  `1` is SDR alone, as Apple's viewer sends without HDR; `9` adds mode 3. Offered 9 for a port
  marked HDR, the Mac's `avconferenced` logged `vcMediaStreamHDRMode = 3` and its encoder "Got 10b
  input … HEVC_Main44410_AutoLevel/bitdepth10".
- **Pictures.** HEVC Range Extensions Main 4:4:4 10, full range, BT.709 matrix, Display P3
  primaries, PQ transfer. The desktop's white is at 100 nits (PQ code 519–520 of 1023), so a viewer
  maps 100 nits to its SDR white.
- **Changing.** A dynamic `SetDisplayConfiguration` that changes only the HDR word is answered like a
  resize (layout, port message with the new bit, offer, answer), in 1.1–1.6 s on both machines. The
  pictures change bit depth with the new stream.
- **Rate.** The encoder's target stays at 58.4 Mbit/s. On an idle desktop an HDR keyframe was 93 KB
  against 176–198 KB in SDR. At 1 % loss each way the 10-bit stream recovered with refresh pictures
  as an SDR one does. `avconferenced` reads the HDR mode only when it configures a stream, never in
  its rate control *(static analysis)*, so a Mac does not fall back to 8-bit by itself.
- **Apple's viewer** offers HDR only as "reference HDR mode", which a person turns on, on a virtual
  display ("Cannot enable HDR Reference mode unless using virtual display"), and while its window is
  on a display with the HDR video reference preset selected *(static analysis:
  `SSVirtualDisplayLocalDisplayMonitor`, `-[SSSessionView setReferenceHDRModeEnabled:]`)*.

### Addresses and ports

- **Media goes to the address TCP reached.** By its `.local` name the VM was reached over IPv6
  link-local although it also had IPv4; UDP legs connected to that same scoped address worked.
  Resolving the name again for UDP could pick the other family.
- The viewer binds the same port numbers the Mac names. On Darwin, `SO_REUSEADDR` lets connected UDP
  sockets bind 5900–5902 again as long as their peers differ, so two sessions to two Macs can share
  the ports; only a second socket to the same Mac is refused. A Mac serves one High Performance
  viewer at a time.
- Through a SOCKS proxy or a tunnel the Mac's TCP peer is not the viewer, which cannot receive its
  datagrams, so only Standard mode works.

### Lifecycle

- **A logout** (`launchctl bootout gui/501`) stopped the stream at once, with no status message and
  no layout. The heartbeat went on, and when the viewer asked for its displays again 8 s later the
  Mac closed the connection. A new connection reached the Login Window, where High Performance worked.
- **Curtain mode is not for High Performance** (see [Curtain mode](#curtain-mode)).

## Input

### Keys

Keys are X11 keysyms in `KeyEvent` (`0x04`) or inside `0x10` blocks.

- Command is `Super_L`/`Super_R`; Option is `Meta_L`/`Meta_R`.
- **A held key does not repeat.** One key-down held 1.5 s types one character (TigerVNC's Xvnc
  behaves the same). Repeats must be further key-downs from the viewer; 225 ms then every 30 ms (the
  Mac's defaults) types a run as expected.
- **Keysyms beyond U+FFFF are dropped** (`0x0101F44D` for 👍), on both protocols. The character's
  UTF-16 surrogates as two Unicode keysyms (`0x0100D83D`, `0x0100DC4D`) type it, so ❤️, 👍🏽, 🇫🇷 and
  👩‍💻 arrive intact one scalar or surrogate per keysym. (TigerVNC takes the plain `0x01xxxxxx`
  keysyms instead.)
- Keysyms are typed as the characters they name, so dead keys do not compose: Option-E then E gives
  "ee", not "é".
- Typed text with quotes, `&` and non-ASCII letters arrives intact; Return, ⌘N, ⌘Q and ⌘⇧3 act.

### Pointer

- Positions are framebuffer pixels in both dialects.
- On Apple's protocol, button bits 1 and 2 are swapped relative to RFB *(reference)*; on plain RFB
  3.8 to a Mac, right is bit 2 (mask 4) as usual.
- For 2 s after the Mac's own mouse moves, a viewer's pointer events in shared-control mode are
  discarded ("ignore mouse move delta") *(static analysis)*.

### Input lost after a login and around display changes

Nothing reports either loss.

- **A Mac discards input for about two seconds after a login.** One pointer move per fresh Standard
  session: sent 0, 250 or 500 ms after the first frame it was lost; sent 1000 ms or later it arrived.
  Keys are lost the same way, also over plain VNC. Re-arming updates or re-sending `SetEncodings`
  does not shorten it. Holding input until 2.6 s after the handshake and then sending it in order
  works.
- **It also discards input around every High Performance display change.** With pointer moves every
  125 ms around a resize, every move from the `SetDisplayConfiguration` until 0.45–0.52 s after the
  new layout was lost (four runs); from 0.52–0.64 s on, all arrived. Holding input from the request
  until 1 s after the layout delivers it.

### Trackpad gestures and scrolling (`0x17`)

Read from the encoders `RFBPostGestureEvent*` and `RFBPostScrollWheelEvent` in ScreenSharing.framework
and the Mac's side in ScreensharingAgent (`agent_SSAgent_PostGestureEvent_rpc`), which turns each
message into a CGEvent field by field *(static analysis)*. Each kind was then sent and its effect
checked on the Mac's screen.

All are kinds of message `0x17`: `17 00 | u16 length of the rest | u16 version | u16 kind | fields`,
positions as in a pointer event. Screen Sharing.app sends one only when a session flag is set; the
Mac took every kind without the viewer setting anything.

| Kind | Message | Bytes | Fields after the kind | The Mac posts |
|---|---|---|---|---|
| 1 | Gesture begin | 16 | `u32` series type, x, y | Type 29, HID type 61, field 117 = series type |
| 2 | Gesture end | 16 | `u32` series type, x, y | Type 29, HID type 62, field 117 |
| 3 | Magnify (version 2) | 36 | `f64` magnification, x, y, `u64` phase, `u64` mask | Type 29, HID 8 (zoom); field 113 = value, 132 = phase, 133 = mask |
| 4 | Smart magnify | 12 | x, y | Type 29, HID 22 (zoom toggle), field 133 = 2 |
| 5 | Rotate (version 2) | 36 | `f64` degrees (positive is counter-clockwise), x, y, `u64` phase, `u64` mask | Type 29, HID 5; fields 114, 132, 133 |
| 6 | Page swipe | 52 | `u32` motion, `u32` swipe mask, `f32` progress, position x, y, velocity x, y, z, `u32` flags, `u32` flavor, x, y | Type 29, HID 16 (navigation swipe); fields 123, 134, 124–126, 129–131, 136, 138; phase (115) from motion and progress |
| 7 | Look up | 12 | x, y | The look-up gesture |
| 8 | Gesture scroll | 36 | `f32` dx, dy, dz, `u32` natural scrolling, `u32` phase, `u32` mask, x, y | Type 29, HID 6; fields 118–120, 135, 132, 133 |
| 11 | Scroll wheel | 58 | See below | Type 22 (scroll wheel) |

- Gesture phases are IOHID phase bits: began 1, changed 2, ended 4, cancelled 8, may-begin 128. A
  version-1 magnify or rotate has no phase and mask; the Mac then puts 4 in field 133. Preview zoomed
  the same with masks 0, 3 and 4.
- Magnify steps multiply: 12 steps totalling 0.5 zoomed Preview ×1.63. Rotate +90 turned an image
  90° counter-clockwise. Smart magnify toggled Preview to actual size; look up highlighted a word in
  TextEdit and opened Look Up.
- Page swipe: motion 2 is under way (began at progress 0, changed after); any other motion is over
  (ended with progress, cancelled without). Mask 4 with progress +1 went back in Safari, −1 forward;
  mask 8 did nothing, and no mask was found for vertical page swipes.
- Scroll wheel (kind 11, length 54, version 1): `i16` line deltas x, y, z; `i32` 16.16 line deltas;
  `i32` point deltas; `u32` scroll phase (began 1, changed 2, ended 4, cancelled 8, may-begin 128;
  field 99); `u32` momentum phase (begin 1, continue 2, end 3; field 123); `u32` scroll count (field
  100); `u32` flags (bit 0: field 14; bit 1: field 88, continuous; bit 2: field 137, inverted from
  device); x, y. Horizontal is the first axis on the wire. A message of 35 bytes or fewer takes the
  Mac's "deprecated scroll wheel event" path, which keeps only the line deltas.
- **Phases are what swipe navigation needs.** A horizontal two-finger scroll with phases went back
  and forward in Safari; the same scroll without phases did nothing. The phase-began event must carry
  the first movement: Safari takes the swipe's direction from it, and a motionless began followed by
  movement did not navigate.
- Momentum events (scroll phase 0, momentum 1/2/3) carry a scroll on after the fingers lift.

### Touches (`0x26`)

From macOS 27.3 a Mac takes a viewer's fingers as a touch screen of its own, and its apps show what
they show for touches: holding a finger on a window's close button enlarges the three buttons, as
on a touch screen. Screen Sharing.app sends them only when the server's bitmap lists `0x26`
*(static analysis)*.

- **For each display the agent keeps a virtual touch screen**, "V-Virtual Touch Display N" (vendor
  `0x5ac`, product `0x8600`, usage page Digitizer, usage Touch Screen), made when a session starts
  and again whenever the Mac's displays change, High Performance's virtual displays included *(Mac
  log)*.
- **The message** is little-endian, unlike every other one: `26 00`, `u16` the length of what follows
  (16 plus the report's), `u16` version 1, eight zero bytes, `u32` the display, `u16` the report's
  length, the report (`RFBSendHIDReport` in ScreenSharing.framework; `HandleHIDReport` in
  `screensharingd`) *(static analysis, then observed)*. The display is the Mac's own id for it, a
  layout's screen id: 1 for the VM's display, 3 or 4 for High Performance's virtual display.
- **The report** is UniversalHID's digitizer report, ID 9, 58 bytes *(Apple's encoder; observed)*:

  | Bytes | Field |
  |---|---|
  | 0 | Report ID, 9 |
  | 1 | Contact count: slots in use |
  | 2 | Contact count maximum, 5 |
  | 3–27 | Five slots of 5 bytes: bits 0–4 the contact identifier (0–4), bit 5 resting (vendor usage `0xff1a`:`0xe0f2`), bit 6 touching, bit 7 in range; `u16` x and y, 0–65535 across the display |
  | 28–39 | A scroll collection: 16 bits, `i8` x and y, two `i32` |
  | 40–44 | One byte per slot, vendor usage `0xe0f4` (UniversalHID's "contact identity") |
  | 45–52 | `u64`, vendor usage `0xff00`:`0x0102` (UniversalHID's "remote timestamp") |
  | 53–57 | Seven groups of 5 bits, one bit per slot, vendor usages `0xe062`–`0xe068`: swipe pending, swipe locked, swipe up, down, left, right, cancelled; then 5 bits of padding |

  A report lists every finger on the display; a finger that lifts is listed once more with touching
  and in range clear. Reports with only the slots, counts and positions filled, everything else
  zero, worked: a tap opened the Apple menu, a held finger enlarged a window's buttons, and two
  fingers dragged down scrolled Terminal back.
- **The daemon passes a report on only** when the viewer may control, the agent of the viewer's
  session is the one on the console (a session of one's own gets none), and the Mac's own pointer
  has not been reported for 2 s *(static analysis)*. The last applies at the start of every session,
  when the agent reports the pointer's place: touches sent in the first 2 s were logged as received
  and went no further. A viewer's own pointer events do not count: touches 0.5 s after one arrived.
  Nothing tells the viewer a report was dropped.
- Screen Sharing.app also withholds touches while it shows several displays combined in one window
  *(static analysis)*.

## Clipboard

- Text set from the viewer is what `pbpaste` prints on the Mac; text copied on the Mac (`pbcopy`) is
  announced with `MiscStatus` 2 and fetched by the viewer.
- **A pasteboard archive must be a zlib stream that is sync-flushed and not finished.** A complete
  stream (final block and checksum) is silently ignored. Verified both ways.
- A Mac does not announce a pasteboard change the viewer itself made.
- Screen Sharing.app does not fetch the pasteboard on `MiscStatus` 2 *(captured)*: with AutoPasteboard
  on, the Mac sends it.

**Files are not carried by the clipboard, in either direction.**

- A file copied in the Mac's Finder reaches the viewer as its name, as text (`public.utf8-plain-text`,
  the UTF-16 flavors and `com.apple.traditional-mac-plain-text`), plus its icon as `com.apple.icns`
  (850 KB for a text file). There is no `public.file-url` flavor and no path.
- With a file on the viewer's clipboard, Screen Sharing.app sends `1f 00 01 00`, token 0, one item
  with no flavors *(captured)*: nothing of the file reaches the Mac.
- A pasteboard whose item is a `public.file-url` of a file on the Mac is refused by the Mac's
  pasteboard ("Failed sandbox check for path", "Sandbox extension creation failed" in
  ScreensharingAgent's log); the Mac's clipboard ends up empty.

## File transfer

Recorded between Screen Sharing.app and a Mac *(captured)*, then exercised with Marionette's client
alone. Four messages:

| Type | Direction | Layout |
|---|---|---|
| `0x20` DragPasteboard | Both | `20 00 00 00`, `u32` token, `u32` inflated length, `u32` compressed length, then a pasteboard archive (the clipboard's format) as its own sync-flushed, unfinished zlib stream. With both lengths zero and no archive (16 bytes) it ends a drag: the viewer sends it with token 0, the Mac with its own token, e.g. `20 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00`. |
| `0x0e` Drag request | Viewer | `0e 00 00 00`, `u32` token: asks what the drag now held on the Mac carries. |
| `0x1e` DropDestination | Mac | `1e 00 00 00`, `u32` token of the viewer's drag, `u32` length, the folder path (no NUL). |
| `0x22` FileTransfer | Both | `22 00`, `u32` length of what follows, `u16` 1, `u16` command, `u32` transfer id (chosen by the viewer, also for the Mac's replies), then the command's fields. |

Commands of `0x22`:

| Command | Sent by | Fields |
|---|---|---|
| 1 fetch | Viewer | `u32` 1 (paths), `u32` 0, `u16` length, path, NUL. The path must be absolute; `~` is not expanded. |
| 2 destination | Viewer | 8 zero bytes, `u16` length, folder path, NUL. `~` is expanded; a missing folder is created. |
| 5 stop | Viewer | Nothing. The Mac stops sending that transfer at once and sends nothing more for it, not even an end; pieces already on their way still arrive (2–15 of 64 KiB). The next transfer works normally. |
| 100 summary | Sender | `u32` 1 for a single file else 0, `u32` 0, `u64` total bytes (data and resource forks), `u64` bytes allocated on disk, `u64` files, `u64` 0, `u64` folders, `u32` 0. |
| 101 item | Sender | `u8` kind (1 file, 2 folder, 3 symbolic link), `u8` 0, 32 bytes of Finder info, `u64` resource fork size, `u64` data size, five `UTCDateTime`s (`u16` high seconds, `u32` seconds since 1904, `u16` 1/65536ths: created, content modified, attributes modified, accessed, backed up), `u16` flags (`0x10` on folders), `u16` depth, `u16` `st_mode`, `u32` `0x7e`, `u16` name length, `u16` 0 (for a link, its data size − 1), name, NUL; for a link, its target (data-size bytes, no NUL). |
| 102 data | Sender | `u32` length (at most 65,536), bytes. A file's data fork follows its item, then its resource fork. Empty files, folders and links have none. |
| 103 compressed data | Sender | `u16` compression (1, zlib; the Mac refuses others), `u32` inflated length, `u32` length, bytes: the next part of one zlib stream for the whole transfer, sync-flushed after each piece *(static analysis; not seen)*. |
| 104 end | Sender | `u32` status, **little-endian**, a Carbon error: 0 when everything was sent. |
| 200 received | Mac | `u16` status, `u16` length, the name the top item was saved under, NUL. 0: saved (renamed "name 2.ext" when the name was taken); 5: the folder could not be written (`/System`). |
| 300 progress | Receiver | `f64` fraction written *(reference; not seen during a 30 MB upload)*. |

- Items come in pre-order, each folder before its contents. Depth 0 is the top item; an item's depth
  is one more than its folder's. Extended attributes other than the resource fork are not sent.
- Nothing is acknowledged before the 200, and there is no flow control: the sender streams.
- **A drag is not needed.** A viewer may send command 2 with any folder, or command 1 with any path,
  in Standard and High Performance alike. A drag only finds the folder or the paths.
- A missing path is answered with command 104 alone, status −43 (`fnfErr`). A file the account may not
  read (`/etc/sudoers`) gets its summary and item, then an end with −5000 (`afpAccessDenied`) and no
  data; a folder it may not list (`/var/root`), its summary and item, then −1.
- **Names travel as the Finder spells them**: a POSIX `:` is `/` on the wire and the other way round.
  A file made as `a:b` in Terminal arrived as `a/b`; an upload named `x/y.txt` was saved as `x:y.txt`
  and reported back as `x/y.txt`. Paths in commands 1 and 2 are POSIX.
- Symbolic links (kind 3) come as items without data; the summary counts each target's length as its
  size. Fetching a folder with links to `target.txt`, `/etc/hosts` and `../../../etc` sent all three
  as they are on disk, absolute or escaping: the receiver must decide what to do with them.
- An upload cut short (an end before the announced bytes) leaves a short file on the Mac, reported as
  received. So cancelling an upload is sending the end; cancelling a download is command 5.
- Compression (103) is the sender's choice, made only when its queue to `screensharingd` backs up
  *(static analysis)*. Reading a 49 MB file at 250 KB/s did not trigger it: `screensharingd` took the
  whole file within 9 s and buffered it for the viewer. A viewer that reads slowly holds the Mac back
  only through TCP and the daemon's memory.

## Dragging files

A drag only tells the two sides *where*; the files then travel by file transfer.

### Into the Mac

1. A pointer event with no button down where the drag enters.
2. `0x20` DragPasteboard under a token the viewer chooses, with one `public.file-url` item per file.
   Only the names matter.
3. A pointer event with the button down: the Mac starts a drag of its own under the pointer.
4. Pointer events with the button down as the drag moves; the Mac highlights folders under it.
5. The release.

- Released over a folder's icon, a Finder window's content, a Finder sidebar entry or the desktop, the
  Mac answers `0x1e` DropDestination with the token and the folder's path within about 0.2 s (bare
  desktop: `/Users/<name>/Desktop`), and the viewer uploads there with command 2.
- Over an app's window or the Dock the Mac sends nothing at all: silence is the refusal. Waiting
  3 s for an answer is enough.
- An empty `0x20` before the release cancels the drag: no `0x1e` follows. Escape does not cancel it.
- **With plain `0x05` pointer events the Mac never answers `0x1e`**: only `0x10` events count.
- On the Mac *(static analysis, matching the Mac log)*: the viewer's `0x20` starts `SSDragHelper.app`;
  the agent posts a synthetic press at the cursor once the helper is ready, or after 0.5 s; it holds
  the viewer's release until the helper has entered its receiver (5 s safety timeout) and relays the
  helper's drop path as `0x1e`. An empty `0x20` during the drag cancels it, deferred up to 1.5 s if
  the helper is not in its drag loop yet.

### Out of the Mac

First seen in a capture of Screen Sharing.app, then done end to end in Standard and High Performance.

- **A Finder drag starts only if the pointer moves within about half a second of the press** (the
  double-click interval). 456 ms from press to first move started a drag; 567 ms and 679 ms did not.
  The same holds for Apple's viewer: its captured event stream, replayed, starts the drag with its
  original 400 ms hold and does not with the hold stretched to 700 ms.
- About 30 ms after the Finder drag starts, the Mac sends `0x20` with token 1, unasked: an archive
  whose item has a `public.file-url` flavor (the file on the Mac) and a
  `com.apple.remotedesktop.dragimage-png` flavor (the picture under the pointer, 64 × 64 for a text
  file's icon). On a 1x display the archive was about half the size.
- It is sent to the viewer whose pointer event had exactly the left button down: `screensharingd`
  marks that viewer the drag's owner. Plain `0x05` events never set the mark.
- The viewer takes the drag over with an empty `0x20`: the Mac cancels its local drag (the agent
  activates Finder and posts Escape) and the file stays where it was. Fetching it by path with
  command 1 then works.
- After the release the Mac sends an empty `0x20` with its token.
- `0x0e` with no drag under way: the Mac logs "drag not active - ignore request" and sends nothing.
  With a drag under way it sends the drag's contents and cancels the local drag *(static analysis)*.

## Curtain mode

The Mac's own screen shows a padlock and a note while the viewer goes on working in the session.
Sources: rootshell-vnc's `AppleCurtainProtocol`, `screensharingd`'s
`HandleChangeSessionVisibilityMessage` and ScreensharingAgent's `EncodeDisplayInfo2ForDaemon`
*(static analysis)*, then the VM's screen captured from its host.

- **Message 12**: `0c 00 | u16 visible | u16 note length | note`. `visible` 0 raises the curtain; any
  other value lowers it, and the note is then unused. The note is UTF-8 without a NUL ("Back soon —
  Café ☕" appeared intact). Over 512 bytes the Mac logs "Session message too large - closing
  connection." and closes.
- The Mac never answers; its next layout, within 2 s, shows the result (flag `0x02`; see
  [Layouts](#layouts-0x451)).
- **Remote Management is what offers it.** With only Screen Sharing on, Standard's layout flags were
  `0x4` and the bitmap left out `0x0c`; the daemon refuses anyway ("remote management not enabled").
  Turned on with `kickstart -activate -configure -access -on -privs -all -allowAccessFor -allUsers
  -restart -agent`, the flags became `0x6` and the bitmap listed `0x0c`. (`kickstart -deactivate
  -configure -access -off` turns Screen Sharing off as well.)
- **Raised in Standard mode**, the layout's flags became `0x3` under a new screen id; the Mac's screen
  showed the padlock and the note while the session showed the desktop, and input still reached it.
- **Lowering it** returns the session to the console, locked (flags `0xc`); the viewer's password
  unlocks it. Ending the session while curtained lowers it within 5 s, to the same lock screen.
- **Not in High Performance.** Sent anyway on a virtual display it was obeyed (flags `0x3`, new ports,
  an answered offer), but no picture came, and after the viewer left its virtual display stayed with
  the Mac's own screen dark until the Mac restarted. The layout does not offer it there.

## Status and liveness

- **`MiscStatus` 4 is the heartbeat**: every 2.1 s while nothing else is sent, in both modes. Over 75 s
  idle the longest time without any byte was 4.2 s (in Standard, statuses wait behind a large picture
  but bytes keep coming). A connection silent for 15 s can be treated as lost.
- `MiscStatus` 2: the Mac's pasteboard changed. `MiscStatus` 12: the pointer is shown; at the Login
  Window it repeats every 2 s in place of the heartbeat. A status 12 also came right after connecting
  to an awake Mac, together with a brief secure-input notice.
- **Network wake.** With the Mac mini asleep (system sleep after 1 minute, wake for network access
  on), the first connection woke it. The Mac's power log shows a dark wake "due to … enet" 1–2 s
  after the first attempt and a full wake about 9–10 s later; TCP is accepted only at the full wake,
  9–11 s after the first attempt. Logging in took another 1.7 s, and High Performance's first picture
  came 11.2 s after that (the Mac logged "time to wake displays 7461" ms). A ping is answered
  throughout, so it says nothing about the wake. A viewer's connect timeout must allow for this.

## Servers that are not Macs: wayshare

wayshare shares a Hyprland desktop on Linux with Screen Sharing.app. Run from source with
`--test-pattern` (an animated picture, no input, High Performance off) and its debug log
(`RUST_LOG=debug`), it differs from a Mac as follows:

| | wayshare | A Mac |
|---|---|---|
| Security types | `[36]` (`[36, 30]` in a development mode) | `[30, 33, 36, 35]` |
| SRP message 1 | **No second type byte**; Screen Sharing.app sends it that way to wayshare | The type byte again when read apart from the login type; without it a Mac then closes the connection (see [SRP login](#srp-login-type-36)) |
| Names in message 1 | Takes I, or U if I is empty; Screen Sharing.app sends U empty | Needs both |
| Group | RFC 5054's **2048-bit** group, g = 2, numbers padded to 256 bytes | 4096-bit, g = 5 |
| Iterations, salt | 20,000 by default, 16-byte salt | 156,250, 32-byte salt |
| Options (L) | The Mac's, plus `,maxbuffersize=65536` | See above |
| Refused proof | `00 00 00 01 00`, then the connection closes; an unknown name fails the same way | Result word `1` |
| ServerInit flags | `0x20`: one display, without the `0x10` "extended" bit and without "may control"; the zero word and the bitmap are there | `0x52` and more |
| Accepted messages | `0 2 3 4 5 6 9 33`, plus `18` (SetEncryption) only with `--stream-encryption` | Many, `18` always |
| Record layer | **Off by default**: pictures, the pasteboard and input go in clear. Screen Sharing.app then encrypts its input as `0x10` blocks under the login key instead *(from wayshare's source)*. With `--stream-encryption` the rekey and records work as a Mac's. | Always offered |
| `SetEncryption 2` | Must come after the rekey has arrived; sent back to back with `SetEncryption 1` the connection closes ("client turned on stream decryption before 18 keys were sent") | Back to back is fine |
| Option and Command | Alt is Option; Meta and Super are both Command | Meta is Option |

A server that offers neither type 30 nor 33 can be treated as not a Mac. Everything above was checked
with Marionette's client: SRP login with and without the record layer, 140–190 pictures in 5 s, typed
text and keys as listed, and a wrong password and an unknown name refused. The 3072-bit group was not
seen on any server.

## A Mac as a plain VNC server

A viewer that answers the Mac's `003.889` with `003.008` (LibVNCClient does) gets plain RFB:

- Option is `Meta_L`/`Meta_R` here too: Meta with Delete deletes a word. `Alt_L`, `Alt_R`, `Super_L`
  and `Hyper_L` are all Command (with Delete they delete the line). `Mode_switch` and
  `ISO_Level3_Shift` do nothing.
- Right button is bit 2 (mask 4 opens the desktop's context menu); bit 1 is not a right click.
- Input in the first two seconds after the login is dropped, as on Apple's protocol.
- A held key does not repeat; characters beyond U+FFFF need surrogates (see [Keys](#keys)).
- Copying text on the Mac sent no ServerCutText within a few seconds.
- `SetPixelFormat` takes 16 or 32 bits a pixel only. Asked for 8 (true colour, 3/3/2 bits) the Mac
  logs "Only 16 or 32 bit pixels supported" and closes the connection (macOS 27; Mac log).

## Open questions

- **The Mac's pointer position on a Mac with a GPU.** Screen Sharing.app gets about 60 positions a
  second on the Mac mini; Marionette's client gets none unless the session started with the Mac
  asleep. What is known:
  - The Mac log shows the agent handing every position to the daemon for every viewer ("set curent
    mouse to …"), so the filter is in `screensharingd`'s per-viewer sending.
  - In `screensharingd` (macOS 27 and 15.6 alike) a position is sent only if the viewer listed
    `0x44c`, a position is pending, the viewer is not in exclusive control, a "screen update was
    sent" condition holds, and the position lies inside the area shown to that viewer. That area
    starts empty on each pass of the update loop and is filled on the branch that logs "set display
    index to %d" (after a `SetDisplay`) and on one other path *(static analysis)*.
  - The "screen update was sent" condition is set at the end of the scaled and full-screen send
    routes, while Adaptive updates on a Mac with a GPU go through the agent's own route ("unscaled
    opencl"), which skips it. A VM has no such route ("agent doesn't support opencl"), which would
    explain why the VM always sends positions *(static analysis)*.
  - Ruled out, each with a hand on the Mac's mouse: starting with `SetDisplay` all as Screen
    Sharing.app does, one display shown, the Mac unlocked at connect, pixel depth 32, Apple's
    ViewerInfo version, no pointer events from the viewer.
  - Next step: have the proxy change one thing at a time in what Screen Sharing.app sends until its
    positions stop. Each experiment needs someone at the Mac.
- `0x15` (accessibility), `0x23` and `0x51` are advertised by Apple's viewer as messages it accepts;
  none was seen in a capture.
- Session-select command 1, and the undescribed command 3 offered to a VNC-password guest.
- High Performance from wayshare on a real Hyprland output.

## Tools

`marionettectl proxy <mac> --output DIR [--listen 55900]` stands in for the Mac on 127.0.0.1. Screen
Sharing.app logs in to it with type 30, which the proxy can read; the proxy logs in to the Mac with
SRP under the same name and password, then relays everything, decrypting each direction with its own
keys, re-encrypting for the other side and rewrapping `0x10` input events. Each connection gets
`DIR/NN/` with `viewer-to-mac.bin` and `mac-to-viewer.bin` (plaintext, end to end) and `log.txt`
(when each piece arrived). Open `vnc://user:password@127.0.0.1:55900`; Screen Sharing warns that it
cannot verify the server, drops that first connection and connects again after Continue.

- High Performance media flows directly between the Mac and the viewer, so the proxy sees only the
  control channel.
- The clear phase must be passed on byte for byte as it arrives: holding back a tail stalled session
  select, whose offer ends in zeros like the start of the rekey header.
- A session-select answer has its credential block re-encrypted for the Mac's login.

UniversalHID's report descriptor and reports come from Apple's own encoder: a small Swift program
that declares `DigitizerReport`, `DigitizerContact` and `HIDReport` from the framework's exported
symbols (each a `@frozen` struct around one `Data`) and calls them. The framework is private, so it
links against a `.tbd` listing those symbols. `marionettectl session --script` has a `touch:` step
for the Mac's side.

Other `marionettectl` commands that help: `probe` (what a Mac says about itself), `session --trace
--stats` (each set-up step and media event), `session --loss/--burst/--bandwidth/--delay` (seeded
network impairment), `session --script` (scripted input, including raw messages) and `transfer`.

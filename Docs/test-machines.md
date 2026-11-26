# Test machines

What the [live tests](testing.md#live-tests) expect of the machines they connect to. Nothing here is
needed for the unit tests or the UI tests.

## A Mac

Any Mac serves: a virtual machine (UTM with Apple Virtualization works) or a real one.

- Turn on **Screen Sharing** and **Remote Login** (System Settings › General › Sharing) for an account
  that has a password. Save its address, account and password with `Scripts/set-test-host.sh`.
- Give a virtual machine automatic login, so that it is back at its desktop after a restart, and a
  network the simulators can reach. A physical device cannot reach a host-only network; bridge the
  VM for device testing.
- A VM beside the simulators is short of CPU. With several simulators booted, logins take five times
  as long and High Performance sessions time out. Boot one simulator for live work and look at the
  host's load before trusting a timing.

A VM stands in for a real Mac in most things, High Performance and two virtual displays included.
Touches need macOS 27.3 or later; on an earlier Mac the touch test cancels itself. These need a real
Mac:

- two physical displays, and virtual displays larger than a VM accepts;
- the Mac's own pointer position on a Mac with a GPU (see the protocol reference's open questions);
- HDR, and sound quality under load;
- anything that depends on sleep and wake.

### A second account, for session select

Session-select tests log in as someone other than the person at the Mac's screen
(`MARIONETTE_TEST_USER2`, `MARIONETTE_TEST_PASSWORD2`).

- Create a second standard account and let it use Screen Sharing:
  `sudo dseditgroup -o edit -a <account> -t user com.apple.access_screensharing`. Without this its
  login fails exactly like a wrong password.
- The Mac offers the choice only to an account other than the one at its screen. Restart the Mac if
  a test leaves the second account logged in at the console.

### The desktop, for drag tests

Nothing in the protocol says where an icon is, so the tests that drag a file off the Mac press on a
position. They expect the first account's desktop to be sorted by name (View › Sort By › Name) and to
hold exactly:

| Item | What |
|---|---|
| `dnd` | A folder holding `mac-note.txt` and a folder `mac-folder` |
| `wfh-batch` | A folder |
| `wfh-drag-test.txt` | A file of 400,001 bytes |
| `wfh-transfer-test.txt` | A small text file |

That puts `wfh-drag-test.txt` third in the column on the right. On a 2048 × 1536 pixel display it is
93.5 % across and 38.1 % down, and `dnd` is 9.3 % down. On another display, take a picture with
`marionettectl screenshot` and pass the positions in `MARIONETTE_DRAG_POSITION` and
`MARIONETTE_DROP_FOLDER_POSITION`; the package test
`aFileDraggedOnTheMacIsTakenOverAndFetched` has the position in its source.

A stray file on the desktop shifts the column and fails these tests. Check the desktop before blaming
the code.

### Other services

- **Curtain mode** is offered only with Remote Management on, not with Screen Sharing alone.
- AppleScript that controls an app (Finder, System Events) is refused over SSH until someone at the
  Mac allows it. `pbpaste`, `open`, `defaults` and `log show` need no approval.
- Running a developer tool such as `strings` on a Mac without the command line tools raises an
  install dialog on its screen. Copy the file to the development Mac and examine it there.

### macOS 15

The Screen Sharing daemon of macOS 15.6 can hang for good: it logs "SRP invalid step" in a loop and
uses a full core, and no viewer can log in. A viewer that sends the SRP login type and message 1
apart, and has them arrive together, causes it (see the protocol reference's SRP login); Marionette
sends them in one write, but an experimental client can still trigger it. Restart the service at the
Mac:

```
sudo launchctl kickstart -k system/com.apple.screensharing
```

A Mac that sleeps is woken by the first connection, which may then take longer than usual; SSH wakes
it too.

## A VNC server that is not a Mac

`MARIONETTE_TEST_VNC_ADDRESS` (`host:port`) and `MARIONETTE_TEST_VNC_PASSWORD` name one. On Ubuntu:

```
sudo apt install tigervnc-standalone-server tigervnc-tools xterm
vncpasswd                      # writes ~/.vnc/passwd
Xtigervnc :7 -geometry 1280x800 -depth 24 -rfbauth ~/.vnc/passwd -SecurityTypes VncAuth -localhost=0 -AlwaysShared &
DISPLAY=:7 xterm &             # something to look at and type into
```

That serves display `:7` on port 5907, without encryption, which the app labels Not Secure.
`xdotool` and `xclip` on the same display check what arrived.

Two more servers are worth a look after changing the VNC back end:

- **QEMU's built-in server** is a second implementation with its own quirks:
  `qemu-system-aarch64 -M virt -m 512 -device ramfb -vnc 0.0.0.0:5 -S` serves port 5905 with no
  guest running.
- **[wayshare](https://github.com/wesleygrimes/wayshare)** speaks Apple's protocol from Linux. Build
  it with `cargo build --release`, add a user as its README describes, and run
  `./target/release/wayshare --test-pattern --no-mdns --no-rdp --stream-encryption --listen 0.0.0.0:5900`.
  Without `--stream-encryption` it does not encrypt the session and Marionette refuses it. How it
  differs from a Mac is in the [protocol reference](protocol/apple-screen-sharing.md#servers-that-are-not-macs-wayshare).

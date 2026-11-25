# Coding guide

How code in this repository is written. Follow the surrounding code where this guide is silent.

## Design

Marionette follows Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines).
Check the relevant HIG page before designing a screen or control, and prefer the system's own
components, placements and behaviours over custom ones.

Where a behaviour is a choice (what a gesture does, what a command is called, which mode is the
default), do what the Screen Sharing app on a Mac does.

When the system offers no API for something, leave the feature out; do not work around the system.

- **Views are thin.** A view takes a model (`SessionModel`, `AppEnvironment`) and calls its intent
  methods. Logic lives in `MarionetteKit` and below, where it can be unit-tested; the app target has
  no view models of its own.
- **Navigation.** A session is a full-screen cover over the library. Every sheet has its own
  `NavigationStack` with an inline title and Done/Cancel in `.confirmationAction`/`.cancellationAction`.
  A sheet with unsaved changes disables interactive dismissal and asks before discarding.
- **Toolbars.** Primary actions go in `.topBarTrailing`, the rest in `.secondaryAction`; session
  details live in the title menu. The iPad menu bar (`MarionetteCommands`) and the session's control
  strip offer the same commands.
- **Glass** is for floating chrome only. Content surfaces, such as key caps and the input deck, are
  opaque. Chrome laid over the remote picture uses the dark colour scheme.
- **iPhone Duo.** Only `SessionArrangement` and `FoldContext` touch fold APIs, behind
  `#available(iOS 27.1, *)` with a fallback that has the same children. Read the pose from
  `reservedRegions(kind: .division)`, never from the hinge angle.

### Wording

- Keep text short. Before explaining a control in words, ask whether the control could explain
  itself. Settings are not help pages.
- Text does not change with state unless it must, as in an error message.
- A menu or button title fits on one line.

### Accessibility

- Every interactive element has a stable kebab-case `accessibilityIdentifier` (`remote-display`,
  `computer-\(name)`). UI tests find elements by identifier, never by label.
- Icon-only buttons have an `accessibilityLabel`; state goes in `accessibilityValue`; hints are full
  sentences. Decorative images are hidden from accessibility.
- Announce state changes the user cannot see (a transfer finishing) with
  `AccessibilityNotification.Announcement`.
- Support Dynamic Type everywhere: switch row layouts at accessibility sizes, let text wrap, use
  `ViewThatFits` for overflow. Where a bar piece must stay small, cap its size and add the large
  content viewer.
- Gate every animation on Reduce Motion.
- Never convey meaning by colour alone. Custom colours are defined once in a `Color` extension and
  checked for contrast in light and dark.

## SwiftUI and UIKit

- `updateUIView` only records what changed. A UIKit call that makes the system lay out or ask for
  input views again (`reloadInputViews`, `becomeFirstResponder`) runs on the next turn of the main
  queue; called inside the update it re-enters SwiftUI's graph and the app freezes.
- A view that must not take touches is removed from the tree, not left at zero opacity.
- A `confirmationDialog` or popover for one item of a collection is attached to that item, so that
  it points at it on iPad.

## Swift

- Swift 6 language mode with complete concurrency checking. Packages target iOS, macOS and visionOS 26.
- **Value types by default.** Data is `Sendable, Hashable` (and `Codable` when stored) structs. Use
  classes for shared state and identity, and actors for components that own non-thread-safe state
  (a connection, a protocol engine).
- **Observable models** are `@MainActor @Observable final class`. Expose state as
  `public private(set)`; mark state the UI does not read `@ObservationIgnored`.
- **Shared mutable state** in a `Sendable` class sits in a `Mutex` from Synchronization around a private
  `State` struct. Collect continuations inside the lock and resume them outside it.
  `@unchecked Sendable` needs a comment stating the invariant that makes it safe.
- **Stale async results** are dropped with a generation token: capture it with `[weak self]`, then
  check `guard let self, self.attempt == token, !Task.isCancelled` after every `await`.
- **Errors** are `enum`s conforming to `Error, Sendable, Hashable`, thrown with typed throws
  (`throws(ConnectionFailure)`). Translate lower-layer errors into the caller's vocabulary at the
  boundary. User-facing wording is kept apart from the error, in presentation extensions.
- **Optional features** are `Capability<Value>`: either available with an object, or unavailable
  with a reason. Front ends build their controls from capabilities alone, never from the back end's
  identity.
- **Units are in the types.** Remote pixels and local points are different types (`PixelSize`,
  `ViewSize`). Use physical left and right for remote geometry, never leading and trailing.
- **Inject what varies.** Time comes from an injected clock, randomness from an injected source, and
  platform services (keychain, pasteboard, discovery) through `Sendable` protocols. Each protocol has a
  live implementation and an in-memory one in the same file; the in-memory ones serve both tests and
  the app's simulated scenarios. Dependencies are passed in a `Dependencies` struct. There are no
  singletons outside the app target.
- **Timing constants** live together in one struct (for example `SessionTiming`), each documented with
  the measured behaviour behind it, so tests can shorten them.
- **Untrusted input is bounded before it is used.** A parser checks a `maximum…` limit before it
  allocates or waits, reads through bounded sub-readers, and returns or throws on malformed input,
  never traps.
- **Protocol code has no I/O.** Messages are value types with `parse(_:)` and an encoder; connections
  and engines sit on top.
- **Imports.** Use `public import` for a module whose types appear in public API, plain `import`
  otherwise. Test-support targets use `package` access.
- **Logging.** One `os.Logger` per module, subsystem `llc.turing.Marionette`, with addresses and user
  data marked `.private`. Queue labels are `llc.turing.Marionette.*`.
- **Localization.** Every string the user sees is `String(localized: "…", bundle: #bundle)` (or a
  `LocalizedStringKey` literal in a view), with a String Catalog per target. Write whole sentences per
  variant and use the catalog's plural variations; never build a sentence from fragments. Identifiers,
  file names and diagnostics are not localized. Use typographic quotes and apostrophes.
  - Interpolate text. A value that is not text, such as an `Error`, compiles with a warning and
    puts its debug description in front of the user; convert it first.
  - `#bundle` cannot be a public default argument; take an optional and resolve it in the body.
  - Xcode updates the catalogs when it builds. After a build from the command line, run
    `Scripts/sync-string-catalogs.py`.

## Dependencies

- Choose third-party libraries for being well established: long-lived, widely used and actively
  maintained. Licence is not a selection criterion; the project takes the most permissive licence its
  dependencies allow.
- Third-party source is never copied in. C libraries are git submodules pinned to release tags and
  compiled by SwiftPM from an explicit source list; OpenSSL is built by `Scripts/build-deps.sh` into an
  xcframework.
- Wrap a C library in its own Swift package (`SwiftSSH2`, `SwiftSRTP`, `SwiftVNCClient`) with its own
  tests before anything depends on it. The package has a hand-written `config/` header and a `shim/`
  that exposes narrow `marionette_`-prefixed functions in place of macros and variadic calls. A
  library that is not thread-safe gets its own serial queue or thread.
- Code adapted from another project names it, its licence and its copyright holder in the file header,
  and is listed in `NOTICE`.

## Files

Every file starts with the copyright line and an SPDX licence identifier (after
`// swift-tools-version:` in a manifest):

```swift
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
```

Use `GPL-3.0-or-later` for code that links LibVNCClient (`SwiftVNCClient`, the app) and Apache-2.0
for everything else. Attribution for adapted work follows after a `//` line.

Group a file with `// MARK: - Section` and a type's members with `// MARK: Topic`.

## Comments

Comments are documentation, not notes. Each one must tell the reader something the code cannot.

**Write**

- `///` documentation on types and members that others call: what it does or represents, parameters,
  units, invariants and gotchas. It appears in Xcode's Quick Help and drives navigation. Link symbols
  with DocC double backticks.
- Inline comments that explain a gotcha; an unintuitive choice or workaround found by debugging,
  stated as its reason; complex logic or an algorithm; or the rationale for a behaviour or constant
  ("a Mac discards input for about 2 s after a login, measured").

**Don't write**

- Comments that restate what the code does. If a reader gets the same information from the names
  and the code in a few seconds, the comment goes. A `///` that only paraphrases the declaration's
  name goes too.
- Explanations of system or framework behaviour that the documentation covers, or of standard
  practice.
- Alternatives considered, approaches decided against, or plans ("could also…", "if we ever…").
- History: what was removed, what something used to do, how a bug was found, dates, ticket numbers.
  The reason stays; the story goes.

Write in the present tense, briefly, in British English, with units on every measurement.

## Documentation

Documents under `Docs/` are reference: organised by topic, in the present tense, and held to the
rules for comments above. They carry no progress logs, dates, plans or development history, and
nothing a reader gets as easily from the code. A fact about Apple's protocol goes in the
[protocol reference](protocol/apple-screen-sharing.md) with how it is known, and is taken from what a
Mac did, not from this code.

## Testing

See [testing.md](testing.md) for how to run everything.

- Packages use Swift Testing (`@Suite struct`, `@Test`, `#expect`, `#require`); UI tests use XCTest.
- Name a test as a sentence about the behaviour it checks
  (`aLongNoteIsCutBetweenCharacters`). A `///` on a test says why the expectation holds or which bug
  it guards, and only when the name does not.
- Tests are deterministic: seeded random generators, injected clocks and shortened timing constants.
  Poll for a condition with a timeout; never sleep for a fixed time.
- Prefer real or scripted counterparts to mocks: a scripted Mac and a scripted RFB server over
  in-memory pipes, a private `sshd` on the loopback interface, VideoToolbox for real bitstreams.
  Protocol fixtures are captured from real sessions and say where they came from.
- Every back end passes `BackendConformance`, run as parameterised tests against the simulated back
  end, the scripted Mac and, in live runs, a real Mac.
- Fuzz parsers and interpreters with seeded mutations; the rule under test is "return or throw, never
  trap".
- Live tests are opt-in through `MARIONETTE_TEST_*` environment variables and are serialised: a Mac
  serves High Performance to one viewer at a time.
- Test-only hooks on production types are documented "For tests." (`waitUntilIdle()`); there are no
  test-only protocols.

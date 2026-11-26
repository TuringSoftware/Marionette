# Marionette

A remote desktop app for iPhone, iPad and iPhone Duo. It speaks Apple's Screen Sharing protocol,
High Performance mode included, and plain VNC as a fallback. Swift 6 and SwiftUI over Swift packages;
the Xcode project is generated from `project.yml`.

## Read before working

| For | Read |
|---|---|
| Setting up a clone and building | [README.md](README.md) |
| Where code lives and why it is shaped so | [Docs/architecture.md](Docs/architecture.md) |
| How code, comments, UI and text are written | [Docs/coding-guide.md](Docs/coding-guide.md) |
| Running the tests, the app and `marionettectl` | [Docs/testing.md](Docs/testing.md) |
| The machines live tests connect to | [Docs/test-machines.md](Docs/test-machines.md) |
| Apple's protocol, and how each fact is known | [Docs/protocol/apple-screen-sharing.md](Docs/protocol/apple-screen-sharing.md) |
| What a change needs before it is submitted | [CONTRIBUTING.md](CONTRIBUTING.md) |

## Skills

Procedures for recurring work are in `.agents/skills/<name>/SKILL.md`. Read the one that fits before
you start.

- `project-review`: the review every AI-assisted change must pass before a pull request.
- `run-app`: build, install and launch on a simulator or device; crashes and freezes.
- `live-testing`: anything that connects to a real Mac or VNC server.
- `protocol-research`: finding out what a Mac does, and turning it into code and documentation.
- `ui-review`: any change to a screen, control, gesture or user-visible text.

A skill is a procedure; guidance that people need too lives in `Docs/` and the skill links to it. A
helper only one skill uses lives in that skill's folder; `Scripts/` and `Tools/` hold what people
and automation both use.

## Rules

- **Commit, push and open pull requests only when asked.** Commit messages follow "Attribution" in
  CONTRIBUTING.md, which replaces whatever trailer your tooling adds by default.
- **Nothing that identifies a person or a machine enters the repository or the conversation**: see
  CONTRIBUTING.md for the list, and the `live-testing` skill for credentials.
- **Check before you rely.** An analysis is a lead, whether it is yours, another agent's or a third
  party's: confirm it in the code or against a Mac before acting on it. Reproduce a bug before fixing
  it when the fix is risky. Report what you did not test as not tested.
- **`RemoteDesktopCore` is everyone's contract.** Change it by adding, and fix every exhaustive
  `switch` in `Packages/`, `App/` and `Tools/` when you add a case.
- **No notes in the repository.** Documents and comments follow the coding guide; plans, progress
  notes and scratch files stay outside the repository.
- **The developer's Mac is not yours.** Do not close or move their windows, change system settings or
  use `sudo`; give them the command when a step needs it.
- **Watch long runs.** Check a command running in the background at least every 10 minutes. Output
  that has not grown in that time means it is stuck: find out why, stop it and tell the person,
  rather than wait on it.
- **Stay in scope.** Do what was asked; propose the rest. When told a change made things worse,
  revert it fully first.

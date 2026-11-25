# Contributing

Thank you for helping with Marionette. Start with the [README](README.md) to build the app and
[Architecture](Docs/architecture.md) to find your way around.

## Submitting a pull request

A pull request is ready when all of this holds:

1. **It follows the [coding guide](Docs/coding-guide.md)**, including its rules for comments, design,
   accessibility and dependencies.
2. **It is tested as [Testing](Docs/testing.md) describes.**
   - `Scripts/test.sh` passes.
   - **The UI tests pass**: the whole suite, on an iPhone and on an iPad simulator. Run them even for
     a change that seems to have nothing to do with the UI.
   - New behaviour comes with tests, and a fixed bug with a test that fails without the fix.
   - A change to a back end, a transport or anything else that talks to a real computer is also run
     through the live tests. Say in the pull request which machine and which macOS it ran against.
3. **What was learned about Apple's protocol is written down** in the
   [protocol reference](Docs/protocol/apple-screen-sharing.md), in the section it belongs to, with
   how it was verified.
4. **It contains nothing that identifies a person or a machine**: no IP or MAC addresses, email
   addresses, account or computer names, device or simulator identifiers, team identifiers or
   provisioning profiles. Examples use `192.0.2.x` addresses and the account `dev`. Fixtures cut from
   captures need a second look, because a capture can hold a name inside compressed data: inflate
   it, replace the name with one of the same length, and compress it again the way it was.
5. **The description says** what changes and why, how it was tested, and what could not be tested
   (for example, anything that needs hardware you do not have).

Keep a pull request to one subject, and its commits to steps that each build and pass the tests.

## AI-assisted contributions

You may use AI tools. You are responsible for every line you submit, exactly as if you had typed it:
read it, understand it and test it before asking anyone else to.

Before opening the pull request you **must** run the project review skill,
[`project-review`](.agents/skills/project-review/SKILL.md), in your agent on the final state of the
branch, and resolve what it reports. Run it again if the branch changes afterwards. The skills in
`.agents/skills/` and the notes in [`AGENTS.md`](AGENTS.md) are there for your agent to use.

### Attribution
When AI tools contribute to development, proper attribution helps track the evolving role of AI in the development process. Note we do NOT use `Co-authored-by` and all commits should remove `Co-authored-by` (as well as any links) that a tool might add automatically. This is to ensure that humans take full responsibility for all code that is written.

Contributions should include an Assisted-by tag in the following format:

```
Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]
```

Where:

* `AGENT_NAME` is the name of the AI tool or framework
* `MODEL_VERSION` is the specific model version used
* `[TOOL1] [TOOL2]` are optional specialized analysis tools used
  (e.g., coccinelle, sparse, smatch, clang-tidy)

Basic development tools (git, gcc, make, editors) should not be listed. Each tool should carry their own attribution tag. If multiple models were used in the main session, each model should also carry their own attribution tag.

Example:

```
Assisted-by: Claude:claude-3-opus coccinelle sparse
```

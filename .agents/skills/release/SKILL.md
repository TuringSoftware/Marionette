---
name: release
description: Release a build of Marionette to App Store Connect (TestFlight) - set the version and build in project.yml, commit and push the change, wait for the GitHub Actions run to pass, download its unsigned archive, then sign and upload it. Use it when asked to release, ship a build, upload to App Store Connect or TestFlight, or bump the version for a release. Takes an optional version and build; by default the version stays and the build goes up by one.
---

# Releasing a build

The workflow, the signing script and the settings they read are described in
[Docs/testing.md](../../../Docs/testing.md) ("Local settings", "Continuous integration and
releases"). Invoking this skill is the
request to commit the version change to `main` and push it; nothing else is committed.

## 1. Before changing anything

- `git status`: on `main`, nothing uncommitted, and `git fetch` shows `main` level with its remote.
  Otherwise stop and say what is in the way.
- `gh auth status` succeeds and `git remote -v` names the GitHub repository.
- `Scripts/sign-archive.sh check upload` passes. If it does not:
  - For each setting it names as missing, ask the person in one message for the path to the App Store
    provisioning profile, the path to the App Store Connect API key (`AuthKey_<key id>.p8`) and the
    issuer ID (App Store Connect › Users and Access › Integrations).
  - Save each answer with `Scripts/env.sh set MARIONETTE_DISTRIBUTION_PROFILE <path>`,
    `… MARIONETTE_ASC_KEY <path>` and `… MARIONETTE_ASC_ISSUER <id>`. This creates `.env` from
    `.env.example` if there is none. Do not repeat the values in your replies.
  - Run the check again. A profile that has expired, is for development or is for another app has to
    be replaced by the person in their developer account; say which, and stop.

## 2. Version and build

`.agents/skills/release/scripts/set-version.sh [version] [build]` edits `project.yml` and prints
`old -> new`. With no arguments the version stays and the build goes up by one, which is the default
unless the person named a version or build. Then run `xcodegen generate`, when no build is using the
project, so the local project matches.

## 3. Commit and push

Commit only `project.yml`, with the message `Set version to <version> (<build>)` and the
`Assisted-by:` line for each model in use, as "Attribution" in CONTRIBUTING.md says (no
`Co-authored-by`). Push `main`, and note the commit's SHA.

## 4. Wait for the run

- `gh run list --workflow build.yml --commit <sha> --json databaseId,status` until the run appears;
  it can take a minute.
- Run `gh run watch <run id> --exit-status --interval 60` in the background and check its output at
  least every 10 minutes. A run without OpenSSL in the cache builds it first, which adds about ten
  minutes.
- If any job fails, the release stops: show the failing step with `gh run view <run id> --log-failed | tail -50`,
  say which job failed, and leave the commit in place. Do not upload an archive from a failed run.

## 5. Download and check the archive

```
gh run download <run id> -n Marionette.xcarchive -D <a new folder in your scratchpad>
unzip -p <folder>/Marionette.xcarchive.zip Marionette.xcarchive/Info.plist > <folder>/Info.plist
plutil -extract ApplicationProperties.CFBundleShortVersionString raw <folder>/Info.plist
plutil -extract ApplicationProperties.CFBundleVersion raw <folder>/Info.plist
```

The version and build must be the ones set in step 2; if they are not, stop.

## 6. Sign and upload

`Scripts/sign-archive.sh upload <folder>/Marionette.xcarchive.zip`. It signs with the App Store profile,
checks the signed app's entitlements, and uploads with the API key. Report the version and build
uploaded, and that App Store Connect processes a build for some minutes before TestFlight lists it.

If the upload fails after the push, the version commit stays as it is: fix the cause and upload the
same archive again, or, if App Store Connect has already taken that build number, run this skill again
for the next one. Never rewrite `main` to undo a pushed version change.

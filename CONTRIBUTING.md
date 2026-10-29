# Contributing

## Setup

```text
brew install swiftlint pre-commit   # swift-format ships with Swift 6
pre-commit install
```

The pre-commit hooks run on every commit (and the tests on every push); CI runs the same
hooks, so a green local run means a green CI run.

## Quality bar

The same as gcpapi-sync-python, in Swift terms:

- `swift format lint --strict` (configuration in `.swift-format`) and SwiftLint with
  **every** opt-in rule, `--strict`. Rules are disabled only where they contradict
  swift-format or idiomatic Swift, each with its reason in `.swiftlint.yml`.
- Swift 6 language mode (complete concurrency checking) with the `ExistentialAny`,
  `InternalImportsByDefault` and `MemberImportVisibility` upcoming features, and **no
  compiler warnings** (`Scripts/check-warnings.sh`).
- **No suppression comments or escape hatches**: no `swiftlint:disable`,
  `swift-format-ignore`, `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency`.
  A hook rejects them; change the code instead.
- No `Any` or `[String: Any]` in the public API: responses are `Codable` models, unknown
  payloads are `JSONValue`.
- Line coverage of at least 99%, on Swift 6.2 to 6.4 on Linux, on macOS and in the iOS
  simulator, and against the lowest supported dependency versions.

## Tests

```text
swift test --filter GCPAPISyncTests                  # everything except live tests
GCPAPI_LIVE_TESTS=1 swift test --filter LiveTests    # against the real API (needs a key)
swift test --enable-code-coverage --filter GCPAPISyncTests
swift run check-coverage "$(swift test --show-codecov-path)" --minimum 99
```

Unit tests talk to an in-process fake API (`Tests/GCPAPISyncTests/Support.swift`). Fixtures
in `Tests/GCPAPISyncTests/Fixtures` are real responses anonymized with `scrub-fixture`, the
same files as in the Python version. Always review a scrubbed fixture before committing it,
and never commit raw responses: they are personal health data.

## Models and API drift

`Sources/GCPAPISync/Models/Generated`, `Tests/GCPAPISyncTests/Generated/ModelSamples.swift`
and `spec/endpoints.json` are written by `swift run generate-models` from the OpenAPI
document embedded in Garmin's Swagger page. Corrections for places where the live API
disagrees with the spec (`extraFields`, `newSchemas`, `fieldSchemas`, ...) are in
`Tools/GenerateModels/Spec.swift`; they are the same tables as in the Python generator, and
`spec/endpoints.json` is byte-identical between the two repositories.

The **API drift** workflow runs every Monday:

1. It regenerates the models and the endpoint surface from Garmin's current spec. If
   anything changed it opens a pull request with the diff, the generator's warnings and the
   test results. `PackageTests` fails when an endpoint appears that no client method wraps,
   or when the client sends a parameter the spec no longer documents.
2. If the `GARMIN_PERSONAL_API_KEY` repository secret is set, it runs the live tests, which
   fail when Garmin returns fields the models do not know or when a request no longer
   decodes. A failure opens an issue labelled `api-drift`.

Personal API keys expire after at most a year; renew the secret before it does.

## Documentation

API documentation is built with DocC from the documentation comments and published to
[camminady.dev/gcpapi-sync-swift](https://camminady.dev/gcpapi-sync-swift/documentation/gcpapisync/)
on every push to `main`. To build it locally:

```text
Scripts/build-docs.sh site
```

## Versioning and releases

Versions are `0.MINOR.YYYYMMDD`, with the same rules as the Python version:

- **`MINOR`** counts releases that change this package. It is bumped at most once per
  release.
- **`YYYYMMDD`** is the date on which the current state of Garmin's API was picked up. It
  changes only when Garmin changes something; our releases keep it.

```text
swift run bump-version feature --note "Add a Keychain token cache"   # our change
swift run bump-version garmin --note "New sleep fields"              # Garmin's change
swift run bump-version show
```

The weekly API-drift pull requests run `garmin` themselves. Every pull request that changes
the package should run `feature` (a test checks that `CHANGELOG.md` describes the version in
`Sources/GCPAPISync/Version.swift`).

**Releasing is merging.** When a new version reaches `main`, the release workflow tests the
package, builds the `gcpapi` tool for Linux and macOS, attests the binaries' build
provenance, then creates the `v<version>` tag and a GitHub release with the binaries. Swift
Package Manager resolves versions from these tags. Versions that already have a tag are
skipped.

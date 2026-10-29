# gcpapi-sync-swift

[![CI](https://github.com/thomascamminady/gcpapi-sync-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/thomascamminady/gcpapi-sync-swift/actions/workflows/ci.yml)
[![API drift](https://github.com/thomascamminady/gcpapi-sync-swift/actions/workflows/drift.yml/badge.svg)](https://github.com/thomascamminady/gcpapi-sync-swift/actions/workflows/drift.yml)
[![Docs](https://img.shields.io/badge/docs-DocC-blue)](https://camminady.dev/gcpapi-sync-swift/documentation/gcpapisync/)
![Swift](https://img.shields.io/badge/Swift-6.2%20%7C%206.3%20%7C%206.4-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20Linux-lightgrey)

An unofficial Swift client and command line tool for the
[Garmin Connect Personal API](https://developer.garmin.com/gc-developer-program/personal/personal-faq/),
the official API that gives you programmatic access to **your own** Garmin data:
activities and their FIT files, sleep, heart rate, HRV, stress, Body Battery, SpO2, steps,
weight, nutrition and more. Built for iOS apps, it runs everywhere Swift does.

This is the Swift port of [gcpapi-sync-python](https://github.com/thomascamminady/gcpapi-sync-python):
the same endpoints, models, corrections, tests and release process, in idiomatic Swift.

> **Disclaimer.** This is a personal, private project. It is not affiliated with, endorsed
> by, or developed on behalf of my employer, Wahoo Fitness, and it is not affiliated with
> or endorsed by Garmin. "Garmin" and "Garmin Connect" are trademarks of Garmin Ltd. or its
> subsidiaries. Use of the API is subject to
> [Garmin's terms](https://www.garmin.com/en-US/legal/terms-of-use/).

## Highlights

- **Every endpoint**, as `async` methods on one `GarminClient`, built for Swift 6 strict
  concurrency (`Sendable` throughout).
- **109 `Codable` models**, generated from Garmin's OpenAPI document and *corrected where
  the live API contradicts it* (see [API quirks](#api-quirks)). No `[String: Any]`: maps
  with known keys are models, intraday series have typed accessors, unknown fields are
  kept in `extraFields`.
- **No dependencies beyond swift-log**: zip extraction, SHA-256 and date handling are
  built in, so the library runs on iOS, macOS, watchOS, tvOS, visionOS and Linux.
- **Authentication handled for you**: API key discovery, the 24-hour token exchange,
  caching (in memory, on disk shared with Garmin's own client and the Python version, or
  your own, such as the Keychain), renewal before expiry and after a rejected token. One
  key exchange is shared by all concurrent requests.
- **Resilient**: retries with exponential backoff and jitter, `Retry-After` support, and a
  precise error hierarchy.
- **No server limits to remember**: date ranges of any length are split to fit each
  endpoint and fetched concurrently; searches of any size are paged.
- **CLI** with everyday commands (`today`, `activities`, incremental FIT `sync`, `export`)
  plus raw JSON for every endpoint.
- **Kept in sync with Garmin**: a weekly job regenerates the models from Garmin's
  published spec and opens a pull request when anything changes.

## Installation

Swift Package Manager:

```text
.package(url: "https://github.com/thomascamminady/gcpapi-sync-swift.git", from: "0.2.20261022")
```

then add `.product(name: "GCPAPISync", package: "gcpapi-sync-swift")` to your target. In
Xcode: *File → Add Package Dependencies…* and paste the repository URL.

Requires Swift 6.2 or newer; iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS 1 or Linux.
API documentation: [camminady.dev/gcpapi-sync-swift](https://camminady.dev/gcpapi-sync-swift/documentation/gcpapisync/).

The `gcpapi` command line tool:

```text
git clone https://github.com/thomascamminady/gcpapi-sync-swift.git && cd gcpapi-sync-swift
swift build -c release && cp .build/release/gcpapi /usr/local/bin/
```

or download a prebuilt binary from the [releases](https://github.com/thomascamminady/gcpapi-sync-swift/releases).

## Getting an API key

1. In [Garmin Connect](https://connect.garmin.com) open **Settings → Personal API** and
   create a key. Garmin shows it only once; keys expire after 30 days to a year.
2. Store it:

   ```text
   gcpapi setup    # prompts for the key (hidden), verifies it, saves it with mode 600
   ```

The client looks for the key in this order: the `apiKey` argument, the `keyFile` argument,
the `GARMIN_PERSONAL_API_KEY` environment variable, and
`~/.config/garmin/connect-personal-api-key` (where `gcpapi setup`, the Python version and
Garmin's own client put it). In an iOS app, keep the key in the Keychain and pass it as
`apiKey`. Never commit the key; this repository's pre-commit hooks refuse to.

## Quick start

```swift
import GCPAPISync

let garmin = try GarminClient()

let runs = try await garmin.searchActivities(
    limit: 5, filters: ActivityFilters(activityType: "running"))
for run in runs {
    let kilometers = (run.distance ?? 0) / 1000
    print(run.startTimeLocal?.date ?? "-", run.activityName ?? "", kilometers)
}

let sleep = try await garmin.getDailySleep("2026-10-21")
if let score = sleep.sleepScores?.overall?.value {
    print("sleep score", score)
}

// 11 requests, returned as one list:
let steps = try await garmin.getDailySteps(start: "2026-01-01", end: "2026-10-21")
print(steps.count)
```

Independent calls run concurrently with `async let`; activities can be streamed page by
page:

```swift
async let sleep = garmin.getDailySleepSummaries(start: "2026-01-01", end: "2026-10-21")
async let hrv = garmin.getDailyHRVSummaries(start: "2026-01-01", end: "2026-10-21")
async let steps = garmin.getDailySteps(start: "2026-01-01", end: "2026-10-21")
let (sleepRecords, hrvRecords, stepRecords) = try await (sleep, hrv, steps)
print(sleepRecords.count, hrvRecords.count, stepRecords.count)

let october = ActivityFilters(startDate: "2026-10-01")
for try await activity in try garmin.iterActivities(filters: october) {
    print(activity.activityId, activity.activityName ?? "")
}
```

## Usage

### Endpoints

Dates are `GarminDate` values or `YYYY-MM-DD` strings; ranges are inclusive.

| Method | Returns | Garmin's limit per request |
| --- | --- | --- |
| `searchActivities(start:limit:filters:)` | `[SummarizedActivity]` | ~45 per page (paged for you) |
| `iterActivities(start:pageSize:filters:)` | `ActivitySequence` (`AsyncSequence`) | |
| `getActivity(_:)` | `ActivitySummary` | |
| `getActivityWorkouts(_:)` | `[ActivityWorkout]` | |
| `downloadActivity(_:)` | `ActivityFile` (original FIT/GPX/TCX) | |
| `downloadActivityZip(_:)` | `Data` (Garmin's zip) | |
| `getDailySummary(_:)` | `UserDailySummary` | |
| `getDailySummaries(start:end:)` | `[UserDailySummaryV2]` | 31 days (split for you) |
| `getDailySleep(_:)` | `DailySleep` | |
| `getDailySleepSummaries(start:end:)` | `[DailySleep]` | 31 days (split for you) |
| `getDailyHeartRate(_:)` | `DailyHeartRate` | |
| `getHeartRateZones(generateDefaults:)` | `[HeartRateZones]` | |
| `getDailyHRV(_:)` | `HrvChart?` | |
| `getDailyHRVSummaries(start:end:)` | `[HrvSummary]` | 365 days (split for you) |
| `getDailyStress(start:end:)` | `[MultiValueWellnessChartItem]` | 28 days (split for you) |
| `getDailySteps(start:end:)` | `[StepsDailyStat]` | 28 days (split for you) |
| `getDailyHydration(start:end:)` | `[UserDailyHydration]` | 31 days (split for you) |
| `getDailyBodyBattery(start:end:chunks:)` | `[BodyBatteryDailyReport]` | 31 days (split for you) |
| `getDailySpO2(_:)` | `DailySpO2AndAcclimation` | |
| `getFitnessAge(_:fullHistoryScan:)` | `FitnessAge` | |
| `getWeightRange(start:end:includeAll:)` | `WeightRange` (weights in grams) | about a year |
| `getWeightEntries(start:end:)` | `[DateWeight]` | currently broken server-side |
| `getEffectiveWeightGoals(start:end:)` | `UserGoalsRange` | |
| `getDailyFoodLogs(_:…)` | `DailyNutritionSummary` | |
| `getMenstrualCycleSummary(_:)` | `MenstrualCycleSummary?` | |
| `getMenstrualCycleDayView(_:today:…)` | `DetailedMenstrualCycleDay?` | |
| `getUserProfileSettings()` | `UserSettings` | |
| `getJSON(_:query:)` | `JSONValue?`, for endpoints not wrapped yet | |

### Searching activities

`ActivityFilters` covers every filter the API supports: dates, activity and event types,
text search, favorites, distance/duration/elevation/power ranges, a geographic
`BoundingBox`, dive parameters, sorting and more.

```swift
let longRuns = try await garmin.searchActivities(
    limit: 100,
    filters: ActivityFilters(
        startDate: "2026-01-01", activityType: "running", sortBy: "distance",
        minDistance: 21_000,
        boundingBox: BoundingBox(north: 50.8, east: 7.2, south: 50.6, west: 7.0)
    )
)
print(longRuns.count)

let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("garmin/fit")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let rides = ActivityFilters(activityType: "cycling")
for try await activity in try garmin.iterActivities(filters: rides) {
    try await garmin.downloadActivity(activity.activityId).save(to: folder)
}
```

### Models

Every response is a `Codable`, `Hashable`, `Sendable` struct conforming to `GarminModel`:

- property names are Garmin's JSON names (already `camelCase`), so Garmin's documentation
  applies unchanged; encoding reproduces Garmin's JSON;
- every property is optional, because Garmin omits and nulls fields freely (only activity
  IDs are required);
- unknown fields are kept in `extraFields`, so API additions never break decoding, and
  `undocumentedFields` lists them;
- timestamps are `Date`s for Garmin's `*GMT` fields and `LocalDateTime` wall-clock readings
  for `*Local` fields, whether Garmin sent ISO strings or epoch milliseconds; calendar days
  are `GarminDate` and times of day `GarminTime`.

Intraday series come as compact rows; typed accessors resolve their columns:

```swift
let heartRate = try await garmin.getDailyHeartRate("2026-10-21")
for sample in heartRate.heartRateSamples() {
    print(sample.timestamp, sample.heartRate ?? 0)
}

let report = try await garmin.getDailyBodyBattery(start: "2026-10-21", end: "2026-10-21").first
let levels = report?.bodyBatterySamples() ?? []
let spo2 = try await garmin.getDailySpO2("2026-10-21").spo2HourlySamples()
print(levels.count, spo2.count)
```

### Errors

```text
GarminError
├── ConfigurationError            no API key found, invalid options
├── InvalidArgumentError          malformed dates, reversed ranges, bad options
└── APIError
    ├── APIConnectionError        network failure (after retries); .isTimeout
    ├── APIStatusError            non-2xx response (after retries); .statusCode, .body, .errorID
    │   ├── BadRequestError       400
    │   ├── AuthenticationError   401: key or token invalid, expired or revoked
    │   ├── PermissionDeniedError 403
    │   ├── NotFoundError         404
    │   ├── RateLimitError        429; .retryAfter
    │   ├── InternalServerError   5xx
    │   └── UnexpectedStatusError any other status
    └── ResponseValidationError   a 2xx response that does not match the models; .raw
```

`GarminError`, `APIError` and `APIStatusError` are protocols, so errors can be caught
individually or as a group:

```swift
do {
    _ = try await garmin.getActivity(42)
} catch let error as NotFoundError {
    print("no such activity", error.errorID ?? "")
} catch let error as RateLimitError {
    print("retry after", error.retryAfter ?? 0)
} catch let error as any APIStatusError {
    print("HTTP", error.statusCode)
}
```

Invalid arguments throw `InvalidArgumentError` before any request is made.

### Configuration

```swift
let configured = try GarminClient(
    keyFile: "~/secrets/garmin.key",
    tokenCache: FileTokenCache(),  // reuse tokens across processes
    timeout: 60,
    retry: try RetryConfig(maxRetries: 5, maxDelay: 30)
)
print(configured)
```

Implement the `TokenCache` protocol to keep tokens elsewhere (the Keychain, a database), and
`HTTPTransport` to send requests your own way. Logs go to a swift-log `Logger` (requests at
`debug`, retries at `info`, problems with key and token files at `warning`); keys and
tokens never appear in logs, errors or `description`s.

## Command line

```text
gcpapi setup                                    # store and verify your API key
gcpapi status                                   # key source, token validity
gcpapi today                                    # steps, HR, stress, Body Battery, sleep, HRV, activities
gcpapi today 2026-10-21 --as-json
gcpapi activities --limit 20 --activity-type running
gcpapi sync ~/garmin/fit --since 2026-01-01     # download new FIT files only
gcpapi export 2026-01-01 2026-10-21 ~/garmin/health
gcpapi get-daily-sleep 2026-10-21               # any client method, as JSON
gcpapi search-activities --limit 5 --min-distance 10000
gcpapi logout                                   # delete the cached token
```

Command and option names may also be written with underscores (`get_daily_sleep`,
`--activity_type`), as in the Python version. `gcpapi --help` and `gcpapi <command> --help`
describe everything.

## API quirks

The client hides a number of places where Garmin's service disagrees with its own
documentation (verified against the live API in October 2026):

- Timestamps are documented as strings but several arrive as epoch milliseconds (sleep,
  weight); several documented objects arrive as plain strings (`ConnectDate`,
  `ConnectTimestamp`, `LocalTime`); the fitness-age endpoint returns an object, not the
  documented array; intraday series are arrays of numbers, not objects.
- Fields documented as non-nullable are frequently `null`, and some undocumented fields are
  returned; both are modeled.
- Range limits differ from the documentation: daily summaries fail with HTTP 500 for ranges
  over roughly 90 days although a year is documented; activity searches fail with HTTP 500
  for pages over about 45 activities, *including the server's own default page size*.
- `GET /weight-service/weight/all/...` answers HTTP 400 for every input.
- Activity downloads require `Accept: application/x-zip-compressed`.

## Versioning

Versions are `0.MINOR.YYYYMMDD`. `MINOR` grows when this package changes (features,
fixes); the date records when the current state of Garmin's API was picked up and changes
only when Garmin changes something. So `0.1.20261022` is followed by `0.1.20261029` if
Garmin changes its API the next week, and by `0.2.20261022` if this package gets a new
feature first. Releases are automatic: every new version merged to `main` is tagged and
released on GitHub, which is how Swift Package Manager finds it. The Python and Swift
versions share the date component: the same date means the same state of Garmin's API.

## Development

```text
git clone git@github.com:thomascamminady/gcpapi-sync-swift.git && cd gcpapi-sync-swift
brew install swiftlint pre-commit && pre-commit install   # swift-format ships with Swift
swift test                                               # unit tests (no network)
GCPAPI_LIVE_TESTS=1 swift test --filter LiveTests        # against the real API with your key
pre-commit run --all-files
```

Models are generated; never edit `Sources/GCPAPISync/Models/Generated` by hand.
Corrections for the live API live in `Tools/GenerateModels/Spec.swift`:

```text
swift run generate-models                          # fetch Garmin's current spec and regenerate
swift run scrub-fixture response.json Tests/GCPAPISyncTests/Fixtures/name.json   # anonymize a fixture
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow and how API drift is detected.

## License

[MIT](LICENSE)

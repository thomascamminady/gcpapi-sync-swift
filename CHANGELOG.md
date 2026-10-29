# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versions are `0.MINOR.YYYYMMDD`: `MINOR` is bumped when this package changes, and the
date records when the current state of Garmin's API was picked up (it changes only when
Garmin changes something). `swift run bump-version` computes the next version. The date
component matches the Python version's: the same date means the same state of Garmin's API.

## [0.1.20261022] - 2026-10-29

### Added

- Swift port of gcpapi-sync-python 0.1.20261022: an `async` `GarminClient` covering every
  endpoint of the Garmin Connect Personal API, for iOS, macOS, tvOS, watchOS, visionOS and
  Linux.
- 109 `Codable` response models generated from Garmin's OpenAPI document, with the same
  corrections as the Python version and typed time-series accessors.
- API key discovery, token exchange, in-memory and file token caches (compatible with
  Garmin's official client and the Python version), renewal before expiry and after
  rejection, one shared exchange for concurrent requests.
- Retries with exponential backoff, jitter and `Retry-After`; a typed error hierarchy.
- Automatic, concurrent splitting of long date ranges and paging of activity searches.
- A dependency-free zip reader for activity downloads.
- The `gcpapi` command line tool: `setup`, `status`, `logout`, `token`, `today`,
  `activities`, `sync`, `export`, and a JSON command for every client method.
- Weekly detection of changes to Garmin's API.

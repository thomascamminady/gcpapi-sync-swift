# ``GCPAPISync``

A typed, `async` client for the Garmin Connect Personal API.

## Overview

The [Garmin Connect Personal API](https://developer.garmin.com/gc-developer-program/personal/personal-faq/)
gives programmatic access to your own Garmin data: activities and their FIT files, sleep,
heart rate, HRV, stress, Body Battery, SpO2, steps, weight, nutrition and more.
``GarminClient`` wraps every endpoint as an `async` method returning `Codable` models.

```swift
import GCPAPISync

let garmin = try GarminClient()
let sleep = try await garmin.getDailySleep("2026-10-21")
let steps = try await garmin.getDailySteps(start: "2026-01-01", end: "2026-10-21")
```

The client discovers the API key (argument, key file, the `GARMIN_PERSONAL_API_KEY`
environment variable, or `~/.config/garmin/connect-personal-api-key`), exchanges it for
24-hour access tokens, retries transient failures, splits long date ranges into the windows
each endpoint accepts and pages activity searches.

This is the Swift port of gcpapi-sync-python. It is a personal project, not affiliated with
Garmin or with the author's employer, Wahoo Fitness.

## Topics

### The client

- ``GarminClient``
- ``ActivityFilters``
- ``BoundingBox``
- ``SortOrder``
- ``ActivitySequence``
- ``ActivityFile``

### Dates and times

- ``DateLike``
- ``GarminDate``
- ``GarminTime``
- ``LocalDateTime``

### Models

- ``GarminModel``
- ``JSONValue``
- ``SeriesRow``
- ``HeartRateSample``
- ``BodyBatterySample``
- ``SpO2Sample``
- ``MonitoringEnvironmentSample``

### Authentication

- ``AccessToken``
- ``TokenCache``
- ``MemoryTokenCache``
- ``FileTokenCache``
- ``APIKeySource``
- ``resolveAPIKey(apiKey:keyFile:environment:logger:)``
- ``locateAPIKey(apiKey:keyFile:environment:logger:)``
- ``saveAPIKey(_:to:overwrite:environment:)``
- ``tokenCacheKey(baseURL:apiKey:)``
- ``ProcessEnvironment``

### Transport and retries

- ``HTTPTransport``
- ``URLSessionTransport``
- ``HTTPRequest``
- ``HTTPResponse``
- ``QueryItem``
- ``TransportError``
- ``RetryConfig``

### Errors

- ``GarminError``
- ``ConfigurationError``
- ``InvalidArgumentError``
- ``FileExistsError``
- ``APIError``
- ``APIConnectionError``
- ``APIStatusError``
- ``BadRequestError``
- ``AuthenticationError``
- ``PermissionDeniedError``
- ``NotFoundError``
- ``RateLimitError``
- ``InternalServerError``
- ``UnexpectedStatusError``
- ``ResponseValidationError``
- ``ErrorBody``

/// Defaults and limits of the Garmin Connect Personal API.
enum Constants {
    static let defaultBaseURL = "https://personal.connectapi.garmin.com"
    static let keyExchangePath = "/personalapitoken-service/personal-api/personal-api-key/token"

    // Same names and locations as Garmin's own client, so both can share one key and token.
    static let apiKeyEnvironmentVariable = "GARMIN_PERSONAL_API_KEY"
    static let baseURLEnvironmentVariable = "GARMIN_PERSONAL_API_BASE_URL"
    static let defaultAPIKeyFile = "~/.config/garmin/connect-personal-api-key"
    static let defaultTokenCacheFile = "~/.config/garmin/connect-personal-api-bearer-token.json"

    static let defaultTimeout = 30.0
    /// Refresh tokens slightly before they expire so in-flight requests never race expiry.
    static let tokenRefreshMargin = 5.0 * 60
    /// Garmin documents a 24 hour lifetime; used only when a token carries no `exp` claim.
    static let fallbackTokenLifetime = 24.0 * 60 * 60

    // Maximum inclusive number of days per request. Garmin answers larger ranges with
    // HTTP 400 (or HTTP 500 for daily summaries, whose documented one-year limit fails
    // in practice beyond roughly 90 days). Longer ranges are split into windows.
    static let maxDaysSteps = 28
    static let maxDaysStress = 28
    static let maxDaysHydration = 31
    static let maxDaysBodyBattery = 31
    static let maxDaysSleep = 31
    static let maxDaysDailySummaries = 31
    static let maxDaysHRV = 365

    // The activity search fails with HTTP 500 for pages larger than about 45 activities,
    // including the server's own default of 99. The client always sends an explicit limit.
    static let defaultActivityPageSize = 20
    static let maxActivityPageSize = 45

    /// Refuse to decompress implausibly large activity archives.
    static let maxActivityFileSize = 512 * 1024 * 1024
}

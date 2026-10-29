# Security

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's
[private vulnerability reporting](https://github.com/thomascamminady/gcpapi-sync-swift/security/advisories/new)
or email thomas@camminady.dev.

## Handling of credentials and data

- API keys are read from an argument, the `GARMIN_PERSONAL_API_KEY` environment variable or
  a key file; `gcpapi setup` stores keys with mode `0600`. Access tokens are cached in
  memory by default, or in a `0600` file when `FileTokenCache` is used. In apps, keep keys
  in the Keychain and implement `TokenCache` with it.
- Keys and tokens never appear in `description`s, mirrors (`dump`), log messages or error
  messages, and the CLI never prints a token.
- The client only sends credentials to the configured API host: it does not follow
  redirects, and `getJSON` rejects paths that could point elsewhere.
- Downloaded archive member names are reduced to their base names before saving, and
  archives are decompressed with a size limit.
- The live tests run in public CI logs and only ever report field names, never values.
- If you suspect a key was exposed, delete it in Garmin Connect (Settings → Personal API),
  which also invalidates every token issued from it.

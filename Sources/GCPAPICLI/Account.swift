import ArgumentParser
import Foundation
import GCPAPISync

private let defaultKeyFile = "~/.config/garmin/connect-personal-api-key"
private let defaultTokenFile = "~/.config/garmin/connect-personal-api-bearer-token.json"

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Store your Personal API key in ~/.config/garmin/connect-personal-api-key.",
        discussion: """
            The key is read from a hidden prompt (or from standard input when piped), checked \
            against Garmin, and saved readable only by you. Create a key in Garmin Connect \
            under Settings > Personal API.
            """
    )

    @Flag(help: "Replace an existing key file.")
    var overwrite = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = CLIContext.current
        let target = context.environment.url(for: defaultKeyFile)
        if FileManager.default.fileExists(atPath: target.path), !overwrite {
            throw CommandError("\(target.path) already exists; pass --overwrite to replace it")
        }
        let key =
            context.console.isTerminal
            ? await context.console.readSecret(prompt: "Garmin Personal API key (input hidden): ")
            : await context.console.readLine()
        guard let key else { throw CommandError("No API key was entered") }
        let token = try await global.client(apiKey: key).getAccessToken()
        let saved = try saveAPIKey(
            key, to: target, overwrite: overwrite, environment: context.environment)
        await context.console.write(
            "Key verified and saved to \(saved.path) "
                + "(token valid until \(Format.utcMinute(token.expiresAt)) UTC)")
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show where the API key comes from and whether it currently works."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = CLIContext.current
        let console = context.console
        let source = try locateAPIKey(
            apiKey: global.apiKey, keyFile: global.keyFile, environment: context.environment,
            logger: context.logger)
        let client = try global.client()
        let isPrivate = source.url.map(fileIsPrivate) ?? true
        await console.write("API host      \(client.baseURL)")
        await console.write(
            "API key       \(source)" + (isPrivate ? "" : " (WARNING: readable by others)"))
        let cache =
            global.noCache ? "disabled" : context.environment.url(for: defaultTokenFile).path
        await console.write("Token cache   \(cache)")
        let token = try await client.getAccessToken()
        let minutes = Int(token.expiresAt.timeIntervalSince(context.now()) / 60)
        await console.write(
            "Access token  valid until \(Format.utcMinute(token.expiresAt)) UTC "
                + "(\(minutes / 60)h \(Format.pad(minutes % 60))m left)")
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout", abstract: "Delete the cached access token.")

    @Flag(name: long("forget-key"), help: "Also delete the stored API key file.")
    var forgetKey = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let context = CLIContext.current
        let cache = FileTokenCache(environment: context.environment)
        try cache.clear()
        await context.console.write("Removed cached token \(cache.url.path)")
        if forgetKey {
            let key = context.environment.url(for: defaultKeyFile)
            if FileManager.default.fileExists(atPath: key.path) {
                try FileManager.default.removeItem(at: key)
            }
            await context.console.write("Removed API key \(key.path)")
        }
    }
}

struct Token: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "token",
        abstract: "Obtain an access token and print when it expires (the token is not shown)."
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let token = try await global.client().getAccessToken()
        try await global.printJSON(["expiresAt": Format.iso(token.expiresAt)])
    }
}

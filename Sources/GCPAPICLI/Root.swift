public import ArgumentParser
import Foundation
import GCPAPISync

/// `gcpapi`: the Garmin Connect Personal API from the command line.
///
/// Everyday commands:
///
///     gcpapi setup                      # store your API key (prompted, never echoed)
///     gcpapi status                     # where the key comes from, token validity
///     gcpapi today                      # steps, sleep, HRV, Body Battery, activities
///     gcpapi activities --limit 20      # recent activities as a table
///     gcpapi sync ~/garmin/fit          # download new activity files (FIT) incrementally
///     gcpapi export 2026-01-01 2026-10-21 ~/garmin/health   # health data as JSON files
///
/// Every client method is also a command that prints its result as JSON:
///
///     gcpapi get-daily-sleep 2026-10-21
///     gcpapi search-activities --limit 5 --activity-type running
public struct GCPAPI: AsyncParsableCommand {
    /// The command's name, help and subcommands.
    public static let configuration = CommandConfiguration(
        commandName: "gcpapi",
        abstract: "Garmin Connect Personal API from the command line.",
        discussion: """
            Every command accepts --api-key, --key-file, --base-url, --no-cache and --indent. \
            Option names may also be written with underscores (--activity_type), and command \
            names too (get_daily_sleep), as in the Python version of this tool.
            """,
        version: packageVersion,
        subcommands: [
            Setup.self, Status.self, Logout.self, Token.self, Today.self, Activities.self,
            Sync.self, Export.self, DownloadActivity.self, DownloadActivityZip.self,
            IterActivities.self,
        ] + jsonCommands
    )

    /// The root command (it only shows help).
    public init() {}

    /// Run `gcpapi` with `arguments` (without the program name) and return the exit code.
    ///
    /// Errors from Garmin, invalid arguments and existing files are reported as
    /// `error: <message>` on standard error with exit code 1.
    public static func main(_ arguments: [String]) async -> Int32 {
        let console = CLIContext.current.console
        do {
            var command = try parseAsRoot(arguments)
            if var asynchronous = command as? any AsyncParsableCommand {
                try await asynchronous.run()
            } else {
                try command.run()
            }
            return 0
        } catch let error as any GarminError {
            await console.note("error: \(error.message)")
            return 1
        } catch {
            let code = exitCode(for: error)
            let message = fullMessage(for: error)
            if code == .success {
                await console.write(message)
            } else {
                await console.note(message)
            }
            return code.rawValue
        }
    }
}

/// An error of the command line tool itself.
struct CommandError: GarminError {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// `snake_case` alias of a kebab-case command name, if different.
func aliases(_ name: String) -> [String] {
    let snake = name.replacingOccurrences(of: "-", with: "_")
    return snake == name ? [] : [snake]
}

func makeConfiguration(
    _ name: String, _ abstract: String, discussion: String = ""
)
    -> CommandConfiguration
{
    CommandConfiguration(
        commandName: name, abstract: abstract, discussion: discussion, aliases: aliases(name))
}

import Foundation
import GCPAPICLI

exit(await GCPAPI.main(Array(CommandLine.arguments.dropFirst())))

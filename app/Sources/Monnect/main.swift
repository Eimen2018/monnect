import Foundation

// Monnect is a menu bar app; setup happens in its own window. The old
// `Monnect init|pair|join|pull|release|status` CLI is gone — scripting goes
// through the URL scheme instead: `open -g monnect://pull`.
if CommandLine.arguments.dropFirst().first == "--version" {
    print(UpdateChecker.currentVersion)
    exit(0)
}

MonnectApp.main()

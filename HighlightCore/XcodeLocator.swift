import Foundation

/// Resolves the installed Xcode the same way xcode-select does, then locates
/// the resources this plugin borrows from it.
nonisolated enum XcodeLocator {
    private static let selectLink = "/var/db/xcode_select_link"
    private static let fallbackDeveloperDir = "/Applications/Xcode.app/Contents/Developer"

    /// The active developer directory (e.g. /Applications/Xcode.app/Contents/Developer).
    /// Candidates are validated by the presence of SourceModel.framework, not
    /// mere existence: xcode-select may point at the Command Line Tools, which
    /// exist but have no SharedFrameworks.
    static func developerDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let resolved = try? fm.destinationOfSymbolicLink(atPath: selectLink) {
            candidates.append(resolved)
        }
        candidates.append(fallbackDeveloperDir)
        for path in candidates {
            let developer = URL(fileURLWithPath: path, isDirectory: true)
            let framework = developer
                .deletingLastPathComponent()
                .appendingPathComponent("SharedFrameworks/SourceModel.framework", isDirectory: true)
            if fm.fileExists(atPath: framework.path) {
                return developer
            }
        }
        return nil
    }

    /// Xcode.app/Contents/SharedFrameworks for the active Xcode.
    static func sharedFrameworksDirectory() -> URL? {
        developerDirectory()?
            .deletingLastPathComponent()
            .appendingPathComponent("SharedFrameworks", isDirectory: true)
    }

    static func sourceModelFrameworkURL() -> URL? {
        sharedFrameworksDirectory()?
            .appendingPathComponent("SourceModel.framework", isDirectory: true)
    }

    /// Xcode's built-in Default color theme for the given appearance.
    static func defaultThemeURL(dark: Bool) -> URL? {
        sharedFrameworksDirectory()?
            .appendingPathComponent("DVTUserInterfaceKit.framework/Versions/A/Resources/FontAndColorThemes", isDirectory: true)
            .appendingPathComponent(dark ? "Default (Dark).xccolortheme" : "Default (Light).xccolortheme")
    }
}

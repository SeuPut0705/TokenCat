import Foundation

/// A throwaway preferences domain for checks and snapshots. `discard()` empties it and deletes its plist; cfprefsd may still
/// write the emptied domain back a moment later, so `sweepLeftovers()` removes those at the next launch of any command.
struct ScratchDefaults {
    /// Every scratch domain is `<prefix>.<UUID>`; the sweep matches these prefixes only.
    static let prefixes = ["dev.seuput.TokenCat.MenuFixtures", "dev.seuput.TokenCat.SettingsSnapshot", "dev.seuput.TokenCat.StatusBarChecks",
                           "dev.seuput.TokenCat.UpdaterCheck", "dev.seuput.TokenCat.check", "TokenCat-check", "TokenCat-live"]
    let name: String
    let defaults: UserDefaults

    init?(_ prefix: String) {
        precondition(Self.prefixes.contains(prefix), "ScratchDefaults prefix \(prefix) must be listed for the sweep")
        name = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        self.defaults = defaults
    }

    func discard() {
        defaults.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(name).plist"))
    }

    private static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences") }

    /// Deletes scratch plists older than a minute (an earlier run's), never a domain a concurrent run may still use.
    static func sweepLeftovers(now: Date = Date()) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".plist") {
            let stem = String(name.dropLast(6))
            guard let dot = stem.lastIndex(of: "."), prefixes.contains(String(stem[..<dot])),
                  UUID(uuidString: String(stem[stem.index(after: dot)...])) != nil else { continue }
            let url = folder.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) > 60 else { continue }
            try? files.removeItem(at: url)
        }
    }
}

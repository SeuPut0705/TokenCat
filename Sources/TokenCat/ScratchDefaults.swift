import Foundation

/// A throwaway preferences domain for checks and snapshots. `discard()` empties it and deletes its plist, so a run leaves no
/// `~/Library/Preferences/<name>.plist` behind (removing the domain alone keeps an empty file there).
struct ScratchDefaults {
    let name: String
    let defaults: UserDefaults

    init?(_ prefix: String) {
        name = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        self.defaults = defaults
    }

    func discard() {
        defaults.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}

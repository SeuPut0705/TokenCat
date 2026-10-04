import Foundation

func runPreferenceChecks() -> [String] {
    let suite = "dev.seuput.TokenCat.check.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["Could not create isolated preference domain"] }
    defer { defaults.removePersistentDomain(forName: suite) }
    var failures: [String] = []
    var checks = 0
    func check(_ valid: @autoclosure () -> Bool, _ description: String) {
        checks += 1
        if !valid() { failures.append(description) }
    }
    defaults.set(["claude", "disk", "codex", "cpu", "memory", "battery", "network"], forKey: "metricOrder")
    defaults.set(["cpu", "claude", "network"], forKey: "visibleMetrics")
    defaults.set(false, forKey: "showRunner")
    defaults.set("tokens", forKey: "animationSource")
    let migrated = Preferences(defaults: defaults)
    check(migrated.order == [.ai, .disk, .cpu, .memory, .battery, .network],
          "Migration changed custom metric order or duplicated the AI item")
    check(migrated.visible == [.cpu, .ai, .network] && !migrated.showRunner && migrated.animationSource == "tokens",
          "Migration lost a visible provider or unrelated user preferences")
    migrated.visible.insert(.battery)
    let reopened = Preferences(defaults: defaults)
    check(reopened.visible == [.cpu, .ai, .network, .battery]
          && reopened.order == migrated.order
          && defaults.stringArray(forKey: "metricOrder")?.contains("claude") == false,
          "Updated preferences did not persist as the migrated format")
    defaults.set(["cpu", "memory"], forKey: "visibleMetrics")
    check(!Preferences(defaults: defaults).visible.contains(.ai),
          "Migration exposed AI when both old provider fields were hidden")
    check(reopened.statusBarLayout == .compact,
          "Existing preferences did not default to the compact menu layout")
    reopened.statusBarLayout = .inline
    check(Preferences(defaults: defaults).statusBarLayout == .inline,
          "Menu layout choice did not persist across reopening")
    print("Preference checks: \(checks - failures.count) PASS / \(failures.count) FAIL / 0 SKIP")
    return failures
}

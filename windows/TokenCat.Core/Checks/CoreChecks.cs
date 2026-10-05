using System.Text;
using System.Text.Json;

namespace TokenCat;

/// WP0's own rules: Json (rule 3), SettingsStore (§7.2), AppPaths and atomic writes (rule 9). Temp folders only.
public static class CoreChecks
{
    public static List<string> Run()
    {
        var c = new Check("Core", "Core: ");
        void check(bool valid, string description) => c.That(valid, description);
        string text(byte[] bytes) => Encoding.UTF8.GetString(bytes);

        // Json: BOM, the settings.json writer, Swift's number casts, Codable names.
        check(Json.Parse([0xEF, 0xBB, 0xBF, .. "{\"a\":1}"u8])?.Field("a")?.Number == 1 && Json.Parse("{"u8) == null
              && Json.Parse("{} x"u8) == null && Json.ParseNode([0xEF, 0xBB, 0xBF, .. "{\"a\":1}"u8])?["a"]?.GetValue<int>() == 1,
              "a UTF-8 BOM is not skipped or invalid JSON is accepted");
        var source = """{"b":{"z":1,"Y":[0.10,1e2,true,"🐱"]},"a":"홍길동 & <x> + 'y' C:/p\\q","A":null,"e":{},"f":[]}"""u8;
        const string sorted = "{\n  \"A\": null,\n  \"a\": \"홍길동 & <x> + 'y' C:/p\\\\q\",\n  \"b\": {\n    \"Y\": [\n      0.10,\n      1e2,\n"
                              + "      true,\n      \"\\uD83D\\uDC31\"\n    ],\n    \"z\": 1\n  },\n  \"e\": {},\n  \"f\": []\n}\n";
        check(text(Json.Write(Json.Parse(source)!.Value)) == sorted && text(Json.Write(Json.ParseNode(source))) == sorted,
              "the settings.json rewrite changed: ordinal keys, LF, 2 spaces, unescaped text, raw numbers, trailing newline");
        var casts = Json.Parse("""{"n":true,"s":"1","x":1e400,"d":2.5,"o":{"k":[]}}"""u8)!.Value;
        check(casts.Field("n")?.Number == null && casts.Field("n")?.Bool == true && casts.Field("s")?.Number == null
              && casts.Field("s")?.Text == "1" && casts.Field("x")?.Number == null && casts.Field("d")?.Number == 2.5
              && casts.Field("o")?.Field("k")?.ValueKind == JsonValueKind.Array && casts.Field("d")?.Field("k") == null,
              "booleans, strings or infinities read as numbers, or a missing field is not null");
        var at = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        var reading = new TokenReading(TokenSource.Claude) { SessionID = "s", ActivityState = TokenActivityState.Input, RequestIDs = ["r"] };
        var encoded = Json.Parse(Json.Serialize(reading))!.Value;
        var decoded = JsonSerializer.Deserialize<TokenReading>(Json.Serialize(reading), Json.Options)!;
        check(encoded.Field("id")?.Text == "claude" && encoded.Field("source")?.Text == "claude" && encoded.Field("sessionID")?.Text == "s"
              && encoded.Field("activityState")?.Text == "input" && encoded.Field("model") == null
              && decoded.Id == "claude" && decoded.SessionID == "s" && decoded.RequestIDs.Contains("r")
              && text(Json.Serialize(TelemetryCollectorState.BusyTokenCat)) == "\"busyTokenCat\"\n"
              && text(Json.Serialize(ClaudeUsageLimits.Empty)) == "{}\n"
              && text(Json.Serialize(new ClaudeUsageLimits(new ClaudeLimitWindow(42, null, at)))) is var limits
              && limits.Contains("\"fiveHour\"") && limits.Contains("\"usedPercent\": 42") && !limits.Contains("isEmpty"),
              "model JSON does not use the Swift Codable names");

        var folder = Directory.CreateTempSubdirectory("tokencat-core-checks-");
        try
        {
            // SettingsStore: typed values, unset vs false, removal, a BOM file, and two writers on one file.
            var file = Path.Combine(folder.FullName, "settings.json");
            SettingsStore a = new(file), b = new(file);
            a.Set("animationSource", "cpu");
            b.Set("telemetryDisconnected", true);
            b.Set(ClaudeUsageLimits.DefaultsKey, new ClaudeUsageLimits(new ClaudeLimitWindow(42, null, at)));
            check(a.Get<string>("animationSource") == "cpu" && a.Get<bool?>("telemetryDisconnected") == true && a.Get<bool?>("notifyInput") == null
                  && a.Get<ClaudeUsageLimits>(ClaudeUsageLimits.DefaultsKey)?.FiveHour?.UsedPercent == 42 && a.Get<int?>("animationSource") == null,
                  "settings values do not round-trip, or a value of another type is not read as unset");
            a.Remove("animationSource");
            b.Set<string>("telemetryDisconnected", null);
            check(b.Get<string>("animationSource") == null && a.Get<bool?>("telemetryDisconnected") == null
                  && a.Get<ClaudeUsageLimits>(ClaudeUsageLimits.DefaultsKey) is not null, "Remove or Set(null) does not remove only that key");
            Parallel.Invoke(() => { for (var i = 0; i < 40; i++) a.Set($"a{i}", i); }, () => { for (var i = 0; i < 40; i++) b.Set($"b{i}", i); });
            check(Enumerable.Range(0, 40).All(i => a.Get<int?>($"b{i}") == i && b.Get<int?>($"a{i}") == i),
                  "two stores writing one file drop each other's keys");
            File.WriteAllBytes(file, [0xEF, 0xBB, 0xBF, .. "{\"k\":1}"u8]);
            a.Set("j", 2);
            check(a.Get<int?>("k") == 1 && a.Get<int?>("j") == 2 && !text(File.ReadAllBytes(file)).StartsWith('\uFEFF')
                  && Directory.GetFiles(folder.FullName).Length == 1, "a BOM settings file loses keys, or a temp file is left behind");

            // AppPaths.
            var nested = Path.Combine(folder.FullName, "new", "file.json");
            AppPaths.WriteAtomically(nested, [1]);
            AppPaths.WriteAtomically(nested, [2, 3]);
            check(File.ReadAllBytes(nested) is [2, 3] && Directory.GetFiles(Path.GetDirectoryName(nested)!).Length == 1,
                  "an atomic write does not create, replace or clean up");
            check(!AppPaths.Support.EndsWith(Path.Combine("Application Support", "TokenCat"), StringComparison.Ordinal)
                  && AppPaths.ClaudeDesktopHistory()[0].EndsWith(Path.Combine("Claude", "plan-usage-history.json"), StringComparison.Ordinal)
                  && AppPaths.ClaudeSettings("H") == Path.Combine("H", ".claude", "settings.json"),
                  "a dev run would share the mac app's folder, or a known path moved");
        }
        finally { folder.Delete(true); }
        return c.Done();
    }
}

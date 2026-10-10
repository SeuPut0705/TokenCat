using System.Text.Json;

namespace TokenCat;

/// Account hashes and numeric windows only cross the persistence seam; identities and session routing stay in memory.
public static class ClaudeLimitsByAccount
{
    public const string LegacyKey = "legacy";

    static bool PersistedKey(string key) => key == LegacyKey || key.Length == 16 && key.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    public static IReadOnlyDictionary<string, ClaudeUsageLimits> Merge(IReadOnlyDictionary<string, ClaudeUsageLimits> limits,
        ClaudeUsageLimits value, LimitAccount? account) => Merged(limits, new Dictionary<string, ClaudeUsageLimits>
        { [account?.StorageKey ?? LegacyKey] = value });

    public static IReadOnlyDictionary<string, ClaudeUsageLimits> Merged(IReadOnlyDictionary<string, ClaudeUsageLimits> a,
        IReadOnlyDictionary<string, ClaudeUsageLimits> b)
    {
        var result = a.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        foreach (var (key, value) in b)
            result[key] = result.TryGetValue(key, out var old) ? ClaudeUsage.Merged(old, value) : value;
        return result;
    }

    public static IReadOnlyDictionary<string, ClaudeUsageLimits> Load(SettingsStore store, LimitAccount? defaultAccount)
    {
        var root = store.Get<JsonElement?>(ClaudeUsageLimits.DefaultsKey);
        if (root is not { ValueKind: JsonValueKind.Object } value) return new Dictionary<string, ClaudeUsageLimits>();
        try
        {
            // Legacy window objects deserialize as empty values too: distinguish the key shape before decoding.
            if (value.EnumerateObject().All(property => PersistedKey(property.Name)))
                return (value.Deserialize<Dictionary<string, ClaudeUsageLimits>>(Json.Options) ?? [])
                    .Where(pair => pair.Value is { IsEmpty: false }).ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
            var legacy = value.Deserialize<ClaudeUsageLimits>(Json.Options);
            return legacy is { IsEmpty: false } ? new Dictionary<string, ClaudeUsageLimits>
                { [defaultAccount?.StorageKey ?? LegacyKey] = legacy } : new Dictionary<string, ClaudeUsageLimits>();
        }
        catch (JsonException) { return new Dictionary<string, ClaudeUsageLimits>(); }
    }

    public static void Save(SettingsStore store, IReadOnlyDictionary<string, ClaudeUsageLimits> limits)
    {
        var safe = limits.Where(pair => PersistedKey(pair.Key) && pair.Value is { IsEmpty: false })
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        if (safe.Count == 0) store.Remove(ClaudeUsageLimits.DefaultsKey);
        else store.Set(ClaudeUsageLimits.DefaultsKey, safe);
    }
}

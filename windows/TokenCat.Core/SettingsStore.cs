using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenCat;

/// `UserDefaults` for Windows (DESIGN §7.2): one JSON object file, same key names as the Swift app. A file has no
/// cross-process merge, so every write re-reads the file under a named mutex; the app and a CLI process
/// (`--disconnect-telemetry`) never drop each other's keys.
public sealed class SettingsStore(string path)
{
    public static SettingsStore Shared { get; } = new(Path.Combine(AppPaths.Support, "settings.json"));

    static readonly Mutex WriteLock = new(false, @"Local\dev.seuput.TokenCat.settings");

    /// Missing key, a value of another type or an unreadable file → default. Ask for `bool?`/`int?` to tell "unset" from false/0.
    public T? Get<T>(string key)
    {
        JsonObject? root;
        try { root = Read(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return default; }
        if (root?[key] is not { } value) return default;
        try { return value.Deserialize<T>(Json.Options); }
        catch (JsonException) { return default; }
    }

    /// A null value removes the key, as `UserDefaults.set(nil, …)` does.
    public void Set<T>(string key, T? value) => Edit(root =>
    {
        if (value is null) root.Remove(key);
        else root[key] = JsonSerializer.SerializeToNode(value, Json.Options);
    });

    public void Remove(string key) => Edit(root => root.Remove(key));

    JsonObject? Read()
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var bytes = new MemoryStream();
            file.CopyTo(bytes);
            return Json.ParseNode(bytes.ToArray()) as JsonObject;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return null; }
    }

    void Edit(Action<JsonObject> change)
    {
        try { WriteLock.WaitOne(); }
        catch (AbandonedMutexException) { } // a crashed holder: the mutex is ours now
        try
        {
            var root = Read() ?? [];
            change(root);
            AppPaths.WriteAtomically(path, Json.Write(root));
        }
        // Disk full, read-only or locked: the change is dropped, never thrown into the app. An unreadable file isn't overwritten.
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        finally { WriteLock.ReleaseMutex(); }
    }
}

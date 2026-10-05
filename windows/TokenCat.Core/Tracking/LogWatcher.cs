namespace TokenCat;

/// Wakes token sampling as soon as Codex/Claude logs change. Only paths are delivered; TokenTracker still reads the
/// files. A wake-up hint only (rule 8): on NTFS an open writer's appends may not raise events until the cache flushes,
/// so the 1 s sample with a fresh size query stays the source of truth.
public sealed class LogWatcher(Action<string[]> changed) : IDisposable
{
    readonly Lock gate = new();
    List<FileSystemWatcher> watchers = [];

    /// Watches the existing directories with their subfolders; returns false when none could be watched.
    public bool Start(IEnumerable<string> directories)
    {
        Stop();
        lock (gate)
        {
            foreach (var directory in directories.Where(Directory.Exists))
            {
                var watcher = new FileSystemWatcher(directory)
                {
                    IncludeSubdirectories = true,
                    InternalBufferSize = 65_536,
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
                };
                watcher.Changed += (_, change) => Deliver(watcher, change.FullPath);
                watcher.Created += (_, change) => Deliver(watcher, change.FullPath);
                watcher.Renamed += (_, change) => Deliver(watcher, change.FullPath);
                // Lost events (buffer overflow): an untracked-looking log path makes the tracker rediscover on its next
                // sample. `*` can't appear in a Windows file name, so it never names a real log.
                watcher.Error += (_, _) => Deliver(watcher, Path.Combine(directory, "*.jsonl"));
                try
                {
                    watcher.EnableRaisingEvents = true;
                    watchers.Add(watcher);
                }
                catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException or PlatformNotSupportedException)
                {
                    watcher.Dispose();
                }
            }
            return watchers.Count > 0;
        }
    }

    void Deliver(FileSystemWatcher source, string path)
    {
        lock (gate)
            if (watchers.Contains(source)) changed([path]);
    }

    /// Waits for an in-flight callback, so the handler never runs after this returns.
    public void Stop()
    {
        List<FileSystemWatcher> stopped;
        lock (gate)
        {
            stopped = watchers;
            watchers = [];
        }
        foreach (var watcher in stopped) watcher.Dispose();
    }

    public void Dispose() => Stop();
}

namespace TokenCat;

// WP1 stub (DESIGN §11, FileSystemWatcher; a wake-up hint only, rule 8). WP1 replaces the bodies and owns this file.
public sealed class LogWatcher : IDisposable
{
    public LogWatcher(Action<string[]> changed) => throw new NotImplementedException();
    public bool Start(IEnumerable<string> directories) => throw new NotImplementedException();
    public void Stop() => throw new NotImplementedException();
    public void Dispose() => Stop();
}

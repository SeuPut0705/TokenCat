using System.Globalization;
using System.Security;

namespace TokenCat;

/// Passive, bounded log reader. It never changes any client's configuration or saves transcripts.
/// Which clients and logs it reads comes from the provider registry (`TokenProvider.All`).
/// Not thread-safe, like the Swift original: one caller runs NoteChanged and Sample.
public sealed class TokenTracker
{
    public const double RecentOutputWindow = 600;
    readonly string home;
    readonly Func<string, string?> environment;
    readonly IReadOnlyList<TokenProvider> providers;
    readonly Func<DateTimeOffset> clock;
    readonly int initialTailBytes;
    readonly double discoveryInterval;
    DateTimeOffset? lastDiscovery;
    Dictionary<string, (TokenSource Source, ITokenLogReader Reader)> files = new(StringComparer.Ordinal);
    /// Every log the last discovery listed, inside the caps or not: a write to one the caps left out ranks again at the
    /// periodic rescan instead of rerunning discovery on each file event.
    HashSet<string> known = new(StringComparer.Ordinal);

    public TokenTracker(string home, Func<DateTimeOffset>? now = null, int initialTailBytes = 1_048_576, double discoveryIntervalSeconds = 5,
        Func<string, string?>? environment = null, IReadOnlyList<TokenProvider>? providers = null)
    {
        this.home = Path.TrimEndingDirectorySeparator(Path.GetFullPath(home));
        this.environment = environment ?? Environment.GetEnvironmentVariable;
        this.providers = providers ?? TokenProvider.All;
        clock = now ?? (() => DateTimeOffset.UtcNow);
        this.initialTailBytes = Math.Max(128, initialTailBytes);
        discoveryInterval = discoveryIntervalSeconds;
    }

    /// Candidate roots of every client with a parser, for `LogWatcher`; the watcher and the folder check keep the existing ones.
    public IReadOnlyList<string> WatchedDirectories =>
        [.. providers.Where(provider => provider.Format is not null).SelectMany(provider => provider.Roots(home, environment))];

    /// Clients whose data folder exists, read or not. Touches only the file system, never tracker state.
    public IReadOnlySet<TokenSource> DetectedSources() =>
        providers.Where(provider => provider.ExistingRoots(home, environment).Count > 0).Select(provider => provider.Source).ToHashSet();

    /// Whether a changed path is a log some client's format would list: under one of that client's roots (Windows paths are
    /// matched with `/`, case-insensitively) and accepted by its `IsLog`. A Claude workflow journal is then never a Codex log.
    public bool IsLog(string path)
    {
        var normalized = path.Replace('\\', '/');
        return providers.Any(provider => provider.Format is { } format && format.IsLog(path)
            && provider.Roots(home, environment).Any(root =>
                normalized.StartsWith(Path.TrimEndingDirectorySeparator(root).Replace('\\', '/') + "/", StringComparison.OrdinalIgnoreCase)));
    }

    /// File-system events name changed paths. A log that is not tracked yet triggers
    /// discovery on the next sample instead of waiting for the periodic rescan.
    public void NoteChanged(IEnumerable<string> paths)
    {
        if (paths.Any(path => !files.ContainsKey(path) && !known.Contains(path) && IsLog(path))) lastDiscovery = null;
    }

    public List<TokenReading> Sample()
    {
        var now = clock();
        if (lastDiscovery is not { } last || (now - last).TotalSeconds >= discoveryInterval)
        {
            Discover(now);
            lastDiscovery = now;
        }
        foreach (var file in files.Values) file.Reader.Read(initialTailBytes, now);
        var readings = new List<TokenReading>();
        foreach (var (path, file) in files)
        {
            var relative = path.Length > home.Length + 1 && path.StartsWith(home, StringComparison.Ordinal) && path[home.Length] is '/' or '\\'
                ? path[(home.Length + 1)..] : path;
            readings.AddRange(file.Reader.Readings($"{file.Source.Id}:{relative.Replace('\\', '/')}", now));
        }
        readings.Sort((a, b) =>
            a.Active != b.Active ? (a.Active ? -1 : 1)
            : a.LastActivity != b.LastActivity ? (b.LastActivity ?? DateTimeOffset.MinValue).CompareTo(a.LastActivity ?? DateTimeOffset.MinValue)
            : string.CompareOrdinal(a.Id, b.Id));
        return readings;
    }

    void Discover(DateTimeOffset now)
    {
        var discovery = new TokenDiscovery(now);
        var retained = new HashSet<string>(StringComparer.Ordinal);
        foreach (var provider in providers)
        {
            if (provider.Format is not { } format) continue;
            var roots = provider.ExistingRoots(home, environment);
            if (roots.Count == 0) continue;
            foreach (var path in format.Files(roots, discovery))
            {
                retained.Add(path);
                if (!files.ContainsKey(path)) files[path] = (provider.Source, format.Open(path));
            }
        }
        known = discovery.Known;
        // A quiet session in a turn, or logged within the hour, is not evicted by a burst of
        // newer subagent logs; re-adding it later would restart from a bounded tail.
        foreach (var (path, file) in files.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            if (!retained.Contains(path) && retained.Count < 256 && file.Reader.IsRecent(now) && File.Exists(path)) retained.Add(path);
        files = files.Where(pair => retained.Contains(pair.Key)).ToDictionary(StringComparer.Ordinal);
    }
}

public sealed partial record TokenLogFormat
{
    public static readonly TokenLogFormat Codex = new(CodexFiles, path => path.EndsWith(".jsonl", StringComparison.Ordinal),
        path => new TokenFileCursor(path, TokenSource.Codex));

    public static readonly TokenLogFormat Claude = new(ClaudeFiles, path =>
    {
        // Workflow journals and other side files under subagents/ are never tracked. Windows paths are matched with `/`.
        var normalized = path.Replace('\\', '/');
        return path.EndsWith(".jsonl", StringComparison.Ordinal)
            && (!normalized.Contains("/subagents/", StringComparison.Ordinal)
                || normalized[(normalized.LastIndexOf('/') + 1)..].StartsWith("agent-", StringComparison.Ordinal));
    }, path => new TokenFileCursor(path, TokenSource.Claude));

    static bool IsJsonl(FileSystemInfo entry) => Path.GetExtension(entry.Name) == ".jsonl";
    static bool HasNoExtension(FileSystemInfo entry) => Path.GetExtension(entry.Name).Length == 0;
    static IOrderedEnumerable<FileSystemInfo> Descending(IEnumerable<FileSystemInfo> entries) =>
        entries.OrderByDescending(entry => entry.Name, StringComparer.Ordinal);

    static List<string> CodexFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        // A resumed conversation stays in its original UTC date directory. Select by file
        // modification time across date directories, without reading transcript bodies here.
        var found = new List<FileSystemInfo>();
        foreach (var root in roots)
        {
            var years = TokenDiscovery.Children(root)
                .Where(entry => long.TryParse(entry.Name, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _));
            foreach (var year in Descending(years))
                foreach (var month in Descending(TokenDiscovery.Children(year.FullName)))
                    foreach (var day in Descending(TokenDiscovery.Children(month.FullName)))
                        found.AddRange(TokenDiscovery.Children(day.FullName).Where(IsJsonl));
        }
        return discovery.Recent(found);
    }

    static List<string> ClaudeFiles(IReadOnlyList<string> roots, TokenDiscovery discovery)
    {
        var main = new List<FileSystemInfo>();
        var subagents = new List<FileSystemInfo>();
        foreach (var project in roots.SelectMany(TokenDiscovery.Children))
        {
            var entries = TokenDiscovery.Children(project.FullName);
            main.AddRange(entries.Where(IsJsonl));
            foreach (var session in entries.Where(HasNoExtension))
                subagents.AddRange(ClaudeSubagentFiles(Path.Combine(session.FullName, "subagents"), 2));
        }
        // Workflow agents create many files; they get their own cap so main sessions stay visible.
        return [.. discovery.Recent(main), .. discovery.Recent(subagents, discovery.Now.UtcDateTime.AddHours(-1))];
    }

    static List<FileSystemInfo> ClaudeSubagentFiles(string directory, int remainingDepth)
    {
        var entries = TokenDiscovery.Children(directory);
        var found = entries.Where(entry => IsJsonl(entry) && entry.Name.StartsWith("agent-", StringComparison.Ordinal)).ToList();
        if (remainingDepth > 0)
            foreach (var child in entries.Where(HasNoExtension)) found.AddRange(ClaudeSubagentFiles(child.FullName, remainingDepth - 1));
        return found;
    }
}

sealed class TokenFileCursor(string path, TokenSource source) : ITokenLogReader
{
    public string Path { get; } = path;
    public TokenLogParser Parser { get; private set; } = NewParser(path, source);
    /// Claude subagent type from `<log>.meta.json`; only `agentType` is kept.
    public string? SidecarRole { get; private set; }
    long offset;
    long identity;
    bool initialized;
    MemoryStream pending = new();
    bool droppingLine;
    const int MaximumLineBytes = 1_048_576;
    const FileShare Sharing = FileShare.ReadWrite | FileShare.Delete; // rule 8: never block the writer's appends or renames

    /// The sidecar may be written after the log, so it is retried while the log grows.
    /// Its other keys (task description, worktree path) are never kept.
    void ReadSidecar()
    {
        if (SidecarRole is not null || Parser.Source != TokenSource.Claude || !Parser.IsSubagent) return;
        var sidecar = System.IO.Path.ChangeExtension(Path, ".meta.json");
        try
        {
            if (new FileInfo(sidecar) is not { Exists: true, Length: <= 16_384 }) return;
            using var stream = new FileStream(sidecar, FileMode.Open, FileAccess.Read, Sharing);
            var data = new byte[stream.Length];
            stream.ReadExactly(data);
            SidecarRole = TokenLogParser.Label(TokenLogParser.Record(data)?.Field("agentType"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// Codex names each rollout after its own thread; a forked log also carries the parent's
    /// session_meta, so the filename decides which one is this log's identity.
    static TokenLogParser NewParser(string path, TokenSource source)
    {
        var name = System.IO.Path.GetFileNameWithoutExtension(path);
        var suffix = name.Length > 36 ? name[^36..] : name;
        var ownSession = source == TokenSource.Codex && Guid.TryParseExact(suffix, "D", out _) ? suffix.ToLowerInvariant() : null;
        return new TokenLogParser(source, source == TokenSource.Claude && path.Replace('\\', '/').Contains("/subagents/", StringComparison.Ordinal),
            ownSession);
    }

    public bool IsRecent(DateTimeOffset now) => Parser.IsRecent(now);

    /// One row once the log showed activity, none before.
    public IEnumerable<TokenReading> Readings(string id, DateTimeOffset now)
    {
        var parser = Parser;
        if (parser.LastActivity is null) return [];
        var completion = parser.Completion;
        var tool = parser.RunningTool;
        return [new TokenReading(parser.Source, id)
        {
            SessionID = parser.SessionID,
            ParentSessionID = parser.ParentSessionID,
            AgentID = parser.AgentID,
            Project = parser.Project,
            ProjectPath = parser.ProjectPath,
            IsSubagent = parser.IsSubagent,
            AgentRole = SidecarRole ?? parser.AgentRole,
            Effort = parser.Effort,
            LastTurnDurationSeconds = parser.LastTurnDuration,
            ToolName = tool?.Name,
            ToolCategory = tool is { } running ? running.Name is { } name ? TokenLogParser.Category(name) : ToolCategory.Other : null,
            Retry = parser.Retry,
            RateLimit = parser.RateLimit,
            Context = parser.Context,
            Model = parser.Model ?? completion?.Model,
            LastActivity = parser.LastActivity,
            LastLogAt = parser.LastLogAt,
            MeasurementAt = completion?.FinishedAt ?? parser.LastActivity,
            Active = parser.IsActive(now),
            ActivityState = parser.ActivityState(now),
            CurrentTurnStartedAt = parser.CurrentTurnStartedAt,
            CurrentTurnOutputTokens = parser.CurrentTurnOutputTokens,
            LastOutputAt = parser.LastOutputAt,
            LastOutputDelta = parser.LastOutputDelta,
            RequestIDs = [.. parser.RequestIDs],
            RecentOutputs = [.. parser.RecentOutputs.Where(e => (now - e.At).TotalSeconds is >= -5 and <= TokenTracker.RecentOutputWindow)],
            SampledAt = now,
            // Output of the last fully observed completed turn; its duration is a separate field.
            LastOutputTokens = completion?.Output,
        }];
    }

    public void Read(int tailLimit, DateTimeOffset now)
    {
        // A future record (one bad timestamp, or the clock set back) must not keep later records filtered or a live turn stale.
        Parser.Clamp(now.AddSeconds(5));
        // A fresh attribute query every tick, never enumeration data: NTFS updates a directory entry's size lazily while
        // a writer keeps the file open (rule 8). The creation time stands in for the mac's dev-ino.
        // ponytail: NTFS can tunnel a creation time for 15 s; use the file ID (GetFileInformationByHandle) if a replaced
        // log is ever missed. A shrink still resets below.
        var info = new FileInfo(Path);
        if (!info.Exists) return;
        var size = info.Length;
        var currentIdentity = info.CreationTimeUtc.Ticks;
        if (initialized && (identity != currentIdentity || size < offset))
        {
            offset = 0;
            initialized = false;
            pending = new();
            droppingLine = false;
            Parser = NewParser(Path, Parser.Source);
        }
        // Unchanged logs are polled every tick; avoid reopening them.
        if (initialized && size == offset) return;
        ReadSidecar();
        try
        {
            using var handle = new FileStream(Path, FileMode.Open, FileAccess.Read, Sharing, bufferSize: 0);
            if (!initialized)
            {
                // Recover identity metadata missed by a tail. This bounded header never replays
                // token counts, lifecycle events, models or conversation content into parser state.
                if (size > tailLimit)
                {
                    var header = ReadAt(handle, 0, 65_536);
                    var start = 0;
                    while (start < header.Length && header.AsSpan(start).IndexOf((byte)10) is var length and >= 0)
                    {
                        Parser.ConsumeMetadata(header.AsSpan(start, length));
                        start += length + 1;
                    }
                }
                if (Parser.Source == TokenSource.Codex && size > tailLimit) RestoreCodexMetadata(handle, size);
                offset = size > tailLimit ? size - tailLimit : 0;
                droppingLine = offset > 0;
                // An open Claude turn that began before the tail is read from its human input,
                // so the whole turn's output is counted rather than reported as unknown.
                if (Parser.Source == TokenSource.Claude && offset > 0 && ClaudeTurnStart(handle, size) is { } turnStart && turnStart < offset)
                {
                    offset = turnStart;
                    droppingLine = false;
                }
                identity = currentIdentity;
                initialized = true;
            }
            // Bursts (large tool outputs, the initial turn replay) are caught up within one sample.
            long budget = 16_777_216 + tailLimit;
            while (offset < size && budget > 0)
            {
                var data = ReadAt(handle, offset, (int)Math.Min(1_048_576, size - offset));
                if (data.Length == 0) break;
                offset += data.Length;
                budget -= data.Length;
                Consume(data);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    static byte[] ReadAt(FileStream handle, long position, int count)
    {
        var buffer = new byte[count];
        handle.Position = position;
        var read = handle.ReadAtLeast(buffer, count, throwOnEndOfStream: false);
        return read == count ? buffer : buffer[..read];
    }

    /// Finds the newest human input of a still-open turn within the last 16 MB.
    /// A completion marker found first means the latest turn is closed and the tail suffices.
    long? ClaudeTurnStart(FileStream handle, long size)
    {
        long? found = null;
        try
        {
            ScanLinesBackward(handle, size, size > 16_777_216 ? size - 16_777_216 : 0, (line, lineOffset) =>
            {
                switch (Parser.ClaudeTurnBoundary(line))
                {
                    case TokenLogParser.TurnBoundary.Start: found = lineOffset; return true;
                    case TokenLogParser.TurnBoundary.End: return true;
                    default: return false;
                }
            });
        }
        catch (IOException) { }
        return found;
    }

    /// Visits complete lines newest first. Lines over `MaximumLineBytes` (the forward limit; a prompt with a pasted image
    /// runs past 64 KB) and an unterminated last record are skipped.
    static void ScanLinesBackward(FileStream handle, long size, long lowerBound, Func<byte[], long, bool> visit)
    {
        var end = size;
        byte[] partial = [];
        var dropping = true;
        while (end > lowerBound)
        {
            var start = Math.Max(lowerBound, end > 65_536 ? end - 65_536 : 0);
            var chunk = ReadAt(handle, start, (int)(end - start));
            if (chunk.Length == 0) return;
            var cursor = chunk.Length;
            while (cursor > 0)
            {
                var newline = chunk.AsSpan(0, cursor).LastIndexOf((byte)10);
                var lineStart = newline + 1;
                if (!dropping)
                {
                    if (partial.Length + cursor - lineStart <= MaximumLineBytes) partial = [.. chunk.AsSpan(lineStart, cursor - lineStart), .. partial];
                    else
                    {
                        partial = [];
                        dropping = true;
                    }
                }
                if (newline < 0) break;
                if (!dropping && partial.Length > 0 && visit(partial, start + lineStart)) return;
                partial = [];
                dropping = false;
                cursor = newline;
            }
            end = start;
        }
        if (end == 0 && !dropping && partial.Length > 0) visit(partial, 0);
    }

    void RestoreCodexMetadata(FileStream handle, long size)
    {
        CodexMetadataCheckpoint? lifecycle = null, opener = null, latestUsage = null;
        var contexts = new List<CodexMetadataCheckpoint>();
        CodexMetadataCheckpoint? MatchingContext() =>
            lifecycle is { } current ? contexts.FirstOrDefault(context => context.TurnID is null || context.TurnID == current.TurnID) : null;
        bool MetadataReady() => lifecycle is not null && opener is { } found && (found.IsInherited || MatchingContext() is not null);
        void Inspect(byte[] line)
        {
            if (Parser.CodexMetadataCheckpointOf(line) is not { } checkpoint) return;
            if (checkpoint.TurnOutputTokens is not null)
            {
                // Scanning backwards: the first usage record is the newest one.
                if (latestUsage is null && lifecycle is null) latestUsage = checkpoint;
                return;
            }
            if (checkpoint.OpensTurn is { } opens)
            {
                if (lifecycle is null)
                {
                    lifecycle = checkpoint;
                    if (opens) opener = checkpoint;
                }
                else if (opener is null && opens && checkpoint.TurnID == lifecycle.TurnID) opener = checkpoint;
            }
            else if (contexts.Count < 16) contexts.Add(checkpoint);
        }
        try
        {
            // A not-yet-terminated last record cannot supply metadata; the scanner skips it.
            ScanLinesBackward(handle, size, size > 16_777_216 ? size - 16_777_216 : 0, (line, _) =>
            {
                Inspect(line);
                return MetadataReady();
            });
            Parser.RestoreCodexMetadata(MatchingContext(), lifecycle, opener, latestUsage);
        }
        catch (IOException) { }
    }

    void Consume(byte[] data)
    {
        var start = 0;
        while (start < data.Length)
        {
            var found = data.AsSpan(start).IndexOf((byte)10);
            var end = found < 0 ? data.Length : start + found;
            if (!droppingLine)
            {
                if (pending.Length + end - start <= MaximumLineBytes) pending.Write(data, start, end - start);
                else
                {
                    // An oversized tool result still names the call it completes near its start.
                    var head = pending.GetBuffer().AsSpan(0, (int)Math.Min(pending.Length, 16_384));
                    Parser.ConsumeOversizedPrefix([.. head, .. data.AsSpan(start, Math.Min(end - start, 16_384 - head.Length))]);
                    pending = new();
                    droppingLine = true;
                }
            }
            if (found < 0) break;
            if (!droppingLine) Parser.Consume(pending.GetBuffer().AsSpan(0, (int)pending.Length));
            pending.SetLength(0);
            droppingLine = false;
            start = end + 1;
        }
    }
}

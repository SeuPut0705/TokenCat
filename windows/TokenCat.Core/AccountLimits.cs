using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using static TokenCat.Lang;

namespace TokenCat;

/// Subscription metadata is memory-only; workspace members are separate identities.
public sealed record LimitAccount
{
    public string Id { get; }
    public string? Email { get; }
    public string? OrganizationName { get; }
    public string Key { get; }
    public string StorageKey { get; }
    public string Label => Email ?? Loc($"계정 …{Id[^Math.Min(4, Id.Length)..]}", $"Account …{Id[^Math.Min(4, Id.Length)..]}");

    public LimitAccount(string id, string? email = null, string? organizationName = null)
    {
        Id = Normalized(id);
        Email = string.IsNullOrWhiteSpace(email) ? null : Normalized(email);
        OrganizationName = string.IsNullOrWhiteSpace(organizationName) ? null : organizationName.Trim();
        Key = Id + "|" + (Email ?? "");
        StorageKey = Sha256(Key)[..16];
    }

    public bool Equals(LimitAccount? other) => other is not null && Id == other.Id && Email == other.Email;
    public override int GetHashCode() => HashCode.Combine(Id, Email);
    public static string Normalized(string value) => value.Trim().ToLowerInvariant();
    public static string Sha256(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    /// Hash the client's original strings, never their normalized identity.
    public static string CredentialPinHash(string provider, string? accountID, string? email, string? organizationID, string? projectID) =>
        Sha256(string.Join('\0', provider, accountID ?? "", email ?? "", organizationID ?? "", projectID ?? ""));
}

public sealed record LimitSlot(TokenSource Provider, LimitAccount? Account);

/// Reads only selected config and SQLite metadata. Token fields are skipped, not decoded or retained.
public sealed class LimitAccountReader(string home, Func<string, string?> environment)
{
    public const int MaximumConfigBytes = 16 << 20;
    public const string CredentialQuery = """
        SELECT provider, json_extract(data, '$.accountId'), json_extract(data, '$.email'),
               json_extract(data, '$.orgId'), json_extract(data, '$.projectId'), json_extract(data, '$.orgName')
        FROM auth_credentials WHERE provider IN ('anthropic', 'openai-codex') AND credential_type = 'oauth'
        """;
    sealed record ClaudeMetadata
    {
        public sealed record Metadata
        {
            public string? AccountUuid { get; init; }
            public string? EmailAddress { get; init; }
            public string? OrganizationName { get; init; }
            public string? OrganizationUuid { get; init; }
        }
        public Metadata? OauthAccount { get; init; }
    }
    sealed record CodexMetadata
    {
        public sealed record Metadata
        {
            [JsonPropertyName("account_id")] public string? AccountID { get; init; }
        }
        public Metadata? Tokens { get; init; }
    }
    sealed record Config(long[] Stamp, LimitAccount? Account, string? OrganizationID);
    sealed record Credential(TokenSource Provider, string Hash, LimitAccount Account);
    sealed record Root(string[] Prefixes, TokenSource Source, string Metadata);
    readonly string home = Path.TrimEndingDirectorySeparator(Path.GetFullPath(home));
    readonly Dictionary<string, Config> configs = new(PathComparer);
    readonly Dictionary<string, (long[] Stamp, List<Credential> Values)> credentials = new(PathComparer);
    readonly Dictionary<TokenSource, LimitAccount> defaults = [];
    readonly Dictionary<TokenSource, List<LimitAccount>> accounts = [];
    List<Root> roots = [];
    List<(TokenSource Source, string[] Prefixes)> clones = [];
    public string? DefaultClaudeOrganizationID { get; private set; }
    internal static StringComparer PathComparer => OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    /// Resolve links in every existing ancestor, not just the final leaf (Windows junctions included).
    internal static string RealPath(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full)!;
        var current = root;
        foreach (var component in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            try
            {
                FileSystemInfo entry = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
                if (entry.LinkTarget is not null && entry.ResolveLinkTarget(true) is { } target) current = target.FullName;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return Path.TrimEndingDirectorySeparator(current);
    }
    internal static string[] Prefixes(string path) =>
        [.. new[] { Path.TrimEndingDirectorySeparator(Path.GetFullPath(path)), RealPath(path) }.Distinct(PathComparer).Select(value => value.Replace('\\', '/') + "/")];
    string ClaudeConfig(string directory) => PathComparer.Equals(Path.GetFullPath(directory), Path.Combine(home, ".claude"))
        ? Path.Combine(home, ".claude.json") : Path.Combine(directory, ".claude.json");
    string DefaultClaudeConfig => TokenProvider.EnvPaths(home, environment, "CLAUDE_CONFIG_DIR").FirstOrDefault() is { } directory
        ? ClaudeConfig(directory) : Path.Combine(home, ".claude.json");
    string DefaultCodexConfig => Path.Combine(TokenProvider.EnvPath(home, environment, "CODEX_HOME") ?? Path.Combine(home, ".codex"), "auth.json");

    public void Refresh()
    {
        roots = [.. TokenProvider.ClaudeConfigDirectories(home, environment).Select(directory =>
            new Root(Prefixes(Path.Combine(directory, "projects")), TokenSource.Claude, ClaudeConfig(directory))),
            .. new[] { TokenProvider.EnvPath(home, environment, "CODEX_HOME"), Path.Combine(home, ".codex") }.OfType<string>()
                .Select(directory => new Root(Prefixes(Path.Combine(directory, "sessions")), TokenSource.Codex, Path.Combine(directory, "auth.json")))];
        var databases = AgentUsageHistory.Databases(home, environment).ToHashSet(PathComparer);
        roots.AddRange(databases.Select(database => new Root(Prefixes(Path.Combine(Path.GetDirectoryName(database)!, "sessions")), TokenSource.Omp, database)));
        if (TokenProvider.EnvPath(home, environment, "PI_CODING_AGENT_SESSION_DIR") is { } piSessions)
        {
            var database = Path.Combine(TokenProvider.EnvPath(home, environment, "PI_CODING_AGENT_DIR") ?? Path.Combine(home, ".pi", "agent"), "agent.db");
            if (databases.Contains(database)) roots.Add(new Root(Prefixes(piSessions), TokenSource.Omp, database));
        }
        clones = [.. TokenClientRoots.All.Where(client => client.Source != TokenSource.Omp)
            .SelectMany(client => client.Roots(home, environment).Select(root => (client.Source, Prefixes(root))))];
        var configPaths = roots.Where(root => root.Source != TokenSource.Omp).Select(root => root.Metadata)
            .Concat([DefaultClaudeConfig, DefaultCodexConfig, Path.Combine(home, ".claude.json")]).ToHashSet(PathComparer);
        foreach (var path in configs.Keys.Where(path => !configPaths.Contains(path)).ToArray()) configs.Remove(path);
        foreach (var path in configPaths) ReadConfig(path);
        foreach (var path in credentials.Keys.Where(path => !databases.Contains(path)).ToArray()) credentials.Remove(path);
        foreach (var database in databases)
        {
            if (OpenCodeDatabase.Signature(database) is not { } stamp) { credentials.Remove(database); continue; }
            if (credentials.TryGetValue(database, out var cached) && cached.Stamp.SequenceEqual(stamp)) continue;
            using var connection = OpenCodeDatabase.Open(database);
            if (connection is null) continue;
            var values = new List<Credential>();
            if (!connection.Query(CredentialQuery, [], row =>
            {
                if (row.Text(0) is not { } provider || row.Text(1) is not { } id || NormalizedEmpty(id)) return;
                var source = provider == "anthropic" ? TokenSource.Claude : TokenSource.Codex;
                var email = row.Text(2);
                values.Add(new Credential(source, LimitAccount.CredentialPinHash(provider, id, email, row.Text(3), row.Text(4)),
                    new LimitAccount(id, email, row.Text(5))));
            })) continue;
            credentials[database] = (stamp, values);
        }
        accounts.Clear();
        foreach (var credential in credentials.Values.SelectMany(value => value.Values)) Add(credential.Provider, credential.Account);
        var claude = roots.Where(root => root.Source == TokenSource.Claude).Select(root => root.Metadata).Append(DefaultClaudeConfig)
            .Select(path => ConfigMetadata(path, TokenSource.Claude)?.Account).OfType<LimitAccount>().ToList();
        foreach (var account in claude.Where(account => account.Email is not null)) Add(TokenSource.Claude, account);
        var resolvedClaude = claude.Select(account => Resolve(TokenSource.Claude, account.Id, account.Email, account.OrganizationName)).OfType<LimitAccount>().ToList();
        foreach (var account in resolvedClaude) Add(TokenSource.Claude, account);
        var codex = roots.Where(root => root.Source == TokenSource.Codex).Select(root => ConfigMetadata(root.Metadata, TokenSource.Codex)?.Account)
            .OfType<LimitAccount>().Select(account => Resolve(TokenSource.Codex, account.Id, account.Email)).OfType<LimitAccount>().ToList();
        defaults.Clear();
        foreach (var (source, path) in new[] { (TokenSource.Claude, DefaultClaudeConfig), (TokenSource.Codex, DefaultCodexConfig) })
            if (ConfigMetadata(path, source)?.Account is { } account && Resolve(source, account.Id, account.Email, account.OrganizationName) is { } resolved)
                defaults[source] = resolved;
        foreach (var account in codex) Add(TokenSource.Codex, account);
        DefaultClaudeOrganizationID = ConfigMetadata(DefaultClaudeConfig, TokenSource.Claude)?.OrganizationID;
        foreach (var values in accounts.Values) values.Sort((a, b) => string.CompareOrdinal(a.Key, b.Key));
    }
    static bool NormalizedEmpty(string id) => LimitAccount.Normalized(id).Length == 0;
    void Add(TokenSource provider, LimitAccount account)
    {
        if (!accounts.TryGetValue(provider, out var values)) accounts[provider] = values = [];
        if (!values.Contains(account)) values.Add(account);
    }
    void ReadConfig(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaximumConfigBytes) { configs.Remove(path); return; }
            long[] stamp = [info.CreationTimeUtc.Ticks, info.Length, info.LastWriteTimeUtc.Ticks];
            if (configs.TryGetValue(path, out var cached) && cached.Stamp.SequenceEqual(stamp)) return;
            LimitAccount? account = null;
            string? organization = null;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (stream.Length > MaximumConfigBytes) { configs.Remove(path); return; }
            var bytes = new byte[(int)stream.Length];
            stream.ReadExactly(bytes);
            try
            {
                if (Path.GetFileName(path) == "auth.json")
                {
                    if (JsonSerializer.Deserialize<CodexMetadata>(Json.StripBom(bytes), Json.Options)?.Tokens?.AccountID is { } id && !NormalizedEmpty(id))
                        account = new LimitAccount(id);
                }
                else if (JsonSerializer.Deserialize<ClaudeMetadata>(Json.StripBom(bytes), Json.Options)?.OauthAccount is { } metadata)
                {
                    if (metadata.AccountUuid is { } id && !NormalizedEmpty(id)) account = new LimitAccount(id, metadata.EmailAddress, metadata.OrganizationName);
                    organization = metadata.OrganizationUuid;
                }
            }
            catch (JsonException) { }
            configs[path] = new Config(stamp, account, organization);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { configs.Remove(path); }
    }
    Config? ConfigMetadata(string path, TokenSource provider)
    {
        if (configs.TryGetValue(path, out var config)) return config;
        var legacy = Path.Combine(TokenProvider.EnvPath(home, environment, "XDG_CONFIG_HOME") ?? Path.Combine(home, ".config"), "claude", ".claude.json");
        return provider == TokenSource.Claude && PathComparer.Equals(path, legacy) ? configs.GetValueOrDefault(Path.Combine(home, ".claude.json")) : null;
    }
    public LimitAccount? DefaultAccount(TokenSource provider) => defaults.GetValueOrDefault(provider);
    public IReadOnlyList<LimitAccount> KnownAccounts(TokenSource provider) => accounts.TryGetValue(provider, out var values) ? values : [];
    public LimitAccount? Resolve(TokenSource provider, string? id, string? email = null, string? organizationName = null)
    {
        if (id is null || NormalizedEmpty(id)) return null;
        var normalizedID = LimitAccount.Normalized(id);
        var normalizedEmail = string.IsNullOrWhiteSpace(email) ? null : LimitAccount.Normalized(email);
        var matching = KnownAccounts(provider).Where(account => account.Id == normalizedID).ToList();
        var known = normalizedEmail is null && matching.Count == 1 ? matching[0] : matching.FirstOrDefault(account => account.Email == normalizedEmail);
        return known is null ? new LimitAccount(normalizedID, normalizedEmail, organizationName)
            : organizationName is null || organizationName == known.OrganizationName ? known : new LimitAccount(known.Id, known.Email, organizationName);
    }
    Root? FindRoot(TokenSource source, string path)
    {
        var paths = new[] { Path.GetFullPath(path).Replace('\\', '/'), RealPath(path).Replace('\\', '/') };
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        bool Matches(string[] prefixes) => prefixes.Any(prefix => paths.Any(path => path.StartsWith(prefix, comparison)));
        if (clones.Any(clone => clone.Source == source && Matches(clone.Prefixes))) return null;
        return roots.Where(root => root.Source == source && Matches(root.Prefixes)).MaxBy(root => root.Prefixes.Max(prefix => prefix.Length));
    }
    public LimitAccount? Account(string path, TokenSource source, string? model = null, IReadOnlyDictionary<TokenSource, string>? pins = null)
    {
        if (source == TokenSource.Omp)
            return TokenSource.LimitProvider(model) is { } provider && pins is not null && pins.TryGetValue(provider, out var hash) ? PinnedAccount(provider, hash, path) : null;
        if (source is not (TokenSource.Claude or TokenSource.Codex) || FindRoot(source, path) is not { } root
            || ConfigMetadata(root.Metadata, source)?.Account is not { } account) return null;
        return Resolve(source, account.Id, account.Email, account.OrganizationName);
    }
    public LimitAccount? ClaudeAccount(string configDirectory)
    {
        var real = RealPath(configDirectory);
        var directory = TokenProvider.ClaudeConfigDirectories(home, environment).FirstOrDefault(directory => PathComparer.Equals(RealPath(directory), real));
        return directory is not null && ConfigMetadata(ClaudeConfig(directory), TokenSource.Claude)?.Account is { } account
            ? Resolve(TokenSource.Claude, account.Id, account.Email, account.OrganizationName) : null;
    }
    public LimitAccount? PinnedAccount(TokenSource provider, string hash, string path)
    {
        if (FindRoot(TokenSource.Omp, path) is not { } root || !credentials.TryGetValue(root.Metadata, out var values)) return null;
        var matches = values.Values.Where(value => value.Provider == provider && value.Hash == hash).Select(value => value.Account).Distinct().ToList();
        return matches.Count == 1 ? matches[0] : null;
    }
}

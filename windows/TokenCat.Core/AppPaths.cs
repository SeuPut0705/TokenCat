namespace TokenCat;

/// Where things live (DESIGN §7.1). Log and config paths take `home` so checks run on temp homes.
public static class AppPaths
{
    /// %USERPROFILE% on Windows, $HOME elsewhere. CODEX_HOME / CLAUDE_CONFIG_DIR / WSL are ignored in v1, as on mac.
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// %LOCALAPPDATA%\TokenCat. Dev runs on macOS use "TokenCat-windows-dev", never the mac app's folder.
    public static string Support => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        OperatingSystem.IsWindows() ? "TokenCat" : "TokenCat-windows-dev");

    public static string CodexSessions(string home) => Path.Combine(home, ".codex", "sessions");
    public static string ClaudeProjects(string home) => Path.Combine(home, ".claude", "projects");
    public static string CodexConfig(string home) => Path.Combine(home, ".codex", "config.toml");
    public static string ClaudeSettings(string home) => Path.Combine(home, ".claude", "settings.json");

    /// Claude desktop usage history candidates in probe order (§2.4): %APPDATA%\Claude (macOS: Application Support/Claude),
    /// then the MSIX-virtualized copy. Missing files are normal.
    public static IReadOnlyList<string> ClaudeDesktopHistory()
    {
        const string name = "plan-usage-history.json";
        var packages = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Packages");
        IEnumerable<string> msix = Directory.Exists(packages)
            ? Directory.EnumerateDirectories(packages, "Claude_*").Select(dir => Path.Combine(dir, "LocalCache", "Roaming", "Claude", name))
            : [];
        return [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", name), .. msix];
    }

    /// Rule 9: temp file in the same folder, then File.Replace (keeps ACL and attributes) or a move when the file is new.
    /// Retried 3× on IOException (editors and antivirus hold files briefly). The temp file never outlives the call.
    public static void WriteAtomically(string path, byte[] bytes)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path))!;
        Directory.CreateDirectory(directory);
        var temp = Path.Combine(directory, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temp, bytes);
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    if (File.Exists(path)) File.Replace(temp, path, null);
                    else File.Move(temp, path, overwrite: true);
                    return;
                }
                catch (IOException) when (attempt < 3) { Thread.Sleep(100); }
            }
        }
        finally { File.Delete(temp); }
    }
}

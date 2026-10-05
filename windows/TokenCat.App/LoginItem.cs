using System.IO;
using Microsoft.Win32;
using static TokenCat.Lang;

namespace TokenCat;

/// LoginItem.swift on Windows (DESIGN §2.7): `HKCU\…\Run\TokenCat` = the quoted exe path, written only from the Settings
/// toggle. Task Manager's own switch lives in `…\Explorer\StartupApproved\Run` and is read, never written.
static class LoginItem
{
    public enum State { NotRegistered, Enabled, DisabledInTaskManager }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const string Name = "TokenCat";

    static string Command => $"\"{Environment.ProcessPath}\"";

    public static State Status
    {
        get
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            // A value for another path (this exe was moved) won't start this copy: off, and turning it on writes this path.
            if (run?.GetValue(Name) is not string value || !value.Equals(Command, StringComparison.OrdinalIgnoreCase)) return State.NotRegistered;
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
            // 02 enabled, 03 disabled (06/07 seen too): the low bit set means disabled.
            return approved?.GetValue(Name) is byte[] { Length: > 0 } flags && (flags[0] & 1) == 1 ? State.DisabledInTaskManager : State.Enabled;
        }
    }

    public static bool IsOn(State state) => state != State.NotRegistered;

    public static void Set(bool enabled)
    {
        using var run = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) run.SetValue(Name, Command);
        else run.DeleteValue(Name, throwOnMissingValue: false);
    }

    /// The recommended folder (no installer): %LOCALAPPDATA%\Programs\TokenCat.
    public static string RecommendedFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "TokenCat");

    public static bool IsInRecommendedFolder =>
        Path.GetDirectoryName(Environment.ProcessPath ?? "")?.Equals(RecommendedFolder, StringComparison.OrdinalIgnoreCase) == true;

    /// Run from inside the zip (Explorer extracts it to %TEMP%): a Run entry there would point at a file that goes away.
    public static bool IsTemporary => UpdateInstaller.InTemporaryFolder(Environment.ProcessPath ?? "");

    public static string Describe(State state) => state switch
    {
        State.Enabled => Loc("켜짐 · Windows 시작 프로그램에 등록돼 있습니다", "On · registered as a Windows startup app"),
        State.DisabledInTaskManager => Loc("작업 관리자 › 시작 앱에서 사용 안 함으로 설정돼 있습니다", "Disabled in Task Manager › Startup apps"),
        _ => Loc("꺼짐 · 켤 때만 시작 프로그램에 등록합니다", "Off · registers as a startup app only when you turn it on"),
    };

    /// Task Manager on its Startup apps page.
    public static void OpenTaskManagerStartup() => Shell.Open("taskmgr.exe", "/0 /startup");
}

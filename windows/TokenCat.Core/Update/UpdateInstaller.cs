namespace TokenCat;

// WP4 stub (DESIGN §9): rename-then-replace of the running exe. WP4 adds Blocker/Verify/Extract/Validate/Replace/Relaunch
// and owns this file. The App's CLI calls the two entry points below.
public static class UpdateInstaller
{
    /// `--after-update <pid>`: waits for the old process (≤ 60 s), then removes TokenCat.exe.old and TokenCat.update\.
    public static void FinishAfterUpdate(int pid) => throw new NotImplementedException();

    /// `--update-selftest <zip>`: runs a copy of the running exe against the given release zip; returns the exit code.
    public static int SelfTest(string zip) => throw new NotImplementedException();
}

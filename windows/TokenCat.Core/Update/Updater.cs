namespace TokenCat;

// WP4 stub (DESIGN §9, §11): Updater.swift's logic for the TokenCat-Windows.zip asset. WP4 adds UpdateState's fields and the
// rest of Updater.swift (AppVersion, UpdateRelease, UpdateFailure, …) and owns this file.

public sealed record UpdateState;

public sealed class Updater
{
    public event Action<UpdateState>? StateChanged
    {
        add => throw new NotImplementedException();
        remove => throw new NotImplementedException();
    }

    public UpdateState State => throw new NotImplementedException();
    public void Start(bool automatic) => throw new NotImplementedException();
    public void CheckNow() => throw new NotImplementedException();
    public void Install() => throw new NotImplementedException();
    public void DashboardOpened() => throw new NotImplementedException();
    public void SystemDidWake() => throw new NotImplementedException();

    /// `--update-check`: one read-only GET of the latest release, printed; returns the exit code.
    public static int CommandLineCheck() => throw new NotImplementedException();
}

namespace TokenCat;

/// `dotnet run --project windows/TokenCat.Checks -- --diagnose-tokens [home]`: the tracker's log readings as
/// `{"tokens": [...]}` with the mac `--diagnose` field names, for the §6.3 parity diff. Read-only; telemetry rows are
/// left out (the diff compares log fields only).
public static class TokenDiagnostics
{
    public static int Run(string home)
    {
        using var output = Console.OpenStandardOutput();
        output.Write(Json.Serialize(new { tokens = new TokenTracker(home).Sample() }));
        return 0;
    }
}

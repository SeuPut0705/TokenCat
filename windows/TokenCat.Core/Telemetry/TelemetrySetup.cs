namespace TokenCat;

// WP2 stub (DESIGN §11, §7.4): TelemetrySetup.swift's public surface. WP2 replaces the bodies and owns this file.
public sealed record TelemetrySetupResult(IReadOnlyList<string> ChangedFiles, IReadOnlyList<TokenSource> RestartRequired, string Message)
{
    /// What the CLI message says about the Claude Code status line, for the app to show without reading the message.
    public IReadOnlyList<TelemetrySetupNote> Notes { get; init; } = [];
    /// Claude Code settings run the status line bridge after this call.
    public bool Bridged { get; init; }
}

/// Swift's three notes plus `StatusLineKept` (Windows v1 keeps an existing statusLine untouched, §7.4).
public enum TelemetrySetupNote { StatusLineSkipped, OriginalUnknown, OriginalRecreated, StatusLineKept }

public static class TelemetrySetupNoteText
{
    extension(TelemetrySetupNote note)
    {
        public string Text => throw new NotImplementedException();
    }
}

/// What the UI says about a failed automatic connection, without reading message text.
public abstract record TelemetrySetupFailure
{
    public sealed record Conflict : TelemetrySetupFailure;
    public sealed record Invalid : TelemetrySetupFailure;
    public sealed record Unavailable : TelemetrySetupFailure;
    public sealed record WriteFailed(bool Restored) : TelemetrySetupFailure;
}

/// Swift's TelemetrySetupError: the reason (conflict/invalid) or the write-failure text as Message.
public sealed class TelemetrySetupError(TelemetrySetupFailure failure, string message) : Exception(message)
{
    public TelemetrySetupFailure Failure { get; } = failure;
}

public sealed class TelemetrySetup
{
    public const int Port = TelemetryCollector.DefaultPort;
    /// Set by `--disconnect-telemetry` (even when it refuses) and cleared by `--connect-telemetry`.
    public const string OptOutKey = "telemetryDisconnected";

    public TelemetrySetup(string home, string supportDirectory) => throw new NotImplementedException();
    /// Throws TelemetrySetupError.
    public TelemetrySetupResult Connect() => throw new NotImplementedException();
    /// Throws TelemetrySetupError.
    public TelemetrySetupResult Disconnect() => throw new NotImplementedException();
}

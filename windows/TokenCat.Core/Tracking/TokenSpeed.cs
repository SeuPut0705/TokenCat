using System.Text.Json.Serialization;

namespace TokenCat;

// WP1 stub (DESIGN §11). WP1 replaces the bodies and owns this file.
public static class TokenSpeed
{
    /// Session and agent identities must match. Model names or timing never establish identity.
    public static List<TokenReading> Apply(IReadOnlyList<TokenReading> readings, IReadOnlyList<TelemetryReading> measurements) =>
        throw new NotImplementedException();
}

public sealed partial record TokenSpeedMeasurement
{
    [JsonIgnore] public TokenRateKind? Kind => throw new NotImplementedException();
    [JsonIgnore] public double? TokensPerSecond => throw new NotImplementedException();
    [JsonIgnore] public string Details => throw new NotImplementedException();
}

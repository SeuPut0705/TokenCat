using System.Text;

namespace TokenCat;

// WP2 owns this file. Parse is the spike's 1:1 port of TelemetryHTTP.parse (checked there, not yet here); Encode is a stub.

/// One request per connection, Content-Length only.
public abstract record HttpDecision
{
    public sealed record Waiting : HttpDecision;
    public sealed record Request(string Path, byte[] Body) : HttpDecision;
    public sealed record Response(int Code) : HttpDecision;
}

public static class TelemetryHttp
{
    public const int MaximumHeaderBytes = 16_384, MaximumBodyBytes = 2_097_152, MaximumStatusBodyBytes = 65_536;
    public const string ClaudeStatusPath = "/v1/claude/status";

    public static HttpDecision Parse(ReadOnlySpan<byte> data)
    {
        var end = data.IndexOf("\r\n\r\n"u8);
        if (end < 0) return data.Length > MaximumHeaderBytes ? new HttpDecision.Response(431) : new HttpDecision.Waiting();
        var headerEnd = end + 4;
        if (headerEnd > MaximumHeaderBytes) return new HttpDecision.Response(431);
        string header;
        try { header = new UTF8Encoding(false, true).GetString(data[..end]); } catch (DecoderFallbackException) { return new HttpDecision.Response(431); }
        var lines = header.Split("\r\n");
        var start = lines[0].Split(' ');
        if (start.Length != 3 || start[2] is not ("HTTP/1.1" or "HTTP/1.0")) return new HttpDecision.Response(400);
        int? length = null; string? contentType = null;
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) return new HttpDecision.Response(400);
            var key = line[..colon].ToLowerInvariant();
            if (key.Length == 0 || !key.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-')) return new HttpDecision.Response(400);
            var value = line[(colon + 1)..].Trim(' ', '\t');
            if (key == "origin") return new HttpDecision.Response(403);
            if (key == "transfer-encoding") return new HttpDecision.Response(400);
            if (key == "content-length")
            {
                if (length != null || value.Length == 0 || !value.All(char.IsAsciiDigit) || !int.TryParse(value, out var count)) return new HttpDecision.Response(400);
                if (count > MaximumBodyBytes) return new HttpDecision.Response(413);
                length = count;
            }
            if (key == "content-type")
            {
                if (contentType != null) return new HttpDecision.Response(400);
                contentType = value.Split(';')[0].Trim().ToLowerInvariant();
            }
        }
        string method = start[0], path = start[1];
        if (path is "/health" or "/v1/readings" or "/v1/diagnostics")
        {
            if (method != "GET") return new HttpDecision.Response(405);
            if ((length ?? 0) != 0 || data.Length != headerEnd) return new HttpDecision.Response(400);
            return new HttpDecision.Request(path, []);
        }
        if (path is not ("/v1/logs" or "/v1/metrics" or "/v1/traces" or ClaudeStatusPath)) return new HttpDecision.Response(404);
        if (method != "POST") return new HttpDecision.Response(405);
        if (contentType != "application/json" || length is not int bodyLength) return new HttpDecision.Response(400);
        if (path == ClaudeStatusPath && bodyLength > MaximumStatusBodyBytes) return new HttpDecision.Response(413);
        var total = headerEnd + bodyLength;
        if (data.Length < total) return new HttpDecision.Waiting();
        if (data.Length != total) return new HttpDecision.Response(400);
        return new HttpDecision.Request(path, data[headerEnd..total].ToArray());
    }

    /// An HTTP/1.1 response with `body` (Connection: close).
    public static byte[] Encode(int code, byte[] body) => throw new NotImplementedException();
}

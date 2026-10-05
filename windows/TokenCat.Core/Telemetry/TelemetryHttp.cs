using System.Text;

namespace TokenCat;

// Telemetry.swift `TelemetryHTTP`: one request per connection, Content-Length only.

public abstract record HttpDecision
{
    public sealed record Waiting : HttpDecision;
    public sealed record Request(string Path, byte[] Body) : HttpDecision;
    /// Answered with `{}` and this code, without reaching the handler.
    public sealed record Response(int Code) : HttpDecision;
}

public static class TelemetryHttp
{
    public const int MaximumHeaderBytes = 16_384, MaximumBodyBytes = 2_097_152, MaximumStatusBodyBytes = 65_536;
    /// Claude Code's status line JSON, forwarded by TokenCat's statusLine bridge; it is a few kilobytes.
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
        long? length = null; string? contentType = null;
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) return new HttpDecision.Response(400);
            var key = line[..colon].ToLowerInvariant();
            if (key.Length == 0 || !key.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-')) return new HttpDecision.Response(400);
            var value = line[(colon + 1)..].Trim(' ', '\t');
            // A browser page can reach loopback; no browser request is ever a client export.
            if (key == "origin") return new HttpDecision.Response(403);
            // A DNS-rebound page sends its own host name with no Origin; every client uses 127.0.0.1.
            if (key == "host" && value.Split(':')[0].ToLowerInvariant() is not ("127.0.0.1" or "localhost")) return new HttpDecision.Response(403);
            if (key == "transfer-encoding") return new HttpDecision.Response(400);
            if (key == "content-length")
            {
                if (length != null || value.Length == 0 || !value.All(char.IsAsciiDigit) || !long.TryParse(value, out var count)) return new HttpDecision.Response(400);
                if (count > MaximumBodyBytes) return new HttpDecision.Response(413);
                length = count;
            }
            if (key == "content-type")
            {
                if (contentType != null) return new HttpDecision.Response(400);
                // Swift's split drops empty pieces: ";application/json" reads as application/json.
                contentType = value.Split(';', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim(' ', '\t').ToLowerInvariant();
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
        if (contentType != "application/json" || length is not { } bodyLength) return new HttpDecision.Response(400);
        if (path == ClaudeStatusPath && bodyLength > MaximumStatusBodyBytes) return new HttpDecision.Response(413);
        var total = headerEnd + (int)bodyLength;
        if (data.Length < total) return new HttpDecision.Waiting();
        if (data.Length != total) return new HttpDecision.Response(400);
        return new HttpDecision.Request(path, data[headerEnd..total].ToArray());
    }

    /// An HTTP/1.1 response with `body` (Connection: close, no CORS headers).
    public static byte[] Encode(int code, byte[] body)
    {
        var reason = code switch
        {
            200 => "OK", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed",
            408 => "Request Timeout", 413 => "Content Too Large", 431 => "Request Header Fields Too Large", _ => "Error",
        };
        return [.. Encoding.ASCII.GetBytes($"HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n"), .. body];
    }
}

using System.Text;

namespace TokenCat;

// Telemetry.swift `TelemetryHTTP`: one request per connection, Content-Length or chunked.

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
        long? length = null; string? contentType = null; var chunked = false;
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
            // Node's OTLP/HTTP exporters (Gemini CLI, Qwen Code) stream the body chunked, without a length.
            if (key == "transfer-encoding")
            {
                if (chunked || value.ToLowerInvariant() != "chunked") return new HttpDecision.Response(400);
                chunked = true;
            }
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
            if (chunked || (length ?? 0) != 0 || data.Length != headerEnd) return new HttpDecision.Response(400);
            return new HttpDecision.Request(path, []);
        }
        if (path is not ("/v1/logs" or "/v1/metrics" or "/v1/traces" or ClaudeStatusPath)) return new HttpDecision.Response(404);
        if (method != "POST") return new HttpDecision.Response(405);
        var limit = path == ClaudeStatusPath ? MaximumStatusBodyBytes : MaximumBodyBytes;
        if (contentType != "application/json" || (length != null) == chunked) return new HttpDecision.Response(400);
        if (chunked) return Dechunk(data[headerEnd..], limit, path);
        var bodyLength = length!.Value;
        if (bodyLength > limit) return new HttpDecision.Response(413);
        var total = headerEnd + (int)bodyLength;
        if (data.Length < total) return new HttpDecision.Waiting();
        if (data.Length != total) return new HttpDecision.Response(400);
        return new HttpDecision.Request(path, data[headerEnd..total].ToArray());
    }

    /// A chunked body: hex sizes (extensions after ';' ignored), CRLF after each chunk, a 0 chunk, then trailer lines
    /// (dropped) up to the empty line. Nothing may follow it. The decoded body keeps the Content-Length limits, and the
    /// framing may at most double it, so tiny chunks cannot hold a connection open on an unbounded buffer.
    static HttpDecision Dechunk(ReadOnlySpan<byte> bytes, int limit, string path)
    {
        if (bytes.Length > 2 * MaximumBodyBytes) return new HttpDecision.Response(413);
        var body = new List<byte>();
        var index = 0;
        static ReadOnlySpan<byte> Line(ReadOnlySpan<byte> bytes, ref int index, out bool found)
        {
            var crlf = bytes[index..].IndexOf("\r\n"u8);
            found = crlf >= 0;
            if (!found) return default;
            var text = bytes.Slice(index, crlf);
            index += crlf + 2;
            return text;
        }
        while (true)
        {
            var sizeLine = Line(bytes, ref index, out var found);
            if (!found) return bytes.Length - index > 1_024 ? new HttpDecision.Response(400) : new HttpDecision.Waiting();
            var semicolon = sizeLine.IndexOf((byte)';');
            var digits = semicolon < 0 ? sizeLine : sizeLine[..semicolon];
            if (digits.Length is < 1 or > 8) return new HttpDecision.Response(400);
            var size = 0L;
            foreach (var digit in digits)
            {
                if (!char.IsAsciiHexDigit((char)digit)) return new HttpDecision.Response(400);
                size = size * 16 + Convert.ToInt32(((char)digit).ToString(), 16);
            }
            if (size == 0) break;
            if (body.Count + size > limit) return new HttpDecision.Response(413);
            if (index + size + 2 > bytes.Length) return new HttpDecision.Waiting();
            if (bytes[index + (int)size] != '\r' || bytes[index + (int)size + 1] != '\n') return new HttpDecision.Response(400);
            body.AddRange(bytes.Slice(index, (int)size));
            index += (int)size + 2;
        }
        while (true)
        {
            var trailer = Line(bytes, ref index, out var found);
            if (!found) return bytes.Length - index > MaximumHeaderBytes ? new HttpDecision.Response(431) : new HttpDecision.Waiting();
            if (trailer.IsEmpty) break;
        }
        if (index != bytes.Length) return new HttpDecision.Response(400);
        return new HttpDecision.Request(path, [.. body]);
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

using System.IO;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Forms = System.Windows.Forms;

namespace TokenCat;

/// SystemSampler.swift on Windows (DESIGN §7.6). Rates need two successful samples of the same counter.
sealed class WindowsSystemSampler
{
    (long Idle, long Total)? previousCpu;
    Dictionary<string, (long Sent, long Received)>? previousNetwork;
    long previousNetworkTime;

    public SystemSnapshot Sample()
    {
        var memory = Native.MemoryStatus.Create();
        var hasMemory = Native.GlobalMemoryStatusEx(ref memory);
        var (disk, diskTotal) = Disk();
        var (ips, upload, download) = Network();
        var power = Forms.SystemInformation.PowerStatus;
        var battery = !power.BatteryChargeStatus.HasFlag(Forms.BatteryChargeStatus.NoSystemBattery)
            && !power.BatteryChargeStatus.HasFlag(Forms.BatteryChargeStatus.Unknown);
        return new SystemSnapshot
        {
            CpuPercent = Cpu(),
            MemoryTotalBytes = hasMemory ? memory.TotalPhys : null,
            MemoryUsedBytes = hasMemory ? memory.TotalPhys - Math.Min(memory.TotalPhys, memory.AvailPhys) : null,
            DiskUsedBytes = disk,
            DiskTotalBytes = diskTotal,
            LocalIPs = ips,
            UploadBytesPerSecond = upload,
            DownloadBytesPerSecond = download,
            BatteryPresent = battery,
            BatteryPercent = battery && power.BatteryLifePercent is >= 0 and <= 1 ? power.BatteryLifePercent * 100 : null,
            IsCharging = battery ? power.BatteryChargeStatus.HasFlag(Forms.BatteryChargeStatus.Charging) : null,
            // The mac strings, so Format.Power is shared.
            PowerSource = power.PowerLineStatus switch { Forms.PowerLineStatus.Online => "AC Power", Forms.PowerLineStatus.Offline => "Battery Power", _ => null },
            SampledAt = DateTimeOffset.UtcNow,
        };
    }

    /// GetSystemTimes deltas: kernel time includes idle.
    double? Cpu()
    {
        if (!Native.GetSystemTimes(out var idle, out var kernel, out var user)) return null;
        var current = (Idle: idle, Total: kernel + user);
        var previous = previousCpu;
        previousCpu = current;
        if (previous is not { } p) return null;
        long total = current.Total - p.Total, idleDelta = current.Idle - p.Idle;
        if (total <= 0) return null;
        return Math.Clamp((double)(total - idleDelta) / total * 100, 0, 100);
    }

    /// The volume holding %USERPROFILE%: used = total − free to this user.
    static (ulong?, ulong?) Disk()
    {
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(AppPaths.Home)!);
            if (!drive.IsReady || drive.TotalSize <= 0) return (null, null);
            var total = (ulong)drive.TotalSize;
            return (total - Math.Min(total, (ulong)drive.AvailableFreeSpace), total);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { return (null, null); }
    }

    /// Up, not loopback or tunnel, and with a gateway (drops the Hyper-V/WSL vEthernet adapters that double-count traffic).
    (List<string>, double?, double?) Network()
    {
        var counters = new Dictionary<string, (long, long)>();
        var ips = new SortedSet<string>(StringComparer.Ordinal);
        NetworkInterface[] interfaces;
        try { interfaces = NetworkInterface.GetAllNetworkInterfaces(); }
        catch (NetworkInformationException) { previousNetwork = null; return ([], null, null); }
        foreach (var adapter in interfaces)
        {
            if (adapter.OperationalStatus != OperationalStatus.Up
                || adapter.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
            var properties = adapter.GetIPProperties();
            if (properties.GatewayAddresses.Count == 0) continue;
            foreach (var address in properties.UnicastAddresses)
                if (address.Address.AddressFamily == AddressFamily.InterNetwork) ips.Add(address.Address.ToString());
            var statistics = adapter.GetIPStatistics();
            counters[adapter.Id] = (statistics.BytesSent, statistics.BytesReceived);
        }
        var now = Stopwatch.GetTimestamp();
        var previous = previousNetwork;
        var previousTime = previousNetworkTime;
        previousNetwork = counters;
        previousNetworkTime = now;
        if (previous is null || now <= previousTime || counters.Count == 0) return ([.. ips], null, null);
        long sent = 0, received = 0;
        var comparable = 0;
        foreach (var (id, current) in counters)
        {
            if (!previous.TryGetValue(id, out var old) || current.Item1 < old.Sent || current.Item2 < old.Received) continue;
            sent += current.Item1 - old.Sent;
            received += current.Item2 - old.Received;
            comparable++;
        }
        if (comparable == 0) return ([.. ips], null, null);
        var seconds = (now - previousTime) / (double)Stopwatch.Frequency;
        return ([.. ips], sent / seconds, received / seconds);
    }
}

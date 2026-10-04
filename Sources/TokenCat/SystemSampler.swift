import Darwin
import Foundation
import IOKit.ps

/// Samples native counters. Rates need two successful samples of the same counter.
final class SystemSampler {
    private struct NetworkCounter {
        var sent: UInt64
        var received: UInt64
    }

    private let hostPort = mach_host_self()
    private var previousCPUTicks: [UInt32]?
    private var previousNetworkCounters: [String: NetworkCounter]?
    private var previousNetworkTime: UInt64?

    deinit {
        if hostPort != MACH_PORT_NULL {
            mach_port_deallocate(mach_task_self_, hostPort)
        }
    }

    func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpuPercent = sampleCPU()
        sampleMemory(into: &snapshot)
        sampleDisk(into: &snapshot)
        sampleNetwork(into: &snapshot)
        sampleBattery(into: &snapshot)
        return snapshot
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let current = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        let previous = previousCPUTicks
        previousCPUTicks = current
        guard let previous else { return nil }

        // These counters are UInt32 and wrap on long-running systems.
        let deltas = zip(current, previous).map { UInt64($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }
        let idle = deltas[Int(CPU_STATE_IDLE)]
        return min(100, max(0, Double(total - idle) / Double(total) * 100))
    }

    private func sampleMemory(into snapshot: inout SystemSnapshot) {
        let total = ProcessInfo.processInfo.physicalMemory
        snapshot.memoryTotalBytes = total

        var pageSize: vm_size_t = 0
        guard host_page_size(hostPort, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        // Resident anonymous pages, wired kernel pages and compressed storage;
        // reclaimable file cache and purgeable pages are excluded.
        let occupiedPages = UInt64(info.internal_page_count)
            + UInt64(info.wire_count)
            + UInt64(info.compressor_page_count)
        let purgeablePages = UInt64(info.purgeable_count)
        let usedPages = occupiedPages > purgeablePages ? occupiedPages - purgeablePages : 0
        snapshot.memoryUsedBytes = min(total, usedPages * UInt64(pageSize))
    }

    private func sampleDisk(into snapshot: inout SystemSnapshot) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity, available >= 0 else { return }
        snapshot.diskTotalBytes = UInt64(total)
        snapshot.diskUsedBytes = UInt64(max(0, total - min(total, available)))
    }

    private func sampleNetwork(into snapshot: inout SystemSnapshot) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            previousNetworkCounters = nil
            previousNetworkTime = nil
            return
        }
        defer { freeifaddrs(first) }

        var counters: [String: NetworkCounter] = [:]
        var ips = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let namePointer = interface.ifa_name, let address = interface.ifa_addr else { continue }
            let name = String(cString: namePointer)
            let flags = interface.ifa_flags
            // en* covers physical Wi-Fi/Ethernet. Avoid VPN, bridge and loopback
            // counters, which would count the same traffic more than once.
            guard name.hasPrefix("en"),
                  flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }

            if address.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data {
                let link = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = NetworkCounter(sent: UInt64(link.ifi_obytes), received: UInt64(link.ifi_ibytes))
            } else if address.pointee.sa_family == UInt8(AF_INET) {
                var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    ips.insert(String(cString: buffer))
                }
            }
        }
        snapshot.localIPs = ips.sorted()

        let now = DispatchTime.now().uptimeNanoseconds
        defer {
            previousNetworkCounters = counters
            previousNetworkTime = now
        }
        guard let previous = previousNetworkCounters, let previousTime = previousNetworkTime,
              now > previousTime, !counters.isEmpty else { return }

        var sent: UInt64 = 0
        var received: UInt64 = 0
        var comparableInterfaces = 0
        for (name, current) in counters {
            guard let old = previous[name], current.sent >= old.sent, current.received >= old.received else { continue }
            sent += current.sent - old.sent
            received += current.received - old.received
            comparableInterfaces += 1
        }
        guard comparableInterfaces > 0 else { return }
        let interval = Double(now - previousTime) / 1_000_000_000
        snapshot.uploadBytesPerSecond = Double(sent) / interval
        snapshot.downloadBytesPerSecond = Double(received) / interval
    }

    private func sampleBattery(into snapshot: inout SystemSnapshot) {
        guard let infoReference = IOPSCopyPowerSourcesInfo() else { return }
        let info = infoReference.takeRetainedValue()
        guard let listReference = IOPSCopyPowerSourcesList(info) else { return }
        let sources = listReference.takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let descriptionReference = IOPSGetPowerSourceDescription(info, source),
                  let description = descriptionReference.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            snapshot.batteryPresent = true
            if let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
               let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
               maximum.doubleValue > 0, current.doubleValue >= 0 {
                snapshot.batteryPercent = min(100, current.doubleValue / maximum.doubleValue * 100)
            }
            snapshot.isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue
            snapshot.powerSource = description[kIOPSPowerSourceStateKey] as? String
            return
        }
    }
}

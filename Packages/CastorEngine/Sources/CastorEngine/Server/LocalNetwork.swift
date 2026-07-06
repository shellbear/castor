import Darwin
import Foundation

public enum LocalNetwork {
    /// The Mac's LAN IPv4 address — the host receivers fetch media from.
    /// Prefers en0 (built-in Wi-Fi/Ethernet), skips loopback and link-local.
    public static func primaryIPv4Address() -> String? {
        var addrList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrList) == 0, let first = addrList else { return nil }
        defer { freeifaddrs(addrList) }

        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            guard let address = host.withUnsafeBufferPointer({ pointer in
                pointer.baseAddress.flatMap { String(validatingCString: $0) }
            }) else { continue }
            guard !address.hasPrefix("169.254.") else { continue }

            if String(cString: interface.ifa_name) == "en0" {
                return address
            }
            fallback = fallback ?? address
        }
        return fallback
    }
}

import Foundation
import SystemConfiguration

public struct NetworkUtilities {
    /// Discovers the active local IPv4 address (e.g., en0 Wi-Fi or active Ethernet)
    public static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            // Check for running, non-loopback IPv4 interface
            if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ifName = String(cString: ptr.pointee.ifa_name)
                        let ip = String(cString: &hostname)
                        
                        // en0 is typically Wi-Fi on macOS
                        if ifName == "en0" {
                            return ip
                        }
                        if address == nil {
                            address = ip
                        }
                    }
                }
            }
        }
        return address
    }
}

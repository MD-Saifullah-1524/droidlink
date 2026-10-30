import Foundation
import Darwin

public final class DeviceWakeupNotifier {
    
    /// Asynchronously signals the paired Android peer via local UDP broadcast beacon and ADB fallback
    public static func notifyAndroidPeer(pairedDevice: PairedDeviceInfo, currentHostIP: String, listeningPort: UInt16? = nil, isManualRequest: Bool = false) {
        let effectivePort = Int(listeningPort ?? (pairedDevice.port > 0 ? pairedDevice.port : 29170))
        DispatchQueue.global(qos: .utility).async {
            // 1. Broadcast UDP Wi-Fi Beacon
            broadcastUdpBeacon(pairedDevice: pairedDevice, currentHostIP: currentHostIP, port: effectivePort, isManualRequest: isManualRequest)
            
            // 2. Dispatch ADB fallback broadcast if device connected via USB
            dispatchAdbBroadcast(host: currentHostIP, port: effectivePort, isManualRequest: isManualRequest)
        }
    }
    
    // MARK: - UDP Wi-Fi Beacon
    
    private static func broadcastUdpBeacon(pairedDevice: PairedDeviceInfo, currentHostIP: String, port: Int, isManualRequest: Bool) {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }
        defer { Darwin.close(sock) }
        
        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        
        let myDeviceName = Host.current().localizedName ?? "Mac"
        let payloadDict: [String: Any] = [
            "event": "MAC_ONLINE",
            "deviceId": PairingStorage.getOrCreateMyDeviceId(),
            "deviceName": myDeviceName,
            "host": currentHostIP,
            "port": port,
            "isManualRequest": isManualRequest
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payloadDict) else { return }
        
        let broadcastPort = in_port_t(9998).bigEndian
        
        // Target 1: Global 255.255.255.255
        var addrAll = sockaddr_in()
        addrAll.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addrAll.sin_family = sa_family_t(AF_INET)
        addrAll.sin_port = broadcastPort
        addrAll.sin_addr.s_addr = inet_addr("255.255.255.255")
        
        // Target 2: Subnet broadcast e.g. 192.168.1.255
        var addrSubnet = sockaddr_in()
        addrSubnet.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addrSubnet.sin_family = sa_family_t(AF_INET)
        addrSubnet.sin_port = broadcastPort
        
        let ipComponents = currentHostIP.split(separator: ".")
        if ipComponents.count == 4 {
            let subnetBroadcast = "\(ipComponents[0]).\(ipComponents[1]).\(ipComponents[2]).255"
            addrSubnet.sin_addr.s_addr = inet_addr(subnetBroadcast)
        } else {
            addrSubnet.sin_addr.s_addr = inet_addr("255.255.255.255")
        }
        
        // Send 3 pulses spaced 250ms apart to overcome packet drops
        for pulse in 1...3 {
            jsonData.withUnsafeBytes { rawBytes in
                guard let baseAddr = rawBytes.baseAddress else { return }
                
                withUnsafePointer(to: &addrAll) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.sendto(sock, baseAddr, jsonData.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                
                withUnsafePointer(to: &addrSubnet) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = Darwin.sendto(sock, baseAddr, jsonData.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if pulse < 3 {
                usleep(250_000)
            }
        }
        
        print("📡 Sent UDP Wi-Fi wake-up beacon to port 9998 (isManualRequest=\(isManualRequest))")
        fflush(stdout)
    }

    // MARK: - ADB USB Fallback

    private static func dispatchAdbBroadcast(host: String, port: Int, isManualRequest: Bool) {
        let adbCandidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        guard let adbPath = adbCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return
        }

        // Establish USB loopback tunnel for port
        let revProcess = Process()
        revProcess.executableURL = URL(fileURLWithPath: adbPath)
        revProcess.arguments = ["reverse", "tcp:\(port)", "tcp:\(port)"]
        revProcess.standardOutput = Pipe()
        revProcess.standardError = Pipe()
        try? revProcess.run()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = [
            "shell", "am", "broadcast",
            "-a", "com.droidlink.ACTION_RETRY_CONNECT",
            "-p", "com.droidlink.app",
            "--es", "host", host,
            "--ei", "port", "\(port)",
            "--ez", "isManualRequest", isManualRequest ? "true" : "false"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            // Ignore ADB failures if daemon not running or device not on USB
        }
    }
}

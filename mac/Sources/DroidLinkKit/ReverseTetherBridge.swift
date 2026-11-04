import Foundation
import Network

/// Userspace NAT & Socket Proxy bridging droidOS Type 0x06 IP packets to the macOS internet connection.
/// Runs entirely in userspace without requiring root permissions, pfctl, or NetworkExtension system approvals.
public final class ReverseTetherBridge: ObservableObject, @unchecked Sendable {
    public static let shared = ReverseTetherBridge()

    @Published public var isEnabled: Bool = true {
        didSet {
            if !isEnabled {
                closeAllSessions()
            }
        }
    }

    /// Callback invoked when a response IPv4 packet is synthesized to send back to the phone (Bulk OUT Type 0x06)
    public var onOutboundIpPacket: ((Data) -> Void)?

    /// Telemetry counters (in bytes)
    public private(set) var totalBytesReceived: UInt64 = 0
    public private(set) var totalBytesSent: UInt64 = 0

    private let queue = DispatchQueue(label: "com.droidlink.reversetether", qos: .userInitiated)
    private let lock = NSLock()

    // Active UDP relay sessions keyed by "srcPort:dstIp:dstPort"
    private var udpSessions: [String: NWConnection] = [:]

    // Active TCP relay sessions keyed by "srcPort:dstIp:dstPort"
    private final class TcpSession: @unchecked Sendable {
        let connection: NWConnection
        let srcIp: UInt32
        let dstIp: UInt32
        let srcPort: UInt16
        let dstPort: UInt16
        var macSeq: UInt32 = 1000
        var phoneSeq: UInt32 = 0
        var isEstablished: Bool = false

        init(connection: NWConnection, srcIp: UInt32, dstIp: UInt32, srcPort: UInt16, dstPort: UInt16) {
            self.connection = connection
            self.srcIp = srcIp
            self.dstIp = dstIp
            self.srcPort = srcPort
            self.dstPort = dstPort
        }
    }
    private var tcpSessions: [String: TcpSession] = [:]

    private init() {}

    /// Ingests an incoming raw IPv4 packet from droidOS TUN interface (via Type 0x06 Bulk IN)
    public func handleIncomingIpPacket(_ packet: Data) {
        guard isEnabled, packet.count >= 20 else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.totalBytesReceived += UInt64(packet.count)
            self.lock.unlock()

            self.parseAndRoute(packet: packet)
        }
    }

    private func parseAndRoute(packet: Data) {
        let versionAndIHL = packet[0]
        let version = (versionAndIHL >> 4) & 0x0F
        guard version == 4 else { return } // IPv4 only for now

        let ihl = Int(versionAndIHL & 0x0F) * 4
        guard packet.count >= ihl else { return }

        let protocolType = packet[9]

        let srcIp = packet.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) }
        let dstIp = packet.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self) }

        let payload = packet.subdata(in: ihl..<packet.count)

        switch protocolType {
        case 1: // ICMP
            handleIcmp(packet: packet, srcIp: srcIp, dstIp: dstIp, icmpData: payload)
        case 17: // UDP (DNS / NTP / App UDP)
            handleUdp(srcIp: srcIp, dstIp: dstIp, udpData: payload)
        case 6: // TCP
            handleTcp(srcIp: srcIp, dstIp: dstIp, tcpData: payload)
        default:
            break
        }
    }

    // MARK: - ICMP Ping Handler (Instant Echo Reply)

    private func handleIcmp(packet: Data, srcIp: UInt32, dstIp: UInt32, icmpData: Data) {
        guard icmpData.count >= 8 else { return }
        let icmpType = icmpData[0]
        let icmpCode = icmpData[1]

        if icmpType == 8 { // Echo Request (ping)
            var replyIcmp = icmpData
            replyIcmp[0] = 0 // Echo Reply
            replyIcmp[1] = icmpCode
            replyIcmp[2] = 0 // Clear checksum
            replyIcmp[3] = 0

            let csum = computeChecksum(replyIcmp)
            var csumBE = csum.bigEndian
            withUnsafeBytes(of: &csumBE) { replyIcmp.replaceSubrange(2..<4, with: $0) }

            let replyIpPacket = buildIpv4Packet(srcIp: dstIp, dstIp: srcIp, protocolType: 1, payload: replyIcmp)
            sendOutbound(packet: replyIpPacket)
        }
    }

    // MARK: - UDP Handler (DNS & General Sockets via NWConnection)

    private func handleUdp(srcIp: UInt32, dstIp: UInt32, udpData: Data) {
        guard udpData.count >= 8 else { return }

        let srcPort = udpData.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let dstPort = udpData.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let length = Int(udpData.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })

        guard udpData.count >= length, length >= 8 else { return }
        let udpPayload = udpData.subdata(in: 8..<length)

        let dstIpStr = ipToString(dstIp)
        let sessionKey = "\(srcPort):\(dstIpStr):\(dstPort)"

        lock.lock()
        var conn = udpSessions[sessionKey]
        lock.unlock()

        if conn == nil {
            guard let port = NWEndpoint.Port(rawValue: dstPort) else { return }
            // If phone queries gateway 10.0.0.1 for DNS, forward to Cloudflare DNS 1.1.1.1
            let targetHostStr = (dstIpStr == "10.0.0.1" && dstPort == 53) ? "1.1.1.1" : dstIpStr
            let host = NWEndpoint.Host(targetHostStr)
            let params = NWParameters.udp
            let newConn = NWConnection(host: host, port: port, using: params)

            newConn.stateUpdateHandler = { [weak self, weak newConn] state in
                guard let self = self, let newConn = newConn else { return }
                if case .ready = state {
                    self.readUdpLoop(conn: newConn, srcIp: srcIp, dstIp: dstIp, srcPort: srcPort, dstPort: dstPort)
                } else if case .failed = state {
                    self.removeUdpSession(key: sessionKey)
                }
            }
            newConn.start(queue: queue)

            lock.lock()
            udpSessions[sessionKey] = newConn
            lock.unlock()
            conn = newConn
        }

        conn?.send(content: udpPayload, completion: .contentProcessed({ error in
            if error != nil {
                // Ignore transient write errors
            }
        }))
    }

    private func readUdpLoop(conn: NWConnection, srcIp: UInt32, dstIp: UInt32, srcPort: UInt16, dstPort: UInt16) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn else { return }
            if let data = data, !data.isEmpty {
                let synthesizedUdp = self.buildUdpPacket(srcIp: dstIp, dstIp: srcIp, srcPort: dstPort, dstPort: srcPort, payload: data)
                self.sendOutbound(packet: synthesizedUdp)
            }
            if !isComplete && error == nil {
                self.readUdpLoop(conn: conn, srcIp: srcIp, dstIp: dstIp, srcPort: srcPort, dstPort: dstPort)
            }
        }
    }

    private func removeUdpSession(key: String) {
        lock.lock()
        udpSessions.removeValue(forKey: key)?.cancel()
        lock.unlock()
    }

    // MARK: - TCP Handler (Userspace Proxy)

    private func handleTcp(srcIp: UInt32, dstIp: UInt32, tcpData: Data) {
        guard tcpData.count >= 20 else { return }

        let srcPort = tcpData.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let dstPort = tcpData.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let seqNum = tcpData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let flags = tcpData[13]
        let dataOffset = Int((tcpData[12] >> 4) & 0x0F) * 4

        let isSyn = (flags & 0x02) != 0
        let isFin = (flags & 0x01) != 0
        let isRst = (flags & 0x04) != 0

        let dstIpStr = ipToString(dstIp)
        let sessionKey = "\(srcPort):\(dstIpStr):\(dstPort)"

        if isSyn {
            // Initiate outbound TCP socket to remote destination
            guard let port = NWEndpoint.Port(rawValue: dstPort) else { return }
            let host = NWEndpoint.Host(dstIpStr)
            let params = NWParameters.tcp
            let newConn = NWConnection(host: host, port: port, using: params)

            let session = TcpSession(connection: newConn, srcIp: srcIp, dstIp: dstIp, srcPort: srcPort, dstPort: dstPort)
            session.phoneSeq = seqNum &+ 1

            lock.lock()
            tcpSessions[sessionKey] = session
            lock.unlock()

            newConn.stateUpdateHandler = { [weak self, weak session] state in
                guard let self = self, let session = session else { return }
                if case .ready = state {
                    session.isEstablished = true
                    // Send SYN-ACK packet back to phone
                    let synAck = self.buildTcpPacket(
                        srcIp: session.dstIp,
                        dstIp: session.srcIp,
                        srcPort: session.dstPort,
                        dstPort: session.srcPort,
                        seqNum: session.macSeq,
                        ackNum: session.phoneSeq,
                        flags: 0x12 // SYN + ACK
                    )
                    session.macSeq &+= 1
                    self.sendOutbound(packet: synAck)
                    self.readTcpLoop(session: session)
                } else if case .failed = state {
                    self.sendTcpRst(srcIp: session.dstIp, dstIp: session.srcIp, srcPort: session.dstPort, dstPort: session.srcPort, seq: session.macSeq, ack: session.phoneSeq)
                    self.removeTcpSession(key: sessionKey)
                }
            }
            newConn.start(queue: queue)
            return
        }

        lock.lock()
        guard let session = tcpSessions[sessionKey] else {
            lock.unlock()
            if !isRst {
                sendTcpRst(srcIp: dstIp, dstIp: srcIp, srcPort: dstPort, dstPort: srcPort, seq: 0, ack: seqNum &+ 1)
            }
            return
        }
        lock.unlock()

        if isFin || isRst {
            session.connection.cancel()
            removeTcpSession(key: sessionKey)
            if isFin {
                let finAck = buildTcpPacket(
                    srcIp: session.dstIp,
                    dstIp: session.srcIp,
                    srcPort: session.dstPort,
                    dstPort: session.srcPort,
                    seqNum: session.macSeq,
                    ackNum: seqNum &+ 1,
                    flags: 0x11 // FIN + ACK
                )
                sendOutbound(packet: finAck)
            }
            return
        }

        // Relay TCP payload data to remote server
        if tcpData.count > dataOffset {
            let payload = tcpData.subdata(in: dataOffset..<tcpData.count)
            session.phoneSeq = seqNum &+ UInt32(payload.count)

            session.connection.send(content: payload, completion: .contentProcessed({ [weak self, weak session] error in
                guard let self = self, let session = session else { return }
                if error == nil {
                    // Send ACK back to phone
                    let ack = self.buildTcpPacket(
                        srcIp: session.dstIp,
                        dstIp: session.srcIp,
                        srcPort: session.dstPort,
                        dstPort: session.srcPort,
                        seqNum: session.macSeq,
                        ackNum: session.phoneSeq,
                        flags: 0x10 // ACK
                    )
                    self.sendOutbound(packet: ack)
                }
            }))
        }
    }

    private func readTcpLoop(session: TcpSession) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 1400) { [weak self, weak session] data, _, isComplete, error in
            guard let self = self, let session = session else { return }
            if let data = data, !data.isEmpty {
                let dataPkt = self.buildTcpPacket(
                    srcIp: session.dstIp,
                    dstIp: session.srcIp,
                    srcPort: session.dstPort,
                    dstPort: session.srcPort,
                    seqNum: session.macSeq,
                    ackNum: session.phoneSeq,
                    flags: 0x18, // PSH + ACK
                    payload: data
                )
                session.macSeq &+= UInt32(data.count)
                self.sendOutbound(packet: dataPkt)
            }
            if isComplete || error != nil {
                let finPkt = self.buildTcpPacket(
                    srcIp: session.dstIp,
                    dstIp: session.srcIp,
                    srcPort: session.dstPort,
                    dstPort: session.srcPort,
                    seqNum: session.macSeq,
                    ackNum: session.phoneSeq,
                    flags: 0x11 // FIN + ACK
                )
                self.sendOutbound(packet: finPkt)
            } else {
                self.readTcpLoop(session: session)
            }
        }
    }

    private func sendTcpRst(srcIp: UInt32, dstIp: UInt32, srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32) {
        let rst = buildTcpPacket(srcIp: srcIp, dstIp: dstIp, srcPort: srcPort, dstPort: dstPort, seqNum: seq, ackNum: ack, flags: 0x14) // RST + ACK
        sendOutbound(packet: rst)
    }

    private func removeTcpSession(key: String) {
        lock.lock()
        tcpSessions.removeValue(forKey: key)?.connection.cancel()
        lock.unlock()
    }

    public func closeAllSessions() {
        lock.lock()
        for (_, c) in udpSessions { c.cancel() }
        udpSessions.removeAll()
        for (_, s) in tcpSessions { s.connection.cancel() }
        tcpSessions.removeAll()
        lock.unlock()
    }

    // MARK: - Packet Synthesis Helpers

    private func sendOutbound(packet: Data) {
        lock.lock()
        totalBytesSent += UInt64(packet.count)
        lock.unlock()
        onOutboundIpPacket?(packet)
    }

    private func buildIpv4Packet(srcIp: UInt32, dstIp: UInt32, protocolType: UInt8, payload: Data) -> Data {
        var ip = Data(count: 20 + payload.count)
        ip[0] = 0x45 // Version 4, IHL 5
        ip[1] = 0x00 // DSCP / ECN
        var totalLenBE = UInt16(ip.count).bigEndian
        withUnsafeBytes(of: &totalLenBE) { ip.replaceSubrange(2..<4, with: $0) }
        ip[4] = 0x00 // ID
        ip[5] = 0x00
        ip[6] = 0x40 // Flags: Don't Fragment
        ip[7] = 0x00
        ip[8] = 64   // TTL
        ip[9] = protocolType
        ip[10] = 0x00 // Checksum
        ip[11] = 0x00
        var sBE = srcIp
        withUnsafeBytes(of: &sBE) { ip.replaceSubrange(12..<16, with: $0) }
        var dBE = dstIp
        withUnsafeBytes(of: &dBE) { ip.replaceSubrange(16..<20, with: $0) }

        let csum = computeChecksum(ip.subdata(in: 0..<20))
        var csumBE = csum.bigEndian
        withUnsafeBytes(of: &csumBE) { ip.replaceSubrange(10..<12, with: $0) }

        ip.replaceSubrange(20..<ip.count, with: payload)
        return ip
    }

    private func buildUdpPacket(srcIp: UInt32, dstIp: UInt32, srcPort: UInt16, dstPort: UInt16, payload: Data) -> Data {
        var udp = Data(count: 8 + payload.count)
        var spBE = srcPort.bigEndian
        withUnsafeBytes(of: &spBE) { udp.replaceSubrange(0..<2, with: $0) }
        var dpBE = dstPort.bigEndian
        withUnsafeBytes(of: &dpBE) { udp.replaceSubrange(2..<4, with: $0) }
        var lenBE = UInt16(udp.count).bigEndian
        withUnsafeBytes(of: &lenBE) { udp.replaceSubrange(4..<6, with: $0) }
        udp[6] = 0x00
        udp[7] = 0x00
        udp.replaceSubrange(8..<udp.count, with: payload)

        return buildIpv4Packet(srcIp: srcIp, dstIp: dstIp, protocolType: 17, payload: udp)
    }

    private func buildTcpPacket(srcIp: UInt32, dstIp: UInt32, srcPort: UInt16, dstPort: UInt16, seqNum: UInt32, ackNum: UInt32, flags: UInt8, payload: Data = Data()) -> Data {
        var tcp = Data(count: 20 + payload.count)
        var spBE = srcPort.bigEndian
        withUnsafeBytes(of: &spBE) { tcp.replaceSubrange(0..<2, with: $0) }
        var dpBE = dstPort.bigEndian
        withUnsafeBytes(of: &dpBE) { tcp.replaceSubrange(2..<4, with: $0) }
        var seqBE = seqNum.bigEndian
        withUnsafeBytes(of: &seqBE) { tcp.replaceSubrange(4..<8, with: $0) }
        var ackBE = ackNum.bigEndian
        withUnsafeBytes(of: &ackBE) { tcp.replaceSubrange(8..<12, with: $0) }
        tcp[12] = 0x50 // Data offset 5 (20 bytes)
        tcp[13] = flags
        var winBE = UInt16(65535).bigEndian
        withUnsafeBytes(of: &winBE) { tcp.replaceSubrange(14..<16, with: $0) }
        tcp[16] = 0x00 // Checksum
        tcp[17] = 0x00
        tcp[18] = 0x00 // Urgent pointer
        tcp[19] = 0x00

        if !payload.isEmpty {
            tcp.replaceSubrange(20..<tcp.count, with: payload)
        }

        // Compute TCP pseudo-header checksum
        let pseudoChecksum = computeTcpChecksum(srcIp: srcIp, dstIp: dstIp, tcpData: tcp)
        var pcBE = pseudoChecksum.bigEndian
        withUnsafeBytes(of: &pcBE) { tcp.replaceSubrange(16..<18, with: $0) }

        return buildIpv4Packet(srcIp: srcIp, dstIp: dstIp, protocolType: 6, payload: tcp)
    }

    private func computeChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i < data.count - 1 {
            let word = UInt32(data[i]) << 8 | UInt32(data[i + 1])
            sum &+= word
            i += 2
        }
        if i < data.count {
            sum &+= UInt32(data[i]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func computeTcpChecksum(srcIp: UInt32, dstIp: UInt32, tcpData: Data) -> UInt16 {
        var sum: UInt32 = 0
        sum &+= (srcIp >> 16) & 0xFFFF
        sum &+= srcIp & 0xFFFF
        sum &+= (dstIp >> 16) & 0xFFFF
        sum &+= dstIp & 0xFFFF
        sum &+= 6 // TCP protocol
        sum &+= UInt32(tcpData.count)

        var i = 0
        while i < tcpData.count - 1 {
            let word = UInt32(tcpData[i]) << 8 | UInt32(tcpData[i + 1])
            sum &+= word
            i += 2
        }
        if i < tcpData.count {
            sum &+= UInt32(tcpData[i]) << 8
        }
        while (sum >> 16) != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    private func ipToString(_ ip: UInt32) -> String {
        let b0 = (ip >> 24) & 0xFF
        let b1 = (ip >> 16) & 0xFF
        let b2 = (ip >> 8) & 0xFF
        let b3 = ip & 0xFF
        return "\(b0).\(b1).\(b2).\(b3)"
    }
}

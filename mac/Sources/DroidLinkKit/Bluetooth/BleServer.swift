import Foundation
import CoreBluetooth
import SwiftProtobuf

/// Protocol for BleServer events
@MainActor
protocol BleServerDelegate: AnyObject {
    func bleServerDidUpdateState(_ isReady: Bool)
    func bleServerDidConnect(deviceName: String, deviceId: String)
    func bleServerDidDisconnect()
    func bleServerDidReceiveMessage(_ message: Droidlink_Protocol_DroidLinkMessage)
}

/// DroidLink BLE Peripheral Server for macOS.
/// Advertises DroidLink service, manages GATT characteristics, and transfers encrypted Protobuf frames.
@MainActor
public final class BleServer: NSObject {
    
    // Custom 128-bit DroidLink BLE Service and Characteristic UUIDs
    public static let serviceUUID = CBUUID(string: "D701D100-38F1-4F24-B1F7-3C7E9D420001")
    public static let pairingCharUUID = CBUUID(string: "D701D101-38F1-4F24-B1F7-3C7E9D420001")
    public static let txCharUUID = CBUUID(string: "D701D102-38F1-4F24-B1F7-3C7E9D420001") // Mac -> Android (Notify)
    public static let rxCharUUID = CBUUID(string: "D701D103-38F1-4F24-B1F7-3C7E9D420001") // Android -> Mac (Write)
    public static let deviceInfoCharUUID = CBUUID(string: "D701D104-38F1-4F24-B1F7-3C7E9D420001") // Read
    
    weak var delegate: BleServerDelegate?
    
    private var peripheralManager: CBPeripheralManager!
    private var service: CBMutableService?
    private var pairingChar: CBMutableCharacteristic?
    private var txChar: CBMutableCharacteristic?
    private var rxChar: CBMutableCharacteristic?
    private var deviceInfoChar: CBMutableCharacteristic?
    
    public private(set) var isAdvertising: Bool = false
    public private(set) var connectedCentral: CBCentral?
    public var cryptoChannel: CryptoChannel?
    
    private let framer = MessageFramer()
    private let rxChunker = BleChunker()
    private var incomingDeframingBuffer = Data()
    private var outgoingChunkQueue: [Data] = []
    private var pendingFileContinuations: [CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>] = []
    
    private var advertisedName: String = "Mac"
    private var isPairingMode: Bool = true
    private var isServicePublished: Bool = false
    
    public override init() {
        super.init()
        self.advertisedName = Host.current().localizedName ?? "Mac"
        self.peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }
    
    /// Starts advertising DroidLink BLE Service
    public func startAdvertising(deviceName: String, pairingMode: Bool = true) {
        self.advertisedName = deviceName
        self.isPairingMode = pairingMode
        self.isAdvertising = true
        
        guard peripheralManager.state == .poweredOn else {
            print("⏳ Bluetooth not powered on yet (state: \(peripheralManager.state.rawValue)), will advertise once ready")
            fflush(stdout)
            return
        }
        
        setupGattServiceIfNeeded()
        
        if isServicePublished {
            beginAdvertisingOnHardware()
        } else {
            print("⏳ Waiting for GATT service publication before starting BLE advertising...")
            fflush(stdout)
        }
    }
    
    private func beginAdvertisingOnHardware() {
        guard peripheralManager.state == .poweredOn, isServicePublished else { return }
        let advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "DroidLink (\(advertisedName))"
        ]
        
        peripheralManager.stopAdvertising()
        peripheralManager.startAdvertising(advertisementData)
        print("📢 DroidLink BLE advertising started as: 'DroidLink (\(advertisedName))'")
        fflush(stdout)
    }
    
    /// Stops advertising
    public func stopAdvertising() {
        peripheralManager.stopAdvertising()
        self.isAdvertising = false
        print("🛑 DroidLink BLE advertising stopped")
        fflush(stdout)
    }
    
    private func setupGattServiceIfNeeded() {
        guard service == nil else { return }
        
        let pairing = CBMutableCharacteristic(
            type: Self.pairingCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        let tx = CBMutableCharacteristic(
            type: Self.txCharUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        
        let rx = CBMutableCharacteristic(
            type: Self.rxCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        
        let infoData = try? JSONEncoder().encode([
            "name": advertisedName,
            "id": PairingStorage.getOrCreateMyDeviceId(),
            "version": "3.0.0"
        ])
        let info = CBMutableCharacteristic(
            type: Self.deviceInfoCharUUID,
            properties: [.read],
            value: infoData,
            permissions: [] // Static cached characteristic must have empty permissions in CoreBluetooth
        )
        
        let gattService = CBMutableService(type: Self.serviceUUID, primary: true)
        gattService.characteristics = [pairing, tx, rx, info]
        
        self.pairingChar = pairing
        self.txChar = tx
        self.rxChar = rx
        self.deviceInfoChar = info
        self.service = gattService
        
        peripheralManager.add(gattService)
        print("✨ Registering DroidLink GATT Service with 4 characteristics...")
        fflush(stdout)
    }
    
    /// Sends a Protobuf message framed and encrypted over BLE TX characteristic
    func send(message: Droidlink_Protocol_DroidLinkMessage) {
        guard let central = connectedCentral, txChar != nil else {
            print("⚠️ Cannot send BLE message: No central connected or TX characteristic unavailable")
            fflush(stdout)
            return
        }
        
        do {
            let serialized = try message.serializedData()
            let encrypted: Data
            if let crypto = cryptoChannel {
                encrypted = try crypto.encrypt(serialized)
            } else {
                encrypted = serialized
            }
            
            let frame = try framer.frame(encrypted)
            
            // Negotiated MTU payload capacity (typical 500-512 bytes on BLE 5.0)
            let maxChunkSize = max(20, min(512, central.maximumUpdateValueLength))
            let chunks = BleChunker.chunk(data: frame, maxChunkSize: maxChunkSize)
            
            outgoingChunkQueue.append(contentsOf: chunks)
            flushOutgoingQueue()
        } catch {
            print("❌ Failed to serialize/encrypt BLE message: \(error)")
            fflush(stdout)
        }
    }
    
    private func flushOutgoingQueue() {
        guard let tx = txChar else { return }
        
        while !outgoingChunkQueue.isEmpty {
            let chunk = outgoingChunkQueue[0]
            let success = peripheralManager.updateValue(chunk, for: tx, onSubscribedCentrals: nil)
            if success {
                outgoingChunkQueue.removeFirst()
            } else {
                // Transmit buffer full; wait for peripheralManagerIsReady
                break
            }
        }
    }

    /// Sends a FileMessage to Android and awaits the response asynchronously
    func requestFileOperation(_ fileMsg: Droidlink_Protocol_FileMessage) async throws -> Droidlink_Protocol_FileMessage {
        guard connectedCentral != nil else {
            throw NSError(domain: "BleServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active BLE connection to Android"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingFileContinuations.append(continuation)
            var rootMsg = Droidlink_Protocol_DroidLinkMessage()
            rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
            rootMsg.timestamp = rootMsg.id
            rootMsg.type = .fileTransfer
            rootMsg.file = fileMsg
            send(message: rootMsg)
        }
    }
    
    /// Sends a goodbye message and resets connection
    public func disconnect(isManual: Bool = false) {
        var sysMsg = Droidlink_Protocol_SystemMessage()
        sysMsg.event = .goodbye
        if isManual {
            var err = Droidlink_Protocol_ErrorMessage()
            err.code = .errorUnknown
            err.message = "MANUAL_DISCONNECT"
            sysMsg.error = err
        }
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .system
        rootMsg.system = sysMsg
        send(message: rootMsg)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.connectedCentral = nil
            self.rxChunker.reset()
            self.incomingDeframingBuffer.removeAll()
            self.outgoingChunkQueue.removeAll()
            for continuation in self.pendingFileContinuations {
                continuation.resume(throwing: NSError(domain: "BleServer", code: -2, userInfo: [NSLocalizedDescriptionKey: "BLE disconnected"]))
            }
            self.pendingFileContinuations.removeAll()
            self.delegate?.bleServerDidDisconnect()
            NotificationCenter.default.post(name: .droidlinkDeviceDisconnected, object: nil)
        }
    }
    
    private func handleIncomingCompleteFrame(_ frameData: Data) {
        incomingDeframingBuffer.append(frameData)
        do {
            let deframedList = try framer.deframe(from: &incomingDeframingBuffer)
            for payload in deframedList {
                let decrypted: Data
                if let crypto = cryptoChannel {
                    decrypted = try crypto.decrypt(payload)
                } else {
                    decrypted = payload
                }
                
                let message = try Droidlink_Protocol_DroidLinkMessage(serializedBytes: decrypted)
                dispatchReceivedMessage(message)
            }
        } catch {
            print("❌ BLE deframing/decryption error: \(error)")
            fflush(stdout)
            incomingDeframingBuffer.removeAll()
        }
    }
    
    private func dispatchReceivedMessage(_ message: Droidlink_Protocol_DroidLinkMessage) {
        delegate?.bleServerDidReceiveMessage(message)
        
        switch message.payload {
        case .clipboard(let clip):
            print("📋 BLE Clipboard received: \(clip.data.text)")
            fflush(stdout)
            NotificationCenter.default.post(name: .droidlinkClipboardReceived, object: clip)
            
        case .notification(let notif):
            print("🔔 BLE Notification received: \(notif.notification.title)")
            fflush(stdout)
            NotificationCenter.default.post(name: .droidlinkNotificationReceived, object: notif)
            
        case .file(let fileMsg):
            print("📁 BLE File message: \(fileMsg.operation)")
            fflush(stdout)
            if fileMsg.operation == .fileChangeEvent {
                NotificationCenter.default.post(name: .droidlinkFileChanged, object: fileMsg)
            } else if !pendingFileContinuations.isEmpty {
                let continuation = pendingFileContinuations.removeFirst()
                continuation.resume(returning: fileMsg)
            } else {
                NotificationCenter.default.post(name: .droidlinkFileReceived, object: fileMsg)
            }
            
        case .system(let sys):
            if sys.event == .goodbye {
                let isManual = sys.hasError && sys.error.message == "MANUAL_DISCONNECT"
                print("👋 BLE Remote peer sent GOODBYE\(isManual ? " (MANUAL_DISCONNECT)" : "")")
                fflush(stdout)
                if isManual {
                    PairingStorage.isManuallyDisconnected = true
                }
                disconnect(isManual: isManual)
            } else if sys.hasError && sys.error.message == "DEVICE_STATUS" {
                if let status = DeviceStatusInfo.fromJsonString(sys.error.details) {
                    print("📱 Received Android telemetry: \(status.deviceName) (\(status.deviceModel)) - Battery: \(status.batteryLevel)%")
                    fflush(stdout)
                    NotificationCenter.default.post(name: .droidlinkDeviceStatusReceived, object: status)
                }
            }
        case .screen(let screenMsg):
            ScreenMirroringManager.shared.handleScreenMessage(screenMsg)
        default:
            break
        }
    }
    
    public func sendLocalTelemetry() {
        let status = MacTelemetryCollector.shared.collectStatus()
        guard let jsonStr = status.toJsonString() else { return }
        
        var errMsg = Droidlink_Protocol_ErrorMessage()
        errMsg.code = .errorUnknown
        errMsg.message = "DEVICE_STATUS"
        errMsg.details = jsonStr
        
        var sysMsg = Droidlink_Protocol_SystemMessage()
        sysMsg.event = .sysError
        sysMsg.error = errMsg
        
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .system
        rootMsg.system = sysMsg
        
        send(message: rootMsg)
        print("📊 Sent Mac telemetry to Android: \(status.deviceName) (\(status.deviceModel)) - \(status.batteryLevel)%")
        fflush(stdout)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BleServer: @preconcurrency CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let isReady = (peripheral.state == .poweredOn)
        print("📶 CBPeripheralManager state: \(peripheral.state.rawValue) (poweredOn=\(isReady))")
        fflush(stdout)
        
        if isReady {
            setupGattServiceIfNeeded()
        }
        delegate?.bleServerDidUpdateState(isReady)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error = error {
            print("❌ Failed to add GATT service: \(error)")
            self.isServicePublished = false
        } else {
            print("✅ Successfully published GATT service: \(service.uuid)")
            self.isServicePublished = true
            if isAdvertising {
                beginAdvertisingOnHardware()
            }
        }
        fflush(stdout)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        print("🔗 Central subscribed to \(characteristic.uuid): \(central.identifier.uuidString)")
        fflush(stdout)
        self.connectedCentral = central
        
        let deviceName = PairingStorage.loadPairedDevice()?.deviceName ?? "Android Device"
        delegate?.bleServerDidConnect(deviceName: deviceName, deviceId: central.identifier.uuidString)
        NotificationCenter.default.post(name: .droidlinkDeviceConnected, object: deviceName)
        sendLocalTelemetry()
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        print("🔌 Central unsubscribed from \(characteristic.uuid)")
        fflush(stdout)
        if connectedCentral?.identifier == central.identifier {
            connectedCentral = nil
            delegate?.bleServerDidDisconnect()
            NotificationCenter.default.post(name: .droidlinkDeviceDisconnected, object: nil)
        }
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushOutgoingQueue()
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let data = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }
            
            if request.characteristic.uuid == Self.pairingCharUUID {
                handlePairingWrite(data: data, request: request)
            } else if request.characteristic.uuid == Self.rxCharUUID {
                if let completeFrame = rxChunker.feed(chunk: data) {
                    print("📦 BLE reassembled complete frame: \(completeFrame.count) bytes")
                    fflush(stdout)
                    handleIncomingCompleteFrame(completeFrame)
                }
                peripheral.respond(to: request, withResult: .success)
            } else {
                peripheral.respond(to: request, withResult: .requestNotSupported)
            }
        }
    }
    
    private func handlePairingWrite(data: Data, request: CBATTRequest) {
        do {
            struct PairingRequest: Decodable {
                let version: String
                let deviceId: String
                let deviceName: String
                let deviceModel: String?
                let sessionKey: String
            }
            
            struct PairingResponse: Encodable {
                let version: String
                let deviceId: String
                let deviceName: String
                let deviceModel: String?
                let status: String
            }
            
            let req = try JSONDecoder().decode(PairingRequest.self, from: data)
            guard let keyData = Data(base64Encoded: req.sessionKey) else {
                peripheralManager.respond(to: request, withResult: .invalidAttributeValueLength)
                return
            }
            
            print("🤝 BLE Pairing Request from \(req.deviceName) (\(req.deviceId))")
            fflush(stdout)
            
            self.cryptoChannel = try CryptoChannel(keyData: keyData)
            
            let myDeviceId = PairingStorage.getOrCreateMyDeviceId()
            let myDeviceName = Host.current().localizedName ?? "Mac"
            let myDeviceModel = MacTelemetryCollector.shared.getMacModel()
            
            let saved = PairedDeviceInfo(
                deviceId: req.deviceId,
                deviceName: req.deviceName,
                deviceModel: req.deviceModel ?? "Android Device",
                sessionKey: keyData,
                bluetoothIdentifier: request.central.identifier.uuidString
            )
            PairingStorage.save(device: saved)
            
            let resp = PairingResponse(
                version: "3.0.0",
                deviceId: myDeviceId,
                deviceName: myDeviceName,
                deviceModel: myDeviceModel,
                status: "PAIRED"
            )
            
            if let respData = try? JSONEncoder().encode(resp) {
                pairingChar?.value = respData
                if let tx = txChar {
                    peripheralManager.updateValue(respData, for: tx, onSubscribedCentrals: [request.central])
                }
            }
            
            self.connectedCentral = request.central
            peripheralManager.respond(to: request, withResult: .success)
            
            delegate?.bleServerDidConnect(deviceName: req.deviceName, deviceId: req.deviceId)
            NotificationCenter.default.post(name: .droidlinkDeviceConnected, object: req.deviceName)
            sendLocalTelemetry()
        } catch {
            print("❌ Pairing request parse failed: \(error)")
            fflush(stdout)
            peripheralManager.respond(to: request, withResult: .unlikelyError)
        }
    }
}

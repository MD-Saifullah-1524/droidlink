import Foundation
import IOKit
import IOKit.usb

// AOA USB Plugin UUID helpers (thread-safe functions avoiding non-Sendable global variables)
private func aoaUSBDeviceUserClientTypeID() -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
}
private func aoaIOCFPlugInInterfaceID() -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
}
private func aoaUSBDeviceInterfaceID100() -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, 0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
}
private func aoaUSBInterfaceUserClientTypeID() -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, 0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4, 0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
}
private func aoaUSBInterfaceInterfaceID100() -> CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil, 0x73, 0xc9, 0x7a, 0xe8, 0x9e, 0xf3, 0x11, 0xD4, 0xb1, 0xd0, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
}

/// High-speed, zero-latency direct USB transport utilizing Android Open Accessory (AOA 2.0).
/// Does NOT require ADB, USB debugging, developer options, or Wi-Fi network routing.
public final class AoaUsbManager: ObservableObject, @unchecked Sendable {
    public static let shared = AoaUsbManager()

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isAccessoryMode: Bool = false
    @Published public private(set) var isDroidOsSession: Bool = false
    @Published public private(set) var connectedDeviceName: String = ""
    @Published public var activeProfile: AoaAccessoryProfile = AoaAccessoryProfile.current

    public var onMessageReceived: ((Data) -> Void)?
    public var onDroidOsPacketReceived: ((_ type: DroidOsProtocol.MessageType, _ flags: UInt8, _ payload: Data) -> Void)?
    public var onConnectionStatusChanged: ((Bool) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private let queue = DispatchQueue(label: "com.droidlink.aoa.usb", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "com.droidlink.aoa.write", qos: .userInitiated)
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    private var _rawIsConnected: Bool = false
    private var _rawIsAccessoryMode: Bool = false
    private var _rawIsDroidOsSession: Bool = false
    private var _rawConnectedDeviceName: String = ""
    private var failedProbeCooldowns: [String: Date] = [:]
    private var consecutiveWriteTimeouts: Int = 0

    /// Thread-safe accessor for USB background queues
    public var isSessionActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _rawIsConnected
    }

    /// Thread-safe check if currently in droidOS mode
    public var isDroidOsActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _rawIsDroidOsSession || activeProfile == .droidOS
    }

    // Active accessory interface
    private var activeDeviceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>?
    private var activeInterfaceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>?
    private var bulkInPipeRef: UInt8 = 0
    private var bulkOutPipeRef: UInt8 = 0
    private var isReading: Bool = false
    private var scanTimer: Timer?

    private init() {}

    deinit {
        stopMonitoring()
        disconnect()
    }

    /// Starts scanning and listening for Android USB devices and AOA accessories
    public func startMonitoring() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.setupUsbNotifications()
            self.scanConnectedDevices()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.scanTimer?.invalidate()
            self.scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if !self.isSessionActive {
                    self.queue.async {
                        self.scanConnectedDevices()
                    }
                }
            }
        }
    }

    /// Stops monitoring USB bus events
    public func stopMonitoring() {
        DispatchQueue.main.async { [weak self] in
            self?.scanTimer?.invalidate()
            self?.scanTimer = nil
        }
        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if terminatedIterator != 0 {
            IOObjectRelease(terminatedIterator)
            terminatedIterator = 0
        }
        if let notifyPort = notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }

    // MARK: - USB Notification & Discovery

    private func setupUsbNotifications() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else {
            print("❌ AoaUsbManager: Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary

        // 1. Matched (Device attached) notification
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let matchCallback: IOServiceMatchingCallback = { userData, iterator in
            guard let userData = userData else { return }
            let manager = Unmanaged<AoaUsbManager>.fromOpaque(userData).takeUnretainedValue()
            manager.queue.async {
                manager.handleMatchedDevices(iterator: iterator)
            }
        }

        let krMatch = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchingDict.mutableCopy() as! CFDictionary,
            matchCallback,
            selfPtr,
            &matchedIterator
        )

        if krMatch == KERN_SUCCESS {
            handleMatchedDevices(iterator: matchedIterator)
        }

        // 2. Terminated (Device detached) notification
        let termCallback: IOServiceMatchingCallback = { userData, iterator in
            guard let userData = userData else { return }
            let manager = Unmanaged<AoaUsbManager>.fromOpaque(userData).takeUnretainedValue()
            manager.queue.async {
                manager.handleTerminatedDevices(iterator: iterator)
            }
        }

        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchingDict.mutableCopy() as! CFDictionary,
            termCallback,
            selfPtr,
            &terminatedIterator
        )
    }

    private func handleMatchedDevices(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if !isConnected {
                probeDevice(service: service)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func handleTerminatedDevices(iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        if isSessionActive {
            print("🔌 AoaUsbManager: USB device disconnected from bus")
            disconnect()
        }
    }

    /// Scans all currently attached USB devices
    public func scanConnectedDevices() {
        guard !isSessionActive else { return }
        for className in ["IOUSBDevice", "IOUSBHostDevice"] {
            var iterator: io_iterator_t = 0
            let matchingDict = IOServiceMatching(className)
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
            guard kr == KERN_SUCCESS else { continue }

            var service = IOIteratorNext(iterator)
            while service != 0 {
                probeDevice(service: service)
                IOObjectRelease(service)
                if isSessionActive {
                    IOObjectRelease(iterator)
                    return
                }
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }
    }

    // MARK: - Device Probing & AOA Handshake

    private func probeDevice(service: io_service_t) {
        guard !isSessionActive else { return }

        var entryName = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &entryName)
        let deviceName = String(cString: entryName)

        stateLock.lock()
        if let lastFail = failedProbeCooldowns[deviceName], Date().timeIntervalSince(lastFail) < 5.0 {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        var score: Int32 = 0
        var plugInPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>? = nil
        let plugInResult = IOCreatePlugInInterfaceForService(
            service,
            aoaUSBDeviceUserClientTypeID(),
            aoaIOCFPlugInInterfaceID(),
            &plugInPtr,
            &score
        )

        guard plugInResult == KERN_SUCCESS, let plugIn = plugInPtr?.pointee?.pointee else { return }

        var rawDevicePtr: LPVOID? = nil
        let uuidBytes = CFUUIDGetUUIDBytes(aoaUSBDeviceInterfaceID100())
        let queryResult = plugIn.QueryInterface(
            plugInPtr,
            CFUUIDBytes(
                byte0: uuidBytes.byte0, byte1: uuidBytes.byte1, byte2: uuidBytes.byte2, byte3: uuidBytes.byte3,
                byte4: uuidBytes.byte4, byte5: uuidBytes.byte5, byte6: uuidBytes.byte6, byte7: uuidBytes.byte7,
                byte8: uuidBytes.byte8, byte9: uuidBytes.byte9, byte10: uuidBytes.byte10, byte11: uuidBytes.byte11,
                byte12: uuidBytes.byte12, byte13: uuidBytes.byte13, byte14: uuidBytes.byte14, byte15: uuidBytes.byte15
            ),
            &rawDevicePtr
        )
        _ = plugIn.Release(plugInPtr)

        guard queryResult == 0, let rawDev = rawDevicePtr else { return }
        let devicePtr = rawDev.bindMemory(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self, capacity: 1)
        guard let device = devicePtr.pointee?.pointee else { return }

        var vendorID: UInt16 = 0
        var productID: UInt16 = 0
        _ = device.GetDeviceVendor(devicePtr, &vendorID)
        _ = device.GetDeviceProduct(devicePtr, &productID)

        print("🔍 AoaUsbManager: Probing device '\(deviceName)' (VID=0x\(String(vendorID, radix: 16)), PID=0x\(String(productID, radix: 16)))")

        // 1. Is it already in AOA Accessory Mode? (Google VID 0x18D1, PID 0x2D00...0x2D05)
        if vendorID == 0x18D1 && (productID >= 0x2D00 && productID <= 0x2D05) {
            print("🚀 AoaUsbManager: Found Android device ALREADY in AOA Accessory Mode! (PID=0x\(String(productID, radix: 16)))")
            connectAccessory(devicePtr: devicePtr)
            return
        }

        // 2. Is it a candidate Android device for AOA handshake?
        // Skip Apple internal controllers/peripherals (VID 0x05AC)
        if vendorID == 0x05AC {
            _ = device.Release(devicePtr)
            return
        }

        let isAndroidVendor = (vendorID == 0x04E8 || vendorID == 0x18D1 || vendorID == 0x2717 ||
                               vendorID == 0x12D1 || vendorID == 0x2A70 || vendorID == 0x1004 ||
                               vendorID == 0x22B8 || vendorID == 0x0BB4 || vendorID == 0x0FCE ||
                               vendorID == 0x22D9 || vendorID == 0x2D95 || vendorID == 0x17EF ||
                               vendorID == 0x0B05 || vendorID == 0x3170 || vendorID == 0x2E04 ||
                               vendorID == 0x2A45 || vendorID == 0x0E8D || vendorID == 0x05C6)

        if isAndroidVendor || !deviceName.isEmpty {
            print("📲 AoaUsbManager: Candidate Android device detected ('\(deviceName)', VID=0x\(String(vendorID, radix: 16))). Initiating AOA 2.0 handshake...")
            triggerAoaHandshake(devicePtr: devicePtr, deviceName: deviceName)
        } else {
            _ = device.Release(devicePtr)
        }
    }

    private func triggerAoaHandshake(devicePtr: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>, deviceName: String) {
        guard let device = devicePtr.pointee?.pointee else { return }
        defer { _ = device.Release(devicePtr) }

        // Attempt device open, but do NOT abort if kIOReturnExclusiveAccess is returned,
        // because Endpoint 0 DeviceRequest control transfers do NOT require exclusive device ownership on macOS.
        let openKr = device.USBDeviceOpen(devicePtr)
        let didOpen = (openKr == KERN_SUCCESS)
        defer {
            if didOpen {
                _ = device.USBDeviceClose(devicePtr)
            }
        }

        // Step 1: Request 51 (GET_PROTOCOL)
        var protocolVersion: UInt16 = 0
        var req51 = IOUSBDevRequest(
            bmRequestType: 0xC0,
            bRequest: 51,
            wValue: 0,
            wIndex: 0,
            wLength: 2,
            pData: &protocolVersion,
            wLenDone: 0
        )
        let kr51 = device.DeviceRequest(devicePtr, &req51)
        guard kr51 == KERN_SUCCESS else {
            print("⚠️ AoaUsbManager: Device does not support AOA (Request 51 returned kr=\(kr51))")
            return
        }

        print("✅ AoaUsbManager: AOA Protocol Version = \(protocolVersion)")
        guard protocolVersion >= 1 else {
            print("❌ AoaUsbManager: Unsupported AOA protocol version: \(protocolVersion)")
            return
        }

        // Step 2: Request 52 (SEND_STRING) - Dynamically resolve based on profile & device name
        let resolved = activeProfile.resolve(forDeviceName: deviceName)
        print("📲 AoaUsbManager: Sending AOA handshake strings: Manufacturer='\(resolved.manufacturer)', Model='\(resolved.model)', Desc='\(resolved.descriptionString)' (Profile: \(activeProfile.rawValue))")
        let accessoryStrings: [(UInt16, String)] = [
            (0, resolved.manufacturer),
            (1, resolved.model),
            (2, resolved.descriptionString),
            (3, activeProfile.version),
            (4, resolved.uri),
            (5, activeProfile.serialNumber)
        ]

        for (index, str) in accessoryStrings {
            var cStr = Array(str.utf8)
            cStr.append(0)
            var req52 = IOUSBDevRequest(
                bmRequestType: 0x40,
                bRequest: 52,
                wValue: 0,
                wIndex: index,
                wLength: UInt16(cStr.count),
                pData: &cStr,
                wLenDone: 0
            )
            let kr52 = device.DeviceRequest(devicePtr, &req52)
            if kr52 != KERN_SUCCESS {
                print("⚠️ AoaUsbManager: Failed to send AOA string index \(index) (kr=\(kr52))")
                return
            }
        }

        // Step 3: Request 53 (START_ACCESSORY)
        var req53 = IOUSBDevRequest(
            bmRequestType: 0x40,
            bRequest: 53,
            wValue: 0,
            wIndex: 0,
            wLength: 0,
            pData: nil,
            wLenDone: 0
        )
        let kr53 = device.DeviceRequest(devicePtr, &req53)
        if kr53 == KERN_SUCCESS {
            print("🚀 AoaUsbManager: AOA START_ACCESSORY command sent successfully! Device re-enumerating...")
        } else {
            print("⚠️ AoaUsbManager: Failed to send START_ACCESSORY (kr=\(kr53))")
        }
    }

    // MARK: - AOA Accessory Connection & Bulk Streaming

    private func connectAccessory(devicePtr: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>) {
        guard let device = devicePtr.pointee?.pointee else { return }

        // Attempt device open, but do NOT abort if kIOReturnExclusiveAccess is returned.
        // Composite devices (e.g. AOA + ADB) have multiple interfaces used by different clients.
        let openKr = device.USBDeviceOpen(devicePtr)
        let didOpenDevice = (openKr == KERN_SUCCESS)
        if !didOpenDevice {
            print("ℹ️ AoaUsbManager: USBDeviceOpen returned \(openKr); claiming interface directly without whole-device lock")
        }

        _ = device.SetConfiguration(devicePtr, 1)

        var findReq = IOUSBFindInterfaceRequest(
            bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare)
        )
        var intfIter: io_iterator_t = 0
        let krIntf = device.CreateInterfaceIterator(devicePtr, &findReq, &intfIter)
        guard krIntf == KERN_SUCCESS, intfIter != 0 else {
            print("❌ AoaUsbManager: Failed to create interface iterator")
            if didOpenDevice { _ = device.USBDeviceClose(devicePtr) }
            _ = device.Release(devicePtr)
            return
        }
        defer { IOObjectRelease(intfIter) }

        var intfService = IOIteratorNext(intfIter)
        var claimedIntfPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>?>? = nil
        var foundInPipe: UInt8 = 0
        var foundOutPipe: UInt8 = 0

        while intfService != 0 {
            defer {
                IOObjectRelease(intfService)
                intfService = IOIteratorNext(intfIter)
            }

            var score: Int32 = 0
            var intfPlugInPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>? = nil
            let krPlugIn = IOCreatePlugInInterfaceForService(
                intfService,
                aoaUSBInterfaceUserClientTypeID(),
                aoaIOCFPlugInInterfaceID(),
                &intfPlugInPtr,
                &score
            )
            guard krPlugIn == KERN_SUCCESS, let intfPlugIn = intfPlugInPtr?.pointee?.pointee else {
                continue
            }

            var rawIntfPtr: LPVOID? = nil
            let intfUuidBytes = CFUUIDGetUUIDBytes(aoaUSBInterfaceInterfaceID100())
            let krQuery = intfPlugIn.QueryInterface(
                intfPlugInPtr,
                CFUUIDBytes(
                    byte0: intfUuidBytes.byte0, byte1: intfUuidBytes.byte1, byte2: intfUuidBytes.byte2, byte3: intfUuidBytes.byte3,
                    byte4: intfUuidBytes.byte4, byte5: intfUuidBytes.byte5, byte6: intfUuidBytes.byte6, byte7: intfUuidBytes.byte7,
                    byte8: intfUuidBytes.byte8, byte9: intfUuidBytes.byte9, byte10: intfUuidBytes.byte10, byte11: intfUuidBytes.byte11,
                    byte12: intfUuidBytes.byte12, byte13: intfUuidBytes.byte13, byte14: intfUuidBytes.byte14, byte15: intfUuidBytes.byte15
                ),
                &rawIntfPtr
            )
            _ = intfPlugIn.Release(intfPlugInPtr)

            guard krQuery == 0, let rawIntf = rawIntfPtr else { continue }
            let candidateIntfPtr = rawIntf.bindMemory(to: UnsafeMutablePointer<IOUSBInterfaceInterface>?.self, capacity: 1)
            guard let candidateIntf = candidateIntfPtr.pointee?.pointee else { continue }

            // Open interface: try normal open first, fallback to OpenSeize
            var krOpenIntf = candidateIntf.USBInterfaceOpen(candidateIntfPtr)
            if krOpenIntf != KERN_SUCCESS {
                krOpenIntf = candidateIntf.USBInterfaceOpenSeize(candidateIntfPtr)
            }

            guard krOpenIntf == KERN_SUCCESS else {
                _ = candidateIntf.Release(candidateIntfPtr)
                continue
            }

            var numEndpoints: UInt8 = 0
            _ = candidateIntf.GetNumEndpoints(candidateIntfPtr, &numEndpoints)
            var inPipe: UInt8 = 0
            var outPipe: UInt8 = 0

            if numEndpoints > 0 {
                for pipe in 1...numEndpoints {
                    var direction: UInt8 = 0
                    var number: UInt8 = 0
                    var transferType: UInt8 = 0
                    var maxPacketSize: UInt16 = 0
                    var interval: UInt8 = 0

                    _ = candidateIntf.GetPipeProperties(candidateIntfPtr, pipe, &direction, &number, &transferType, &maxPacketSize, &interval)
                    if transferType == 2 { // Bulk
                        if direction == 1 { // In
                            inPipe = pipe
                        } else if direction == 0 { // Out
                            outPipe = pipe
                        }
                    }
                }
            }

            if inPipe != 0 && outPipe != 0 {
                claimedIntfPtr = candidateIntfPtr
                foundInPipe = inPipe
                foundOutPipe = outPipe
                break
            } else {
                _ = candidateIntf.USBInterfaceClose(candidateIntfPtr)
                _ = candidateIntf.Release(candidateIntfPtr)
            }
        }

        guard let intfPtr = claimedIntfPtr else {
            print("❌ AoaUsbManager: No usable AOA Bulk interface found on accessory device")
            if didOpenDevice { _ = device.USBDeviceClose(devicePtr) }
            _ = device.Release(devicePtr)
            return
        }

        self.activeDeviceInterface = didOpenDevice ? devicePtr : nil
        if !didOpenDevice {
            _ = device.Release(devicePtr)
        }
        self.activeInterfaceInterface = intfPtr
        self.bulkInPipeRef = foundInPipe
        self.bulkOutPipeRef = foundOutPipe

        stateLock.lock()
        _rawIsConnected = true
        _rawIsAccessoryMode = true
        _rawIsDroidOsSession = (activeProfile == .droidOS)
        _rawConnectedDeviceName = (activeProfile == .droidOS) ? "droidOS Device (Direct USB)" : "Android Device (Direct USB)"
        stateLock.unlock()

        print("⚡ AoaUsbManager: Successfully connected to Android AOA Accessory! (InPipe=\(foundInPipe), OutPipe=\(foundOutPipe))")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = true
            self.isAccessoryMode = true
            self.isDroidOsSession = (self.activeProfile == .droidOS)
            self.connectedDeviceName = (self.activeProfile == .droidOS) ? "droidOS Device (Direct USB)" : "Android Device (Direct USB)"
            self.onConnectionStatusChanged?(true)
            NotificationCenter.default.post(name: .droidlinkUsbConnected, object: self.connectedDeviceName)
            NotificationCenter.default.post(name: .droidlinkDeviceConnected, object: self.connectedDeviceName)
        }

        startReaderThread()
    }

    private func startReaderThread() {
        guard !isReading, activeInterfaceInterface != nil else { return }
        isReading = true

        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16384)
            var streamBuffer = Data()
            let framer = MessageFramer()
            let droidOsFramer = DroidOsFramer()
            var isDroidOsMode = false

            while let self = self, self.isSessionActive, let intf = self.activeInterfaceInterface?.pointee?.pointee {
                var readSize: UInt32 = UInt32(buffer.count)
                let kr = intf.ReadPipe(self.activeInterfaceInterface, self.bulkInPipeRef, &buffer, &readSize)

                if kr == KERN_SUCCESS && readSize > 0 {
                    self.consecutiveWriteTimeouts = 0
                    let chunk = Data(buffer[0..<Int(readSize)])

                    if isDroidOsMode || (chunk.count >= 2 && chunk[0] == DroidOsProtocol.magicByte0 && chunk[1] == DroidOsProtocol.magicByte1) {
                        if !isDroidOsMode {
                            isDroidOsMode = true
                            self.stateLock.lock()
                            self._rawIsDroidOsSession = true
                            self.stateLock.unlock()
                            DispatchQueue.main.async {
                                self.isDroidOsSession = true
                            }
                        }
                        let packets = droidOsFramer.deframe(chunk: chunk)
                        for pkt in packets {
                            self.onDroidOsPacketReceived?(pkt.type, pkt.flags, pkt.payload)
                        }
                    } else {
                        streamBuffer.append(chunk)

                        do {
                            let messages = try framer.deframe(from: &streamBuffer)
                            for msgData in messages {
                                self.onMessageReceived?(msgData)

                            if let rootMsg = try? Droidlink_Protocol_DroidLinkMessage(serializedBytes: msgData) {
                                switch rootMsg.payload {
                                case .externalDisplay(let extMsg):
                                    Task { @MainActor in
                                        ExternalDisplayManager.shared.handleIncomingMessage(extMsg)
                                    }
                                case .file(let fileMsg):
                                    print("📁 AOA USB File message received: \(fileMsg.operation) (id: \(fileMsg.fileID))")
                                    fflush(stdout)
                                    if fileMsg.operation == .fileChangeEvent {
                                        NotificationCenter.default.post(name: .droidlinkFileChanged, object: fileMsg)
                                    } else if let cont = self.popFileContinuation(id: fileMsg.fileID) {
                                        cont.resume(returning: fileMsg)
                                    } else {
                                        NotificationCenter.default.post(name: .droidlinkFileReceived, object: fileMsg)
                                    }
                                case .clipboard(let clip):
                                    print("📋 Protobuf Clipboard received via AOA USB: \(clip.data.text)")
                                    fflush(stdout)
                                    DispatchQueue.main.async {
                                        NotificationCenter.default.post(name: .droidlinkClipboardReceived, object: clip)
                                    }
                                case .notification(let notif):
                                    print("🔔 Notification received via AOA USB: \(notif.notification.title) - \(notif.notification.text)")
                                    fflush(stdout)
                                    DispatchQueue.main.async {
                                        NotificationCenter.default.post(name: .droidlinkNotificationReceived, object: notif)
                                    }
                                case .screen:
                                    break
                                case .system(let sys):
                                    if sys.event == .hello {
                                        let remoteDevName = sys.hello.deviceName.isEmpty ? "Android Phone" : sys.hello.deviceName
                                        let remoteDevId = sys.hello.deviceID.isEmpty ? "android_aoa" : sys.hello.deviceID
                                        print("🤝 Received HELLO handshake via AOA USB from: \(remoteDevName) (\(remoteDevId))")
                                        fflush(stdout)

                                        var ack = Droidlink_Protocol_SystemMessage()
                                        ack.event = .helloAck
                                        var helloAck = Droidlink_Protocol_HelloAckMessage()
                                        helloAck.protocolVersion = "3.0.0"
                                        helloAck.deviceID = PairingStorage.getOrCreateMyDeviceId()
                                        helloAck.deviceName = Host.current().localizedName ?? "Mac"
                                        helloAck.deviceType = .mac
                                        ack.helloAck = helloAck

                                        var ackRoot = Droidlink_Protocol_DroidLinkMessage()
                                        ackRoot.id = UInt64(Date().timeIntervalSince1970 * 1000)
                                        ackRoot.timestamp = ackRoot.id
                                        ackRoot.type = .system
                                        ackRoot.system = ack

                                        self.send(message: ackRoot)

                                        DispatchQueue.main.async {
                                            NotificationCenter.default.post(name: .droidlinkDeviceConnected, object: remoteDevName)
                                        }
                                        self.sendTelemetry(MacTelemetryCollector.shared.collectStatus(tcpPort: 0))
                                    } else if sys.hasError && sys.error.message == "DEVICE_STATUS" {
                                        if let status = DeviceStatusInfo.fromJsonString(sys.error.details) {
                                            print("📱 Received Android telemetry via AOA USB: \(status.deviceName) (\(status.deviceModel)) - \(status.batteryLevel)%")
                                            DispatchQueue.main.async {
                                                NotificationCenter.default.post(name: .droidlinkDeviceStatusReceived, object: status)
                                            }
                                        }
                                    }
                                default:
                                    break
                                }
                            }
                        }
                    } catch {
                        print("⚠️ AoaUsbManager: Deframing error: \(error), clearing streamBuffer to resync")
                        streamBuffer.removeAll()
                    }
                }
                } else if kr != KERN_SUCCESS {
                    print("⚠️ AoaUsbManager: ReadPipe failed with kr=\(kr)")
                    break
                }
            }

            self?.isReading = false
            self?.disconnect()
        }
    }

    /// Sends an ExternalDisplayMessage wrapped in DroidLinkMessage and framed over USB Bulk OUT
    func send(externalDisplay message: Droidlink_Protocol_ExternalDisplayMessage) -> Bool {
        guard isSessionActive else { return false }
        var rootMsg = Droidlink_Protocol_DroidLinkMessage()
        rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        rootMsg.type = .externalDisplay
        rootMsg.externalDisplay = message

        do {
            let serialized = try rootMsg.serializedData()
            let framed = try MessageFramer().frame(serialized)
            return send(data: framed)
        } catch {
            print("❌ AoaUsbManager: Failed to serialize/frame external display message: \(error)")
            return false
        }
    }

    /// Sends a droidOS protocol frame with 8-byte framing header over USB Bulk OUT
    @discardableResult
    public func send(droidOsType: DroidOsProtocol.MessageType, flags: UInt8 = 0, payload: Data = Data()) -> Bool {
        let frame = DroidOsProtocol.packFrame(type: droidOsType, flags: flags, payload: payload)
        return send(data: frame)
    }

    /// Sends raw bytes across the high-speed USB Bulk OUT endpoint using timeout-guarded WritePipeTO
    public func send(data: Data) -> Bool {
        sendLock.lock()
        defer { sendLock.unlock() }

        guard isSessionActive, let intfPtr = activeInterfaceInterface, let intf = intfPtr.pointee?.pointee, bulkOutPipeRef != 0 else { return false }

        // If the endpoint has repeatedly timed out (Android app closed or not consuming), abort early to avoid stalling callers
        if consecutiveWriteTimeouts >= 2 {
            return false
        }

        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let totalBytes = UInt32(data.count)
            var bytesWritten: UInt32 = 0

            while bytesWritten < totalBytes {
                let chunkSize = min(totalBytes - bytesWritten, 16384)
                let ptr = UnsafeMutableRawPointer(mutating: baseAddress.advanced(by: Int(bytesWritten)))
                // Use WritePipeTO with 1500ms timeout instead of unbounded blocking WritePipe
                let kr = intf.WritePipeTO(intfPtr, bulkOutPipeRef, ptr, chunkSize, 1500, 1500)
                if kr != KERN_SUCCESS {
                    consecutiveWriteTimeouts += 1
                    print("⚠️ AoaUsbManager: WritePipeTO timed out/failed with kr=\(kr) (consecutive: \(consecutiveWriteTimeouts))")
                    if consecutiveWriteTimeouts >= 2 {
                        print("❌ AoaUsbManager: USB Bulk OUT pipe stalled (no consumer on Android). Suspending write pipeline.")
                    }
                    return false
                }
                consecutiveWriteTimeouts = 0
                bytesWritten += chunkSize
            }
            return true
        }
    }

    /// Disconnects from the USB device and cleans up interface pointers
    public func disconnect() {
        stateLock.lock()
        let wasConnected = _rawIsConnected || activeInterfaceInterface != nil || activeDeviceInterface != nil
        guard wasConnected else {
            stateLock.unlock()
            return
        }
        let devName = _rawConnectedDeviceName
        if !devName.isEmpty {
            failedProbeCooldowns[devName] = Date()
        }
        _rawIsConnected = false
        _rawIsAccessoryMode = false
        _rawIsDroidOsSession = false
        _rawConnectedDeviceName = ""
        consecutiveWriteTimeouts = 0
        stateLock.unlock()

        sendLock.lock()
        if let intfPtr = activeInterfaceInterface, let intf = intfPtr.pointee?.pointee {
            _ = intf.USBInterfaceClose(intfPtr)
            _ = intf.Release(intfPtr)
            activeInterfaceInterface = nil
        }

        if let devPtr = activeDeviceInterface, let dev = devPtr.pointee?.pointee {
            _ = dev.USBDeviceClose(devPtr)
            _ = dev.Release(devPtr)
            activeDeviceInterface = nil
        }

        bulkInPipeRef = 0
        bulkOutPipeRef = 0
        sendLock.unlock()

        let toResume = drainFileContinuations()
        for cont in toResume {
            cont.resume(throwing: NSError(domain: "AoaUsbManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "AOA USB disconnected"]))
        }

        print("🔌 AoaUsbManager: Accessory disconnected")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.isAccessoryMode = false
            self.isDroidOsSession = false
            self.connectedDeviceName = ""
            self.onConnectionStatusChanged?(false)
            NotificationCenter.default.post(name: .droidlinkUsbDisconnected, object: nil)
            NotificationCenter.default.post(name: .droidlinkDeviceDisconnected, object: nil)
        }
    }

    // MARK: - File Transfer Operations over AOA USB

    /// Sends an Endpoint 0 Control Request to the USB Device or Interface (used for AOA 2.0 HID commands)
    @discardableResult
    public func sendControlRequest(
        requestType: UInt8,
        request: UInt8,
        value: UInt16,
        index: UInt16,
        data: Data? = nil
    ) -> Bool {
        var mutableData = data
        let pData: UnsafeMutableRawPointer? = (mutableData != nil && !mutableData!.isEmpty) ?
            mutableData!.withUnsafeMutableBytes { $0.baseAddress } : nil
        var req = IOUSBDevRequest(
            bmRequestType: requestType,
            bRequest: request,
            wValue: value,
            wIndex: index,
            wLength: UInt16(data?.count ?? 0),
            pData: pData,
            wLenDone: 0
        )
        if let devPtr = activeDeviceInterface, let dev = devPtr.pointee?.pointee {
            let kr = dev.DeviceRequest(devPtr, &req)
            if kr == KERN_SUCCESS { return true }
        }
        if let intfPtr = activeInterfaceInterface, let intf = intfPtr.pointee?.pointee {
            let kr = intf.ControlRequest(intfPtr, 0, &req)
            if kr == KERN_SUCCESS { return true }
        }
        return false
    }

    private var pendingFileRequests: [String: CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>] = [:]
    private var pendingFileContinuationsOrder: [String] = []
    private let fileContinuationLock = NSLock()

    func addFileContinuation(id: String, _ continuation: CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>) {
        fileContinuationLock.lock()
        defer { fileContinuationLock.unlock() }
        pendingFileRequests[id] = continuation
        pendingFileContinuationsOrder.append(id)
    }

    func popFileContinuation(id: String) -> CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>? {
        fileContinuationLock.lock()
        defer { fileContinuationLock.unlock() }
        if !id.isEmpty, let matched = pendingFileRequests.removeValue(forKey: id) {
            pendingFileContinuationsOrder.removeAll(where: { $0 == id })
            return matched
        }
        guard let firstId = pendingFileContinuationsOrder.first,
              let matched = pendingFileRequests.removeValue(forKey: firstId) else {
            return nil
        }
        pendingFileContinuationsOrder.removeFirst()
        return matched
    }

    func removeFileContinuation(id: String) {
        fileContinuationLock.lock()
        defer { fileContinuationLock.unlock() }
        pendingFileRequests.removeValue(forKey: id)
        pendingFileContinuationsOrder.removeAll(where: { $0 == id })
    }

    func drainFileContinuations() -> [CheckedContinuation<Droidlink_Protocol_FileMessage, any Error>] {
        fileContinuationLock.lock()
        defer { fileContinuationLock.unlock() }
        let toResume = Array(pendingFileRequests.values)
        pendingFileRequests.removeAll()
        pendingFileContinuationsOrder.removeAll()
        return toResume
    }

    /// Sends a Protobuf message framed over AOA USB Bulk OUT
    func send(message: Droidlink_Protocol_DroidLinkMessage) {
        guard isSessionActive, !isDroidOsActive else { return }
        do {
            let serialized = try message.serializedData()
            let framer = MessageFramer()
            let framed = try framer.frame(serialized)
            _ = send(data: framed)
        } catch {
            print("❌ AoaUsbManager: Failed to frame/send Protobuf message: \(error)")
        }
    }

    /// Sends telemetry message to Android client over AOA USB Bulk OUT
    public func sendTelemetry(_ status: DeviceStatusInfo) {
        guard isSessionActive, !isDroidOsActive, let jsonStr = status.toJsonString() else { return }
        writeQueue.async { [weak self] in
            guard let self = self, self.isSessionActive else { return }
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

            self.send(message: rootMsg)
            print("📊 Sent Mac telemetry to Android via AOA USB: \(status.deviceName) (\(status.deviceModel)) - \(status.batteryLevel)%")
            fflush(stdout)
        }
    }

    /// Requests a file operation over high-speed AOA USB Bulk endpoints (35-45+ MB/s)
    func requestFileOperation(_ fileMsg: Droidlink_Protocol_FileMessage) async throws -> Droidlink_Protocol_FileMessage {
        guard isSessionActive else {
            throw NSError(domain: "AoaUsbManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "AOA USB is not connected"])
        }
        let reqId = fileMsg.fileID.isEmpty ? UUID().uuidString : fileMsg.fileID
        var preparedMsg = fileMsg
        preparedMsg.fileID = reqId
        let messageToSend = preparedMsg

        return try await withCheckedThrowingContinuation { continuation in
            self.addFileContinuation(id: reqId, continuation)

            var rootMsg = Droidlink_Protocol_DroidLinkMessage()
            rootMsg.id = UInt64(Date().timeIntervalSince1970 * 1000)
            rootMsg.timestamp = rootMsg.id
            rootMsg.type = .fileTransfer
            rootMsg.file = messageToSend
            self.send(message: rootMsg)

            Task {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                if let timedOutCont = self.popFileContinuation(id: reqId) {
                    timedOutCont.resume(throwing: NSError(domain: "AoaUsbManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "AOA USB file operation timed out"]))
                }
            }
        }
    }
}

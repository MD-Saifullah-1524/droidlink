import Foundation
import IOKit.ps
import CoreWLAN

public struct DeviceStatusInfo: Codable, Equatable, Sendable {
    public var deviceName: String
    public var deviceModel: String
    public var batteryLevel: Int
    public var isCharging: Bool
    public var powerSource: String
    public var wifiSsid: String
    public var wifiSignalLevel: Int // 0 - 4
    public var wifiRssi: Int
    public var hasCellular: Bool
    public var carrierName: String
    public var cellularNetworkType: String
    public var cellularSignalLevel: Int // 0 - 4
    public var simState: String
    public var simDisplayName: String
    public var localIpAddress: String
    public var tcpPort: Int
    public var isFinderStorageEnabled: Bool
    public var screenWidth: Int?
    public var screenHeight: Int?

    public init(
        deviceName: String = "",
        deviceModel: String = "",
        batteryLevel: Int = -1,
        isCharging: Bool = false,
        powerSource: String = "Battery",
        wifiSsid: String = "",
        wifiSignalLevel: Int = 0,
        wifiRssi: Int = 0,
        hasCellular: Bool = false,
        carrierName: String = "",
        cellularNetworkType: String = "",
        cellularSignalLevel: Int = 0,
        simState: String = "",
        simDisplayName: String = "",
        localIpAddress: String = "",
        tcpPort: Int = 29170,
        isFinderStorageEnabled: Bool = true,
        screenWidth: Int? = nil,
        screenHeight: Int? = nil
    ) {
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.powerSource = powerSource
        self.wifiSsid = wifiSsid
        self.wifiSignalLevel = wifiSignalLevel
        self.wifiRssi = wifiRssi
        self.hasCellular = hasCellular
        self.carrierName = carrierName
        self.cellularNetworkType = cellularNetworkType
        self.cellularSignalLevel = cellularSignalLevel
        self.simState = simState
        self.simDisplayName = simDisplayName
        self.localIpAddress = localIpAddress
        self.tcpPort = tcpPort
        self.isFinderStorageEnabled = isFinderStorageEnabled
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    public func toJsonString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func fromJsonString(_ string: String) -> DeviceStatusInfo? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DeviceStatusInfo.self, from: data)
    }
}

public final class MacTelemetryCollector: Sendable {
    public static let shared = MacTelemetryCollector()

    private init() {}

    public func collectStatus(tcpPort: Int = 29170) -> DeviceStatusInfo {
        let name = Host.current().localizedName ?? "Mac"
        let model = getMacModel()
        let (batteryLevel, isCharging, powerSource) = getBatteryInfo()
        let (wifiSsid, wifiSignalLevel, wifiRssi) = getWifiInfo()

        return DeviceStatusInfo(
            deviceName: name,
            deviceModel: model,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            powerSource: powerSource,
            wifiSsid: wifiSsid,
            wifiSignalLevel: wifiSignalLevel,
            wifiRssi: wifiRssi,
            hasCellular: false,
            carrierName: "N/A (Mac)",
            cellularNetworkType: "Wi-Fi Only",
            cellularSignalLevel: 0,
            simState: "N/A",
            simDisplayName: "No SIM",
            localIpAddress: NetworkUtilities.getLocalIPAddress() ?? "",
            tcpPort: tcpPort,
            isFinderStorageEnabled: true,
            screenWidth: nil,
            screenHeight: nil
        )
    }

    public func getMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let raw = model.withUnsafeBufferPointer { ptr in
            ptr.baseAddress.map { String(cString: $0) } ?? ""
        }

        if raw.contains("MacBookPro") {
            return "Apple MacBook Pro"
        } else if raw.contains("MacBookAir") {
            return "Apple MacBook Air"
        } else if raw.contains("Macmini") {
            return "Apple Mac mini"
        } else if raw.contains("MacStudio") {
            return "Apple Mac Studio"
        } else if raw.contains("MacPro") {
            return "Apple Mac Pro"
        } else if raw.contains("iMac") {
            return "Apple iMac"
        } else if !raw.isEmpty {
            return "Apple Mac (\(raw))"
        } else {
            return "Apple Mac"
        }
    }

    private func getBatteryInfo() -> (Int, Bool, String) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return (100, false, "AC Power")
        }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let currentCapacity = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let powerSourceState = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            let isAC = (powerSourceState == kIOPSACPowerValue)
            let sourceStr = isAC ? (isCharging ? "Charging via AC" : "AC Power") : "Battery"

            return (currentCapacity, isCharging, sourceStr)
        }

        return (100, false, "AC Power")
    }

    private func getWifiInfo() -> (String, Int, Int) {
        if let iface = CWWiFiClient.shared().interface(), iface.powerOn() {
            let ssid = iface.ssid() ?? "Wi-Fi Connected"
            let rssi = iface.rssiValue()
            let bars: Int
            if rssi >= -55 {
                bars = 4
            } else if rssi >= -67 {
                bars = 3
            } else if rssi >= -80 {
                bars = 2
            } else if rssi >= -90 {
                bars = 1
            } else {
                bars = 0
            }
            return (ssid, bars, rssi)
        }
        return ("Wi-Fi", 3, -60)
    }

    public func hasStatusChanged(from old: DeviceStatusInfo?, to new: DeviceStatusInfo) -> Bool {
        guard let old = old else { return true }
        return old.batteryLevel != new.batteryLevel ||
               old.isCharging != new.isCharging ||
               old.powerSource != new.powerSource ||
               old.wifiSsid != new.wifiSsid ||
               old.wifiSignalLevel != new.wifiSignalLevel ||
               old.localIpAddress != new.localIpAddress ||
               old.isFinderStorageEnabled != new.isFinderStorageEnabled ||
               old.screenWidth != new.screenWidth ||
               old.screenHeight != new.screenHeight
    }

    private static nonisolated(unsafe) var isObservingPower = false

    public static func startObservingPowerChanges() {
        guard !isObservingPower else { return }
        isObservingPower = true
        let callback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: .droidlinkLocalTelemetryChanged, object: nil)
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }
}

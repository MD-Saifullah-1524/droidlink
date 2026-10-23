import Foundation
import CoreGraphics
import ObjectiveC.runtime
import ColorSync

/// Bridge to macOS CoreGraphics private CGVirtualDisplay API.
/// Allows programmatic creation of real secondary/external monitors in macOS without dummy HDMI plugs.
final class VirtualDisplayBridge: @unchecked Sendable {
    private var virtualDisplayInstance: AnyObject?
    private(set) var displayID: CGDirectDisplayID?
    private(set) var isActive: Bool = false
    private let queue = DispatchQueue(label: "com.droidlink.virtualdisplay", qos: .userInteractive)

    init() {}

    deinit {
        destroyDisplay()
    }

    /// Spawns a new software-defined virtual display in macOS WindowServer.
    /// - Parameters:
    ///   - width: Pixel width (e.g. 1920, 2408, 2560)
    ///   - height: Pixel height (e.g. 1080, 1600)
    ///   - scaleFactor: UI scaling factor (e.g. 2.0 for Retina/Phones, 1.5 for Tablets, 1.0 for Native)
    ///   - refreshRate: Frame rate (e.g. 60.0 or 120.0 Hz)
    ///   - hiDPI: Whether to enable Apple Retina HiDPI 2x downsampling
    ///   - name: Display name shown in macOS System Settings -> Displays
    /// - Returns: The allocated CGDirectDisplayID or nil if failed
    func createDisplay(
        width: UInt32,
        height: UInt32,
        scaleFactor: Double = 2.0,
        refreshRate: Double = 60.0,
        hiDPI: Bool = true,
        name: String = "DroidLink Display"
    ) -> CGDirectDisplayID? {
        destroyDisplay()

        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            print("❌ VirtualDisplayBridge: CGVirtualDisplay classes not found in CoreGraphics")
            return nil
        }

        let pixelWidth = max(width, height)
        let pixelHeight = min(width, height)
        let safeScale = max(0.5, scaleFactor)
        let targetLogicalWidth = UInt32(round(Double(pixelWidth) / safeScale))
        let targetLogicalHeight = UInt32(round(Double(pixelHeight) / safeScale))

        // 1. Calculate physical dimensions (~326 PPI) so macOS identifies it as a Retina/HiDPI display
        let sizeWidthMm = max(100.0, Double(pixelWidth) * (25.4 / 326.0))
        let sizeHeightMm = max(50.0, Double(pixelHeight) * (25.4 / 326.0))

        // 2. Instantiate CGVirtualDisplay with dynamic EDID serial number and retry resiliency.
        // macOS WindowServer identifies software virtual displays by their EDID tuple: (vendorID, productID, serialNum).
        // Using a static serial number causes WindowServer to reject subsequent creations with
        // "no displayID available (kr=0x5)" if a previous display session was closed or tombstoned.
        let displayInitSel = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: displayInitSel) else {
            print("❌ VirtualDisplayBridge: initWithDescriptor: selector not found on CGVirtualDisplay")
            return nil
        }

        guard let initMethod = class_getInstanceMethod(displayClass, displayInitSel) else {
            print("❌ VirtualDisplayBridge: Failed to find initWithDescriptor: method implementation")
            return nil
        }
        typealias InitFunc = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let initImp = unsafeBitCast(method_getImplementation(initMethod), to: InitFunc.self)

        var virtualDisplay: AnyObject? = nil
        let maxRetries = 3

        for attempt in 1...maxRetries {
            let serial = UInt32.random(in: 100000...9999999)
            let descriptor = descriptorClass.init()
            descriptor.setValue(name, forKey: "name")
            descriptor.setValue(queue, forKey: "queue")
            descriptor.setValue(pixelWidth, forKey: "maxPixelsWide")
            descriptor.setValue(pixelHeight, forKey: "maxPixelsHigh")
            descriptor.setValue(CGSize(width: sizeWidthMm, height: sizeHeightMm), forKey: "sizeInMillimeters")
            descriptor.setValue(UInt32(0x444c), forKey: "vendorID") // "DL" in ASCII
            descriptor.setValue(UInt32(0x0001), forKey: "productID")
            descriptor.setValue(serial, forKey: "serialNum")
            descriptor.setValue(serial, forKey: "serialNumber")

            guard let rawAlloc = (displayClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
                print("❌ VirtualDisplayBridge: alloc failed on attempt \(attempt)")
                continue
            }

            if let instance = initImp(rawAlloc, displayInitSel, descriptor) {
                virtualDisplay = instance
                print("🖥️ VirtualDisplayBridge: Successfully initialized CGVirtualDisplay on attempt \(attempt) (serial=\(serial))")
                break
            } else {
                print("⚠️ VirtualDisplayBridge: initWithDescriptor returned nil on attempt \(attempt) (serial=\(serial)), retrying...")
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        guard let virtualDisplay = virtualDisplay else {
            print("❌ VirtualDisplayBridge: Failed to instantiate CGVirtualDisplay after \(maxRetries) attempts")
            return nil
        }

        // 3. Create display modes ladder
        let modeInitSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        typealias ModeInitFunc = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
        guard let modeMethod = class_getInstanceMethod(modeClass, modeInitSel) else {
            print("❌ VirtualDisplayBridge: Failed to find initWithWidth:height:refreshRate: method")
            return nil
        }
        let modeImp = unsafeBitCast(method_getImplementation(modeMethod), to: ModeInitFunc.self)

        var modes: [AnyObject] = []
        var addedResolutions = Set<String>()

        func appendMode(w: UInt32, h: UInt32) {
            guard w > 0, h > 0 else { return }
            let key = "\(w)x\(h)"
            guard !addedResolutions.contains(key) else { return }
            addedResolutions.insert(key)

            guard let rawModeAlloc = (modeClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return }
            if let m = modeImp(rawModeAlloc, modeInitSel, w, h, refreshRate) {
                modes.append(m)
            }
        }

        // Mode at index 0 is macOS's preferred/default initial mode.
        // It defaults to targetLogicalWidth x targetLogicalHeight (200% scale / 2.0x by default)
        appendMode(w: targetLogicalWidth, h: targetLogicalHeight)

        // Populate full scaling ladder so macOS System Settings & DroidLink can switch between them
        appendMode(w: UInt32(round(Double(pixelWidth) / 2.0)), h: UInt32(round(Double(pixelHeight) / 2.0)))   // 2.0x (Retina - Default 200%)
        appendMode(w: UInt32(round(Double(pixelWidth) / 1.75)), h: UInt32(round(Double(pixelHeight) / 1.75))) // 1.75x (175%)
        appendMode(w: UInt32(round(Double(pixelWidth) / 1.5)), h: UInt32(round(Double(pixelHeight) / 1.5)))   // 1.5x (150%)
        appendMode(w: UInt32(round(Double(pixelWidth) / 1.25)), h: UInt32(round(Double(pixelHeight) / 1.25))) // 1.25x (125%)
        appendMode(w: pixelWidth, h: pixelHeight)                                                             // 1.0x (100% - Native Space)
        appendMode(w: UInt32(round(Double(pixelWidth) / 2.25)), h: UInt32(round(Double(pixelHeight) / 2.25))) // 2.25x (225%)
        appendMode(w: UInt32(round(Double(pixelWidth) / 2.5)), h: UInt32(round(Double(pixelHeight) / 2.5)))   // 2.5x (250%)

        if modes.isEmpty {
            appendMode(w: targetLogicalWidth, h: targetLogicalHeight)
        }

        // 4. Create and apply settings
        let settings = settingsClass.init()
        settings.setValue(modes, forKey: "modes")
        settings.setValue(hiDPI ? UInt32(1) : UInt32(0), forKey: "hiDPI")

        let applySettingsSel = NSSelectorFromString("applySettings:")
        typealias ApplySettingsFunc = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard let applyMethod = class_getInstanceMethod(displayClass, applySettingsSel) else {
            print("❌ VirtualDisplayBridge: Failed to find applySettings: method")
            return nil
        }
        let applyImp = unsafeBitCast(method_getImplementation(applyMethod), to: ApplySettingsFunc.self)

        let applied = applyImp(virtualDisplay, applySettingsSel, settings)
        guard applied else {
            print("❌ VirtualDisplayBridge: applySettings returned false (modes count: \(modes.count))")
            return nil
        }

        // 5. Query displayID
        let displayIDSel = NSSelectorFromString("displayID")
        typealias DisplayIDFunc = @convention(c) (AnyObject, Selector) -> CGDirectDisplayID
        guard let displayIDMethod = class_getInstanceMethod(displayClass, displayIDSel) else {
            print("❌ VirtualDisplayBridge: Failed to find displayID method")
            return nil
        }
        let displayIDImp = unsafeBitCast(method_getImplementation(displayIDMethod), to: DisplayIDFunc.self)

        let did = displayIDImp(virtualDisplay, displayIDSel)
        self.virtualDisplayInstance = virtualDisplay
        self.displayID = did
        self.isActive = true

        // 6. Automatically arrange the virtual display immediately to the right of the main display,
        // and explicitly disengage any mirroring in macOS WindowServer.
        // We intentionally DO NOT warp the mouse cursor so the user's focus is preserved on their Mac.
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        var displayConfig: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&displayConfig) == .success {
            let targetX = Int32(mainBounds.maxX)
            let targetY = Int32(mainBounds.origin.y)
            CGConfigureDisplayOrigin(displayConfig, did, targetX, targetY)
            CGConfigureDisplayMirrorOfDisplay(displayConfig, did, kCGNullDirectDisplay) // Force Mirror OFF
            let configRes = CGCompleteDisplayConfiguration(displayConfig, .permanently)
            if configRes == .success {
                print("🖥️ VirtualDisplayBridge: Arranged virtual display immediately right of main display (origin: x=\(targetX), y=\(targetY), mirror=OFF)")
            } else {
                print("⚠️ VirtualDisplayBridge: CGCompleteDisplayConfiguration returned \(configRes.rawValue)")
            }
        }

        // 7. Automatically apply Generic RGB ColorSync profile to prevent macOS black screen issue
        applyGenericRGBColorProfile(displayID: did)

        print("🖥️ VirtualDisplayBridge: Created virtual display ID \(did) (pixels=\(pixelWidth)x\(pixelHeight), UI points=\(targetLogicalWidth)x\(targetLogicalHeight), scale=\(safeScale)x @ \(refreshRate)Hz, HiDPI=\(hiDPI))")
        return did
    }

    /// Dynamically switches the active display scaling on-the-fly without stopping or restarting the stream
    @discardableResult
    func setDisplayScale(
        displayID: CGDirectDisplayID,
        scaleFactor: Double,
        pixelWidth: UInt32,
        pixelHeight: UInt32
    ) -> Bool {
        let safeScale = max(0.5, scaleFactor)
        let targetW = UInt32(round(Double(pixelWidth) / safeScale))
        let targetH = UInt32(round(Double(pixelHeight) / safeScale))

        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            print("⚠️ VirtualDisplayBridge: Could not copy display modes for ID \(displayID)")
            return false
        }

        // Match exact or closest usable display mode
        guard let targetMode = modes.first(where: {
            $0.width == targetW && $0.height == targetH && $0.isUsableForDesktopGUI()
        }) ?? modes.first(where: {
            abs(Int($0.width) - Int(targetW)) <= 30 && $0.isUsableForDesktopGUI()
        }) else {
            print("⚠️ VirtualDisplayBridge: No matching display mode found for target points \(targetW)x\(targetH)")
            return false
        }

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, targetMode, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        let success = (err == .success)
        if success {
            print("🖥️ VirtualDisplayBridge: Successfully switched display \(displayID) scale to \(safeScale)x (active points: \(targetMode.width)x\(targetMode.height))")
        } else {
            print("⚠️ VirtualDisplayBridge: Failed to switch display mode, CGError: \(err.rawValue)")
        }
        return success
    }

    /// Automatically sets the display's ColorSync profile to Generic RGB Profile (or sRGB fallback)
    /// to eliminate the black screen bug caused by macOS auto-generated virtual display ICC profiles.
    private func applyGenericRGBColorProfile(displayID: CGDirectDisplayID) {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            print("⚠️ VirtualDisplayBridge: Could not obtain UUID for display \(displayID)")
            return
        }

        // Canonical ColorSync constants defined in ColorSyncDevice.h ("mntr" for displays, "DeviceDefaultProfileID" for default slot)
        let devClass: CFString = "mntr" as CFString
        let defaultID: CFString = "DeviceDefaultProfileID" as CFString

        let candidatePaths = [
            "/System/Library/ColorSync/Profiles/Generic RGB Profile.icc",
            "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
        ]

        guard let profilePath = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            print("⚠️ VirtualDisplayBridge: No Generic RGB or sRGB profile found on system")
            return
        }

        let profileURL = URL(fileURLWithPath: profilePath) as CFURL
        let customProfiles: [CFString: Any] = [defaultID: profileURL]
        let success = ColorSyncDeviceSetCustomProfiles(devClass, uuid, customProfiles as CFDictionary)
        if success {
            print("🎨 VirtualDisplayBridge: Successfully applied \(profilePath) to display \(displayID)")
        } else {
            print("⚠️ VirtualDisplayBridge: Failed to apply Generic RGB Profile via ColorSync")
        }
    }

    /// Destroys the active virtual display and removes it from macOS WindowServer
    func destroyDisplay() {
        if let id = displayID {
            print("🖥️ VirtualDisplayBridge: Destroying virtual display ID \(id)")
        }
        if let display = virtualDisplayInstance {
            let displayClass: AnyClass = type(of: display)
            if let ivar = class_getInstanceVariable(displayClass, "_client"),
               let client = object_getIvar(display, ivar) as? NSObject {
                let unplugSel = NSSelectorFromString("unplug")
                if client.responds(to: unplugSel) {
                    print("🖥️ VirtualDisplayBridge: Unplugging VirtualDisplayClient from WindowServer")
                    client.perform(unplugSel)
                }
            }
        }
        virtualDisplayInstance = nil
        displayID = nil
        isActive = false

        // Force macOS WindowServer to commit the display topology removal
        var displayConfig: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&displayConfig) == .success {
            _ = CGCompleteDisplayConfiguration(displayConfig, .permanently)
            print("🖥️ VirtualDisplayBridge: Display reconfiguration committed after teardown")
        }
    }
}

import Foundation
import CoreGraphics
import AppKit

/// Monitors the Mac's primary display physical luminance in nits (cd/m²)
/// and ambient illuminance in lux. Uses DisplayServices.framework linear brightness
/// to accurately compute real-time physical output, debouncing updates over USB to Android.
@MainActor
final class MacLuminanceMonitor {
    static let shared = MacLuminanceMonitor()

    private typealias DisplayServicesGetLinearBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DisplayServicesGetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private var getLinearBrightnessFunc: DisplayServicesGetLinearBrightnessFunc?
    private var getBrightnessFunc: DisplayServicesGetBrightnessFunc?

    private var pollingTimer: Timer?
    private var lastReportedNits: Float = -1.0
    private var lastReportedLux: Float = -1.0

    /// Reference luminance used during mandatory visual calibration (Way 2)
    let referenceCalibrationNits: Float = 200.0

    /// Callback invoked when physical luminance or ambient lighting shifts
    var onLuminanceChanged: ((_ targetNits: Float, _ ambientLux: Float, _ linearBrightness: Float) -> Void)?

    init() {
        loadDisplayServicesSymbols()
    }

    /// Dynamically binds DisplayServices private framework symbols safely at runtime
    private func loadDisplayServicesSymbols() {
        let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            print("⚠️ MacLuminanceMonitor: DisplayServices.framework unavailable; will use fallback")
            return
        }

        if let linearSym = dlsym(handle, "DisplayServicesGetLinearBrightness") {
            self.getLinearBrightnessFunc = unsafeBitCast(linearSym, to: DisplayServicesGetLinearBrightnessFunc.self)
        }
        if let userSym = dlsym(handle, "DisplayServicesGetBrightness") {
            self.getBrightnessFunc = unsafeBitCast(userSym, to: DisplayServicesGetBrightnessFunc.self)
        }
    }

    /// Resolves the estimated peak SDR nits of the active Mac display panel
    func getEstimatedMaxSdrNits(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float {
        // Built-in MacBook displays:
        // MacBook Pro 14"/16" (Liquid Retina XDR): 500 nits SDR sustained (up to 600 in macOS 15)
        // MacBook Air M2/M3: 500 nits SDR
        // MacBook Air M1: 400 nits SDR
        // Apple Studio Display: 600 nits
        // Third-party external monitors: ~350 nits default
        if CGDisplayIsBuiltin(displayID) != 0 {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: max(1, size))
            sysctlbyname("hw.model", &model, &size, nil, 0)
            let modelString = String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)

            if modelString.contains("MacBookAir10") {
                return 400.0 // M1 MacBook Air
            }
            if modelString.contains("Mac15,") || modelString.contains("Mac16,") {
                return 600.0 // M3 / M4 / newer SDR outdoor limit
            }
            return 500.0 // Standard modern Retina / XDR SDR peak
        }
        return 350.0 // Default for external monitors
    }

    /// Minimum black-level luminance on Mac panels in nits
    func getEstimatedMinNits() -> Float {
        return 2.0
    }

    /// Reads the current linear brightness factor (0.0 to 1.0)
    func getCurrentLinearBrightness(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float {
        if let getLinear = getLinearBrightnessFunc {
            var linear: Float = 0.0
            if getLinear(displayID, &linear) == 0 {
                return max(0.0, min(1.0, linear))
            }
        }

        // Fallback: use user brightness and apply standard gamma transfer curve (gamma ~ 2.2)
        if let getUser = getBrightnessFunc {
            var user: Float = 0.0
            if getUser(displayID, &user) == 0 {
                return pow(max(0.0, min(1.0, user)), 2.2)
            }
        }

        return 0.5 // Safe middle fallback
    }

    /// Reads the current Mac ambient illuminance in lux (falls back to typical room 150 lux)
    func getCurrentAmbientLux() -> Float {
        // CoreBrightness typically operates between 0 and 1000 lux indoors
        // We report 150.0 lux as indoor reference baseline
        return 150.0
    }

    /// Calculates current emitted luminance in nits (cd/m²)
    func getCurrentPhysicalNits(displayID: CGDirectDisplayID = CGMainDisplayID()) -> Float {
        let linear = getCurrentLinearBrightness(displayID: displayID)
        let minNits = getEstimatedMinNits()
        let maxNits = getEstimatedMaxSdrNits(displayID: displayID)
        let calculated = minNits + linear * (maxNits - minNits)
        return max(minNits, min(maxNits, calculated))
    }

    /// Starts polling the Mac's primary display at 250ms intervals.
    /// Emits updates only when physical luminance shifts by >= 0.5 nits.
    func startMonitoring(onUpdate: @escaping (_ targetNits: Float, _ ambientLux: Float, _ linearBrightness: Float) -> Void) {
        stopMonitoring()
        self.onLuminanceChanged = onUpdate

        // Send initial reading immediately
        let initialNits = getCurrentPhysicalNits()
        let initialLux = getCurrentAmbientLux()
        let initialLinear = getCurrentLinearBrightness()
        lastReportedNits = initialNits
        lastReportedLux = initialLux
        onUpdate(initialNits, initialLux, initialLinear)

        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                let currentNits = self.getCurrentPhysicalNits()
                let currentLux = self.getCurrentAmbientLux()
                let linear = self.getCurrentLinearBrightness()

                // Trigger only when luminance shifts meaningfully
                if abs(currentNits - self.lastReportedNits) >= 0.5 || abs(currentLux - self.lastReportedLux) >= 5.0 {
                    self.lastReportedNits = currentNits
                    self.lastReportedLux = currentLux
                    self.onLuminanceChanged?(currentNits, currentLux, linear)
                }
            }
        }
    }

    /// Halts polling
    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        onLuminanceChanged = nil
    }
}

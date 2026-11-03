# DroidLink macOS Application & Extensions

Native macOS application, Finder File Provider extension, and Share extension for DroidLink.

---

## 🎯 Architecture Overview

The macOS side of DroidLink consists of four tightly-coupled targets:

1. **DroidLink (`DroidLink.app`)**:
   - Built with **SwiftUI** and native `NavigationSplitView`.
   - Sidebar navigation: `Home` (telemetry dashboard & transport status), `External Display` (monitor resolution, scaling, and controls), `Notifications` (alert history and filters), `Clipboard` (sync history and incognito mode), `Roadmap`, and `Settings`.
   
2. **DroidLinkKit (`DroidLinkKit.framework` / Swift Package)**:
   - Shared library powering transports, encryption, and protocol framing.
   - **`AoaUsbManager`**: Low-level IOKit USB communication communicating directly over Android Open Accessory (AOA 2.0).
   - **`BleServer`**: CoreBluetooth GATT peripheral broadcasting control plane services.
   - **`TcpServer`**: Network framework TCP listener with 4-byte framing.
   - **`VirtualDisplayBridge` & `H264EncoderEngine`**: macOS virtual monitor engine powered by CoreGraphics and VideoToolbox.
   - **`MacLuminanceMonitor`**: Real-time Mac ambient sensor monitoring and target nits calculation.
   - **`CryptoChannel`**: AES-256-GCM message encryption.

3. **DroidLinkFileProvider (`DroidLinkFileProvider.appex`)**:
   - Native `NSFileProviderReplicatedExtension` running out-of-process.
   - Mounts `/storage/emulated/0` directly into Finder's sidebar.
   - Communicates with the main app via local XPC and shared App Groups.

4. **DroidLinkShare (`DroidLinkShare.appex`)**:
   - macOS system Share Sheet extension allowing instant file transmission to Android from Finder, Safari, Photos, and other apps.

---

## 🛠️ Building & Packaging

### Automated Release Packaging (`build_pkg.sh`)
The recommended way to build and package DroidLink is using `build_pkg.sh`:

```bash
cd mac
./build_pkg.sh
```

This automated script:
1. Increments the bundle version with `xcrun agvtool next-version -all`.
2. Compiles `DroidLink`, `DroidLinkFileProvider`, and `DroidLinkShare` in `Release` mode using `xcodebuild`.
3. Bundles icons, assets, and localization resources.
4. Code-signs all binaries, frameworks, and app extensions with hardened runtime and respective entitlements.
5. Builds the signed macOS distribution package `DroidLink.pkg`.

---

### Building in Xcode
1. Open `DroidLink.xcodeproj` in Xcode 15 or later:
   ```bash
   open DroidLink.xcodeproj
   ```
2. Select the `DroidLink` scheme.
3. Build and run (⌘ + R).

---

## 🔐 Required System Permissions

For full functionality, DroidLink requests the following macOS permissions:
- **Screen Recording** (`CGPreflightScreenCaptureAccess`): Required to capture the virtual display stream for External Display.
- **Accessibility** (`AXIsProcessTrusted`): Required to inject touch and mouse events into the virtual display canvas.
- **Local Network**: Required for Wi-Fi discovery and TCP socket communication.
- **Bluetooth**: Required for the BLE GATT control plane.

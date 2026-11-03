# DroidLink Project Summary

**Platform**: DroidLink — Local-First Android ↔ macOS Device Integration  
**Current Version**: 1.1 (macOS Build 80+)  
**License**: Apache 2.0 (Open Source)

---

## 🎯 Executive Summary

DroidLink is an open-source, local-first software suite designed to unify Android and macOS devices without relying on third-party cloud servers, user accounts, or subscription fees. 

The platform delivers deep operating-system integration on both platforms:
- **macOS**: Native SwiftUI interface with `NavigationSplitView`, a native macOS File Provider extension (`NSFileProviderReplicatedExtension`) for Finder sidebar mounting, a system Share extension (`DroidLinkShare`), and a CoreGraphics/ScreenCaptureKit virtual display engine.
- **Android**: Modern Jetpack Compose UI with Material 3, a low-latency hardware `MediaCodec` external display decoder, an AOA 2.0 USB receiver, a persistent foreground service (`DroidLinkService`), a Quick Settings toggle tile (`DroidLinkTileService`), and an accessibility service for background clipboard sync.
- **Protocol**: Protocol Buffers v3 binary schemas with 4-byte length-prefixed framing and end-to-end symmetric encryption (AES-256-GCM / TLS 1.3).

---

## 🏛️ The 7 Core Pillars

### 1. Multi-Transport Network Architecture
- **Bluetooth Low Energy (BLE)**: Serves as the primary control plane. A custom GATT service (`D701D100-38F1-4F24-B1F7-3C7E9D420001`) handles continuous background keep-alive, proximity pairing, and state notifications with minimal battery impact.
- **Direct USB (Android Open Accessory 2.0)**: Hardware-speed connection allowing maximum throughput (~200+ Mbps) and sub-20ms latency without requiring Android Developer Mode or ADB debugging.
- **Wi-Fi TCP**: Length-prefixed binary socket transport for wireless data synchronization over local subnet networks.
- **CryptoChannel**: Symmetric AES-256-GCM message encryption with keys secured in macOS Keychain and Android Keystore.

### 2. External Display for Mac
- Converts any connected Android smartphone or tablet into a high-performance secondary macOS monitor.
- **Encoder**: Hardware-accelerated VideoToolbox H.264 Baseline encoding on macOS with zero frame-delay count.
- **Decoder**: Android `MediaCodec` hardware decoder configured for minimal latency (10ms queue timeout) rendering to `ExternalDisplaySurfaceView`.
- **Dynamic Luminance Engine**: Uses ambient light sensor data and screen nits estimation on Mac (`MacLuminanceMonitor`) and Android (`LuminanceEngine`) to automatically match display brightness.
- **Input Injection**: Full touch, stylus, trackpad, and mouse coordinates captured on Android and mapped back into macOS via `VirtualDisplayInputInjector`.

### 3. Native macOS Finder Storage (`DroidLinkFileProvider`)
- Native macOS `NSFileProviderReplicatedExtension` mounts `/storage/emulated/0` directly in Finder's sidebar.
- **Wire-Speed Transfers**: Reads and writes flow directly through AOA USB with local Wi-Fi fallback.
- **64-bit Streaming**: Adaptive chunking from 512 KB to 8 MB with support for files exceeding 4 GB.
- **Filesystem Synchronization**: Android `AndroidFileWatcher` alerts Finder when remote files change.

### 4. Universal Clipboard
- Bidirectional synchronization of text snippets, URLs, and code blocks.
- Incognito Mode toggle to pause sharing during sensitive work.
- Android Accessibility Service and Quick Settings Tile for quick toggling and background sync.

### 5. Notification Mirroring & Controls
- Intercepts Android status bar alerts via `NotificationListenerService` and renders them in macOS Notification Center with original app icons.
- Supports actionable notification callbacks from Mac to Android.
- Android in-app notification filter screen allows whitelisting or blacklisting specific apps.

### 6. Hardware Vitals & Telemetry
- Transmits live device diagnostics from Android to macOS:
  - Battery charge level, charging status, and power source (AC/USB/Wireless).
  - Wi-Fi SSID, RSSI, and link quality indicators.
  - Cellular carrier name, network technology (5G/LTE), and dual-SIM signal bars.

### 7. Cross-Platform Share Extensions
- Right-click macOS Share Extension (`DroidLinkShare`) to send files to Android directly from Finder.
- Android system Share Sheet (`ShareActivity`) sends photos, documents, and videos directly to macOS.

---

## 📁 Repository Documentation Map

```
droidlink/
├── README.md                    # Main landing page, overview, and quickstart guide
├── IMPLEMENTATION_STATUS.md     # Granular implementation checklist and component status
├── PROJECT_SUMMARY.md           # Executive architectural summary (this document)
├── AGENTS.md                    # Developer and AI agent technical reference & tech stack
├── docs/
│   ├── ARCHITECTURE.md          # Comprehensive architectural blueprint
│   ├── PROTOCOL.md              # Protobuf schema specification, framing, and transport
│   └── DEVELOPMENT.md           # Local development setup and contribution guidelines
├── mac/
│   ├── README.md                # macOS app build, signing, and packaging documentation
│   └── build_pkg.sh             # Automated installer creation script (DroidLink.pkg)
└── protocol/
    └── README.md                # Protocol Buffer catalog and code generation steps
```

---

## 📦 Build & Release Artifacts

- **macOS Installer**: `mac/DroidLink.pkg` (macOS 14.0+)
- **Android Package**: `android/app/build/outputs/apk/debug/app-debug.apk` (Android 10+)
- **Code Signing**: Hardened runtime with entitlement files for Finder FileProvider, Share extension, and ScreenCapture.

# DroidLink

> **Open-source, local-first Android ↔ Mac/iPad device bridging platform**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Version: 1.1](https://img.shields.io/badge/Version-1.1%20(Build%2080%2B)-purple.svg)](https://github.com/MD-Saifullah-1524/droidlink)
[![macOS: Sonoma & Sequoia](https://img.shields.io/badge/macOS-14%2B%20(Sonoma%2FSequoia)-black.svg)](https://www.apple.com/macos)
[![Android: 10+](https://img.shields.io/badge/Android-10%2B%20(API%2029%2B)-3DDC84.svg?logo=android&logoColor=white)](https://developer.android.com)
[![Multi-Transport: USB + Wi-Fi + BLE](https://img.shields.io/badge/Transport-USB%20%7C%20Wi--Fi%20%7C%20BLE-success.svg)](https://github.com/MD-Saifullah-1524/droidlink)
[![Security: AES-256-GCM + TLS](https://img.shields.io/badge/Security-AES--256--GCM-darkgreen.svg)](https://github.com/MD-Saifullah-1524/droidlink)

---

## 🚀 Overview

**DroidLink** is a free, privacy-first, open-source alternative to LinkMyMac that seamlessly bridges the Android and Apple ecosystems through direct, local device-to-device communication. 

**Zero Cloud. Zero Accounts. Zero Tracking.** All data moves directly between your devices over ultra-low-latency direct USB (Android Open Accessory 2.0), high-speed local Wi-Fi, or power-efficient Bluetooth Low Energy (BLE).

---

## ✨ Key Features

### 🖥️ 1. External Display for Mac (Extended Desktop)
Turn your Android tablet or phone into a high-performance secondary macOS monitor:
- **Ultra-Low Latency Hardware Pipeline**: VideoToolbox real-time H.264 baseline encoding on macOS with zero frame-delay count, paired with MediaCodec hardware acceleration on Android.
- **Direct USB AOA 2.0 Transport**: 60 FPS video streaming over a standard USB cable without requiring ADB debugging.
- **Dynamic Luminance & Ambient Sensor Sync**: Continuous luminance calibration matching macOS target nits to Android screen backlight in real-time.
- **Interactive Input Injection**: Full mouse, trackpad gestures, and multi-touch events forwarded directly back to macOS.
- **Flexible Display Scaling**: Choose from 1.0x (native resolution) up to 2.5x Retina scaling with automatic aspect ratio matching for phones and tablets.

### 📁 2. Android Storage in Native Finder
Browse and manage your Android files directly in the macOS Finder sidebar:
- **Native NSFileProvider Extension**: Deep integration via `NSFileProviderReplicatedExtension` mounting `/storage/emulated/0` natively in Finder.
- **Wire-Speed AOA USB & Wi-Fi Fallback**: Transfer gigabyte-sized files at full hardware cable speeds with seamless automatic fallback to local Wi-Fi.
- **64-bit Chunked Streaming**: Large-file support without 4 GB size limits, adaptive chunking (512 KB to 8 MB), and directory pagination.
- **Live File Watcher**: Automatic synchronization when files are created, modified, or deleted on either device.

### 📋 3. Universal Clipboard
Bidirectional clipboard synchronization that works transparently:
- **Instant Two-Way Sync**: Copy text or links on your Mac and paste immediately on Android, and vice-versa.
- **Incognito Mode**: Pause clipboard broadcast anytime for sensitive passwords or confidential tokens.
- **Quick Settings Tile & Accessibility Service**: Fast background capture and quick-toggle directly from Android's notification shade.

### 🔔 4. Notification Mirroring & Actions
Stay focused on your Mac without picking up your phone:
- **Native macOS Alerts**: Android notifications appear as native macOS notification banners with original app icons.
- **Action Callbacks**: Trigger notification actions directly from your Mac.
- **Granular App Filtering**: Per-app filter toggles to whitelist or mute noisy apps.

### ⚡ 5. Multi-Transport Separation
Robust multi-tiered local connectivity designed for maximum reliability and battery efficiency:
- **Tier 1: Bluetooth Low Energy (BLE GATT)**: Low-power persistent control plane, proximity pairing, device discovery, and background keep-alive.
- **Tier 2: Wi-Fi TCP**: High-bandwidth wireless socket transport with length-prefixed framing and end-to-end encryption.
- **Tier 3: Direct USB (AOA 2.0)**: Hardware-accelerated transport for extended display and high-speed file transfers without ADB requirement.

### 📊 6. Real-Time Device Telemetry
Monitor your phone's hardware vitals directly from the macOS Home dashboard:
- **Battery & Charging**: Exact battery percentage, charging state, and power source (AC/USB/Wireless).
- **Wi-Fi Diagnostics**: Connected SSID, RSSI signal levels, and connection bars.
- **Cellular & SIM**: Active carrier name, cellular network type (5G/LTE), and dual-SIM signal status.

### 📤 7. System Share Extensions
- **macOS Share Extension**: Right-click any file in Finder or Safari and choose "Share → DroidLink" to send instantly to Android.
- **Android Share Intent**: Send photos, videos, and files directly to your Mac using the system share sheet.

---

## 🏗️ System Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        macOS App                             │
│   SwiftUI (NavigationSplitView) + DroidLinkKit + Extensions  │
│                                                              │
│  ┌───────────────────────┐        ┌───────────────────────┐  │
│  │ DroidLinkFileProvider │        │    DroidLinkShare     │  │
│  │ (Finder Integration)  │        │   (Share Extension)   │  │
│  └───────────┬───────────┘        └───────────┬───────────┘  │
│              │                                │              │
│  ┌───────────▼────────────────────────────────▼───────────┐  │
│  │                    DroidLinkKit                        │  │
│  │   • VirtualDisplayBridge      • FileTransferManager    │  │
│  │   • VideoToolbox H264 Encoder • ClipboardManager       │  │
│  │   • MacLuminanceMonitor       • NotificationManager    │  │
│  └───────────────────────────┬────────────────────────────┘  │
└──────────────────────────────┼───────────────────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            │   Protocol Buffers v3 + Framing     │
            │   AES-256-GCM / TLS 1.3 Encryption  │
            └──────────────────┬──────────────────┘
                               │
       ┌───────────────────────┼───────────────────────┐
       ▼                       ▼                       ▼
  [USB AOA 2.0]           [Wi-Fi TCP]             [BLE GATT]
  (Display & Files)       (Data & Sync)           (Control & Keepalive)
       ▲                       ▲                       ▲
       └───────────────────────┼───────────────────────┘
                               │
┌──────────────────────────────┼───────────────────────────────┐
│  ┌───────────────────────────▼────────────────────────────┐  │
│  │                 DroidLink Android Service              │  │
│  │   • ExternalDisplayDecoder    • AndroidFileSystemMgr   │  │
│  │   • MediaCodec SurfaceView    • ClipboardManager       │  │
│  │   • LuminanceEngine           • NotificationListener   │  │
│  │   • AmbientLightSensorMgr     • TelemetryCollector     │  │
│  └───────────┬────────────────────────────────┬───────────┘  │
│              │                                │              │
│  ┌───────────▼───────────┐        ┌───────────▼───────────┐  │
│  │    ExternalDisplay    │        │  Main Jetpack Compose │  │
│  │       Activity        │        │      UI / Scanner     │  │
│  └───────────────────────┘        └───────────────────────┘  │
│                                                              │
│                       Android App                            │
└──────────────────────────────────────────────────────────────┘
```

---

## 📦 Installation & Setup

### Prerequisites
- **Mac**: macOS 14.0 (Sonoma) or macOS 15.0 (Sequoia)
- **Android**: Android 10 (API level 29) or later
- **USB Cable**: Standard USB-C or USB-A to USB-C data cable (for USB features)
- **Permissions**:
  - Mac: Screen Recording (for External Display), Accessibility (for input injection), Local Network
  - Android: Notification Listener, File Access / Storage, Camera (for pairing QR scan)

---

### macOS Setup

#### Option 1: Install Release Package (`.pkg`)
1. Download the latest `DroidLink.pkg` installer from the repository or release build.
2. Run the installer to install `DroidLink.app` to `/Applications`.
3. Launch DroidLink from Launchpad or Spotlight.
4. Grant the required permissions when prompted:
   - **Screen Recording**: System Settings → Privacy & Security → Screen Recording
   - **Accessibility**: System Settings → Privacy & Security → Accessibility

#### Option 2: Build from Source
```bash
cd mac
./build_pkg.sh
```
This increments the build number, compiles the main app and both app extensions (`DroidLinkFileProvider` and `DroidLinkShare`) in Release mode, code-signs with local developer certificates, and packages everything into `DroidLink.pkg`.

---

### Android Setup

#### Option 1: Install Debug APK
```bash
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

#### Option 2: Open in Android Studio
1. Open the `android/` directory in Android Studio (Ladybug or later).
2. Sync Gradle dependencies.
3. Run `:app` on your connected physical Android device.

---

### Pairing & Connecting

1. Launch **DroidLink** on macOS.
2. Launch **DroidLink** on Android.
3. Pair using either method:
   - **Bluetooth LE Auto-Discovery**: Devices discover each other automatically over BLE when in close proximity.
   - **QR Code Pairing**: Display QR code on Mac (`Home` tab → `Pair Device`) and scan using the Android in-app CameraX scanner.
4. **Connect via USB**: Connect your phone to your Mac with a USB cable. On Android, accept the prompt to allow DroidLink USB accessory communication.
5. All modules (Clipboard, Notifications, Finder Storage, and External Display) are immediately available.

---

## 🛠️ Repository Structure

```
droidlink/
├── mac/                                    # macOS Native Application
│   ├── DroidLink.xcodeproj                # Xcode project configuration
│   ├── build_pkg.sh                       # Automated release packaging script
│   ├── Sources/
│   │   ├── DroidLink/                     # Main SwiftUI application
│   │   │   ├── ContentView.swift          # Primary NavigationSplitView layout
│   │   │   ├── HomeDetailView.swift       # Dashboard, vitals, & connection controls
│   │   │   ├── ExternalDisplayDetailView.swift # Extended monitor settings & controls
│   │   │   ├── NotificationsDetailView.swift   # Mirrored alerts history & filters
│   │   │   ├── ClipboardDetailView.swift  # Clipboard history & incognito settings
│   │   │   └── SettingsDetailView.swift   # Transports, audio & preferences
│   │   ├── DroidLinkKit/                  # Core shared framework
│   │   │   ├── AoaUsbManager.swift        # USB AOA 2.0 communication engine
│   │   │   ├── VirtualDisplayBridge.swift # macOS virtual monitor lifecycle
│   │   │   ├── H264EncoderEngine.swift    # VideoToolbox real-time encoder
│   │   │   ├── VirtualDisplayInputInjector.swift # Remote touch/mouse injection
│   │   │   ├── MacLuminanceMonitor.swift  # Ambient light monitor & nits estimator
│   │   │   ├── FileTransferManager.swift  # 64-bit chunked file streaming
│   │   │   ├── FileProvider/              # NSFileProviderReplicatedExtension domain manager
│   │   │   ├── Bluetooth/                 # CoreBluetooth BLE server & chunking
│   │   │   └── CryptoChannel.swift        # AES-256-GCM symmetric encryption
│   │   ├── DroidLinkFileProvider/         # Native Finder extension
│   │   └── DroidLinkShare/                # macOS Share extension
│   └── Tests/                             # DroidLink test suite
│
├── android/                                # Android Application
│   ├── app/                               # Main application module
│   │   └── src/main/java/com/droidlink/app/
│   │       ├── display/                   # External display MediaCodec player & luminance
│   │       │   ├── ExternalDisplayActivity.kt
│   │       │   ├── ExternalDisplayDecoder.kt
│   │       │   ├── LuminanceEngine.kt
│   │       │   └── AmbientLightSensorManager.kt
│   │       ├── filesystem/                # File Provider service & directory watcher
│   │       ├── service/                   # DroidLinkService, Notification & Tile services
│   │       ├── ui/                        # Jetpack Compose UI, QR Scanner, App Filters
│   │       └── telemetry/                 # Battery, Wi-Fi, and SIM status collectors
│   └── core/                              # Modular core libraries
│       ├── network/                       # AOA USB transport, BLE scanner/client, TCP
│       ├── security/                      # KeyStore, crypto channels, and QR parsing
│       └── clipboard/                     # System clipboard monitoring
│
├── protocol/                               # Shared Protocol Buffer definitions
│   └── protos/
│       ├── external_display_messages.proto # Extended display control & video frames
│       ├── file_messages.proto            # File operations & FileProvider extensions
│       ├── clipboard_messages.proto       # Clipboard synchronization payloads
│       ├── notification_messages.proto    # Push notifications & action schemas
│       ├── continuity_messages.proto      # Telemetry, battery, & cellular status
│       ├── system_messages.proto          # Handshake, heartbeat, and diagnostics
│       └── droidlink_messages.proto       # Root message envelope
│
└── docs/                                  # Architectural & protocol documentation
    ├── ARCHITECTURE.md                    # In-depth architectural blueprint
    ├── PROTOCOL.md                        # Protocol specification & framing
    └── DEVELOPMENT.md                     # Contributor environment setup
```

---

## 🆚 Feature Comparison

| Capability | DroidLink | LinkMyMac | KDE Connect | scrcpy |
|:---|:---:|:---:|:---:|:---:|
| **License & Price** | **Free & Open Source** | \$20–\$40/yr | Free & Open Source | Free & Open Source |
| **Privacy / Cloudless** | **100% Local** | 100% Local | 100% Local | 100% Local |
| **No ADB Required** | **Yes (Native AOA 2.0)** | Yes | Yes | No (Requires ADB) |
| **External Mac Display** | **Yes (Hardware H.264)** | No | No | No |
| **Finder File Integration**| **Yes (NSFileProvider)**| No | Virtual Mount | No |
| **Universal Clipboard** | **Yes (Bi-directional)**| Yes | Yes | Partial |
| **Notification Mirroring** | **Yes** | Yes | Yes | No |
| **Device Vitals & Telemetry** | **Yes (Battery/SIM/Wi-Fi)** | Yes | Partial | No |
| **Dynamic Luminance Sync** | **Yes (Real-time Nits)** | No | No | No |
| **Native macOS Share Sheet** | **Yes** | Partial | No | No |

---

## 🔒 Privacy & Security

DroidLink is built around a strict **local-first, zero-trust** security model:
1. **No External Servers**: DroidLink never initiates external internet connections, stores no telemetric tracking data, and maintains no cloud accounts.
2. **End-to-End Encryption**: All traffic exchanged across local networks or Wi-Fi is protected with AES-256-GCM symmetric encryption using keys generated during initial pairing.
3. **OS-Level Sandboxing**: Cryptographic private keys are securely anchored in macOS Keychain and the Android Keystore.
4. **Transparent Codebase**: Complete source code for both macOS and Android is open for audit under the Apache 2.0 license.

---

## 📄 License

```
Copyright 2025-2026 DroidLink Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

# Project: DroidLink

**An open-source, local-first Android ↔ Mac/iPad device bridging platform**

## Project Vision

Build a free, privacy-focused alternative to LinkMyMac that enables seamless Android-Apple ecosystem integration through direct local connections. No cloud, no accounts, no tracking — just device-to-device communication over USB (AOA 2.0), local Wi-Fi, and Bluetooth Low Energy (BLE).

## Tech Stack

### Android App
- **Language**: Kotlin 2.0+ with Coroutines & Flow
- **UI**: Jetpack Compose with Material 3
- **Architecture**: Modular Clean Architecture (`:app`, `:core:network`, `:core:security`, `:core:clipboard`)
- **Networking & Transport**: Custom AOA 2.0 USB transport, TCP client with length-prefixed binary framing, BLE scanner/client
- **Hardware Acceleration**: `MediaCodec` low-latency H.264 decoder for external display
- **Permissions**: Notification listener, storage/media access, camera (CameraX for QR pairing)
- **Background Services**: Persistent foreground service (`DroidLinkService`), Quick Settings Tile (`DroidLinkTileService`), Accessibility Service (`DroidLinkAccessibilityService`)

### Mac App
- **Language**: Swift 6
- **UI**: SwiftUI (macOS 14+ Sonoma & macOS 15+ Sequoia) with `NavigationSplitView`
- **Architecture**: MVVM with Combine and Swift Concurrency
- **Shared Framework**: `DroidLinkKit` (Transports, Cryptography, Virtual Display, Protobuf schemas)
- **Extensions**:
  - `DroidLinkFileProvider`: Native `NSFileProviderReplicatedExtension` mounting Android storage in Finder
  - `DroidLinkShare`: Native macOS Share extension for 1-click file delivery
- **Hardware Acceleration**: VideoToolbox real-time H.264 baseline encoder with zero frame delay count
- **Virtual Monitor**: CoreGraphics / DisplayServices / ScreenCaptureKit virtual display bridge
- **Security**: Keychain Services, AES-256-GCM symmetric encryption

### Communication Protocol
- **Transport**: Direct USB (AOA 2.0), local Wi-Fi TCP, and Bluetooth Low Energy (BLE GATT)
- **Serialization**: Protocol Buffers v3 (`.proto` schemas as single source of truth)
- **Framing**: 4-byte header (3-byte length + 1-byte message type)
- **Security**: AES-256-GCM symmetric encryption with keys exchanged during pairing

## Project Structure

```
droidlink/
├── android/                                # Android app (Kotlin + Jetpack Compose)
│   ├── app/                               # Main application module
│   │   └── src/main/java/com/droidlink/app/
│   │       ├── display/                   # External display MediaCodec player & luminance
│   │       ├── filesystem/                # AndroidFileSystemManager & directory watcher
│   │       ├── telemetry/                 # Battery, Wi-Fi, and SIM telemetry collectors
│   │       ├── service/                   # DroidLinkService, Notification & Tile services
│   │       └── ui/                        # Compose UI screens, QR Scanner, app filters
│   └── core/                              # Modular core libraries
│       ├── network/                       # AOA USB transport, BLE scanner/client, TCP
│       ├── security/                      # KeyStore, CryptoChannel, QR parser
│       └── clipboard/                     # System clipboard monitoring
├── mac/                                    # macOS app (Swift + SwiftUI)
│   ├── DroidLink.xcodeproj                # Xcode project configuration
│   ├── build_pkg.sh                       # Packaging script generating DroidLink.pkg
│   └── Sources/
│       ├── DroidLink/                     # Main SwiftUI app & view controllers
│       ├── DroidLinkKit/                  # Core shared framework
│       │   ├── AoaUsbManager.swift        # USB AOA 2.0 engine
│       │   ├── VirtualDisplayBridge.swift # macOS virtual monitor lifecycle
│       │   ├── H264EncoderEngine.swift    # VideoToolbox encoder
│       │   ├── FileTransferManager.swift  # 64-bit chunked file streaming
│       │   ├── FileProvider/              # NSFileProvider domain management
│       │   ├── Bluetooth/                 # BLE server and chunking
│       │   └── CryptoChannel.swift        # AES-256-GCM encryption
│       ├── DroidLinkFileProvider/         # Native macOS Finder extension
│       └── DroidLinkShare/                # macOS Share extension
├── protocol/                               # Shared protocol definitions
│   └── protos/                            # Protocol Buffer v3 schemas
└── docs/                                  # Architecture, protocol, and setup guides
```

## Key Commands

```bash
# Android
cd android
./gradlew assembleDebug                    # Build debug APK
./gradlew testDebugUnitTest                # Run Android unit tests
adb install -r app/build/outputs/apk/debug/app-debug.apk # Install on device

# Mac
cd mac
./build_pkg.sh                             # Compile Release build, sign, and build DroidLink.pkg
xcodebuild -scheme DroidLink build         # Build Mac app via command line
swift test --package-path Sources/DroidLinkKit # Run kit tests

# Protocol Buffers
protoc --swift_out=mac/Sources/DroidLinkKit/Generated \
  --proto_path=protocol/protos protocol/protos/*.proto # Generate Swift bindings
protoc --kotlin_out=android/core/network/src/main/java \
  --proto_path=protocol/protos protocol/protos/*.proto # Generate Kotlin bindings
```

## Status & Shipped Capabilities (v1.1)

1. **Multi-Transport Separation**: Direct AOA 2.0 USB + BLE GATT control plane + High-speed Wi-Fi TCP.
2. **External Display for Mac**: Hardware-accelerated VideoToolbox H.264 encoding + MediaCodec decoding, reverse touch/mouse injection, dynamic luminance calibration.
3. **Android Storage in Finder**: Native macOS `NSFileProvider` mounting `/storage/emulated/0` with wire-speed USB streaming.
4. **Universal Clipboard**: Instant two-way sync, Incognito Mode, Quick Settings tile, and Accessibility Service.
5. **Notification Mirroring**: Push alerts to macOS Notification Center with app icons and action triggers.
6. **Device Telemetry**: Real-time battery, Wi-Fi SSID/RSSI, cellular carrier & dual-SIM diagnostics.
7. **System Share Extensions**: 1-click sharing between Mac Finder and Android Share Sheet.

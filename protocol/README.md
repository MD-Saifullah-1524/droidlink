# DroidLink Protocol Definitions

This directory contains the Protocol Buffer schemas for all DroidLink cross-platform communication.

---

## 📋 Overview

Communication between Android and macOS devices uses **Protocol Buffers v3** for strongly-typed, binary serialization with backwards and forwards compatibility.

---

## 📂 Schemas Catalog

All schemas reside in [`protocol/protos/`](protos/):

| Schema File | Package / Class | Purpose |
|:---|:---|:---|
| **`droidlink_messages.proto`** | `droidlink.protocol.DroidLinkMessage` | Root envelope wrapping all feature payloads |
| **`external_display_messages.proto`**| `droidlink.protocol.ExternalDisplayMessage` | External Display session lifecycle, H.264 video frames, touch/mouse input injection, and luminance/ambient sensor sync |
| **`file_messages.proto`** | `droidlink.protocol.FileMessage` | Native macOS FileProvider operations (directory enumeration, 64-bit chunked read/write, file watching) |
| **`clipboard_messages.proto`** | `droidlink.protocol.ClipboardMessage` | Bi-directional clipboard synchronization of text and links |
| **`notification_messages.proto`**| `droidlink.protocol.NotificationMessage` | Push alerts, notification dismissal, action callbacks, and app icons |
| **`continuity_messages.proto`** | `droidlink.protocol.ContinuityMessage` | Live hardware vitals: battery percentage/charging state, Wi-Fi SSID/RSSI, cellular carrier & dual-SIM diagnostics |
| **`screen_messages.proto`** | `droidlink.protocol.ScreenMessage` | Legacy screen mirroring and remote control protocols |
| **`media_messages.proto`** | `droidlink.protocol.MediaMessage` | Virtual webcam and microphone streaming schemas (Phase 2) |
| **`system_messages.proto`** | `droidlink.protocol.SystemMessage` | Handshake, pairing confirmation, heartbeat probes, and error reports |

---

## 📦 Message Framing

Every Protocol Buffer message is transmitted across TCP or USB with a 4-byte header:

```
┌────────────────────────────────────┐
│  Header (4 bytes)                  │
│  ├─ Length (3 bytes, big-endian)   │
│  └─ Type (1 byte)                  │
│      ├─ 0x01: DATA                 │
│      ├─ 0x02: HEARTBEAT            │
│      └─ 0x03: ERROR                │
├────────────────────────────────────┤
│  Protobuf Message (variable length)│
└────────────────────────────────────┘
```

---

## ⚙️ Generating Code

### Android (Kotlin)
```bash
protoc --kotlin_out=android/core/network/src/main/java \
  --proto_path=protocol/protos \
  protocol/protos/*.proto
```

### macOS (Swift)
```bash
protoc --swift_out=mac/Sources/DroidLinkKit/Generated \
  --proto_path=protocol/protos \
  protocol/protos/*.proto
```

---

## 🔒 Versioning & Compatibility Rules

1. **Additive Changes**: New fields must use optional semantics (standard in proto3) and distinct tag numbers.
2. **Never Re-number Fields**: Existing field numbers must remain constant to preserve wire compatibility.
3. **Graceful Fallbacks**: Older client builds automatically ignore unrecognized fields without failing.

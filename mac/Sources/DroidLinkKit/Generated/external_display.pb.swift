// DO NOT EDIT.
// swift-format-ignore-file
// swiftlint:disable all
//
// Generated SwiftProtobuf types for external_display_messages.proto

import Foundation
import SwiftProtobuf

fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

enum Droidlink_Protocol_DisplayCodec: SwiftProtobuf.Enum, Swift.CaseIterable {
  typealias RawValue = Int
  case displayCodecUnknown // = 0
  case displayH264 // = 1
  case displayH265 // = 2
  case UNRECOGNIZED(Int)

  init() {
    self = .displayCodecUnknown
  }

  init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .displayCodecUnknown
    case 1: self = .displayH264
    case 2: self = .displayH265
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  var rawValue: Int {
    switch self {
    case .displayCodecUnknown: return 0
    case .displayH264: return 1
    case .displayH265: return 2
    case .UNRECOGNIZED(let i): return i
    }
  }

  static let allCases: [Droidlink_Protocol_DisplayCodec] = [
    .displayCodecUnknown,
    .displayH264,
    .displayH265,
  ]
}

struct Droidlink_Protocol_ExternalDisplayConfig: Sendable, Equatable, SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "droidlink.protocol.ExternalDisplayConfig"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "width"),
    2: .same(proto: "height"),
    3: .same(proto: "fps"),
    4: .same(proto: "dpi"),
    5: .standard(proto: "hi_dpi"),
    6: .standard(proto: "bitrate_kbps"),
    7: .same(proto: "codec"),
    8: .standard(proto: "enable_audio"),
    9: .standard(proto: "enable_input"),
    10: .standard(proto: "scale_factor"),
  ]

  var width: Int32 = 0
  var height: Int32 = 0
  var fps: Int32 = 0
  var dpi: Int32 = 0
  var hiDpi: Bool = false
  var bitrateKbps: Int32 = 0
  var codec: Droidlink_Protocol_DisplayCodec = .displayCodecUnknown
  var enableAudio: Bool = false
  var enableInput: Bool = false
  var scaleFactor: Float = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularInt32Field(value: &self.width)
      case 2: try decoder.decodeSingularInt32Field(value: &self.height)
      case 3: try decoder.decodeSingularInt32Field(value: &self.fps)
      case 4: try decoder.decodeSingularInt32Field(value: &self.dpi)
      case 5: try decoder.decodeSingularBoolField(value: &self.hiDpi)
      case 6: try decoder.decodeSingularInt32Field(value: &self.bitrateKbps)
      case 7: try decoder.decodeSingularEnumField(value: &self.codec)
      case 8: try decoder.decodeSingularBoolField(value: &self.enableAudio)
      case 9: try decoder.decodeSingularBoolField(value: &self.enableInput)
      case 10: try decoder.decodeSingularFloatField(value: &self.scaleFactor)
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.width != 0 {
      try visitor.visitSingularInt32Field(value: self.width, fieldNumber: 1)
    }
    if self.height != 0 {
      try visitor.visitSingularInt32Field(value: self.height, fieldNumber: 2)
    }
    if self.fps != 0 {
      try visitor.visitSingularInt32Field(value: self.fps, fieldNumber: 3)
    }
    if self.dpi != 0 {
      try visitor.visitSingularInt32Field(value: self.dpi, fieldNumber: 4)
    }
    if self.hiDpi != false {
      try visitor.visitSingularBoolField(value: self.hiDpi, fieldNumber: 5)
    }
    if self.bitrateKbps != 0 {
      try visitor.visitSingularInt32Field(value: self.bitrateKbps, fieldNumber: 6)
    }
    if self.codec != .displayCodecUnknown {
      try visitor.visitSingularEnumField(value: self.codec, fieldNumber: 7)
    }
    if self.enableAudio != false {
      try visitor.visitSingularBoolField(value: self.enableAudio, fieldNumber: 8)
    }
    if self.enableInput != false {
      try visitor.visitSingularBoolField(value: self.enableInput, fieldNumber: 9)
    }
    if self.scaleFactor != 0 {
      try visitor.visitSingularFloatField(value: self.scaleFactor, fieldNumber: 10)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Droidlink_Protocol_ExternalDisplayConfig, rhs: Droidlink_Protocol_ExternalDisplayConfig) -> Bool {
    if lhs.width != rhs.width { return false }
    if lhs.height != rhs.height { return false }
    if lhs.fps != rhs.fps { return false }
    if lhs.dpi != rhs.dpi { return false }
    if lhs.hiDpi != rhs.hiDpi { return false }
    if lhs.bitrateKbps != rhs.bitrateKbps { return false }
    if lhs.codec != rhs.codec { return false }
    if lhs.enableAudio != rhs.enableAudio { return false }
    if lhs.enableInput != rhs.enableInput { return false }
    if lhs.scaleFactor != rhs.scaleFactor { return false }
    if lhs.unknownFields != rhs.unknownFields { return false }
    return true
  }
}

struct Droidlink_Protocol_ExternalDisplayFrame: Sendable, Equatable, SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "droidlink.protocol.ExternalDisplayFrame"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .standard(proto: "frame_data"),
    2: .standard(proto: "frame_number"),
    3: .same(proto: "timestamp"),
    4: .standard(proto: "is_keyframe"),
    5: .same(proto: "width"),
    6: .same(proto: "height"),
  ]

  var frameData: Data = Data()
  var frameNumber: Int32 = 0
  var timestamp: Int64 = 0
  var isKeyframe: Bool = false
  var width: Int32 = 0
  var height: Int32 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularBytesField(value: &self.frameData)
      case 2: try decoder.decodeSingularInt32Field(value: &self.frameNumber)
      case 3: try decoder.decodeSingularInt64Field(value: &self.timestamp)
      case 4: try decoder.decodeSingularBoolField(value: &self.isKeyframe)
      case 5: try decoder.decodeSingularInt32Field(value: &self.width)
      case 6: try decoder.decodeSingularInt32Field(value: &self.height)
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.frameData.isEmpty {
      try visitor.visitSingularBytesField(value: self.frameData, fieldNumber: 1)
    }
    if self.frameNumber != 0 {
      try visitor.visitSingularInt32Field(value: self.frameNumber, fieldNumber: 2)
    }
    if self.timestamp != 0 {
      try visitor.visitSingularInt64Field(value: self.timestamp, fieldNumber: 3)
    }
    if self.isKeyframe != false {
      try visitor.visitSingularBoolField(value: self.isKeyframe, fieldNumber: 4)
    }
    if self.width != 0 {
      try visitor.visitSingularInt32Field(value: self.width, fieldNumber: 5)
    }
    if self.height != 0 {
      try visitor.visitSingularInt32Field(value: self.height, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Droidlink_Protocol_ExternalDisplayFrame, rhs: Droidlink_Protocol_ExternalDisplayFrame) -> Bool {
    if lhs.frameData != rhs.frameData { return false }
    if lhs.frameNumber != rhs.frameNumber { return false }
    if lhs.timestamp != rhs.timestamp { return false }
    if lhs.isKeyframe != rhs.isKeyframe { return false }
    if lhs.width != rhs.width { return false }
    if lhs.height != rhs.height { return false }
    if lhs.unknownFields != rhs.unknownFields { return false }
    return true
  }
}

struct Droidlink_Protocol_ExternalDisplayInput: Sendable, Equatable, SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "droidlink.protocol.ExternalDisplayInput"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "action"),
    2: .standard(proto: "tool_type"),
    3: .standard(proto: "pointer_id"),
    4: .standard(proto: "normalized_x"),
    5: .standard(proto: "normalized_y"),
    6: .same(proto: "pressure"),
    7: .standard(proto: "tilt_x"),
    8: .standard(proto: "tilt_y"),
    9: .standard(proto: "button_state"),
    10: .standard(proto: "scroll_dx"),
    11: .standard(proto: "scroll_dy"),
    12: .standard(proto: "key_code"),
    13: .same(proto: "modifiers"),
    14: .same(proto: "characters"),
  ]

  enum ActionType: SwiftProtobuf.Enum, Swift.CaseIterable {
    typealias RawValue = Int
    case actionUnknown // = 0
    case down // = 1
    case move // = 2
    case up // = 3
    case scroll // = 4
    case cancel // = 5
    case keyDown // = 6
    case keyUp // = 7
    case UNRECOGNIZED(Int)

    init() { self = .actionUnknown }

    init?(rawValue: Int) {
      switch rawValue {
      case 0: self = .actionUnknown
      case 1: self = .down
      case 2: self = .move
      case 3: self = .up
      case 4: self = .scroll
      case 5: self = .cancel
      case 6: self = .keyDown
      case 7: self = .keyUp
      default: self = .UNRECOGNIZED(rawValue)
      }
    }

    var rawValue: Int {
      switch self {
      case .actionUnknown: return 0
      case .down: return 1
      case .move: return 2
      case .up: return 3
      case .scroll: return 4
      case .cancel: return 5
      case .keyDown: return 6
      case .keyUp: return 7
      case .UNRECOGNIZED(let i): return i
      }
    }

    static let allCases: [ActionType] = [
      .actionUnknown, .down, .move, .up, .scroll, .cancel, .keyDown, .keyUp,
    ]
  }

  enum ToolType: SwiftProtobuf.Enum, Swift.CaseIterable {
    typealias RawValue = Int
    case toolUnknown // = 0
    case finger // = 1
    case stylus // = 2
    case mouse // = 3
    case UNRECOGNIZED(Int)

    init() { self = .toolUnknown }

    init?(rawValue: Int) {
      switch rawValue {
      case 0: self = .toolUnknown
      case 1: self = .finger
      case 2: self = .stylus
      case 3: self = .mouse
      default: self = .UNRECOGNIZED(rawValue)
      }
    }

    var rawValue: Int {
      switch self {
      case .toolUnknown: return 0
      case .finger: return 1
      case .stylus: return 2
      case .mouse: return 3
      case .UNRECOGNIZED(let i): return i
      }
    }

    static let allCases: [ToolType] = [
      .toolUnknown, .finger, .stylus, .mouse,
    ]
  }

  var action: ActionType = .actionUnknown
  var toolType: ToolType = .toolUnknown
  var pointerID: Int32 = 0
  var normalizedX: Float = 0
  var normalizedY: Float = 0
  var pressure: Float = 0
  var tiltX: Float = 0
  var tiltY: Float = 0
  var buttonState: Int32 = 0
  var scrollDx: Float = 0
  var scrollDy: Float = 0
  var keyCode: Int32 = 0
  var modifiers: Int32 = 0
  var characters: String = String()

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularEnumField(value: &self.action)
      case 2: try decoder.decodeSingularEnumField(value: &self.toolType)
      case 3: try decoder.decodeSingularInt32Field(value: &self.pointerID)
      case 4: try decoder.decodeSingularFloatField(value: &self.normalizedX)
      case 5: try decoder.decodeSingularFloatField(value: &self.normalizedY)
      case 6: try decoder.decodeSingularFloatField(value: &self.pressure)
      case 7: try decoder.decodeSingularFloatField(value: &self.tiltX)
      case 8: try decoder.decodeSingularFloatField(value: &self.tiltY)
      case 9: try decoder.decodeSingularInt32Field(value: &self.buttonState)
      case 10: try decoder.decodeSingularFloatField(value: &self.scrollDx)
      case 11: try decoder.decodeSingularFloatField(value: &self.scrollDy)
      case 12: try decoder.decodeSingularInt32Field(value: &self.keyCode)
      case 13: try decoder.decodeSingularInt32Field(value: &self.modifiers)
      case 14: try decoder.decodeSingularStringField(value: &self.characters)
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.action != .actionUnknown {
      try visitor.visitSingularEnumField(value: self.action, fieldNumber: 1)
    }
    if self.toolType != .toolUnknown {
      try visitor.visitSingularEnumField(value: self.toolType, fieldNumber: 2)
    }
    if self.pointerID != 0 {
      try visitor.visitSingularInt32Field(value: self.pointerID, fieldNumber: 3)
    }
    if self.normalizedX != 0 {
      try visitor.visitSingularFloatField(value: self.normalizedX, fieldNumber: 4)
    }
    if self.normalizedY != 0 {
      try visitor.visitSingularFloatField(value: self.normalizedY, fieldNumber: 5)
    }
    if self.pressure != 0 {
      try visitor.visitSingularFloatField(value: self.pressure, fieldNumber: 6)
    }
    if self.tiltX != 0 {
      try visitor.visitSingularFloatField(value: self.tiltX, fieldNumber: 7)
    }
    if self.tiltY != 0 {
      try visitor.visitSingularFloatField(value: self.tiltY, fieldNumber: 8)
    }
    if self.buttonState != 0 {
      try visitor.visitSingularInt32Field(value: self.buttonState, fieldNumber: 9)
    }
    if self.scrollDx != 0 {
      try visitor.visitSingularFloatField(value: self.scrollDx, fieldNumber: 10)
    }
    if self.scrollDy != 0 {
      try visitor.visitSingularFloatField(value: self.scrollDy, fieldNumber: 11)
    }
    if self.keyCode != 0 {
      try visitor.visitSingularInt32Field(value: self.keyCode, fieldNumber: 12)
    }
    if self.modifiers != 0 {
      try visitor.visitSingularInt32Field(value: self.modifiers, fieldNumber: 13)
    }
    if !self.characters.isEmpty {
      try visitor.visitSingularStringField(value: self.characters, fieldNumber: 14)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Droidlink_Protocol_ExternalDisplayInput, rhs: Droidlink_Protocol_ExternalDisplayInput) -> Bool {
    if lhs.action != rhs.action { return false }
    if lhs.toolType != rhs.toolType { return false }
    if lhs.pointerID != rhs.pointerID { return false }
    if lhs.normalizedX != rhs.normalizedX { return false }
    if lhs.normalizedY != rhs.normalizedY { return false }
    if lhs.pressure != rhs.pressure { return false }
    if lhs.tiltX != rhs.tiltX { return false }
    if lhs.tiltY != rhs.tiltY { return false }
    if lhs.buttonState != rhs.buttonState { return false }
    if lhs.scrollDx != rhs.scrollDx { return false }
    if lhs.scrollDy != rhs.scrollDy { return false }
    if lhs.keyCode != rhs.keyCode { return false }
    if lhs.modifiers != rhs.modifiers { return false }
    if lhs.characters != rhs.characters { return false }
    if lhs.unknownFields != rhs.unknownFields { return false }
    return true
  }
}

struct Droidlink_Protocol_ExternalDisplayMessage: @unchecked Sendable, Equatable, SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  static let protoMessageName: String = "droidlink.protocol.ExternalDisplayMessage"
  static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "event"),
    2: .same(proto: "config"),
    3: .same(proto: "frame"),
    4: .same(proto: "input"),
    5: .same(proto: "message"),
    6: .same(proto: "timestamp"),
  ]

  enum DisplayEventType: SwiftProtobuf.Enum, Swift.CaseIterable {
    typealias RawValue = Int
    case eventUnknown // = 0
    case startRequest // = 1
    case startResponse // = 2
    case started // = 3
    case stop // = 4
    case videoFrame // = 5
    case inputEvent // = 6
    case configUpdate // = 7
    case heartbeat // = 8
    case error // = 9
    case UNRECOGNIZED(Int)

    init() { self = .eventUnknown }

    init?(rawValue: Int) {
      switch rawValue {
      case 0: self = .eventUnknown
      case 1: self = .startRequest
      case 2: self = .startResponse
      case 3: self = .started
      case 4: self = .stop
      case 5: self = .videoFrame
      case 6: self = .inputEvent
      case 7: self = .configUpdate
      case 8: self = .heartbeat
      case 9: self = .error
      default: self = .UNRECOGNIZED(rawValue)
      }
    }

    var rawValue: Int {
      switch self {
      case .eventUnknown: return 0
      case .startRequest: return 1
      case .startResponse: return 2
      case .started: return 3
      case .stop: return 4
      case .videoFrame: return 5
      case .inputEvent: return 6
      case .configUpdate: return 7
      case .heartbeat: return 8
      case .error: return 9
      case .UNRECOGNIZED(let i): return i
      }
    }

    static let allCases: [DisplayEventType] = [
      .eventUnknown, .startRequest, .startResponse, .started, .stop,
      .videoFrame, .inputEvent, .configUpdate, .heartbeat, .error
    ]
  }

  var event: DisplayEventType = .eventUnknown

  var config: Droidlink_Protocol_ExternalDisplayConfig {
    get { return _config ?? Droidlink_Protocol_ExternalDisplayConfig() }
    set { _config = newValue }
  }
  private var _config: Droidlink_Protocol_ExternalDisplayConfig? = nil

  var frame: Droidlink_Protocol_ExternalDisplayFrame {
    get { return _frame ?? Droidlink_Protocol_ExternalDisplayFrame() }
    set { _frame = newValue }
  }
  private var _frame: Droidlink_Protocol_ExternalDisplayFrame? = nil

  var input: Droidlink_Protocol_ExternalDisplayInput {
    get { return _input ?? Droidlink_Protocol_ExternalDisplayInput() }
    set { _input = newValue }
  }
  private var _input: Droidlink_Protocol_ExternalDisplayInput? = nil

  var message: String = String()
  var timestamp: Int64 = 0

  var unknownFields = SwiftProtobuf.UnknownStorage()

  init() {}

  mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      switch fieldNumber {
      case 1: try decoder.decodeSingularEnumField(value: &self.event)
      case 2: try decoder.decodeSingularMessageField(value: &self._config)
      case 3: try decoder.decodeSingularMessageField(value: &self._frame)
      case 4: try decoder.decodeSingularMessageField(value: &self._input)
      case 5: try decoder.decodeSingularStringField(value: &self.message)
      case 6: try decoder.decodeSingularInt64Field(value: &self.timestamp)
      default: break
      }
    }
  }

  func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.event != .eventUnknown {
      try visitor.visitSingularEnumField(value: self.event, fieldNumber: 1)
    }
    if let v = self._config {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }
    if let v = self._frame {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    }
    if let v = self._input {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
    }
    if !self.message.isEmpty {
      try visitor.visitSingularStringField(value: self.message, fieldNumber: 5)
    }
    if self.timestamp != 0 {
      try visitor.visitSingularInt64Field(value: self.timestamp, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  static func ==(lhs: Droidlink_Protocol_ExternalDisplayMessage, rhs: Droidlink_Protocol_ExternalDisplayMessage) -> Bool {
    if lhs.event != rhs.event { return false }
    if lhs._config != rhs._config { return false }
    if lhs._frame != rhs._frame { return false }
    if lhs._input != rhs._input { return false }
    if lhs.message != rhs.message { return false }
    if lhs.timestamp != rhs.timestamp { return false }
    if lhs.unknownFields != rhs.unknownFields { return false }
    return true
  }
}

import Foundation
import AVFoundation

/// Dedicated non-isolated audio capturer for Mac microphone.
/// By keeping this class un-isolated from `@MainActor`, `installTap` callbacks execute
/// on CoreAudio / AVFAudio realtime queues without triggering Swift 6 actor-isolation runtime crashes.
final class MicAudioCapturer: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var isRunning = false
    private let lock = NSLock()

    var onAudioData: (@Sendable (_ pcm16Data: Data, _ sampleRate: Int32, _ channels: Int32, _ level: Float) -> Void)?

    func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            print("⚠️ MicAudioCapturer: Invalid input sample rate: \(inputFormat.sampleRate)")
            return
        }

        let sampleRate = Int32(inputFormat.sampleRate)
        let channelCount = Int32(inputFormat.channelCount)

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            self.lock.lock()
            let active = self.isRunning
            self.lock.unlock()
            guard active else { return }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let floatData = buffer.floatChannelData?[0] else { return }

            var sum: Float = 0.0
            var pcm16 = [Int16](repeating: 0, count: frameLength)
            for i in 0..<frameLength {
                let sample = floatData[i]
                sum += abs(sample)
                let clamped = max(-1.0, min(1.0, sample))
                pcm16[i] = Int16(clamped * 32767.0)
            }

            let avg = sum / Float(frameLength)
            let level = min(1.0, avg * 5.0)
            let pcmData = pcm16.withUnsafeBufferPointer { Data(buffer: $0) }

            self.onAudioData?(pcmData, sampleRate, channelCount, level)
        }

        do {
            try engine.start()
            self.engine = engine
            self.isRunning = true
            print("🎙️ MicAudioCapturer: Engine started at \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) ch")
        } catch {
            print("❌ MicAudioCapturer: Failed to start engine: \(error)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning || engine != nil else { return }
        isRunning = false
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        print("🎙️ MicAudioCapturer: Engine stopped")
    }
}

/// Handles low-latency playback of Android device audio and captures Mac microphone audio.
@MainActor
final class ScreenAudioEngine: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let micCapturer = MicAudioCapturer()
    private var isPlaying = false
    private var isCapturingMic = false

    @Published var isDeviceAudioMuted: Bool = false
    @Published var isMicMuted: Bool = true
    @Published var micLevel: Float = 0.0

    var onMicAudioCaptured: ((Data, Int32, Int32) -> Void)?

    private let playbackFormat: AVAudioFormat

    init() {
        self.playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) ??
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    }

    // MARK: - Device Audio Playback (Android -> Mac)

    func startPlayback() {
        guard !isPlaying else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        do {
            try engine.start()
            player.play()
            self.audioEngine = engine
            self.playerNode = player
            self.isPlaying = true
            print("🔊 ScreenAudioEngine: Playback started at 48kHz stereo float32")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
        }
    }

    func playAudioFrame(pcmData: Data, sampleRate: Int32, channels: Int32) {
        guard isPlaying, !isDeviceAudioMuted, let player = playerNode else { return }

        let sampleCount = pcmData.count / 2 // 2 bytes per 16-bit sample
        let numChannels = Int(channels > 0 ? channels : 2)
        guard numChannels > 0 else { return }
        let frames = sampleCount / numChannels
        guard frames > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frames)

        guard let leftChannel = pcmBuffer.floatChannelData?[0] else { return }
        let rightChannel = (numChannels > 1) ? pcmBuffer.floatChannelData?[1] : leftChannel

        pcmData.withUnsafeBytes { raw in
            guard let int16Ptr = raw.bindMemory(to: Int16.self).baseAddress else { return }
            if numChannels >= 2, let right = rightChannel {
                for i in 0..<frames {
                    leftChannel[i] = Float(int16Ptr[i * 2]) / 32768.0
                    right[i] = Float(int16Ptr[i * 2 + 1]) / 32768.0
                }
            } else {
                for i in 0..<frames {
                    leftChannel[i] = Float(int16Ptr[i]) / 32768.0
                }
            }
        }

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    func stopPlayback() {
        guard isPlaying else { return }
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        isPlaying = false
        print("🔇 ScreenAudioEngine: Playback stopped")
    }

    // MARK: - Mac Microphone Capture (Mac -> Android)

    func startMicCapture() {
        guard !isCapturingMic else { return }

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self = self, granted else {
                    print("⚠️ Mac microphone permission denied")
                    return
                }
                self.setupMicEngine()
            }
        }
    }

    private func setupMicEngine() {
        guard !isCapturingMic else { return }

        micCapturer.onAudioData = { [weak self] pcmData, sampleRate, channels, level in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isMicMuted, self.isCapturingMic else { return }
                self.micLevel = level
                self.onMicAudioCaptured?(pcmData, sampleRate, channels)
            }
        }

        micCapturer.start()
        self.isCapturingMic = true
        print("🎙️ ScreenAudioEngine: Mic capture active")
    }

    func stopMicCapture() {
        guard isCapturingMic else { return }
        isCapturingMic = false
        micCapturer.stop()
        micLevel = 0.0
        print("🎙️ ScreenAudioEngine: Mic capture stopped")
    }

    func teardown() {
        stopPlayback()
        stopMicCapture()
    }
}

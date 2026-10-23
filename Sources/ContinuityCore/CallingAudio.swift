import Foundation
import AVFoundation

/// In-memory audio used by tests and loopback checks. No hardware, no permission.
/// `--call-audio-selftest`: runs the real engine for 3 s without a call and reports capture health.
public enum CallingSelfTest {
    @MainActor public static func run() async -> String {
        func report(_ text: String) -> String {
            CallingDiagnostics.shared.log(text); CallingDiagnostics.shared.flush(); return text
        }
        guard await CallingAudioEngine.requestMicrophone() else { return report("selftest: microphone access not granted") }
        let engine = CallingAudioEngine()
        do { try engine.start() } catch { return report("selftest: engine failed to start code=\((error as NSError).code)") }
        var samples = 0, peak = 0, energy = 0.0
        let end = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < end {
            try? await Task.sleep(nanoseconds: 20_000_000)
            let chunk = engine.capture.read(4096)
            samples += chunk.count
            for v in chunk { let a = abs(Int(v)); peak = max(peak, a); energy += Double(v) * Double(v) }
        }
        let totals = engine.captureTotals
        let rms = samples > 0 ? Int((energy / Double(samples)).squareRoot()) : 0
        let vp = engine.voiceProcessing
        let report = "selftest: captured16kSamples=\(samples) (~\(samples / 320) frames of 20 ms, expect ~150) rms=\(rms) peak=\(peak) tapCalls=\(totals.tapCalls) converted=\(totals.framesOut) voiceProcessingStayedOn=\(vp) \(engine.diagnostics)"
        engine.stop()
        CallingDiagnostics.shared.log(report); CallingDiagnostics.shared.flush()
        return report
    }
}

final class CallingMemoryAudio: CallingAudioIO {
    let capture = CallingPCMRing(capacity: 16000)
    let playback = CallingPCMRing(capacity: 16000)
    private(set) var started = false
    func start() throws { started = true }
    func stop() { started = false }
}

/// Microphone and speaker through AVAudioEngine, converted to 16 kHz mono Int16 for the codec.
/// - Microphone permission is requested only by `requestMicrophone()`, which the call controller calls when
///   a call starts (never at launch).
/// - Capture converts tapped PCM in memory; playback is an AVAudioSourceNode that
///   only copies from a preallocated ring.
/// - Route/configuration changes restart the engine and reinstall the tap.
final class CallingAudioEngine: CallingAudioIO {
    let capture = CallingPCMRing(capacity: 16000 / 2)        // 0.5 s
    let playback = CallingPCMRing(capacity: 16000 / 2)
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var captureConverter = CallingCaptureConverter()
    private var observer: NSObjectProtocol?
    private var running = false
    /// Whether echo cancellation is active for the current call (diagnostics).
    private(set) var voiceProcessing = false
    private let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 8192)
    deinit { scratch.deallocate() }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        guard !running else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw ContinuityError.message("Microphone access is not allowed for this app.") }
        // Voice processing gives echo cancellation on a speaker + mic Mac, but its I/O unit fails to
        // initialize (-10875) on some device combinations, such as a separate Bluetooth output. Then the
        // call continues on a fresh engine without it.
        do { try startEngine(voiceProcessing: true) } catch {
            CallingDiagnostics.shared.log("audio voice-processing start failed code=\((error as NSError).code)")
            teardown(); engine = AVAudioEngine()
            try startEngine(voiceProcessing: false)
        }
        running = true
        CallingDiagnostics.shared.log("audio engine started vp=\(voiceProcessing) active=\(engine.inputNode.isVoiceProcessingEnabled) in=\(inputDescription)")
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.routeChanged()
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        if voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        self.voiceProcessing = voiceProcessing
        let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let ring = playback, scratch = self.scratch
        let node = AVAudioSourceNode(format: playbackFormat) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = min(Int(frames), 8192)   // scratch is preallocated: no allocation on the audio thread
            let got = ring.read(into: UnsafeMutableBufferPointer(start: scratch, count: count))
            for i in 0..<got { out[i] = Float(scratch[i]) / 32768 }
            if got < Int(frames) { for i in got..<Int(frames) { out[i] = 0 } }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
        // VoiceProcessingIO exposes extra raw microphone/reference channels. Request only its
        // processed mono stream and use the same client format on the output side.
        if voiceProcessing { engine.connect(engine.mainMixerNode, to: engine.outputNode, format: captureFormat) }
        installTap()
        engine.prepare()
        do { try engine.start() } catch {
            CallingDiagnostics.shared.log("audio start failed vp=\(voiceProcessing) code=\((error as NSError).code) in=\(inputDescription) out=\(engine.outputNode.inputFormat(forBus: 0))")
            throw error
        }
    }

    // Capture diagnostics (written from the tap thread, read from the diagnostics timer).
    private let counterLock = NSLock()
    private var tapCalls = 0, tapFramesIn = 0, framesOut = 0, convertErrors = 0, lastConvertError = ""
    private(set) var inputDescription = "none"

    var diagnostics: String {
        counterLock.lock(); defer { counterLock.unlock() }
        return "audio[vp=\(voiceProcessing) in=\(inputDescription) tapCalls=\(tapCalls) framesIn=\(tapFramesIn) framesOut16k=\(framesOut) convErr=\(convertErrors)\(lastConvertError.isEmpty ? "" : " last=" + lastConvertError) capRing=\(capture.available) capOverflow=\(capture.overflowed)]"
    }
    /// Frames delivered by the microphone tap and converted samples since start (self-test).
    var captureTotals: (tapCalls: Int, framesOut: Int) { counterLock.lock(); defer { counterLock.unlock() }; return (tapCalls, framesOut) }


    private var captureFormat: AVAudioFormat {
        if voiceProcessing {
            let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if rate > 0, let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) { return mono }
        }
        return engine.inputNode.outputFormat(forBus: 0)
    }

    private func installTap() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = captureFormat
        counterLock.lock()
        inputDescription = "\(Int(format.sampleRate))Hz/\(format.channelCount)ch/\(format.commonFormat.rawValue)\(format.isInterleaved ? "i" : "n")"
        counterLock.unlock()
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        captureConverter = CallingCaptureConverter()
        let ring = capture
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            self.counterLock.lock(); self.tapCalls += 1; self.tapFramesIn += frames; self.counterLock.unlock()
            guard frames > 0 else { return }
            // Voice processing can deliver several channels. Take channel 0 explicitly and convert that mono signal;
            // AVAudioConverter's own multichannel-to-mono path fails silently for some layouts.
            let out: AVAudioPCMBuffer
            do { out = try self.captureConverter.convert(buffer) }
            catch { self.noteError("capture conversion code=\((error as NSError).code)"); return }
            if let data = out.int16ChannelData?[0], out.frameLength > 0 {
                ring.write(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
                self.counterLock.lock(); self.framesOut += Int(out.frameLength); self.counterLock.unlock()
            }
        }
    }

    private func noteError(_ text: String) {
        counterLock.lock(); convertErrors += 1; lastConvertError = text; counterLock.unlock()
    }

    private func routeChanged() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        installTap()
        engine.prepare()
        if !engine.isRunning { try? engine.start() }
    }

    /// Releases the graph of a failed or finished start.
    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let source { engine.detach(source) }
        source = nil; captureConverter = CallingCaptureConverter()
    }

    func stop() {
        guard running else { return }
        running = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        teardown()
        capture.clear(); playback.clear()
    }
}

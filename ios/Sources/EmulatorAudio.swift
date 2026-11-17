import AVFoundation
import Foundation

/// Plays interleaved stereo S16 PCM drained from the core after each frame.
final class EmulatorAudio {
  private let engine = AVAudioEngine()
  private var sourceNode: AVAudioSourceNode?
  private var started = false
  private var outputEnabled = true
  private var lastVolume: Float = -1
  private var hwRate = Double(PK_IOS_AUDIO_SAMPLE_RATE)
  private var observers: [NSObjectProtocol] = []
  /// Bumps on start/stop so a deferred tear-down can't kill a new session.
  private var generation = 0
  /// Preallocated — never malloc on the real-time audio callback.
  private let maxCallbackFrames = 4096
  private let pcmScratch: UnsafeMutablePointer<Int16>

  init() {
    pcmScratch = .allocate(capacity: maxCallbackFrames * 2)
    pcmScratch.initialize(repeating: 0, count: maxCallbackFrames * 2)
  }

  deinit {
    removeSessionObservers()
    pcmScratch.deallocate()
  }

  func start() {
    generation += 1
    guard !started else {
      outputEnabled = true
      applyVolumeIfNeeded()
      return
    }
    configureSessionAndEngine()
    installSessionObservers()
  }

  /// Silence only — never touches `AVAudioEngine.stop()` (that blocked Exit).
  func mute() {
    outputEnabled = false
    if started {
      engine.mainMixerNode.outputVolume = 0
      lastVolume = 0
    }
  }

  /// Mute now; tear down the engine on a later main turn (never inline on Exit).
  func stop() {
    generation += 1
    let gen = generation
    removeSessionObservers()
    mute()
    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == gen else { return }
      guard self.started else { return }
      self.tearDownEngine()
      // Do not setActive(false) — it can hang; next start() reactivates.
    }
  }

  func setOutputEnabled(_ enabled: Bool) {
    outputEnabled = enabled
    applyVolumeIfNeeded()
  }

  // MARK: - Engine

  private func configureSessionAndEngine() {
    hwRate = Double(PK_IOS_AUDIO_SAMPLE_RATE)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setPreferredSampleRate(Double(PK_IOS_AUDIO_SAMPLE_RATE))
      // ~50 ms — GBC Expand still crackled at 40 ms on underruns; DS uses audio catch-up.
      try session.setPreferredIOBufferDuration(0.05)
      try session.setActive(true)
      // iOS often keeps 44.1 kHz despite a 48 kHz preference. Drive blip and the
      // source node at the *actual* rate or music plays slow / pitch-shifted.
      if session.sampleRate > 0 {
        hwRate = session.sampleRate
      }
    } catch {
      // Still attempt engine start; session prefs are best-effort.
    }
    pk_ios_set_output_sample_rate(hwRate)

    let format = AVAudioFormat(standardFormatWithSampleRate: hwRate, channels: 2)!
    let scratch = pcmScratch
    let scratchCap = maxCallbackFrames
    let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
      let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard let leftBuf = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
        return noErr
      }
      let frames = min(Int(frameCount), scratchCap)
      _ = pk_ios_audio_render(scratch, Int32(frames))
      if abl.count > 1, let rightBuf = abl[1].mData?.assumingMemoryBound(to: Float.self) {
        for i in 0..<frames {
          leftBuf[i] = Float(scratch[i * 2]) / 32768.0
          rightBuf[i] = Float(scratch[i * 2 + 1]) / 32768.0
        }
        if frames < Int(frameCount) {
          let z = UnsafeMutableBufferPointer(start: leftBuf + frames, count: Int(frameCount) - frames)
          z.initialize(repeating: 0)
          let zr = UnsafeMutableBufferPointer(start: rightBuf + frames, count: Int(frameCount) - frames)
          zr.initialize(repeating: 0)
        }
      } else {
        for i in 0..<frames {
          leftBuf[i * 2] = Float(scratch[i * 2]) / 32768.0
          leftBuf[i * 2 + 1] = Float(scratch[i * 2 + 1]) / 32768.0
        }
      }
      return noErr
    }

    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    sourceNode = node
    lastVolume = -1
    applyVolumeIfNeeded()

    do {
      try engine.start()
      started = true
    } catch {
      tearDownEngine()
    }
  }

  private func tearDownEngine() {
    if engine.isRunning { engine.stop() }
    if let node = sourceNode {
      engine.detach(node)
      sourceNode = nil
    }
    started = false
    lastVolume = -1
  }

  private func applyVolumeIfNeeded() {
    guard started else { return }
    let v: Float = outputEnabled ? 1.0 : 0.0
    guard abs(v - lastVolume) > 0.001 else { return }
    engine.mainMixerNode.outputVolume = v
    lastVolume = v
  }

  /// iOS screenshots / Control Center can interrupt or stop AVAudioEngine; bring it back.
  private func recoverAfterInterruption() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setActive(true)
      if session.sampleRate > 0, abs(session.sampleRate - hwRate) > 1 {
        hwRate = session.sampleRate
        pk_ios_set_output_sample_rate(hwRate)
      }
    } catch {}

    if !started {
      configureSessionAndEngine()
      return
    }
    if !engine.isRunning {
      do {
        try engine.start()
        applyVolumeIfNeeded()
      } catch {
        tearDownEngine()
        configureSessionAndEngine()
      }
    }
  }

  // MARK: - Session observers

  private func installSessionObservers() {
    removeSessionObservers()
    let nc = NotificationCenter.default
    observers.append(
      nc.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] note in
        guard let self else { return }
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
          .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
        if type == .ended {
          self.recoverAfterInterruption()
        }
      }
    )
    observers.append(
      nc.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.tearDownEngine()
        self?.configureSessionAndEngine()
      }
    )
    observers.append(
      nc.addObserver(
        forName: .AVAudioEngineConfigurationChange,
        object: engine,
        queue: .main
      ) { [weak self] _ in
        self?.recoverAfterInterruption()
      }
    )
  }

  private func removeSessionObservers() {
    let nc = NotificationCenter.default
    for o in observers { nc.removeObserver(o) }
    observers.removeAll()
  }
}

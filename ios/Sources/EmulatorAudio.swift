import AVFoundation
import Foundation

/// Plays interleaved stereo S16 PCM drained from the core after each frame.
final class EmulatorAudio {
  private let engine = AVAudioEngine()
  private var sourceNode: AVAudioSourceNode?
  private var started = false
  /// Preallocated — never malloc on the real-time audio callback.
  private let maxCallbackFrames = 4096
  private let pcmScratch: UnsafeMutablePointer<Int16>

  init() {
    pcmScratch = .allocate(capacity: maxCallbackFrames * 2)
    pcmScratch.initialize(repeating: 0, count: maxCallbackFrames * 2)
  }

  deinit {
    pcmScratch.deallocate()
  }

  func start() {
    guard !started else { return }
    var hwRate = Double(PK_IOS_AUDIO_SAMPLE_RATE)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setPreferredSampleRate(Double(PK_IOS_AUDIO_SAMPLE_RATE))
      // ~20 ms callbacks — fewer wakeups, more room before underrun.
      try session.setPreferredIOBufferDuration(0.02)
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
    engine.mainMixerNode.outputVolume = 1.0
    sourceNode = node

    do {
      try engine.start()
      started = true
    } catch {
      engine.detach(node)
      sourceNode = nil
      started = false
    }
  }

  func stop() {
    guard started else { return }
    engine.stop()
    if let node = sourceNode {
      engine.detach(node)
      sourceNode = nil
    }
    started = false
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  func setOutputEnabled(_ enabled: Bool) {
    guard started else { return }
    engine.mainMixerNode.outputVolume = enabled ? 1.0 : 0.0
  }
}

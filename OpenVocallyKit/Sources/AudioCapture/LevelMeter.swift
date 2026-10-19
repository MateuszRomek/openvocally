import Accelerate

public struct AudioLevels: Sendable, Equatable {
  public let level: Float
  /// 20 values in 0...1, loudest frequencies in the middle.
  public let bands: [Float]

  static let silent = AudioLevels(level: 0, bands: Array(repeating: 0, count: LevelMeter.bandCount))
}

/// Reproduces a WebAudio analyser with fftSize 1024, smoothing 0.45 and byte dB scaling from
/// -100 to -30 dB. It analyses at the device rate. The constants were tuned at 44.1 or 48 kHz; on a
/// 16 or 24 kHz Bluetooth mic the 1024-sample window covers more time and the bands stop at
/// that rate's Nyquist, so the tuned constants read differently there.
struct LevelMeter {
  static let bandCount = 20
  static let fftSize = 1024
  static let earlySession: Duration = .milliseconds(900)
  private static let smoothing: Float = 0.45
  private static let minDecibels: Float = -100
  private static let maxDecibels: Float = -30

  private var meterLevel: Float = 0
  private var noiseFloor: Float = 0.015
  private var speechActivity: Float = 0
  private var bandPeaks: [Float] = Array(repeating: 1, count: bandCount)
  private var smoothed = [Float](repeating: 0, count: fftSize / 2)
  private let window = vDSP.window(
    ofType: Float.self, usingSequence: .blackman, count: fftSize, isHalfWindow: false)
  private let fft = vDSP.FFT(log2n: vDSP_Length(10), radix: .radix2, ofType: DSPSplitComplex.self)

  /// `samples` holds the newest `fftSize` samples at `sampleRate`; fewer are zero-padded in front.
  mutating func analyze(samples: some Collection<Float>, sampleRate: Double, elapsed: Duration) -> AudioLevels
  {
    var frame = [Float](repeating: 0, count: Self.fftSize)
    let tail = samples.suffix(Self.fftSize)
    frame.replaceSubrange((Self.fftSize - tail.count)..., with: tail)

    let rms = vDSP.rootMeanSquare(frame)
    let bytes = frequencyBytes(frame)
    let speechEnergy = Self.speechEnergy(bytes, sampleRate: sampleRate)
    let speechDetected = speechEnergy > noiseFloor * 1.22 + 0.008
    let floorBlend: Float = speechDetected ? 0.004 : 0.08
    noiseFloor = noiseFloor * (1 - floorBlend) + speechEnergy * floorBlend

    let gatedSpeech = clamp01((speechEnergy - (noiseFloor + 0.006)) * 7.8)
    if gatedSpeech > speechActivity {
      speechActivity = speechActivity * 0.52 + gatedSpeech * 0.48
    } else {
      speechActivity = speechActivity * 0.84 + gatedSpeech * 0.16
    }

    let isEarly = elapsed < Self.earlySession
    let next =
      isEarly
      ? clamp01(max(clamp01(rms * 3.1), speechActivity * 0.86))
      : clamp01(max(clamp01(rms * 2.2) * 0.4, speechActivity))
    if next > meterLevel {
      meterLevel = meterLevel * 0.5 + next * 0.5
    } else {
      meterLevel = meterLevel * 0.88 + next * 0.12
    }

    let activity = isEarly ? max(speechActivity, 0.72) : speechActivity
    let bands = shapeBands(Self.bandPeaks(bytes, sampleRate: sampleRate), speechActivity: activity)
    return AudioLevels(level: meterLevel, bands: Self.arrangeCenterOut(bands))
  }

  /// What AnalyserNode.getByteFrequencyData returns: Blackman window, |X| / N, time smoothing,
  /// then dB mapped onto 0...255.
  mutating func frequencyBytes(_ frame: [Float]) -> [UInt8] {
    let half = Self.fftSize / 2
    let windowed = vDSP.multiply(frame, window)
    var real = [Float](repeating: 0, count: half)
    var imaginary = [Float](repeating: 0, count: half)
    var magnitudes = [Float](repeating: 0, count: half)
    real.withUnsafeMutableBufferPointer { realBuffer in
      imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
        guard let realBase = realBuffer.baseAddress, let imaginaryBase = imaginaryBuffer.baseAddress else {
          return
        }
        var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
        windowed.withUnsafeBytes { raw in
          raw.withMemoryRebound(to: DSPComplex.self) { complex in
            vDSP.convert(interleavedComplexVector: Array(complex), toSplitComplexVector: &split)
          }
        }
        fft?.forward(input: split, output: &split)
        // vDSP's packed real FFT puts the Nyquist term in imagp[0]; the analyser drops it.
        imaginaryBase[0] = 0
        vDSP.absolute(split, result: &magnitudes)
      }
    }
    // vDSP's forward real FFT is scaled by 2 relative to the DFT.
    let scale = 1 / (2 * Float(Self.fftSize))
    for index in 0..<half {
      let magnitude = magnitudes[index] * scale
      smoothed[index] =
        Self.smoothing * smoothed[index] + (1 - Self.smoothing) * (magnitude.isFinite ? magnitude : 0)
    }
    let range = Self.maxDecibels - Self.minDecibels
    return smoothed.map { value in
      let decibels = 20 * log10(value)
      let scaled = (255 / range) * (decibels - Self.minDecibels)
      guard scaled.isFinite else { return 0 }
      return UInt8(min(255, max(0, scaled.rounded(.down))))
    }
  }

  static func speechEnergy(_ bytes: [UInt8], sampleRate: Double) -> Float {
    guard !bytes.isEmpty else { return 0 }
    let nyquist = sampleRate / 2
    let toBin = { (hz: Double) in
      min(bytes.count - 1, max(0, Int((hz / nyquist * Double(bytes.count)).rounded(.down))))
    }
    let start = toBin(180)
    let end = min(max(start + 1, toBin(3600)), bytes.count)
    let sum = bytes[start..<end].reduce(Float(0)) { $0 + Float($1) }
    return pow(sum / Float(end - start) / 255, 0.8)
  }

  static func bandEdges(binCount: Int, sampleRate: Double) -> [Int] {
    let nyquist = sampleRate / 2
    let minHz = 60.0
    let maxHz = max(minHz + 1, nyquist)
    return (0...bandCount).map { index in
      let hz = min(maxHz, max(minHz, minHz * pow(maxHz / minHz, Double(index) / Double(bandCount))))
      return min(binCount - 1, max(0, Int((hz / nyquist * Double(binCount)).rounded(.down))))
    }
  }

  /// The loudest byte in each log-spaced band, tilted toward the highs.
  static func bandPeaks(_ bytes: [UInt8], sampleRate: Double) -> [Float] {
    guard !bytes.isEmpty else { return Array(repeating: 0, count: bandCount) }
    let edges = bandEdges(binCount: bytes.count, sampleRate: sampleRate)
    return (0..<bandCount).map { band in
      let start = edges[band]
      let end = min(max(start + 1, edges[band + 1]), bytes.count)
      let peak = Float(bytes[start..<end].max() ?? 0)
      let tilt = 0.8 + 0.7 * Float(band) / Float(max(1, bandCount - 1))
      return peak * tilt
    }
  }

  private mutating func shapeBands(_ tilted: [Float], speechActivity: Float) -> [Float] {
    let gate = max(0.04, 0.12 - speechActivity * 0.06)
    let ceiling = 0.82 - max(0, speechActivity - 0.5) * 0.28
    let gain = 0.58 + speechActivity * 0.36
    return tilted.enumerated().map { band, value in
      let peak = max(max(1, bandPeaks[band] * 0.98), value)
      bandPeaks[band] = peak
      let gated = max(0, min(1, value / peak) - gate)
      return min(ceiling, pow(gated, 0.9) * gain)
    }
  }

  static func arrangeCenterOut(_ values: [Float]) -> [Float] {
    let count = values.count
    var arranged = [Float](repeating: 0, count: count)
    guard count > 0 else { return arranged }
    let leftCenter = (count - 1) / 2
    let rightCenter = leftCenter + 1
    var left = leftCenter
    var right = rightCenter
    for (index, value) in values.enumerated() {
      if index == 0 {
        arranged[leftCenter] = value
      } else if index == 1, rightCenter < count {
        arranged[rightCenter] = value
      } else if index % 2 == 0 {
        left -= 1
        if left >= 0 { arranged[left] = value }
      } else {
        right += 1
        if right < count { arranged[right] = value }
      }
    }
    return arranged
  }
}

private func clamp01(_ value: Float) -> Float {
  guard value.isFinite else { return 0 }
  return min(1, max(0, value))
}

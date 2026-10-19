import AVFoundation

/// One-shot conversion of hardware-rate mono to 16 kHz mono Float32. Fed the whole buffer
/// then end of stream, so the output length is exact.
enum SpeechResampler {
  static let outputSampleRate: Double = 16_000
  /// Converting more audio changed at most the last 9 output samples of a prefix at 24, 44.1
  /// and 48 kHz.
  static let unsettledSamples = 32

  /// The 16 kHz samples of a recording so far that converting the whole recording will not
  /// change.
  static func settledPrefix(_ input: ArraySlice<Float>, from rate: Double) -> [Float]? {
    guard var output = convert(input, from: rate) else { return nil }
    output.removeLast(min(output.count, unsettledSamples))
    return output
  }

  static func convert(_ input: ArraySlice<Float>, from rate: Double) -> [Float]? {
    guard !input.isEmpty else { return [] }
    guard
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
      let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(input.count)),
      let sourceData = source.floatChannelData?[0]
    else { return nil }
    source.frameLength = AVAudioFrameCount(input.count)
    input.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      sourceData.update(from: base, count: buffer.count)
    }
    let expected = Int((Double(input.count) * outputSampleRate / rate).rounded(.up))
    guard
      let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(expected + 64))
    else { return nil }
    var result: [Float] = []
    result.reserveCapacity(expected + 64)
    var fed = false
    while true {
      output.frameLength = 0
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if fed {
          inputStatus.pointee = .endOfStream
          return nil
        }
        fed = true
        inputStatus.pointee = .haveData
        return source
      }
      if status == .error { return nil }
      if let channel = output.floatChannelData?[0] {
        result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
      }
      if status != .haveData || output.frameLength == 0 { break }
    }
    return result
  }
}

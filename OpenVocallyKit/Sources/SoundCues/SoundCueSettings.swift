import Foundation

public struct SoundCueSettings: Sendable, Equatable {
  public var enabled: Bool
  /// 0...1 in 0.05 steps. Anything else is normalized on the way in.
  public var volume: Double

  public init(enabled: Bool = true, volume: Double = Self.defaultVolume) {
    self.enabled = enabled
    self.volume = Self.normalize(volume)
  }

  static func normalize(_ volume: Double) -> Double {
    guard volume.isFinite else { return defaultVolume }
    return (min(1, max(0, volume)) * 20).rounded() / 20
  }

  public static let defaultVolume = 0.8
  public static let enabledKey = "soundCues.enabled"
  public static let volumeKey = "soundCues.volume"

  public static func load(from defaults: UserDefaults) -> SoundCueSettings {
    SoundCueSettings(
      enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
      volume: defaults.object(forKey: volumeKey) as? Double ?? defaultVolume)
  }
}

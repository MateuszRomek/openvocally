import DictationCore

/// Decides whether a cue plays and how loud. Pure, so the cooldowns are testable without audio.
struct CueGate: Sendable {
  private var lastPlayed: [SoundCue: ContinuousClock.Instant] = [:]

  static func cooldown(for cue: SoundCue) -> Duration? {
    switch cue {
    case .start: .milliseconds(85)
    case .cancel: .milliseconds(140)
    case .error: nil
    }
  }

  /// Returns the gain to play at, or nil to stay silent.
  mutating func admit(_ cue: SoundCue, at now: ContinuousClock.Instant, settings: SoundCueSettings) -> Float?
  {
    let volume = SoundCueSettings.normalize(settings.volume)
    guard settings.enabled, volume > 0 else { return nil }
    if let cooldown = Self.cooldown(for: cue), let last = lastPlayed[cue], now - last < cooldown {
      return nil
    }
    lastPlayed[cue] = now
    return Float(volume * (cue == .cancel ? 0.7 : 1))
  }

  /// A start cue that could not play within 300 ms says "the mic is live" too late; drop it.
  static func isStale(_ cue: SoundCue, enqueuedAt: ContinuousClock.Instant, now: ContinuousClock.Instant)
    -> Bool
  {
    cue == .start && now - enqueuedAt > .milliseconds(300)
  }

  /// AirPods switch to the call profile about 370 ms after the mic opens, cutting the cue's loud 100-350 ms.
  static let replayWindow: Duration = .milliseconds(500)

  /// A start cue scheduled up to `replayWindow` before an output change played into the old route; play it again.
  static func shouldReplay(
    _ cue: SoundCue, scheduledAt: ContinuousClock.Instant, changedAt: ContinuousClock.Instant
  ) -> Bool {
    cue == .start && changedAt >= scheduledAt && changedAt - scheduledAt <= replayWindow
  }
}

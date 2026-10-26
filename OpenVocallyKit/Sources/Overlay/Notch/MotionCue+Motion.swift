import DesignSystem
import OverlayCore

extension MotionCue {
  /// The one place a cue becomes an animation token.
  var motion: Motion {
    switch self {
    case .grow: .grow
    case .shrink: .shrink
    case .keyboard: .keyboard
    case .content: .content
    }
  }
}

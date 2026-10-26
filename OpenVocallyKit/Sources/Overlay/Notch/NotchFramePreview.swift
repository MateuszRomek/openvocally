import DictationCore
import SwiftUI

/// Renders the dictation notch without a panel, for the Design Gallery: the scene a fresh
/// notch shows after `phases`.
public struct NotchFramePreview: View {
  private let drawing: NotchDrawing
  private let placement: NotchPlacement
  private let reduceMotion: Bool
  @State private var bars: BarsModel

  /// `waitingForMicrophone` lets the connecting deadline pass after the last phase.
  public init(
    phases: [DictationPhase], waitingForMicrophone: Bool = false, geometry: NotchGeometry = .simulated,
    bands: [Float] = [], reduceMotion: Bool = false
  ) {
    drawing = .after(phases, waitingForMicrophone: waitingForMicrophone)
    placement = NotchPlacement(notch: geometry, hardware: true)
    self.reduceMotion = reduceMotion
    _bars = State(initialValue: BarsModel(bands: bands))
  }

  public var body: some View {
    NotchFrameView(drawing: drawing, placement: placement)
      .environment(bars)
      .environment(\.reduceMotionOverride, reduceMotion)
  }
}

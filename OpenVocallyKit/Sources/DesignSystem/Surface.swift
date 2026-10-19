import SwiftUI

/// What a view sits on. The macOS 26 HIG keeps Liquid Glass in the control layer, so content
/// never gets `.control`. The overlay is opaque: the notch is always black like the hardware,
/// and the island follows light and dark.
public enum Surface: String, CaseIterable, Sendable {
  /// Liquid Glass, for custom controls, or the regular material before macOS 26. Standard
  /// controls, the sidebar and the toolbar get it from the system.
  case control
  /// The island overlay: white in light mode, black in dark, with a hairline edge and a soft
  /// shadow so it stays visible on a window of the same color.
  case island
  /// The notch overlay: always black, so it extends the hardware notch.
  case notch
  /// A standard material, for stat cards, chart panels and grouped lists. It gains a
  /// separator outline under Increase Contrast.
  case card
}

extension View {
  /// A switch in the system green. The mono tint makes an on switch unreadable in dark mode.
  public func switchStyle() -> some View {
    toggleStyle(.switch).tint(SemanticColor.success.color)
  }

  public func surface(_ surface: Surface, in shape: some Shape) -> some View {
    modifier(SurfaceModifier(surface: surface, shape: shape))
  }
}

private struct SurfaceModifier<S: Shape>: ViewModifier {
  let surface: Surface
  let shape: S
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder func body(content: Content) -> some View {
    switch surface {
    case .control:
      if #available(macOS 26, *) {
        content.glassEffect(.regular, in: shape)
      } else {
        content.background(.regularMaterial, in: shape)
      }
    case .island:
      content
        .background(SemanticColor.onAccent.color, in: shape)
        .overlay { shape.stroke(SemanticColor.separator.color) }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 12, y: 4)
    case .notch:
      content
        .foregroundStyle(Color(nsColor: .white))
        .background(Color(nsColor: .black), in: shape)
    case .card:
      content
        .background(.regularMaterial, in: shape)
        .overlay {
          if contrast == .increased {
            shape.stroke(SemanticColor.separator.color)
          }
        }
    }
  }
}

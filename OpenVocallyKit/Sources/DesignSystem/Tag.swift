import SwiftUI

/// A short fact about an item, such as a size or a state, drawn as a capsule. `tint` colors
/// the symbol only, so the text stays readable in every appearance.
public struct Tag: View {
  let title: String
  let systemImage: String?
  let tint: SemanticColor?

  public init(_ title: String, systemImage: String? = nil, tint: SemanticColor? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
  }

  public var body: some View {
    HStack(spacing: Space.xxs.points) {
      if let systemImage {
        Image(systemName: systemImage)
          .foregroundStyle(tint.map { Color.token($0) } ?? .secondary)
          .contentTransition(.symbolEffect(.replace))
      }
      Text(title).foregroundStyle(.secondary).contentTransition(.interpolate)
    }
    .textStyle(.subheadline)
    .padding(.horizontal, Space.s)
    .padding(.vertical, Space.xxs)
    .background(.token(.selection), in: Capsule())
  }
}

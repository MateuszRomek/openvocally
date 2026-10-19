import SwiftUI

/// The heading above a group of rows or cards, with an optional line of context.
public struct SectionHeader: View {
  let title: String
  let detail: String?

  public init(title: String, detail: String? = nil) {
    self.title = title
    self.detail = detail
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Space.xxs.points) {
      Text(title).textStyle(.headline)
      if let detail {
        Text(detail).textStyle(.callout).foregroundStyle(.secondary)
      }
    }
    .accessibilityAddTraits(.isHeader)
  }
}

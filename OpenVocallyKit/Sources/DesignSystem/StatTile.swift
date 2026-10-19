import SwiftUI

/// One large number with its label, on a card. The label sits above the number, an optional
/// detail line below it, and an optional accessory, such as a change `Tag`, at the detail's right.
/// In a row, every tile takes the tallest one's height.
public struct StatTile<Accessory: View>: View {
  let value: String
  let label: String
  let detail: String?
  let accessory: Accessory

  public init(value: String, label: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
    self.value = value
    self.label = label
    self.detail = detail
    self.accessory = accessory()
  }

  public var body: some View {
    Card {
      VStack(alignment: .leading, spacing: Space.xs.points) {
        Text(label).textStyle(.callout).foregroundStyle(.secondary).lineLimit(1)
        Text(value)
          .textStyle(.numeral)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        HStack(spacing: Space.s.points) {
          if let detail {
            Text(detail).textStyle(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
          }
          Spacer(minLength: 0)
          accessory.fixedSize()
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .accessibilityElement(children: .combine)
  }
}

extension StatTile where Accessory == EmptyView {
  public init(value: String, label: String, detail: String? = nil) {
    self.init(value: value, label: label, detail: detail) { EmptyView() }
  }
}

import SwiftUI

/// A form row whose control sits centered against the title and its subtitle. A native form row
/// lines the control up with the title alone, which leaves it high on a two-line row. Hide the
/// control's own label, since the row shows it.
public struct SettingRow<Subtitle: View, Control: View>: View {
  let title: String
  let subtitle: Subtitle
  let control: Control

  public init(
    _ title: String, @ViewBuilder subtitle: () -> Subtitle, @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.subtitle = subtitle()
    self.control = control()
  }

  public var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: Space.xxs.points) {
        Text(title).textStyle(.body)
        subtitle.textStyle(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      control
    }
  }
}

extension SettingRow where Subtitle == Text? {
  public init(_ title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
    self.init(title, subtitle: { subtitle.map { Text($0) } }, control: control)
  }
}

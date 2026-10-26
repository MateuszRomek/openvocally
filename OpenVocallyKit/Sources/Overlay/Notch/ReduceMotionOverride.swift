import SwiftUI

extension EnvironmentValues {
  /// Forces Reduce Motion on or off for the overlay views, because `accessibilityReduceMotion`
  /// cannot be set from outside. The Design Gallery sets it to show both variants, and a Debug
  /// launch argument sets it on the running notch. nil follows the system setting.
  @Entry var reduceMotionOverride: Bool?
}

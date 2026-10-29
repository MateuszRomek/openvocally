import Foundation
import Testing

@testable import Overlay

struct MenuBarPlacementTests {
  static func display(x: CGFloat = 0, width: CGFloat, height: CGFloat, menuBar: CGFloat) -> ScreenGeometry {
    ScreenGeometry(
      frame: CGRect(x: x, y: 0, width: width, height: height),
      visibleFrame: CGRect(x: x, y: 0, width: width, height: height - menuBar))
  }

  @Test func `a 1080p display without a notch gets a 185 by 30 notch under its menu bar`() {
    let placement = NotchPlacement(
      Self.display(width: 1920, height: 1080, menuBar: 30), fallbackMenuBarHeight: 24)
    #expect(placement.hardware == false)
    #expect(placement.notch.size == CGSize(width: 185, height: 30))
    #expect(placement.notch.midX == 960)
    #expect(
      placement.panelFrame(on: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        == CGRect(x: 660, y: 900, width: 600, height: 180))
    #expect(placement.shapeSize(.strip) == CGSize(width: 349, height: 30))
    #expect(placement.shapeSize(.hidden) == CGSize(width: 181, height: 0))
  }

  @Test func `an ultrawide display to the right is centred on its own frame`() {
    let placement = NotchPlacement(
      Self.display(x: 1920, width: 3440, height: 1440, menuBar: 30), fallbackMenuBarHeight: 24)
    #expect(placement.hardware == false)
    #expect(placement.notch.size == CGSize(width: 185, height: 30))
    #expect(placement.notch.midX == 3640)
    #expect(
      placement.panelFrame(on: CGRect(x: 1920, y: 0, width: 3440, height: 1440))
        == CGRect(x: 3340, y: 1260, width: 600, height: 180))
    #expect(placement.shapeSize(.strip) == CGSize(width: 349, height: 30))
    #expect(placement.shapeSize(.hidden) == CGSize(width: 181, height: 0))
  }

  @Test func `a display whose menu bar leaves no gap uses the fallback height`() {
    let screen = Self.display(width: 1920, height: 1080, menuBar: 0)
    #expect(screen.menuBarHeight(fallback: 24) == 24)
    let placement = NotchPlacement(screen, fallbackMenuBarHeight: 24)
    #expect(placement.notch.size == CGSize(width: 185, height: 24))
    #expect(placement.shapeSize(.strip) == CGSize(width: 349, height: 24))
  }

  @Test func `the menu bar height is the gap above the visible frame`() {
    #expect(Self.display(width: 1920, height: 1080, menuBar: 30).menuBarHeight(fallback: 24) == 30)
  }

  @Test func `a hardware notch ignores the menu bar height`() {
    let placement = NotchPlacement(NotchGeometryTests.notched, fallbackMenuBarHeight: 24)
    #expect(placement.hardware == true)
    #expect(placement.notch.size == CGSize(width: 185, height: 32))
    #expect(placement.notch.midX == 864)
    #expect(
      placement.panelFrame(on: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        == CGRect(x: 564, y: 937, width: 600, height: 180))
    #expect(placement.shapeSize(.strip) == CGSize(width: 349, height: 32))
    #expect(placement.shapeSize(.hidden) == CGSize(width: 181, height: 30))
  }

  @Test func `with separate Spaces every display has a menu bar`() {
    #expect(MenuBarPresence.displays([3, 1, 2], separateSpaces: true) == [3, 1, 2])
  }

  @Test func `without separate Spaces only the primary display has a menu bar`() {
    #expect(MenuBarPresence.displays([3, 1, 2], separateSpaces: false) == [3])
    #expect(MenuBarPresence.displays([Int](), separateSpaces: false) == [])
  }
}

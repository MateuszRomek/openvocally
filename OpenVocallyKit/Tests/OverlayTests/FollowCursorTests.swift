import CoreGraphics
import Testing

@testable import Overlay

@MainActor struct FollowCursorTests {
  static let left: (id: CGDirectDisplayID, frame: CGRect) = (1, CGRect(x: 0, y: 0, width: 1440, height: 900))
  static let right: (id: CGDirectDisplayID, frame: CGRect) = (
    2, CGRect(x: 1440, y: 0, width: 1920, height: 1080)
  )

  @Test func `a cursor on the second display picks that display`() {
    #expect(OverlayHost.display(containing: CGPoint(x: 2000, y: 500), in: [Self.left, Self.right]) == 2)
  }

  @Test func `a cursor in the gap between displays picks none`() {
    #expect(OverlayHost.display(containing: CGPoint(x: 700, y: 1000), in: [Self.left, Self.right]) == nil)
  }

  @Test func `a cursor on the shared edge belongs to the display on its right`() {
    #expect(OverlayHost.display(containing: CGPoint(x: 1440, y: 500), in: [Self.left, Self.right]) == 2)
    #expect(OverlayHost.display(containing: CGPoint(x: 1440, y: 500), in: [Self.right, Self.left]) == 2)
  }

  @Test func `a display above and left of the main one is found by negative coordinates`() {
    let main: (id: CGDirectDisplayID, frame: CGRect) = (1, CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let upperLeft: (id: CGDirectDisplayID, frame: CGRect) = (
      3, CGRect(x: -2560, y: 1117, width: 2560, height: 1440)
    )
    #expect(OverlayHost.display(containing: CGPoint(x: -100, y: 2000), in: [main, upperLeft]) == 3)
    #expect(OverlayHost.display(containing: CGPoint(x: 100, y: 500), in: [main, upperLeft]) == 1)
    #expect(OverlayHost.display(containing: CGPoint(x: -100, y: 500), in: [main, upperLeft]) == nil)
  }
}

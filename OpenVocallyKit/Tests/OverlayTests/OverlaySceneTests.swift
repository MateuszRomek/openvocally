import DesignSystem
import DictationCore
import Testing

@testable import Overlay

struct OverlaySceneTests {
  static let recording = OverlayActivity(
    glyph: nil, status: "Recording", body: .compact(.bars(.live)))
  static let agent = OverlayActivity(
    glyph: .agent, status: "Drafting reply", body: .alert(OverlayAlert("Reply drafted")))

  @Test func `dictation wins the main shape whatever the order`() {
    var first: [OverlaySource: OverlayActivity] = [:]
    first[.agent] = Self.agent
    first[.dictation] = Self.recording
    var second: [OverlaySource: OverlayActivity] = [:]
    second[.dictation] = Self.recording
    second[.agent] = Self.agent
    for slots in [first, second] {
      let scene = OverlayScene(slots)
      #expect(scene.primary == Self.recording)
      #expect(scene.level == .compact)
    }
  }

  @Test func `clearing dictation promotes the agent`() {
    let scene = OverlayScene([.agent: Self.agent])
    #expect(scene.primary == Self.agent)
    #expect(scene.level == .alert)
  }

  @Test func `VoiceOver reads the card's text, not its status word`() {
    let card = OverlayActivity(
      glyph: .agent, status: "Drafting reply",
      body: .card(OverlayCard(title: "Reply drafted", detail: "Three lines")))
    #expect(card.accessibilityLabel == "Reply drafted, Three lines")
    #expect(Self.agent.accessibilityLabel == "Reply drafted")
  }

  @Test func `no activity is hidden`() {
    #expect(OverlayScene([:]) == .hidden)
    #expect(OverlayScene.hidden.level == .hidden)
  }

  static let compact = OverlayScene([.dictation: recording])
  static let alert = OverlayScene([.agent: agent])

  @Test(arguments: [
    (OverlayScene.hidden, compact, Motion.overlayExpand),
    (compact, alert, .overlayGrow),
    (alert, compact, .overlayCollapse),
    (compact, .hidden, .overlayHide),
    (alert, .hidden, .overlayHide),
    (compact, compact, .overlayContentSwap),
  ])
  func `each change of level picks its own curve`(
    old: OverlayScene, new: OverlayScene, motion: Motion
  ) {
    #expect(OverlayScene.motion(from: old, to: new) == motion)
  }
}

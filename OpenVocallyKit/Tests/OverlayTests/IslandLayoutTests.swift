import AppKit
import DesignSystem
import DictationCore
import SwiftUI
import Testing

@testable import Overlay

@MainActor struct IslandLayoutTests {
  static func size(of activity: OverlayActivity) -> CGSize {
    let view = NSHostingView(rootView: ActivityRow(activity: activity).environment(BarsModel()))
    return view.fittingSize
  }

  static func dictation(_ phase: DictationPhase) throws -> OverlayActivity {
    try #require(OverlayActivity(dictation: phase))
  }

  @Test func `compact rows are one island high and the meter never changes the width`() throws {
    let recording = Self.size(of: try Self.dictation(.recording(.toggle)))
    let transcribing = Self.size(of: try Self.dictation(.transcribing))
    let pasted = Self.size(of: try Self.dictation(.complete))
    #expect(recording.height == OverlayMetrics.islandHeight)
    #expect(pasted.height == OverlayMetrics.islandHeight)
    #expect(recording.width == transcribing.width)
  }

  @Test(arguments: DictationActivityTests.phases)
  func `every dictation state is one 36 pt line, plus an action line, inside the canvas`(
    phase: DictationPhase
  ) throws {
    let activity = try Self.dictation(phase)
    let size = Self.size(of: activity)
    if case .alert(let alert) = activity.body, !alert.keys.isEmpty {
      #expect(size.height > OverlayMetrics.islandHeight)
      #expect(size.height < OverlayMetrics.islandHeight * 2)
    } else {
      #expect(size.height == OverlayMetrics.islandHeight)
    }
    #expect(size.width <= OverlayMetrics.canvas.width)
  }

  @Test func `the longest card still fits the canvas`() {
    let long = String(repeating: "A long agent sentence that keeps going. ", count: 20)
    let card = OverlayActivity(
      glyph: .agent, status: "Drafting reply", body: .card(OverlayCard(title: long, detail: long)))
    let row = ActivityRow(activity: card).environment(BarsModel())
    let size = NSHostingController(rootView: row).sizeThatFits(in: OverlayMetrics.canvas)
    #expect(size.width <= OverlayMetrics.canvas.width)
    #expect(size.height < OverlayMetrics.canvas.height)
  }
}

@MainActor struct OverlayHostTests {
  /// These read real panels mid-animation, so they need a display and the full motion.
  static var animatesOnScreen: Bool {
    !NSScreen.screens.isEmpty && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// The island's frame is read from the hosting view's layers, which SwiftUI lays out
  /// before `show` returns.
  /// Polls instead of sleeping a fixed time, because the hide completes on the display link.
  static func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<40 where !condition() {
      try await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  @Test(.enabled { await Self.animatesOnScreen })
  func `show draws the island into a visible panel before it returns`() async throws {
    _ = NSApplication.shared
    let recording = try IslandLayoutTests.dictation(.recording(.pushToTalk))
    let host = OverlayHost(preference: { OverlayPreference(style: .island, edge: .bottom) })
    host.prewarm()
    host.show(recording, from: .dictation)
    let panel = try #require(host.visiblePanel)
    let content = try #require(panel.contentView)
    #expect(!content.needsLayout)
    #expect(!content.needsDisplay)
    let island = try #require(content.layer?.sublayers?.first).frame
    // The first frame is the appear transition's start, at `appearScale`.
    let full = IslandLayoutTests.size(of: recording)
    #expect(abs(island.width - full.width * OverlayMetrics.appearScale) < 0.5)
    #expect(abs(island.height - full.height * OverlayMetrics.appearScale) < 0.5)
    #expect(island.midX == OverlayMetrics.canvas.width / 2)
    host.show(nil, from: .dictation)
    #expect(try await Self.eventually { host.visiblePanel == nil })
  }

  @Test(.enabled { await Self.animatesOnScreen })
  func `a press during the hide keeps the panel and a plain hide hides it`() async throws {
    _ = NSApplication.shared
    let recording = try IslandLayoutTests.dictation(.recording(.pushToTalk))
    let host = OverlayHost(preference: { OverlayPreference(style: .island, edge: .bottom) })
    host.prewarm()
    host.show(recording, from: .dictation)
    host.show(nil, from: .dictation)
    host.show(recording, from: .dictation)
    // The first hide's completion has run, and found the press after it.
    #expect(try await Self.eventually { host.finishedAnimations == 3 })
    #expect(host.visiblePanel != nil)
    host.show(nil, from: .dictation)
    #expect(try await Self.eventually { host.visiblePanel == nil })
  }

  /// A panel ordered out while a full-screen Space closes loses every other full-screen Space,
  /// so hiding must keep it ordered in, through an app hide too.
  @Test(.enabled { await Self.animatesOnScreen })
  func `a hidden panel stays ordered in at alpha 0`() async throws {
    _ = NSApplication.shared
    let recording = try IslandLayoutTests.dictation(.recording(.pushToTalk))
    let host = OverlayHost(preference: { OverlayPreference(style: .island, edge: .bottom) })
    host.prewarm()
    host.show(recording, from: .dictation)
    let panel = try #require(host.visiblePanel)
    host.show(nil, from: .dictation)
    #expect(try await Self.eventually { host.visiblePanel == nil })
    #expect(panel.isVisible)
    #expect(panel.alphaValue == 0)
    #expect(!panel.canHide)
  }

  @Test(.enabled { await Self.animatesOnScreen })
  func `a preference change applies on the next appearance`() async throws {
    _ = NSApplication.shared
    let recording = try IslandLayoutTests.dictation(.recording(.pushToTalk))
    let stored = PreferenceBox(OverlayPreference(style: .island, edge: .bottom))
    let host = OverlayHost(preference: { stored.value })
    host.prewarm()
    host.show(recording, from: .dictation)
    let bottom = try #require(host.visiblePanel).frame
    host.show(nil, from: .dictation)
    #expect(try await Self.eventually { host.visiblePanel == nil })
    stored.value.edge = .top
    host.show(recording, from: .dictation)
    let top = try #require(host.visiblePanel).frame
    #expect(top.minY > bottom.minY)
    host.show(nil, from: .dictation)
    #expect(try await Self.eventually { host.visiblePanel == nil })
  }

  /// The pill is a few layers (fill, stroke, clip) that share one frame. A second pill would
  /// show up as an island-sized layer with a different frame.
  @Test(.enabled { await Self.animatesOnScreen })
  func `a press during the hide reverses the same pill instead of adding one`() async throws {
    _ = NSApplication.shared
    let recording = try IslandLayoutTests.dictation(.recording(.pushToTalk))
    let host = OverlayHost(preference: { OverlayPreference(style: .island, edge: .bottom) })
    host.prewarm()
    host.show(recording, from: .dictation)
    let content = try #require(host.visiblePanel?.contentView)
    #expect(try await Self.eventually { host.finishedAnimations == 1 })
    host.show(nil, from: .dictation)
    // Partway into the hide, as a quick second press lands.
    try await Task.sleep(for: .milliseconds(80))
    host.show(recording, from: .dictation)
    for _ in 0..<10 {
      let islands = (content.layer?.sublayers ?? []).filter { $0.frame.width > 20 }
      let widths = islands.map(\.frame.width)
      #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 2)
      #expect(Set(islands.map { Int($0.frame.midX.rounded()) }).count == 1)
      try await Task.sleep(for: .milliseconds(30))
    }
    host.show(nil, from: .dictation)
    #expect(try await Self.eventually { host.visiblePanel == nil })
  }
}

@MainActor private final class PreferenceBox {
  var value: OverlayPreference

  init(_ value: OverlayPreference) {
    self.value = value
  }
}

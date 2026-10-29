import AppKit
import DesignSystem
import DictationCore
import SwiftUI
import Testing

@testable import Overlay

@MainActor struct NotchLayoutTests {
  static let notch = NotchGeometry.simulated

  static func dictation(_ phase: DictationPhase) throws -> OverlayActivity {
    try #require(OverlayActivity(dictation: phase))
  }

  @Test func `the mic stays through dictation and is bright only while listening`() throws {
    #expect(LeadingMark(try Self.dictation(.starting(.pushToTalk))) == .mic(listening: false))
    #expect(LeadingMark(try Self.dictation(.recording(.toggle))) == .mic(listening: true))
    #expect(LeadingMark(try Self.dictation(.transcribing)) == .mic(listening: false))
    #expect(LeadingMark(try Self.dictation(.pasting)) == .mic(listening: false))
    #expect(LeadingMark(try Self.dictation(.complete)) == .glyph(.success))
    #expect(LeadingMark(try Self.dictation(.failed(.noSpeech))) == .glyph(.attention))
    #expect(LeadingMark(try Self.dictation(.failed(.manualPasteExpired))) == nil)
  }

  @Test func `a waking mic keeps the dim mic beside its words`() throws {
    let waking = try #require(OverlayActivity(dictation: .starting(.pushToTalk), wakingMicrophone: true))
    #expect(LeadingMark(waking) == .mic(listening: false))
  }

  @Test func `wings are equal and grow with the wider side`() {
    let wing = OverlayMetrics.notchWing
    #expect(NotchRowLayout.wingWidth(leading: 0, trailing: 0) == wing)
    #expect(
      NotchRowLayout.wingWidth(leading: 90, trailing: 10)
        == NotchRowLayout.wingWidth(leading: 10, trailing: 90))
    #expect(NotchRowLayout.wingWidth(leading: 90, trailing: 10) == 90 + 2 * OverlayMetrics.notchWingInset)
  }

  @Test func `the shape never draws smaller than the hidden size and stays on the top edge`() {
    let shape = NotchShape(radii: OverlayMetrics.notchCompactRadii, minimumSize: Self.notch.hiddenSize)
    let rect = CGRect(x: 100, y: 0, width: 20, height: 4)
    let drawn = shape.drawnRect(in: rect)
    #expect(drawn.size == Self.notch.hiddenSize)
    #expect(drawn.minY == rect.minY)
    #expect(drawn.midX == rect.midX)
  }

  @Test func `the hidden shape stays inside the hardware notch`() {
    let shape = NotchShape(radii: OverlayMetrics.notchHiddenRadii, minimumSize: Self.notch.hiddenSize)
    let bounds = shape.path(in: CGRect(origin: .zero, size: Self.notch.hiddenSize)).boundingRect
    #expect(bounds.width <= Self.notch.size.width)
    #expect(bounds.height <= Self.notch.size.height)
  }
}

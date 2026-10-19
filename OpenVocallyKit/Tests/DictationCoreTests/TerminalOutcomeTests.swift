import Testing

@testable import DictationCore

struct TerminalOutcomeTests {
  @Test(arguments: [
    (TerminalOutcome.complete, Duration.milliseconds(650)),
    (.failed(.aborted, hasMessage: true), .milliseconds(120)),
    (.failed(.transcriptionError, hasMessage: true), .milliseconds(2900)),
    (.failed(.captureError(.captureFailed), hasMessage: false), .milliseconds(1900)),
  ])
  func overlayStaysVisibleBeforeReturningToIdle(outcome: TerminalOutcome, expected: Duration) {
    #expect(outcome.displayDuration == expected)
  }
}

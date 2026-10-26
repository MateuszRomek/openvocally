/// One step of a provider-neutral script. Each `Wire` decides which frames say it.
package indirect enum Beat: Sendable, Hashable {
  /// Wait for the host's next user message and open a turn. Stdin EOF ends the session.
  case awaitUserTurn
  /// Open a turn with no host input.
  case selfStartTurn
  /// Stream `text` as `chunks` deltas, then the full message.
  case stream(String, chunks: Int)
  /// Stream the prefix and the host's answers joined by ", ", which proves the answer arrived.
  case echoAnswer(prefix: String)
  /// Raise a request and wait for the answer. A host interrupt ends the turn without a branch.
  case ask(Ask, approved: [Beat], declined: [Beat])
  case completeTurn
  case failTurn(TurnFailure)
  /// Write `stderr` and exit at once, with no closing frames.
  case crash(exitCode: Int32, stderr: String)
}

package enum Ask: Sendable, Hashable {
  case command(String, workingDirectory: String)
  case fileChange(path: String, oldText: String, newText: String)
  case chromeSite(domain: String, url: String)
  case computerUse(app: String)
  case question(header: String, question: String, options: [String])
  case mcpForm(server: String, message: String, fields: [FormField])
  case mcpSignIn(server: String, url: String)
  /// An elicitation in a `mode` the host does not know. Only a decline is a valid answer.
  case mcpUnknownMode(server: String, mode: String, message: String)

  package struct FormField: Sendable, Hashable {
    package let name: String
    package let title: String
    package let required: Bool

    package init(name: String, title: String, required: Bool) {
      self.name = name
      self.title = title
      self.required = required
    }
  }
}

package enum Reply: Sendable, Hashable {
  case approved
  /// A question or form answer. Counts as approved.
  case answered([String])
  case declined
  case interrupted
}

package enum TurnFailure: Sendable, Hashable {
  case notLoggedIn
}

package enum TurnEnding: Sendable, Hashable {
  case completed
  case interrupted
  case failed(TurnFailure)
}

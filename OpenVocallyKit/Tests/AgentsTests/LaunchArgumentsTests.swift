import Testing

@testable import Agents

struct LaunchArgumentsTests {
  @Test(
    arguments: [
      ("", []),
      ("  --chrome  ", ["--chrome"]),
      ("a b\tc\nd", ["a", "b", "c", "d"]),
      ("$HOME", ["$HOME"]),
      ("a;b | c", ["a;b", "|", "c"]),
      ("`whoami`", ["`whoami`"]),
      ("~/x *.txt && (y)", ["~/x", "*.txt", "&&", "(y)"]),
      ("'a b' \"c d\"", ["a b", "c d"]),
      ("'$HOME \\n'", ["$HOME \\n"]),
      ("\"say \\\"hi\\\"\"", ["say \"hi\""]),
      ("\"a\\\\b\"", ["a\\b"]),
      ("\"a\\nb\"", ["a\\nb"]),
      ("a\\ b", ["a b"]),
      ("''", [""]),
      ("x'y'\"z\"", ["xyz"]),
    ] as [(String, [String])])
  func splits(_ text: String, _ expected: [String]) throws {
    #expect(try LaunchArguments(text).split() == expected)
    #expect(LaunchArguments(text).problem == nil)
  }

  @Test(arguments: [
    ("'abc", LaunchArgumentError.unterminatedQuote(offset: 0)),
    ("x \"abc", .unterminatedQuote(offset: 2)),
    ("\"abc\\", .unterminatedQuote(offset: 0)),
    ("abc\\", .trailingBackslash),
    ("a\0b", .containsNul),
  ])
  func rejects(_ text: String, _ error: LaunchArgumentError) {
    #expect(throws: error) { try LaunchArguments(text).split() }
    #expect(LaunchArguments(text).problem == error)
  }
}

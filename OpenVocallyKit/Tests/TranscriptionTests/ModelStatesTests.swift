import Foundation
import ModelsTestSupport
import Testing

@testable import Models
@testable import Transcription

struct ModelStatesTests {
  let german = Locale(identifier: "de_DE")
  let polish = Locale(identifier: "pl_PL")

  @Test func `an entry has one work slot and only its holder can finish it`() throws {
    var states = ModelStates([
      .parakeetV3: .init(resolved: .hosted(.parakeetV3), presence: .present),
      .whisperTurbo: .init(resolved: .hosted(.whisperTurbo), presence: .absent),
    ])
    let replaceToken = states.begin(.install(replacing: true, from: .verifying), on: .parakeetV3)
    let replace = try #require(replaceToken)
    let removing = states.begin(.remove, on: .parakeetV3)
    let checking = states.begin(.check, on: .parakeetV3)
    let second = states.begin(.install(replacing: false, from: .indeterminate), on: .whisperTurbo)
    #expect(removing == nil)
    #expect(checking == nil)
    #expect(second == nil, "one install at a time")

    let failed = states.finishInstall(replace, .failure(.download(.corrupted)), present: true)
    #expect(failed)
    #expect(states[.parakeetV3].presence == .present, "a failed replace keeps the old files")
    let replayed = states.finishInstall(replace, .success(()), present: true)
    #expect(!replayed, "a spent token is ignored")
    #expect(states[.parakeetV3].failure == .download(.corrupted))
    #expect(states[.parakeetV3].isReady)
  }

  @Test func `an install before the first check ends on what is on disk`() throws {
    var states = ModelStates([
      .whisperTurbo: .init(resolved: .hosted(.whisperTurbo)),
      .appleSpeech: .init(resolved: .system(.speech, german)),
    ])
    let hostedToken = states.begin(.install(replacing: false, from: .indeterminate), on: .whisperTurbo)
    states.finishInstall(try #require(hostedToken), .failure(.download(.offline)), present: false)
    #expect(states[.whisperTurbo].presence == .absent, "a failed install leaves no row stuck checking")
    #expect(states[.whisperTurbo].failure == .download(.offline))

    let systemToken = states.begin(.install(replacing: false, from: .indeterminate), on: .appleSpeech)
    states.finishInstall(try #require(systemToken), .success(()), present: false)
    #expect(states[.appleSpeech].presence == .absent, "an install that left nothing on disk is not installed")
  }

  @Test func `a language change drops the check it replaces`() throws {
    var states = ModelStates([.appleDictation: .init(resolved: .system(.dictation, german))])
    let launchToken = states.begin(.check, on: .appleDictation)
    let launch = try #require(launchToken)
    let changedToken = states.relocate(.appleDictation, to: .system(.dictation, polish))
    let changed = try #require(changedToken)

    let stale = states.finishCheck(launch, present: true)
    #expect(!stale, "the replaced check's token is ignored")
    #expect(states[.appleDictation].presence == .unknown)
    let current = states.finishCheck(changed, present: false)
    #expect(current)
    #expect(states[.appleDictation].presence == .absent)
  }

  @Test func `a language can't change while that model installs`() throws {
    var states = ModelStates([
      .appleDictation: .init(resolved: .system(.dictation, german), presence: .absent)
    ])
    let installToken = states.begin(.install(replacing: false, from: .indeterminate), on: .appleDictation)
    let install = try #require(installToken)
    let relocated = states.relocate(.appleDictation, to: .system(.dictation, polish))
    #expect(relocated == nil)
    #expect(states[.appleDictation].resolved == .system(.dictation, german))
    states.finishInstall(install, .failure(.system(.cancelled)), present: false)
    #expect(states[.appleDictation].failure == nil, "a cancel is not a failure")
  }

  @Test func `progress counts only a new whole percent or a new phase`() throws {
    var states = ModelStates([.whisperTurbo: .init(resolved: .hosted(.whisperTurbo), presence: .absent)])
    let begun = states.begin(
      .install(replacing: false, from: .downloading(received: 0, total: 1000)), on: .whisperTurbo)
    let token = try #require(begun)
    let reports: [DownloadProgress] = [
      .downloading(received: 9, total: 1000), .downloading(received: 10, total: 1000),
      .downloading(received: 19, total: 1000), .verifying, .verifying,
    ]
    let redraws = reports.map { states.progress($0, token) }
    #expect(redraws == [false, true, false, true, false])
  }

  enum Operation: CaseIterable, Sendable {
    case install, remove, changeLanguage
  }

  func start() -> ModelStates {
    ModelStates([
      .whisperTurbo: .init(resolved: .hosted(.whisperTurbo), presence: .present),
      .appleSpeech: .init(resolved: .system(.speech, german), presence: .absent),
      .appleDictation: .init(resolved: .system(.dictation, german), presence: .present),
    ])
  }

  func begin(_ operation: Operation, in states: inout ModelStates) throws -> ModelStates.Token {
    let token =
      switch operation {
      case .install: states.begin(.install(replacing: false, from: .indeterminate), on: .appleSpeech)
      case .remove: states.begin(.remove, on: .whisperTurbo)
      case .changeLanguage: states.relocate(.appleDictation, to: .system(.dictation, polish))
      }
    return try #require(token)
  }

  func finish(_ operation: Operation, _ token: ModelStates.Token, in states: inout ModelStates) {
    switch operation {
    case .install: states.finishInstall(token, .success(()), present: true)
    case .remove: states.finishRemove(token, present: false)
    case .changeLanguage: states.finishCheck(token, present: true)
    }
  }

  @Test(arguments: [
    [Operation.install, .remove, .changeLanguage], [.install, .changeLanguage, .remove],
    [.remove, .install, .changeLanguage], [.remove, .changeLanguage, .install],
    [.changeLanguage, .install, .remove], [.changeLanguage, .remove, .install],
  ])
  func `overlapping operations finishing in any order end as if run one after another`(order: [Operation])
    throws
  {
    var sequential = start()
    for operation in Operation.allCases {
      let token = try begin(operation, in: &sequential)
      finish(operation, token, in: &sequential)
    }

    var overlapping = start()
    var tokens: [Operation: ModelStates.Token] = [:]
    for operation in Operation.allCases { tokens[operation] = try begin(operation, in: &overlapping) }
    for operation in order { finish(operation, try #require(tokens[operation]), in: &overlapping) }

    #expect(overlapping.entries == sequential.entries)
    #expect(overlapping[.appleSpeech].presence == .present)
    #expect(overlapping[.whisperTurbo].presence == .absent)
    #expect(overlapping[.appleDictation].resolved == .system(.dictation, polish))
  }

  @Test func `the runtime keeps its model while the answer is unknown or a replace downloads`() {
    let model = ResolvedModel.hosted(.parakeetV3)
    var entry = ModelStates.Entry(resolved: model)
    #expect(RuntimeIntent.of(entry, phase: .running) == .keep)
    entry.presence = .absent
    #expect(RuntimeIntent.of(entry, phase: .launching) == .keep)
    #expect(RuntimeIntent.of(entry, phase: .running) == .unload)
    entry.presence = .present
    #expect(RuntimeIntent.of(entry, phase: .launching) == .load(model))
    entry.slot = .init(work: .installing(.verifying, replacing: true), serial: 1)
    #expect(RuntimeIntent.of(entry, phase: .running) == .keep)
  }
}

struct SpeechAssetErrorTests {
  @available(macOS 26, *)
  @Test(arguments: [
    (CancellationError() as any Error, SystemInstallError.cancelled),
    (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .offline),
    (CocoaError(.fileWriteOutOfSpace), .diskFull),
    (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .diskFull),
    (NSError(domain: "com.apple.SpeechAssets", code: 7), .failed(domain: "com.apple.SpeechAssets", code: 7)),
  ])
  func `an AssetInventory error maps to what the user can do about it`(
    error: any Error, expected: SystemInstallError
  ) {
    #expect(AppleSpeechAssets.installError(error) == expected)
  }

  @available(macOS 26, *)
  @Test func `any error in a cancelled task is a cancel, not a failure`() async {
    let mapped = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return AppleSpeechAssets.installError(NSError(domain: "com.apple.SpeechAssets", code: 7))
    }
    #expect(await mapped.value == .cancelled)
  }
}

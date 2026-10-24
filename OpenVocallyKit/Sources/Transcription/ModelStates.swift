import Foundation
import Models

struct ModelStates: Equatable {
  enum Presence: Equatable { case unknown, absent, present }

  enum Work: Equatable {
    case checking
    case installing(DownloadProgress, replacing: Bool)
    case removing
  }

  enum Request {
    case check
    case install(replacing: Bool, from: DownloadProgress)
    case remove
  }

  struct Token: Equatable {
    fileprivate let id: ModelID
    fileprivate let serial: Int
  }

  struct Slot: Equatable {
    var work: Work
    let serial: Int
  }

  struct Entry: Equatable {
    var resolved: ResolvedModel?
    var languages: [Locale] = []
    var presence = Presence.unknown
    var slot: Slot?
    var failure: InstallError?

    var isIdle: Bool { slot == nil }
    var isReady: Bool { slot == nil && presence == .present }
  }

  private(set) var entries: [ModelID: Entry]
  private var serial = 0

  init(_ entries: [ModelID: Entry]) {
    self.entries = entries
  }

  subscript(id: ModelID) -> Entry {
    entries[id] ?? Entry(resolved: nil, presence: .absent)
  }

  var installing: ModelID? {
    entries.first { _, entry in
      guard case .installing? = entry.slot?.work else { return false }
      return true
    }?.key
  }

  mutating func begin(_ request: Request, on id: ModelID) -> Token? {
    guard var entry = entries[id], entry.isIdle, let resolved = entry.resolved else { return nil }
    let work: Work
    switch request {
    case .check:
      work = .checking
    case .install(let replacing, let start):
      guard installing == nil, Self.fits(replacing: replacing, resolved, entry.presence) else { return nil }
      entry.failure = nil
      work = .installing(start, replacing: replacing)
    case .remove:
      guard case .hosted = resolved, entry.presence == .present else { return nil }
      work = .removing
    }
    serial += 1
    entry.slot = Slot(work: work, serial: serial)
    entries[id] = entry
    return Token(id: id, serial: serial)
  }

  private static func fits(replacing: Bool, _ resolved: ResolvedModel, _ presence: Presence) -> Bool {
    switch resolved {
    case .hosted: replacing == (presence == .present)
    case .system: !replacing && presence != .present
    }
  }

  mutating func list(_ languages: [Locale], for id: ModelID) {
    entries[id]?.languages = languages
  }

  mutating func relocate(_ id: ModelID, to resolved: ResolvedModel?) -> Token? {
    guard var entry = entries[id] else { return nil }
    switch entry.slot?.work {
    case .installing?, .removing?: return nil
    case .checking?, nil: break
    }
    entry.resolved = resolved
    guard resolved != nil else {
      entry.presence = .absent
      entry.slot = nil
      entries[id] = entry
      return nil
    }
    serial += 1
    entry.presence = .unknown
    entry.slot = Slot(work: .checking, serial: serial)
    entries[id] = entry
    return Token(id: id, serial: serial)
  }

  mutating func progress(_ progress: DownloadProgress, _ token: Token) -> Bool {
    guard holds(token), case .installing(let before, let replacing)? = entries[token.id]?.slot?.work else {
      return false
    }
    let percent = { (progress: DownloadProgress) in progress.fraction.map { Int($0 * 100) } }
    let phaseChanged = progress.fraction == nil && progress != before
    guard percent(progress) != percent(before) || phaseChanged else { return false }
    entries[token.id]?.slot?.work = .installing(progress, replacing: replacing)
    return true
  }

  @discardableResult
  mutating func finishCheck(_ token: Token, present: Bool) -> Bool {
    guard holds(token) else { return false }
    entries[token.id]?.presence = present ? .present : .absent
    entries[token.id]?.slot = nil
    return true
  }

  /// `present` is a check made after the install, so the entry ends on what is on disk whether
  /// the install worked, failed, or found nothing to do.
  @discardableResult
  mutating func finishInstall(_ token: Token, _ result: Result<Void, InstallError>, present: Bool) -> Bool {
    guard holds(token) else { return false }
    entries[token.id]?.presence = present ? .present : .absent
    switch result {
    case .success:
      entries[token.id]?.failure = nil
    case .failure(let error) where error.isCancelled:
      entries[token.id]?.failure = nil
    case .failure(let error):
      entries[token.id]?.failure = error
    }
    entries[token.id]?.slot = nil
    return true
  }

  @discardableResult
  mutating func finishRemove(_ token: Token, present: Bool) -> Bool {
    guard holds(token) else { return false }
    entries[token.id]?.presence = present ? .present : .absent
    entries[token.id]?.slot = nil
    return true
  }

  private func holds(_ token: Token) -> Bool {
    entries[token.id]?.slot?.serial == token.serial
  }
}

enum RuntimeIntent: Equatable {
  case keep
  case load(ResolvedModel)
  case unload

  static func of(_ entry: ModelStates.Entry, phase: LibraryPhase) -> RuntimeIntent {
    switch entry.slot?.work {
    case .checking?, .removing?, .installing(_, replacing: true)?: return .keep
    case .installing(_, replacing: false)?, nil: break
    }
    switch entry.presence {
    case .unknown: return .keep
    case .present: return entry.resolved.map(RuntimeIntent.load) ?? .unload
    case .absent:
      switch phase {
      case .launching: return .keep
      case .running: return .unload
      }
    }
  }
}

/// While launching, a missing active model keeps the runtime untouched until launch decides
/// whether another model takes over.
enum LibraryPhase {
  case launching
  case running
}

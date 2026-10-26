#if FEATURE_AGENTS
  import Foundation

  /// Separate from health: it arrives later, on its own cadence, and an unsupported version can have one.
  public enum UpdateAdvisory: Sendable, Equatable {
    /// Not checked, offline, or nothing to check for this install. Shows nothing.
    case unknown
    case current
    case available(latest: CLIVersion)
  }

  enum UpdateCheck {
    static func advisory(installed: CLIVersion, latest: CLIVersion?) -> UpdateAdvisory {
      guard let latest else { return .unknown }
      return latest > installed ? .available(latest: latest) : .current
    }

    static let bodyCap = 256 * 1024

    /// https only, an ephemeral session with no cookies or cache, 10 s, and a capped body. Wire JSON
    /// stays here; callers get a parsed version or a throw that means "could not find out".
    @concurrent
    static func fetchLatest(_ source: LatestVersionSource) async throws -> CLIVersion {
      guard let url = source.url, url.scheme == "https" else { throw UpdateCheckError.badSource }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 10
      configuration.timeoutIntervalForResource = 10
      configuration.httpShouldSetCookies = false
      configuration.urlCache = nil
      let session = URLSession(configuration: configuration)
      defer { session.finishTasksAndInvalidate() }
      let (bytes, response) = try await session.bytes(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateCheckError.badResponse }
      var body = Data()
      for try await byte in bytes {
        body.append(byte)
        if body.count > bodyCap { throw UpdateCheckError.tooLarge }
      }
      let text: String? =
        switch source {
        case .npm, .homebrewCask: try JSONDecoder().decode(VersionField.self, from: body).version
        case .homebrewFormula: try JSONDecoder().decode(FormulaVersions.self, from: body).versions.stable
        }
      guard let text, let version = CLIVersion(text) ?? CLIVersion.firstToken(in: text) else {
        throw UpdateCheckError.badResponse
      }
      return version
    }

    private struct VersionField: Decodable { let version: String? }
    private struct FormulaVersions: Decodable {
      struct Versions: Decodable { let stable: String? }
      let versions: Versions
    }
  }

  enum UpdateCheckError: Error {
    case badSource
    case badResponse
    case tooLarge
  }
#endif

#if DEBUG
  import Foundation
  import Models

  /// The runs a dictation harness plays, read from the JSON file `-dictationHarness` names:
  /// `{"maxWordErrorRate": 0.1, "model": "large-v3-turbo", "runs": [{"fixture": "/abs/en-short.wav",
  /// "mode": "pushToTalk", "expected": "Please move…"}]}`. Without `model` the runs use the active
  /// model.
  struct DictationScenario: Decodable, Equatable {
    enum Mode: String, Decodable {
      case pushToTalk
      case toggle
    }

    struct Run: Decodable, Equatable {
      let fixture: String
      let mode: Mode
      let expected: String?
    }

    let runs: [Run]
    let maxWordErrorRate: Double
    let model: ModelID?

    private enum CodingKeys: String, CodingKey {
      case runs, maxWordErrorRate, model
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      runs = try container.decode([Run].self, forKey: .runs)
      maxWordErrorRate = try container.decodeIfPresent(Double.self, forKey: .maxWordErrorRate) ?? 0.1
      model = try container.decodeIfPresent(String.self, forKey: .model).map { id in
        guard let model = ModelID(rawValue: id) else {
          throw DecodingError.dataCorruptedError(
            forKey: .model, in: container, debugDescription: "Unknown model \(id)")
        }
        return model
      }
    }

    static func load(_ url: URL) throws -> DictationScenario {
      try JSONDecoder().decode(DictationScenario.self, from: Data(contentsOf: url))
    }
  }
#endif

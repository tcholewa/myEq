import CDSP
import CTransport
import Foundation

public enum FilterType: Int32, Codable, CaseIterable, Identifiable, Sendable {
  case bell, lowShelf, highShelf, lowCut, highCut
  public var id: Int32 { rawValue }
  public var name: String {
    ["Bell", "Low shelf", "High shelf", "Low cut", "High cut"][Int(rawValue)]
  }
  public var hasGain: Bool { rawValue < 3 }
  public var widthLabel: String { self == .bell ? "Width · oct" : (hasGain ? "Slope" : "Q") }
  public var widthRange: ClosedRange<Double> {
    self == .bell ? 0.05...5 : (hasGain ? 0.1...1 : 0.1...10)
  }
  public var defaultWidth: Double { self == .bell ? 1 : (hasGain ? 1 : 1 / sqrt(2)) }
}

public struct EQBand: Codable, Equatable, Identifiable {
  public var id: Int
  public var enabled: Bool
  public var type: FilterType
  public var frequency: Double
  public var gain: Double
  public var width: Double
  public init(
    id: Int, enabled: Bool = true, type: FilterType = .bell, frequency: Double, gain: Double = 0,
    width: Double = 1
  ) {
    self.id = id
    self.enabled = enabled
    self.type = type
    self.frequency = frequency
    self.gain = gain
    self.width = width
  }
  public var native: MEQBand {
    MEQBand(type: type.rawValue, enabled: enabled, frequency: frequency, gain: gain, width: width)
  }
  public var isValid: Bool {
    (0..<8).contains(id) && frequency.isFinite && (20...20000).contains(frequency) && gain.isFinite
      && (-24...24).contains(gain) && width.isFinite && type.widthRange.contains(width)
  }
}

public struct EQPreset: Codable, Equatable, Identifiable {
  public var id: UUID
  public var name: String
  public var bands: [EQBand]
  public var autoPreamp: Bool
  public var manualPreamp: Double
  public init(
    id: UUID = UUID(), name: String, bands: [EQBand], autoPreamp: Bool = true,
    manualPreamp: Double = 0
  ) {
    self.id = id
    self.name = name
    self.bands = bands
    self.autoPreamp = autoPreamp
    self.manualPreamp = manualPreamp
  }
  public var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
      && bands.count == 8 && Set(bands.map(\.id)) == Set(0..<8)
      && bands.enumerated().allSatisfy { $0.offset == $0.element.id && $0.element.isValid }
      && manualPreamp.isFinite && (-60...12).contains(manualPreamp)
  }
  public static let flat = EQPreset(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Flat",
    bands: [60, 150, 350, 690, 2000, 4000, 11200, 16000].enumerated().map {
      EQBand(id: $0.offset, enabled: $0.offset < 7, frequency: Double($0.element))
    })
  public static let botaniq = EQPreset(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Botaniq1",
    bands: zip(
      zip([74.0, 150, 350, 690, 2000, 4000, 11200], [4.8, -4.6, 3.7, -5, 2, 2.5, 2]),
      [0.8, 0.1, 0.3, 0.15, 0.45, 1, 1]
    ).enumerated().map {
      EQBand(id: $0.offset, frequency: $0.element.0.0, gain: $0.element.0.1, width: $0.element.1)
    } + [EQBand(id: 7, enabled: false, frequency: 16000)], manualPreamp: -4.8)
  public static let factory: [EQPreset] = [.flat, .botaniq]
  public var isFactory: Bool { Self.factory.contains { $0.id == id } }
}

public enum EQResponse {
  public static func gain(_ bands: [EQBand], at frequency: Double, sampleRate: Double = 48000)
    -> Double
  {
    let native = bands.map(\.native)
    return native.withUnsafeBufferPointer {
      meq_response($0.baseAddress, Int32($0.count), frequency, sampleRate)
    }
  }
  public static func autoPreamp(_ bands: [EQBand], sampleRate: Double = 48000) -> Double {
    let native = bands.map(\.native)
    return native.withUnsafeBufferPointer { p in
      var peak = 0.0
      let maxFrequency = sampleRate / 2
      for i in 0...4096 {
        let f = i == 0 ? 0 : 10 * pow(maxFrequency / 10, Double(i) / 4096)
        peak = max(peak, meq_response(p.baseAddress, Int32(p.count), f, sampleRate))
      }
      for b in bands where b.enabled {
        peak = max(
          peak,
          meq_response(
            p.baseAddress, Int32(p.count), min(b.frequency, sampleRate * 0.45), sampleRate))
      }
      // Round attenuation upward so the displayed value never overstates headroom.
      return -ceil(peak * 10) / 10
    }
  }
  public static func curve(_ bands: [EQBand], sampleRate: Double, count: Int = 512) -> [Double] {
    let native = bands.map(\.native)
    let ceiling = min(20000, sampleRate * 0.45)
    return native.withUnsafeBufferPointer { p in
      (0..<count).map {
        meq_response(
          p.baseAddress, Int32(p.count), 20 * pow(ceiling / 20, Double($0) / Double(count - 1)),
          sampleRate)
      }
    }
  }
}

public enum AudioEngineState: Equatable {
  case bypassed, starting, reconnecting, running
  case suspended(String)
  case error(String)
  public var title: String {
    switch self {
    case .bypassed: return "Bypassed"
    case .starting: return "Starting…"
    case .reconnecting: return "Reconnecting…"
    case .running: return "Equalizing"
    case .suspended: return "Paused"
    case .error: return "Needs attention"
    }
  }
  public var detail: String? {
    switch self {
    case .suspended(let s), .error(let s): return s
    default: return nil
    }
  }
}

public struct SavedState: Codable, Equatable {
  public var schemaVersion = 2
  public var current = EQPreset.flat
  public var presets: [EQPreset] = []
  public var enabled = false
  public var preferredOutputUID: String?
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, current, presets, enabled, preferredOutputUID
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let version = try c.decode(Int.self, forKey: .schemaVersion)
    guard version == 1 || version == 2 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c, debugDescription: "Unsupported settings version.")
    }
    schemaVersion = 2
    current = try c.decode(EQPreset.self, forKey: .current)
    presets = try c.decode([EQPreset].self, forKey: .presets)
    enabled = try c.decode(Bool.self, forKey: .enabled)
    preferredOutputUID = try c.decodeIfPresent(String.self, forKey: .preferredOutputUID)
  }
  public var isValid: Bool {
    schemaVersion == 2 && (preferredOutputUID.map { !$0.isEmpty && $0.utf8.count <= 1024 } ?? true)
      && current.isValid && presets.allSatisfy { $0.isValid && !$0.isFactory }
      && Set(presets.map(\.id)).count == presets.count
  }
}

public final class PresetStore {
  public let url: URL
  public init(url: URL? = nil) {
    self.url =
      url
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("myEq/settings.json")
  }
  public func load() throws -> SavedState {
    var bytes: UnsafeMutablePointer<UInt8>?
    var length = 0
    let result = url.path.withCString { meq_read_settings($0, &bytes, &length) }
    if result == 1 { return SavedState() }
    guard result == 0, let bytes else { throw StoreError.invalid }
    defer { free(bytes) }
    let value = try JSONDecoder().decode(SavedState.self, from: Data(bytes: bytes, count: length))
    guard value.isValid else { throw StoreError.invalid }
    return value
  }
  public func save(_ state: SavedState) throws {
    guard state.isValid else { throw StoreError.invalid }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 4 * 1024 * 1024 else { throw StoreError.invalid }
    let written = data.withUnsafeBytes { buffer in
      url.path.withCString {
        meq_write_settings($0, buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count)
      }
    }
    guard written else { throw StoreError.invalid }
  }
  public func preserveInvalidFile() throws -> URL? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let backup = url.deletingPathExtension().appendingPathExtension(
      "invalid-\(UUID().uuidString).json")
    try FileManager.default.moveItem(at: url, to: backup)
    return backup
  }
  public enum StoreError: LocalizedError {
    case invalid
    public var errorDescription: String? {
      "Saved settings are invalid or from an unsupported version."
    }
  }
}

public enum InstallationMetadata {
  public static func identifier() throws -> String {
    var value = [CChar](repeating: 0, count: 64)
    guard meq_installation_id(&value, value.count) else { throw PresetStore.StoreError.invalid }
    return String(cString: value)
  }
}

import Foundation

public struct OutputLevels {
  public var left: Float
  public var right: Float
  public var reduction: Float
  public var active: Bool

  public init(left: Float = 0, right: Float = 0, reduction: Float = 0, active: Bool = false) {
    self.left = left
    self.right = right
    self.reduction = reduction
    self.active = active
  }
}

/// Display ballistics only; this never changes audio or the limiter envelope.
public struct OutputMeterEnvelope: Equatable {
  public static let floorDB = -60.0
  public private(set) var leftDB = floorDB
  public private(set) var rightDB = floorDB
  public private(set) var reductionDB = 0.0
  public init() {}

  public mutating func update(_ levels: OutputLevels, elapsed: Double) {
    guard levels.active else {
      self = Self()
      return
    }
    let decay = 24 * (elapsed.isFinite ? max(0, elapsed) : 0)
    leftDB = max(Self.decibels(levels.left), leftDB - decay)
    rightDB = max(Self.decibels(levels.right), rightDB - decay)
    let reduction = levels.reduction.isFinite ? max(0, Double(levels.reduction)) : 0
    reductionDB = max(reduction, reductionDB - decay)
  }

  private static func decibels(_ amplitude: Float) -> Double {
    guard amplitude.isFinite, amplitude > 0 else { return floorDB }
    return min(0, max(floorDB, 20 * log10(Double(amplitude))))
  }
}

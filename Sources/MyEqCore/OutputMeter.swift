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
  public var leftPeakDB: Double { leftPeak.decibels }
  public var rightPeakDB: Double { rightPeak.decibels }
  private var leftPeak = PeakHold()
  private var rightPeak = PeakHold()
  public init() {}

  public mutating func update(_ levels: OutputLevels, elapsed: Double) {
    guard levels.active else {
      self = Self()
      return
    }
    let interval = elapsed.isFinite ? max(0, elapsed) : 0
    let decay = 24 * interval
    let left = Self.decibels(levels.left)
    let right = Self.decibels(levels.right)
    leftDB = max(left, leftDB - decay)
    rightDB = max(right, rightDB - decay)
    leftPeak.update(left, elapsed: interval)
    rightPeak.update(right, elapsed: interval)
    let reduction = levels.reduction.isFinite ? max(0, Double(levels.reduction)) : 0
    reductionDB = max(reduction, reductionDB - decay)
  }

  private static func decibels(_ amplitude: Float) -> Double {
    guard amplitude.isFinite, amplitude > 0 else { return floorDB }
    return min(0, max(floorDB, 20 * log10(Double(amplitude))))
  }

  /// Holds each new peak for one second, then falls at 6 dB/second.
  private struct PeakHold: Equatable {
    var decibels = OutputMeterEnvelope.floorDB
    private var remainingHold = 0.0

    mutating func update(_ inputDB: Double, elapsed: Double) {
      let fallingTime = max(0, elapsed - remainingHold)
      remainingHold = max(0, remainingHold - elapsed)
      decibels = max(OutputMeterEnvelope.floorDB, decibels - 6 * fallingTime)
      if inputDB > OutputMeterEnvelope.floorDB, inputDB >= decibels {
        decibels = inputDB
        remainingHold = 1
      }
    }
  }
}

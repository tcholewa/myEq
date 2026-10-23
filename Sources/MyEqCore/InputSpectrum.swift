import Accelerate
import Foundation

public struct SpectrumFrame: Equatable {
  public static let pointCount = 64
  public static let floorDB: Float = -90
  public let levels: [Float]
  public let peaks: [Float]
  public let sampleRate: Double
  public let timestamp: TimeInterval
  public let sequence: UInt64
  public var frequencyLimit: Double { min(20000, sampleRate * 0.45) }

  public init(
    levels: [Float], sampleRate: Double, timestamp: TimeInterval, sequence: UInt64 = 0,
    peaks: [Float] = []
  ) {
    self.peaks = peaks.isEmpty ? levels : peaks
    self.levels = levels
    self.sampleRate = sampleRate
    self.timestamp = timestamp
    self.sequence = sequence
  }
}

public struct SpectrumEnvelope {
  public private(set) var levels = [Float](
    repeating: SpectrumFrame.floorDB, count: SpectrumFrame.pointCount)
  public private(set) var peaks = [Float](
    repeating: SpectrumFrame.floorDB, count: SpectrumFrame.pointCount)
  private var holds = [TimeInterval](repeating: 0, count: SpectrumFrame.pointCount)
  public init() {}
  public mutating func update(_ input: [Float], elapsed: TimeInterval) {
    guard input.count == levels.count else { return }
    let dt = elapsed.isFinite ? max(0, elapsed) : 0
    for i in levels.indices {
      let target =
        input[i].isFinite ? min(0, max(SpectrumFrame.floorDB, input[i])) : SpectrumFrame.floorDB
      levels[i] = max(target, levels[i] - Float(24 * dt))
      let falling = max(0, dt - holds[i])
      holds[i] = max(0, holds[i] - dt)
      peaks[i] = max(SpectrumFrame.floorDB, peaks[i] - Float(6 * falling))
      if target > SpectrumFrame.floorDB, target >= peaks[i] {
        peaks[i] = target
        holds[i] = 1
      }
    }
  }
}

/// Utility-worker only. All FFT/window workspaces are allocated once per audio format.
final class SpectrumAnalyzer {
  let frames: Int
  let sampleRate: Double
  let samples: UnsafeMutablePointer<Float>
  private let window: UnsafeMutablePointer<Float>
  private let real: UnsafeMutablePointer<Float>
  private let imaginary: UnsafeMutablePointer<Float>
  private let power: UnsafeMutablePointer<Float>
  private let other: UnsafeMutablePointer<Float>
  private let setup: FFTSetup
  private let log2Frames: vDSP_Length
  private let normalization: Float
  private let ranges: [(Int, Int, Float)]

  init?(sampleRate: Double, frames: Int) {
    guard sampleRate.isFinite, (32000...192000).contains(sampleRate),
      (4096...32768).contains(frames), frames.nonzeroBitCount == 1,
      let setup = vDSP_create_fftsetup(
        vDSP_Length(frames.trailingZeroBitCount), FFTRadix(kFFTRadix2))
    else { return nil }
    self.setup = setup
    self.frames = frames
    self.sampleRate = sampleRate
    log2Frames = vDSP_Length(frames.trailingZeroBitCount)
    samples = .allocate(capacity: frames * 2)
    window = .allocate(capacity: frames)
    real = .allocate(capacity: frames / 2)
    imaginary = .allocate(capacity: frames / 2)
    power = .allocate(capacity: frames / 2)
    other = .allocate(capacity: frames / 2)
    samples.initialize(repeating: 0, count: frames * 2)
    var sum: Double = 0
    for i in 0..<frames {
      let value = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frames))
      window[i] = Float(value)
      sum += value
    }
    // vDSP's real FFT is twice the ordinary DFT; this yields a bin-centered sine's amplitude².
    normalization = Float(0.5 / (sum * sum))
    let limit = min(20000, sampleRate * 0.45)
    let ratio = log(limit / 20) / Double(SpectrumFrame.pointCount - 1)
    let binHz = sampleRate / Double(frames)
    ranges = (0..<SpectrumFrame.pointCount).map { index in
      let center = 20 * exp(Double(index) * ratio) / binHz
      let lower = max(1, Int(ceil(20 * exp((Double(index) - 0.5) * ratio) / binHz)))
      let upper = min(frames / 2 - 1, Int(floor(20 * exp((Double(index) + 0.5) * ratio) / binHz)))
      if lower <= upper { return (lower, upper, -1) }
      let base = min(frames / 2 - 2, max(1, Int(floor(center))))
      return (base, base + 1, Float(max(0, min(1, center - Double(base)))))
    }
  }

  deinit {
    vDSP_destroy_fftsetup(setup)
    samples.deallocate()
    window.deallocate()
    real.deallocate()
    imaginary.deallocate()
    power.deallocate()
    other.deallocate()
  }

  func analyze() -> [Float] {
    var nonzero = false
    for i in 0..<(frames * 2) {
      let value = samples[i].isFinite ? max(-16, min(16, samples[i])) : 0
      samples[i] = value
      nonzero = nonzero || value != 0
    }
    guard nonzero else {
      return .init(repeating: SpectrumFrame.floorDB, count: SpectrumFrame.pointCount)
    }
    var split = DSPSplitComplex(realp: real, imagp: imaginary)
    for channel in 0..<2 {
      vDSP_vmul(samples + channel, 4, window, 2, real, 1, vDSP_Length(frames / 2))
      vDSP_vmul(samples + channel + 2, 4, window + 1, 2, imaginary, 1, vDSP_Length(frames / 2))
      vDSP_fft_zrip(setup, &split, 1, log2Frames, FFTDirection(FFT_FORWARD))
      vDSP_zvmags(&split, 1, channel == 0 ? power : other, 1, vDSP_Length(frames / 2))
    }
    vDSP_vadd(power, 1, other, 1, power, 1, vDSP_Length(frames / 2))
    return ranges.map { lower, upper, fraction in
      var value: Float = 0
      if fraction >= 0 {
        value = power[lower] + fraction * (power[upper] - power[lower])
      } else {
        for bin in lower...upper { value = max(value, power[bin]) }
      }
      let db = 10 * log10(max(1e-9, Double(value * normalization)))
      return db.isFinite ? Float(min(0, max(-90, db))) : SpectrumFrame.floorDB
    }
  }
}

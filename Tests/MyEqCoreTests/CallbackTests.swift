import AudioToolbox
import CDSP
import XCTest

@testable import MyEqCore

private final class Buffers {
  let raw: UnsafeMutableRawPointer
  let pointer: UnsafeMutablePointer<AudioBufferList>
  let samples: [UnsafeMutablePointer<Float>]
  init(channels: [Int], frames: Int = 128) {
    let size =
      MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)! + channels.count
      * MemoryLayout<AudioBuffer>.stride
    raw = .allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    pointer = raw.assumingMemoryBound(to: AudioBufferList.self)
    pointer.pointee.mNumberBuffers = UInt32(channels.count)
    samples = channels.map { count in
      let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * count)
      p.initialize(repeating: 0, count: frames * count)
      return p
    }
    let list = UnsafeMutableAudioBufferListPointer(pointer)
    for (i, count) in channels.enumerated() {
      list[i] = AudioBuffer(
        mNumberChannels: UInt32(count), mDataByteSize: UInt32(frames * count * 4), mData: samples[i]
      )
    }
  }
  deinit {
    for p in samples { p.deallocate() }
    raw.deallocate()
  }
}

final class CallbackTests: XCTestCase {
  private func invoke(_ dsp: OpaquePointer, _ input: Buffers, _ output: Buffers) {
    var stamp = AudioTimeStamp()
    withUnsafePointer(to: &stamp) { p in
      XCTAssertEqual(
        meq_audio_callback(0, p, input.pointer, p, output.pointer, p, UnsafeMutableRawPointer(dsp)),
        noErr)
    }
  }
  func testDuplexDeviceNeverReadsMicrophone() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    // First buffer is a microphone. Only the trailing stereo tap is audible.
    let input = Buffers(channels: [1, 2])
    let output = Buffers(channels: [2])
    input.samples[0].update(repeating: 0.9, count: 128)
    input.samples[1][0] = 0.1
    input.samples[1][1] = 0.2
    meq_layout(
      dsp, MEQChannel(buffer: 1, channel: 0, stride: 2),
      MEQChannel(buffer: 1, channel: 1, stride: 2), MEQChannel(buffer: 0, channel: 0, stride: 2),
      MEQChannel(buffer: 0, channel: 1, stride: 2))
    invoke(dsp, input, output)
    XCTAssertEqual(output.samples[0][96], 0.1, accuracy: 1e-6)
    XCTAssertEqual(output.samples[0][97], 0.2, accuracy: 1e-6)
    XCTAssertEqual(
      (0..<256).reduce(Float(0)) { $0 + abs(output.samples[0][$1]) }, 0.3, accuracy: 1e-6)
    XCTAssertEqual(meq_meter(dsp).faults, 0)
  }
  func testPlanarBuffersAndSwappedOutputChannels() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    let input = Buffers(channels: [1, 1])
    let output = Buffers(channels: [1, 1])
    input.samples[0][0] = 0.1
    input.samples[1][0] = 0.2
    meq_layout(
      dsp, MEQChannel(buffer: 0, channel: 0, stride: 1),
      MEQChannel(buffer: 1, channel: 0, stride: 1), MEQChannel(buffer: 1, channel: 0, stride: 1),
      MEQChannel(buffer: 0, channel: 0, stride: 1))
    invoke(dsp, input, output)
    XCTAssertEqual(output.samples[1][48], 0.1, accuracy: 1e-6)
    XCTAssertEqual(output.samples[0][48], 0.2, accuracy: 1e-6)
  }
  func testDormantTapIsSilenceNotFailure() {
    let dsp = meq_create()!
    defer { meq_destroy(dsp) }
    let bands = EQPreset.flat.bands.map(\.native)
    XCTAssertTrue(meq_prepare(dsp, 48000, bands, 8, 0))
    let input = Buffers(channels: [2])
    let output = Buffers(channels: [2])
    let channels = UnsafeMutableAudioBufferListPointer(input.pointer)
    channels[0].mData = nil
    meq_layout(
      dsp, MEQChannel(buffer: 0, channel: 0, stride: 2),
      MEQChannel(buffer: 0, channel: 1, stride: 2), MEQChannel(buffer: 0, channel: 0, stride: 2),
      MEQChannel(buffer: 0, channel: 1, stride: 2))
    for _ in 0..<20 { invoke(dsp, input, output) }
    XCTAssertEqual(meq_meter(dsp).faults, 0)
    XCTAssertEqual(meq_meter(dsp).callbacks, 20)
    XCTAssertTrue((0..<256).allSatisfy { output.samples[0][$0] == 0 })
    channels[0].mNumberChannels = 1
    invoke(dsp, input, output)
    XCTAssertEqual(meq_meter(dsp).faults, 1)
  }
}

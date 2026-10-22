import XCTest

@testable import MyEqCore

final class PresetTests: XCTestCase {
  func testRejectsOversizedLinkedAndWritableSettings() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("original.json")
    let store = PresetStore(url: original)
    try store.save(SavedState())
    let linked = folder.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: original)
    XCTAssertThrowsError(try PresetStore(url: linked).load())
    XCTAssertThrowsError(try PresetStore(url: linked).save(SavedState()))
    try FileManager.default.removeItem(at: linked)
    try FileManager.default.linkItem(at: original, to: linked)
    XCTAssertThrowsError(try store.load())
    try FileManager.default.removeItem(at: linked)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: original.path)
    XCTAssertThrowsError(try store.load())
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
    try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: original)
    XCTAssertThrowsError(try store.load())
    let backup = try XCTUnwrap(store.preserveInvalidFile())
    XCTAssertEqual(try backup.resourceValues(forKeys: [.fileSizeKey]).fileSize, 4 * 1024 * 1024 + 1)
  }

  func testVersionOneMigratesWithoutLosingPresetsOrEnablePreference() throws {
    var old = SavedState()
    old.current = .botaniq
    old.enabled = true
    var personal = EQPreset.flat
    personal.id = UUID()
    personal.name = "My saved EQ"
    old.presets = [personal]
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    json["schemaVersion"] = 1
    json.removeValue(forKey: "preferredOutputUID")
    let migrated = try JSONDecoder().decode(
      SavedState.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(migrated.schemaVersion, 2)
    XCTAssertEqual(migrated.current, old.current)
    XCTAssertEqual(migrated.presets, old.presets)
    XCTAssertTrue(migrated.enabled)
    XCTAssertNil(migrated.preferredOutputUID)
    XCTAssertTrue(migrated.isValid)
    json["schemaVersion"] = 99
    XCTAssertThrowsError(
      try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: json)))
  }
  func testOutputPreferenceRoundTripAndValidation() throws {
    var state = SavedState()
    state.preferredOutputUID = "USB:personal-output"
    XCTAssertEqual(
      try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state)), state)
    state.preferredOutputUID = ""
    XCTAssertFalse(state.isValid)
    state.preferredOutputUID = String(repeating: "x", count: 1025)
    XCTAssertFalse(state.isValid)
  }
  func testFactoryPresetMatchesReference() {
    XCTAssertTrue(EQPreset.flat.isValid)
    XCTAssertTrue(EQPreset.botaniq.isValid)
    XCTAssertEqual(
      EQPreset.botaniq.bands.map(\.frequency), [74, 150, 350, 690, 2000, 4000, 11200, 16000])
    XCTAssertEqual(EQPreset.botaniq.bands.map(\.gain), [4.8, -4.6, 3.7, -5, 2, 2.5, 2, 0])
    XCTAssertFalse(EQPreset.botaniq.bands[7].enabled)
    XCTAssertLessThanOrEqual(EQResponse.autoPreamp(EQPreset.botaniq.bands), -4.8)
  }
  func testAtomicPersistenceAndInvalidRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PresetStore(url: root.appendingPathComponent("settings.json"))
    XCTAssertEqual(try store.load(), SavedState())
    var s = SavedState()
    s.current = .botaniq
    s.enabled = true
    var custom = EQPreset.botaniq
    custom.id = UUID()
    custom.name = "Personal"
    s.presets = [custom]
    try store.save(s)
    XCTAssertEqual(try store.load(), s)
    try Data("broken".utf8).write(to: store.url)
    XCTAssertThrowsError(try store.load())
    let backup = try XCTUnwrap(store.preserveInvalidFile())
    XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    XCTAssertEqual(try store.load(), SavedState())
    s.current.bands[0].width = .nan
    XCTAssertThrowsError(try store.save(s))
  }
}

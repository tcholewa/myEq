import XCTest
@testable import MyEqCore

final class PresetTests: XCTestCase {
    func testFactoryPresetMatchesReference() {
        XCTAssertTrue(EQPreset.flat.isValid);XCTAssertTrue(EQPreset.botaniq.isValid)
        XCTAssertEqual(EQPreset.botaniq.bands.map(\.frequency),[74,150,350,690,2000,4000,11200,16000])
        XCTAssertEqual(EQPreset.botaniq.bands.map(\.gain),[4.8,-4.6,3.7,-5,2,2.5,2,0])
        XCTAssertFalse(EQPreset.botaniq.bands[7].enabled)
        XCTAssertLessThanOrEqual(EQResponse.autoPreamp(EQPreset.botaniq.bands),-4.8)
    }
    func testAtomicPersistenceAndInvalidRecovery() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PresetStore(url:root.appendingPathComponent("settings.json"))
        XCTAssertEqual(try store.load(),SavedState())
        var s=SavedState();s.current = .botaniq;s.enabled=true
        var custom=EQPreset.botaniq;custom.id=UUID();custom.name="Personal";s.presets=[custom]
        try store.save(s);XCTAssertEqual(try store.load(),s)
        try Data("broken".utf8).write(to:store.url)
        XCTAssertThrowsError(try store.load())
        let backup=try XCTUnwrap(store.preserveInvalidFile());XCTAssertTrue(FileManager.default.fileExists(atPath:backup.path))
        XCTAssertEqual(try store.load(),SavedState())
        s.current.bands[0].width = .nan;XCTAssertThrowsError(try store.save(s))
    }
}

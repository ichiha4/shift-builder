import XCTest
@testable import ShiftManagerApp

@MainActor
final class ShiftPhotoReaderTests: XCTestCase {
    func testRealVisionReadsSampleImageIntoThreeShifts() async throws {
        let text = try await ShiftPhotoReader.read(ShiftPhotoSample.data())
        let parsed = try ShiftImportParser.parse(lines:text.lines,month:"2026-10")
        XCTAssertEqual(parsed.candidates.map(\.date),["2026-10-06","2026-10-08","2026-10-10"],text.lines.joined(separator:"\n"))
        XCTAssertEqual(parsed.candidates.map(\.startMinute),[1020,1080,600])
        XCTAssertEqual(parsed.candidates.map(\.endMinute),[1320,1320,960])
        XCTAssertEqual(parsed.candidates.map(\.breakMinutes),[30,0,45])
        XCTAssertFalse(text.previewData.isEmpty)
    }
    func testInvalidImageFailsWithoutCandidates() async {
        do { _ = try await ShiftPhotoReader.read(Data("not an image".utf8)); XCTFail("Expected invalid image") }
        catch { XCTAssertTrue(error is ShiftPhotoReadError) }
    }
    func testOversizedImageFailsBeforeDecoding() async {
        do { _ = try await ShiftPhotoReader.read(Data(count:20*1024*1024+1)); XCTFail("Expected size limit") }
        catch { XCTAssertTrue(error is ShiftPhotoReadError) }
    }
    func testCancelledReadDoesNotReturnCandidates() async {
        let task=Task { try await ShiftPhotoReader.read(ShiftPhotoSample.data()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

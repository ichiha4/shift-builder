import XCTest
@testable import PayrollEngine

final class ShiftImportTests: XCTestCase {
    private let profile = EmployerProfile(name: "Cafe", defaultWage: 1200, defaultTransport: 300, otherAllowance: 50)
    private func candidate(_ id: Int = 0, date: String = "2026-10-06", start: Int = 1020, end: Int = 1320,
                           pause: Int = 30) -> ShiftImportCandidate {
        .init(id: id, date: date, startMinute: start, endMinute: end, breakMinutes: pause)
    }
    func testJapaneseFullwidthAndPartialDatesKeepCorrectTimes() throws {
        let parsed = try ShiftImportParser.parse(lines: [
            "自分のシフト",
            "２０２６／１０／０６ １７：００－２２：００ 休憩３０分",
            "10月8日(木) 18時〜22時",
            "10日 10:00–16:00"
        ], month: "2026-10")
        XCTAssertEqual(parsed.candidates.map(\.date), ["2026-10-06","2026-10-08","2026-10-10"])
        XCTAssertEqual(parsed.candidates.map(\.startMinute), [1020,1080,600])
        XCTAssertEqual(parsed.candidates.map(\.endMinute), [1320,1320,960])
        XCTAssertEqual(parsed.candidates[0].breakMinutes, 30)
        XCTAssertTrue(parsed.candidates[0].breakWasRead)
        XCTAssertFalse(parsed.candidates[1].breakWasRead)
    }
    func testInvalidCalendarDatesAreReportedInsteadOfNormalized() throws {
        let parsed = try ShiftImportParser.parse(lines: ["2026/2/29 10-16","2024/2/29 10-16","2026/4/31 10-16"], month: "2026-02")
        XCTAssertEqual(parsed.candidates.map(\.date), ["2024-02-29"])
        XCTAssertEqual(parsed.issues.count, 2)
    }
    func testMissingYearAndMonthUseExplicitSelection() throws {
        let parsed = try ShiftImportParser.parse(lines: ["6日 17-22","12/31 10-16"], month: "2027-01")
        XCTAssertEqual(parsed.candidates.map(\.date), ["2027-01-06","2027-12-31"])
    }
    func testOvernightAndMidnightArePreserved() throws {
        let parsed = try ShiftImportParser.parse(lines: ["10/6 22:00-翌2:00","10/7 17:00-24:00"], month: "2026-10")
        XCTAssertEqual(parsed.candidates.map(\.endMinute), [120,0])
        XCTAssertEqual(try ShiftImportPlanner.plan(candidates: parsed.candidates, profile: profile, existing: []).shifts.count, 2)
    }
    func testMalformedTimesAndMultipleRangesAreNotGuessed() throws {
        let parsed = try ShiftImportParser.parse(lines: [
            "10/6 17:99-22:00", "10/7 17:00-25:00", "10/8 17:00-17:00",
            "10/9 10:00-14:00 17:00-22:00", "10/10 午後5時-10時"
        ], month: "2026-10")
        XCTAssertTrue(parsed.candidates.isEmpty)
        XCTAssertEqual(parsed.issues.count, 5)
    }
    func testStaffNamesAndScheduleCodesAreNotAssignedAutomatically() throws {
        let parsed = try ShiftImportParser.parse(lines: ["Aさん 10/6 17-22", "10/7 早", "10/8 遅"], month: "2026-10")
        XCTAssertTrue(parsed.candidates.isEmpty)
        XCTAssertEqual(parsed.issues.count, 3)
    }
    func testInvalidMonthIsRejected() {
        for month in ["2026-13","2026-1","nonsense","0000-01"] {
            XCTAssertThrowsError(try ShiftImportParser.parse(lines: [], month: month))
        }
    }
    func testProfileDefaultsAreCarriedIntoRealShifts() throws {
        let plan = try ShiftImportPlanner.plan(candidates: [candidate()], profile: profile, existing: [])
        let shift = try XCTUnwrap(plan.shifts.first)
        XCTAssertEqual(shift.segments[0].hourlyWage,1200)
        XCTAssertEqual(shift.transport,300)
        XCTAssertEqual(shift.otherAllowance,50)
        XCTAssertEqual(shift.breakMinutes,30)
        XCTAssertEqual(shift.scheduledMinutes,profile.scheduledMinutes)
    }
    func testExistingAndRepeatedSelectionsAreDeduplicatedWithoutChangingOldRecord() throws {
        let old = Shift(id: "original", date:"2026-10-06", employer:"Cafe",
                        segments:[WorkSegment(startMinute:1020,endMinute:1320,hourlyWage:1500)],breakMinutes:60)
        let plan = try ShiftImportPlanner.plan(candidates: [candidate(),candidate(1),candidate(2,date:"2026-10-08")], profile: profile, existing: [old])
        XCTAssertEqual(plan.shifts.count,1)
        XCTAssertEqual(plan.duplicateCount,2)
        XCTAssertEqual(old.id,"original")
        XCTAssertEqual(old.breakMinutes,60)
    }
    func testDuplicatesInsideNewBatchAreAddedOnce() throws {
        let plan = try ShiftImportPlanner.plan(candidates: [candidate(),candidate(1)], profile:profile,existing:[])
        XCTAssertEqual(plan.shifts.count,1); XCTAssertEqual(plan.duplicateCount,1)
    }
    func testTimeChangesRequireEditingRatherThanAddingOverlappingRecord() {
        let old=Shift(id:"old",date:"2026-10-06",employer:"Cafe",segments:[WorkSegment(startMinute:1020,endMinute:1320,hourlyWage:1200)])
        XCTAssertThrowsError(try ShiftImportPlanner.plan(candidates:[candidate(0,date:"2026-10-08"),candidate(1,start:1080,end:1380)],profile:profile,existing:[old])) {
            XCTAssertEqual($0 as? ShiftImportError,.overlappingShift("2026-10-06"))
        }
    }
    func testInvalidRowsAndMissingWageBlockEntireSelection() {
        for row in [candidate(pause:-1),candidate(pause:301),candidate(date:"2026-02-30"),candidate(start:1440)] {
            XCTAssertThrowsError(try ShiftImportPlanner.plan(candidates:[candidate(9,date:"2026-10-08"),row],profile:profile,existing:[]))
        }
        XCTAssertThrowsError(try ShiftImportPlanner.plan(candidates:[candidate()],profile:EmployerProfile(name:"Cafe"),existing:[]))
        XCTAssertThrowsError(try ShiftImportPlanner.plan(candidates:[],profile:profile,existing:[]))
    }
}

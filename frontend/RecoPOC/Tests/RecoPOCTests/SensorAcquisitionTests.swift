import Foundation

#if canImport(Testing)
import Testing
@testable import RecoPOC

@Suite("Raw sensor acquisition")
struct SensorAcquisitionTests {
    @Test("freeze uses a fixed 15 second deadline and keeps captured readings")
    func fixedDeadlineAndCapturedReadings() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let freeze = start.addingTimeInterval(15)
        let clock = SequenceSensorClock(moments: [start, freeze])

        let location = FakeRawSensorProvider(
            sensorName: .location,
            result: .reading(
                RawSensorReading(
                    observedAt: start.addingTimeInterval(2),
                    freshnessWindow: 30,
                    values: [
                        "place_type": .string("写字楼"),
                        "place_type_confidence": .double(0.8),
                        "place_type_quality": .string("exact_or_good_mapping"),
                        "latitude": .double(31.2304),
                        "longitude": .double(121.4737)
                    ]
                )
            )
        )

        let battery = FakeRawSensorProvider(sensorName: .battery, result: .unavailable(.sensorDisabled))

        let freezer = RawSensorSnapshotFreezer(
            providers: [location, battery],
            clock: clock,
            scheduler: ImmediateDeadlineScheduler()
        )

        let snapshot = await freezer.freeze()

        #expect(snapshot.startedAt == start)
        #expect(snapshot.deadline == freeze)
        #expect(snapshot.frozenAt == freeze)
        #expect(snapshot[.location]?.state == .captured)
        #expect(snapshot[.battery]?.state == .unavailable(.sensorDisabled))
        #expect(snapshot.placeType == "写字楼")
        #expect(snapshot.latitude == 31.2304)
    }

    @Test("deadline fallback marks missing readings unavailable instead of fabricating values")
    func deadlineFallback() async throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let freeze = start.addingTimeInterval(15)
        let clock = SequenceSensorClock(moments: [start, freeze])

        let provider = FakeRawSensorProvider(
            sensorName: .connectivity,
            resultFactory: {
                .reading(
                    RawSensorReading(observedAt: start, values: ["network": .string("wifi")])
                )
            }
        )

        let freezer = RawSensorSnapshotFreezer(
            providers: [provider],
            clock: clock,
            scheduler: ControlledDeadlineScheduler(mode: .useFallback)
        )

        let snapshot = await freezer.freeze()
        let field = try #require(snapshot[.connectivity])

        #expect(field.state == .unavailable(.deadlineExceeded))
        #expect(field.reading == nil)
        #expect(snapshot.network == "任意")
        #expect(snapshot.deadline == freeze)
        #expect(snapshot.frozenAt == freeze)
    }

    @Test("stale readings stay marked stale with their actual last reading")
    func staleReadingsRemainMarkedStale() async throws {
        let start = Date(timeIntervalSince1970: 3_000)
        let freeze = start.addingTimeInterval(15)
        let clock = SequenceSensorClock(moments: [start, freeze])
        let staleReading = RawSensorReading(
            observedAt: start.addingTimeInterval(-20),
            freshnessWindow: 5,
            values: ["activity_state": .string("步行")]
        )

        let freezer = RawSensorSnapshotFreezer(
            providers: [FakeRawSensorProvider(sensorName: .activity, result: .reading(staleReading))],
            clock: clock,
            scheduler: ImmediateDeadlineScheduler()
        )

        let snapshot = await freezer.freeze()
        let field = try #require(snapshot[.activity])

        #expect(field.state == .stale(.exceededFreshnessWindow))
        #expect(field.reading == staleReading)
        #expect(snapshot.activityState == "步行")
        #expect(snapshot.activityStateAvailable == false)
    }

    @Test("one run returns one frozen snapshot with omitted sensors marked unavailable")
    func omittedSensorsMarkedUnavailable() async throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let freeze = start.addingTimeInterval(15)
        let freezer = RawSensorSnapshotFreezer(
            providers: [],
            clock: SequenceSensorClock(moments: [start, freeze]),
            scheduler: ImmediateDeadlineScheduler()
        )

        let snapshot = await freezer.freeze()

        #expect(Set(snapshot.fields.map(\.name)) == Set(RawSensorName.allCases))
        #expect(snapshot.fields.allSatisfy { $0.reading == nil })
        #expect(snapshot.fields.allSatisfy {
            if case .unavailable = $0.state { return true }
            return false
        })
        #expect(snapshot.statuses[RawSensorName.location.rawValue]?.availability == .unavailable)
    }
}

#elseif canImport(XCTest)
import XCTest
@testable import RecoPOC

final class SensorAcquisitionTests: XCTestCase {
    func testFixedDeadlineAndCapturedReadings() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let freeze = start.addingTimeInterval(15)
        let freezer = RawSensorSnapshotFreezer(
            providers: [
                FakeRawSensorProvider(
                    sensorName: .location,
                    result: .reading(
                        RawSensorReading(
                            observedAt: start,
                            freshnessWindow: 30,
                            values: ["place_type": .string("写字楼")]
                        )
                    )
                )
            ],
            clock: SequenceSensorClock(moments: [start, freeze]),
            scheduler: ImmediateDeadlineScheduler()
        )

        let snapshot = await freezer.freeze()
        XCTAssertEqual(snapshot.deadline, freeze)
        XCTAssertEqual(snapshot.placeType, "写字楼")
    }
}
#endif

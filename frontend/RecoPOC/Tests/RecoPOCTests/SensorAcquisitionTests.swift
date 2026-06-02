import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(Testing)
import Testing
@testable import RecoPOC

@Suite("Raw sensor acquisition")
struct SensorAcquisitionTests {
    @Test("freeze uses a fixed 60 second upper bound and keeps captured readings")
    func fixedDeadlineAndCapturedReadings() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = start.addingTimeInterval(60)
        let completedAt = start.addingTimeInterval(5)
        let clock = SequenceSensorClock(moments: [start, completedAt])

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
        #expect(snapshot.deadline == deadline)
        #expect(snapshot.frozenAt == completedAt)
        #expect(snapshot[.location]?.state == .captured)
        #expect(snapshot[.battery]?.state == .unavailable(.sensorDisabled))
        #expect(snapshot.placeType == "写字楼")
        #expect(snapshot.latitude == 31.2304)
        #expect(snapshot.acquisitionTrace?.deadline == deadline)
    }

    @Test("deadline fallback marks missing readings unavailable instead of fabricating values")
    func deadlineFallback() async throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let deadline = start.addingTimeInterval(60)
        let clock = SequenceSensorClock(moments: [start, deadline])

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
        #expect(snapshot.deadline == deadline)
        #expect(snapshot.frozenAt == deadline)
        #expect(snapshot.acquisitionTrace?.providers.first { $0.sensor == .connectivity }?.reasonCode == "deadlineExceeded")
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

    @Test("native-capable catalog has host-gated weather without changing baseline defaults")
    func nativeCatalogWeatherAndBaselineDefaults() async throws {
        let start = Date(timeIntervalSince1970: 5_000)
        let baseline = await SystemBaselineRawSensorAcquirer(
            clock: { start },
            timezone: { TimeZone(identifier: "Asia/Shanghai")! }
        ).acquireSnapshot(deadline: 60)

        #expect(baseline.network == "任意")
        #expect(baseline.bluetooth == "任意")
        #expect(baseline.weather == nil)
        #expect(baseline.statuses[RawSensorName.weather.rawValue]?.availability == .unavailable)

        let weatherProvider = try #require(
            NativeSensorProviderCatalog().makeProviders().first { $0.sensorName == .weather }
        )
        #expect(await weatherProvider.read() == .unavailable(.unsupported))
    }

    @Test("snapshot statuses preserve unavailable reasons for diagnostics")
    func snapshotStatusesPreserveReasons() async throws {
        let start = Date(timeIntervalSince1970: 6_000)
        let snapshot = RawSensorSnapshot(
            startedAt: start,
            frozenAt: start.addingTimeInterval(1),
            deadline: start.addingTimeInterval(60),
            fields: [
                RawSensorField(name: .location, state: .unavailable(.permissionDenied)),
                RawSensorField(
                    name: .connectivity,
                    state: .captured,
                    reading: RawSensorReading(observedAt: start, values: ["network": .string("wifi")])
                ),
            ]
        )

        #expect(snapshot.statuses[RawSensorName.location.rawValue]?.message == "permissionDenied")
        #expect(snapshot.statuses[RawSensorName.connectivity.rawValue]?.message == "captured")
    }

    @Test("snapshot statuses prefer trace detail for provider diagnostics")
    func snapshotStatusesPreferTraceDetail() async throws {
        let start = Date(timeIntervalSince1970: 7_000)
        let trace = SensorAcquisitionTrace(
            startedAt: start,
            endedAt: start.addingTimeInterval(1),
            deadline: start.addingTimeInterval(60),
            providers: [
                SensorProviderTrace(
                    sensor: .weather,
                    startedAt: start,
                    endedAt: start.addingTimeInterval(1),
                    availability: .unavailable,
                    reasonCode: "weatherkit_error:TestError",
                    detail: "Simulated WeatherKit failure"
                )
            ]
        )
        let snapshot = RawSensorSnapshot(
            startedAt: start,
            frozenAt: start.addingTimeInterval(1),
            deadline: start.addingTimeInterval(60),
            fields: [
                RawSensorField(name: .weather, state: .unavailable(.missingSample))
            ],
            acquisitionTrace: trace
        )

        #expect(snapshot.statuses[RawSensorName.weather.rawValue]?.message == "weatherkit_error:TestError: Simulated WeatherKit failure")
    }

    @Test("AMap place mapper uses typecode as primary evidence and supports sports venues")
    func amapPlaceMapperTypecodeAndSports() async throws {
        let restaurant = NativePlaceTypeMapper.testCandidate(typecode: "050100", type: "餐饮服务", name: "测试餐厅", distance: 40)
        let sports = NativePlaceTypeMapper.testCandidate(typecode: "080100", type: "体育休闲服务;运动场馆", name: "市民体育馆", distance: 32)
        let office = NativePlaceTypeMapper.testCandidate(typecode: "170000", type: "公司企业", name: "测试科技公司", distance: 60)

        #expect(restaurant.placeType == "餐厅")
        #expect(restaurant.source == "amap_typecode_name")
        #expect(sports.placeType == "运动场所")
        #expect(sports.confidence >= 0.70)
        #expect(office.placeType == "写字楼")
    }

    @Test("AMap name-only candidates are capped and still mapped when typecode is absent")
    func amapPlaceMapperNameOnlyCap() async throws {
        let candidate = NativePlaceTypeMapper.testCandidate(
            name: "中国科学院上海高等研究院",
            distance: 40
        )
        let place = NativePlaceTypeMapper.testDecision(candidates: [candidate])

        #expect(candidate.placeType == "写字楼")
        #expect(candidate.source == "amap_name_keyword")
        #expect(candidate.confidence <= 0.55)
        #expect(place.placeType == "写字楼")
        #expect(place.quality == "noisy_mapping")
    }

    @Test("AMap mapper downgrades conflicting name and typecode evidence")
    func amapPlaceMapperConflictPenalty() async throws {
        let consistent = NativePlaceTypeMapper.testCandidate(
            typecode: "050100",
            type: "餐饮服务",
            name: "测试餐厅",
            distance: 40
        )
        let conflicting = NativePlaceTypeMapper.testCandidate(
            typecode: "050100",
            type: "餐饮服务",
            name: "测试酒店",
            distance: 40
        )

        #expect(conflicting.placeType == "餐厅")
        #expect(conflicting.confidence < consistent.confidence)
    }

    @Test("AMap decision aggregates same type candidates and returns sanitized Top-3")
    func amapDecisionAggregatesAndReturnsTop3() async throws {
        let place = NativePlaceTypeMapper.testDecision(candidates: [
            NativePlaceTypeMapper.testCandidate(typecode: "050100", type: "餐饮服务", name: "餐厅 A", distance: 40, rank: 0),
            NativePlaceTypeMapper.testCandidate(typecode: "050100", type: "餐饮服务", name: "餐厅 B", distance: 50, rank: 1),
            NativePlaceTypeMapper.testCandidate(typecode: "080100", type: "体育休闲服务;运动场馆", name: "体育馆", distance: 70, rank: 2),
            NativePlaceTypeMapper.testCandidate(typecode: "100000", type: "住宿服务", name: "酒店 A", distance: 180, rank: 3),
        ])

        #expect(place.placeType == "餐厅")
        #expect(place.confidence >= 0.80)
        #expect(place.poiLookupAvailable == true)
        #expect(place.candidates.count == 3)
        #expect(place.candidates[0].placeType == "餐厅")
        #expect(place.candidates.allSatisfy { candidate in
            ["amap_typecode", "amap_typecode_name", "amap_name_keyword"].contains(candidate.source)
        })
    }

    @Test("AMap decision downgrades close runner-up conflicts")
    func amapDecisionDowngradesCloseRunnerUp() async throws {
        let place = NativePlaceTypeMapper.testDecision(candidates: [
            NativePlaceTypeMapper.testCandidate(typecode: "050100", type: "餐饮服务", name: "餐厅 A", distance: 40),
            NativePlaceTypeMapper.testCandidate(typecode: "100000", type: "住宿服务", name: "酒店 A", distance: 40),
        ])

        #expect(place.poiLookupAvailable == true)
        #expect(place.quality == "noisy_mapping")
        #expect(place.confidence < place.candidates[1].confidence + 0.12)
    }

    @Test("AMap decision returns unavailable for zero usable candidates")
    func amapDecisionReturnsUnavailableForNoCandidates() async throws {
        let place = NativePlaceTypeMapper.testDecision(candidates: [])

        #expect(place.placeType == "任意")
        #expect(place.confidence == 0)
        #expect(place.quality == "unavailable")
        #expect(place.poiLookupAvailable == false)
        #expect(place.candidates.isEmpty)
    }

    @Test("unavailable place labels are not treated as captured POI lookups")
    func unavailablePlaceLabelDoesNotPretendPOIWasCaptured() async throws {
        let start = Date(timeIntervalSince1970: 7_500)
        let snapshot = RawSensorSnapshot(
            startedAt: start,
            frozenAt: start.addingTimeInterval(1),
            deadline: start.addingTimeInterval(60),
            fields: [
                RawSensorField(
                    name: .location,
                    state: .captured,
                    reading: RawSensorReading(
                        observedAt: start,
                        values: [
                            "place_type": .string("任意"),
                            "place_type_confidence": .double(0),
                            "place_type_quality": .string("unavailable"),
                            "place_source": .string("amap_unavailable"),
                            "poi_lookup_available": .int(0),
                        ]
                    )
                )
            ]
        )

        #expect(snapshot.placeType == "任意")
        #expect(snapshot.placeTypeAvailable == false)
        #expect(snapshot.statuses[RawSensorName.location.rawValue]?.availability == .available)
    }

    @Test("native weak-signal mappers keep backend vocabulary stable")
    func nativeWeakSignalMappers() async throws {
        #expect(NativeActivityStateMapper.map(stationary: true, walking: false, running: false, automotive: false, cycling: false).activityState == "静止")
        #expect(NativeActivityStateMapper.map(stationary: false, walking: true, running: false, automotive: false, cycling: false).activityState == "慢速")
        #expect(NativeActivityStateMapper.map(stationary: false, walking: false, running: false, automotive: true, cycling: false).activityState == "中速")
        #expect(NativeActivityStateMapper.map(stationary: false, walking: false, running: true, automotive: false, cycling: false).activityState == "高速")
        #expect(NativeActivityStateMapper.map(stationary: false, walking: false, running: false, automotive: false, cycling: true).activityState == "高速")
        #expect(NativeActivityStateMapper.map(stationary: false, walking: false, running: false, automotive: false, cycling: false, unknown: true).activityState == "任意")
        #expect(NativeNoiseMapper.label(forAveragePowerDBFS: -55) == "安静")
        #expect(NativeNoiseMapper.label(forAveragePowerDBFS: -35) == "普通")
        #expect(NativeNoiseMapper.label(forAveragePowerDBFS: -15) == "嘈杂")
        #expect(NativeHealthValueMapper.heartRateZone(bpm: 72) == "静息")
        #expect(NativeHealthValueMapper.heartRateZone(bpm: 92) == "稍高")
        #expect(NativeHealthValueMapper.heartRateZone(bpm: 120) == "高")
        #expect(NativeHealthValueMapper.heartRateZone(bpm: 90, previousBpm: 60) == "波动")
        #expect(NativeHealthValueMapper.sleepQuality(asleepMinutes: 450, awakeMinutes: 10) == "好")
        #expect(NativeWeatherMapper.label(for: "heavyRain") == "小雨")
        #expect(NativeWeatherMapper.label(for: "mostlyCloudy") == "多云")
    }

    @Test("motion activity resolver uses recency and pedometer fallbacks")
    func motionActivityResolverUsesRecencyAndPedometerFallbacks() async throws {
        let now = Date(timeIntervalSince1970: 9_000)
        let oldStationary = NativeMotionActivitySignal(
            stationary: true,
            confidence: "high",
            confidenceScore: 3,
            startedAt: now.addingTimeInterval(-120),
            source: "history_activity"
        )
        let recentWalking = NativeMotionActivitySignal(
            walking: true,
            confidence: "medium",
            confidenceScore: 2,
            startedAt: now.addingTimeInterval(-10),
            source: "history_activity"
        )
        let recencyDecision = NativeMotionActivityResolver.resolve(
            live: nil,
            history: [oldStationary, recentWalking],
            pedometer: nil,
            now: now
        )
        #expect(recencyDecision.activityState == "慢速")
        #expect(recencyDecision.source == "history_activity")

        let liveStationary = NativeMotionActivitySignal(
            stationary: true,
            confidence: "medium",
            confidenceScore: 2,
            startedAt: now,
            source: "live_activity"
        )
        let walkingSteps = NativePedometerSignal(
            steps: 8,
            distanceM: 6.4,
            startedAt: now.addingTimeInterval(-90),
            endedAt: now
        )
        let pedometerWalkingDecision = NativeMotionActivityResolver.resolve(
            live: liveStationary,
            history: [],
            pedometer: walkingSteps,
            now: now
        )
        #expect(pedometerWalkingDecision.activityState == "慢速")
        #expect(pedometerWalkingDecision.source == "pedometer_steps")

        let automotive = NativeMotionActivitySignal(
            automotive: true,
            confidence: "low",
            confidenceScore: 1,
            startedAt: now,
            source: "live_activity"
        )
        let automotiveDecision = NativeMotionActivityResolver.resolve(
            live: automotive,
            history: [],
            pedometer: walkingSteps,
            now: now
        )
        #expect(automotiveDecision.activityState == "中速")
        #expect(automotiveDecision.source == "live_activity")

        let unknownLive = NativeMotionActivitySignal(
            unknown: true,
            confidence: "low",
            confidenceScore: 1,
            startedAt: now,
            source: "live_activity"
        )
        let noSteps = NativePedometerSignal(
            steps: 0,
            startedAt: now.addingTimeInterval(-90),
            endedAt: now
        )
        let staticFallbackDecision = NativeMotionActivityResolver.resolve(
            live: unknownLive,
            history: [],
            pedometer: noSteps,
            now: now
        )
        #expect(staticFallbackDecision.activityState == "静止")
        #expect(staticFallbackDecision.source == "pedometer_no_steps_static_fallback")

        let unresolvedDecision = NativeMotionActivityResolver.resolve(
            live: unknownLive,
            history: [],
            pedometer: nil,
            now: now
        )
        #expect(unresolvedDecision.activityState == "任意")
        #expect(unresolvedDecision.reasonCode == "motion_resolution_unknown")
    }

    @Test("snapshot derives activity and noise from captured provider fields")
    func snapshotDerivesActivityAndNoise() async throws {
        let start = Date(timeIntervalSince1970: 8_000)
        let snapshot = RawSensorSnapshot(
            startedAt: start,
            frozenAt: start.addingTimeInterval(1),
            deadline: start.addingTimeInterval(60),
            fields: [
                RawSensorField(
                    name: .activity,
                    state: .captured,
                    reading: RawSensorReading(
                        observedAt: start,
                        values: [
                            "activity_state": .string("慢速"),
                            "raw_motion_activity": .string("walking"),
                        ]
                    )
                ),
                RawSensorField(
                    name: .microphone,
                    state: .captured,
                    reading: RawSensorReading(
                        observedAt: start,
                        values: [
                            "noise_class": .string("普通"),
                            "raw_noise_avg_dbfs": .double(-34.5),
                        ]
                    )
                ),
            ]
        )

        #expect(snapshot.activityState == "慢速")
        #expect(snapshot.activityStateAvailable == true)
        #expect(snapshot.noiseClass == "普通")
        #expect(snapshot.noiseAvailable == true)
    }

    @Test("one run returns one frozen snapshot with omitted sensors marked unavailable")
    func omittedSensorsMarkedUnavailable() async throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let freeze = start.addingTimeInterval(1)
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
        #expect(snapshot.acquisitionTrace?.providers.count == RawSensorName.allCases.count)
    }

    #if canImport(CoreLocation)
    @Test("location provider preserves one-shot CoreLocation diagnostics")
    func locationProviderPreservesOneShotDiagnostics() async throws {
        let startedAt = Date(timeIntervalSince1970: 9_000)
        let failure = NativeSensorFailure(
            reason: .deadlineExceeded,
            reasonCode: "cllocation_timeout",
            detail: "Simulated one-shot timeout."
        )
        let lowLevelStep = SensorStepTrace(
            name: "corelocation.timeout",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(55),
            availability: .unavailable,
            reasonCode: failure.reasonCode,
            detail: failure.detail
        )
        let provider = SystemLocationSnapshotProvider(
            locationReader: StubLocationReader(
                report: LocationReadReport(outcome: .failure(failure), steps: [lowLevelStep])
            )
        )

        let outcome = await provider.readLocationSnapshotWithTrace()

        #expect(outcome.result == .unavailable(.deadlineExceeded))
        #expect(outcome.reasonCode == "cllocation_timeout")
        #expect(outcome.steps.map(\.name).contains("cllocation.request"))
        #expect(outcome.steps.map(\.name).contains("corelocation.timeout"))
    }

    @Test("AMap location provider emits sanitized candidates without raw POI secrets")
    func amapLocationProviderSanitizesPOIData() async throws {
        let startedAt = Date()
        let location = LocationSample(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                altitude: 0,
                horizontalAccuracy: 35,
                verticalAccuracy: -1,
                timestamp: startedAt
            )
        )
        let provider = SystemLocationSnapshotProvider(
            locationReader: StubLocationReader(report: LocationReadReport(outcome: .success(location))),
            amapConfiguration: AmapPOIConfiguration(
                apiKey: "secret-amap-key",
                enabled: true,
                inputCoordinateSystem: .autonavi
            ),
            amapClient: FakeAmapPOIClient(
                pois: .success([
                    AmapRawPOI(name: "秘密体育馆", type: "体育休闲服务;运动场馆", typecode: "080100", location: "121.4738,31.2305", distance: "32"),
                    AmapRawPOI(name: "秘密餐厅", type: "餐饮服务", typecode: "050100", location: "121.4739,31.2306", distance: "220"),
                ])
            )
        )

        let outcome = await provider.readLocationSnapshotWithTrace()
        guard case .reading(let reading) = outcome.result else {
            Issue.record("Expected captured location reading.")
            return
        }

        #expect(reading.values["place_type"] == JSONValue.string("运动场所"))
        #expect(reading.values["place_source"] == JSONValue.string("amap_typecode_name"))
        #expect(reading.values["poi_lookup_available"] == JSONValue.int(1))
        let candidateValue: JSONValue? = reading.values["place_candidates"]
        guard case .array(let candidates)? = candidateValue else {
            Issue.record("Expected place_candidates array.")
            return
        }
        #expect(candidates.count == 2)
        #expect(candidates.first == JSONValue.object([
            "place_type": .string("运动场所"),
            "confidence": .double(0.86),
            "distance_m": .double(32),
            "source": .string("amap_typecode_name"),
            "quality": .string("exact_or_good_mapping")
        ]))

        let traceText = outcome.steps.compactMap { $0.detail }.joined(separator: "\n")
        let payloadText = String(describing: reading.values)
        for forbidden in ["secret-amap-key", "https://restapi.amap.com", "秘密体育馆", "秘密餐厅", "address", "poi_id"] {
            #expect(!traceText.contains(forbidden))
            #expect(!payloadText.contains(forbidden))
        }
    }

    @Test("shared location reader coalesces concurrent one-shot requests")
    func sharedLocationReaderCoalescesConcurrentRequests() async throws {
        let counter = LocationRequestCounter()
        let startedAt = Date(timeIntervalSince1970: 10_000)
        let report = LocationReadReport(
            outcome: .failure(
                NativeSensorFailure(
                    reason: .missingSample,
                    reasonCode: "cllocation_error:0",
                    detail: "Simulated CoreLocation failure."
                )
            ),
            steps: [
                SensorStepTrace(
                    name: "corelocation.did_fail_with_error",
                    startedAt: startedAt,
                    endedAt: startedAt.addingTimeInterval(1),
                    availability: .unavailable,
                    reasonCode: "cllocation_error:0",
                    detail: "Simulated CoreLocation failure."
                )
            ]
        )
        let reader = SharedLocationReader { _ in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(50))
            return report
        }

        async let first = reader.requestLocation(timeout: 55)
        async let second = reader.requestLocation(timeout: 55)
        let reports = await [first, second]

        #expect(await counter.value == 1)
        #expect(reports == [report, report])
    }

    private struct StubLocationReader: LocationReading {
        var report: LocationReadReport

        func requestLocation(timeout: TimeInterval) async -> LocationReadReport {
            report
        }
    }

    private actor LocationRequestCounter {
        private var count = 0

        var value: Int { count }

        func increment() {
            count += 1
        }
    }
    #endif
}

#elseif canImport(XCTest)
import XCTest
@testable import RecoPOC

final class SensorAcquisitionTests: XCTestCase {
    func testFixedDeadlineAndCapturedReadings() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let completedAt = start.addingTimeInterval(5)
        let deadline = start.addingTimeInterval(60)
        let freezer = RawSensorSnapshotFreezer(
            providers: [
                FakeRawSensorProvider(
                    sensorName: .location,
                    result: .reading(
                        RawSensorReading(
                            observedAt: start,
                            freshnessWindow: 120,
                            values: ["place_type": .string("写字楼")]
                        )
                    )
                )
            ],
            clock: SequenceSensorClock(moments: [start, completedAt]),
            scheduler: ImmediateDeadlineScheduler()
        )

        let snapshot = await freezer.freeze()
        XCTAssertEqual(snapshot.deadline, deadline)
        XCTAssertEqual(snapshot.frozenAt, completedAt)
        XCTAssertEqual(snapshot.placeType, "写字楼")
    }
}
#endif

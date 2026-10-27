import XCTest
@testable import OptiStatsCore

final class SMCDecoderTests: XCTestCase {
    func testFixedPointAndIntegers() {
        XCTAssertEqual(SMCDecoder.decode(type: "sp78", bytes: [0x2D, 0x80]), 45.5)             // 45,5 °C
        XCTAssertEqual(SMCDecoder.decode(type: "sp78", bytes: [0xFF, 0x00]), -1)               // sinal
        XCTAssertEqual(SMCDecoder.decode(type: "ui8 ", bytes: [200]), 200)
        XCTAssertEqual(SMCDecoder.decode(type: "ui16", bytes: [0x01, 0x02]), 258)
        XCTAssertEqual(SMCDecoder.decode(type: "ui32", bytes: [0, 0, 0x01, 0x00]), 256)
        XCTAssertEqual(SMCDecoder.decode(type: "fpe2", bytes: [0x12, 0xC0]), 1200)              // RPM
        XCTAssertEqual(SMCDecoder.decode(type: "sp5a", bytes: [0x04, 0x00]), 1)
    }
    func testFloatIsLittleEndian() {
        let bits = Float(3.5).bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        XCTAssertEqual(SMCDecoder.decode(type: "flt ", bytes: bytes), 3.5)
    }
    func testShortBuffersAndUnknownTypesAreNilNotCrash() {
        XCTAssertNil(SMCDecoder.decode(type: "flt ", bytes: [1, 2]))
        XCTAssertNil(SMCDecoder.decode(type: "ui32", bytes: []))
        XCTAssertNil(SMCDecoder.decode(type: "zzzz", bytes: [1, 2, 3, 4]))
    }
    func testFourCC() {
        XCTAssertEqual(SMCDecoder.fourCC("Tp09"), 0x54703039)
        XCTAssertNil(SMCDecoder.fourCC("abc"))
    }
}

final class SensorTests: XCTestCase {
    func desc(_ key: String, role: SensorRole, kind: SensorKind = .temperature) -> SensorDescriptor {
        SensorDescriptor(key: key, name: key, kind: kind, role: role, source: .smc)
    }

    func testValidatorRejectsAbsentNaNAndOutOfRange() {
        XCTAssertNil(SensorValidator.validate(0, kind: .temperature))          // termistor inexistente
        XCTAssertNil(SensorValidator.validate(.nan, kind: .temperature))
        XCTAssertNil(SensorValidator.validate(500, kind: .temperature))
        XCTAssertNil(SensorValidator.validate(.infinity, kind: .power))
        XCTAssertEqual(SensorValidator.validate(0, kind: .power), 0)            // 0 W válido é zero real
        XCTAssertEqual(SensorValidator.validate(-3.2, kind: .current), -3.2)
        XCTAssertEqual(SensorValidator.validate(43.5, kind: .temperature), 43.5)
    }

    func testInvalidReadingBecomesUnavailableNotZero() {
        let r = SensorValidator.reading(desc("Tp09", role: .cpuEfficiencyZone), raw: 0, at: 1)
        XCTAssertNil(r.value); XCTAssertEqual(r.quality, .unavailable)
    }

    func testStableIDs() {
        XCTAssertEqual(desc("Tp09", role: .cpuPerformanceZone).id, "smc:Tp09")
        XCTAssertEqual(SensorDescriptor(key: "pACC MTR Temp Sensor0", name: "x", kind: .temperature, role: .cpuPerformanceZone, source: .hid).id,
                       "hid:pACC MTR Temp Sensor0")
    }

    func testAggregatesAreCalculatedAndIgnoreUnavailable() {
        let rs = [SensorValidator.reading(desc("a", role: .cpuEfficiencyZone), raw: 40, at: 1),
                  SensorValidator.reading(desc("b", role: .cpuPerformanceZone), raw: 50, at: 1),
                  SensorValidator.reading(desc("c", role: .cpuPerformanceZone), raw: nil, at: 1),
                  SensorValidator.reading(desc("d", role: .gpuZone), raw: 36, at: 1),
                  SensorValidator.reading(desc("e", role: .airflow), raw: 99, at: 1)]
        let agg = SensorAggregator.aggregates(from: rs, at: 1)
        func value(_ k: String) -> Double? { agg.first { $0.descriptor.key == k }?.value }
        XCTAssertEqual(value("avg-cpu"), 45)
        XCTAssertEqual(value("max-cpu"), 50)
        XCTAssertEqual(value("avg-gpu"), 36)
        XCTAssertTrue(agg.allSatisfy { $0.quality == .calculated && $0.descriptor.source == .derived })
        XCTAssertTrue(SensorAggregator.aggregates(from: [], at: 1).isEmpty)       // sem dados → sem agregado
    }

    func testStaleness() {
        let r = SensorValidator.reading(desc("a", role: .gpuZone), raw: 40, at: 100)
        XCTAssertFalse(r.isStale(now: 104, expectedInterval: 3))
        XCTAssertTrue(r.isStale(now: 120, expectedInterval: 3))
    }

    func testCatalogPerGeneration() {
        let m1 = ChipFamily.parse(brand: "Apple M1")!, m4pro = ChipFamily.parse(brand: "Apple M4 Pro")!
        let m4 = ChipFamily.parse(brand: "Apple M4")!, future = ChipFamily.parse(brand: "Apple M9")!
        let keys: (ChipFamily?) -> Set<String> = { Set(SMCCatalog.specs(for: $0).map(\.key)) }
        XCTAssertTrue(keys(m1).contains("Tp09")); XCTAssertFalse(keys(m1).contains("Te05"))
        XCTAssertTrue(keys(m4pro).contains("Tg1U")); XCTAssertFalse(keys(m4pro).contains("Tg0G"))
        XCTAssertTrue(keys(m4).contains("Tg0G")); XCTAssertFalse(keys(m4).contains("Tg1U"))
        // Chip futuro: só chaves gerais; nada de tabela de outra geração aplicada por engano.
        XCTAssertTrue(keys(future).contains("PSTR"))
        XCTAssertFalse(keys(future).contains("Tp09"))
        XCTAssertTrue(keys(nil).contains("PSTR"))
    }

    func testPowerCatalogMarksOverlappingDomainsDistinctly() {
        let power = SMCCatalog.all.filter { $0.kind == .power }
        XCTAssertTrue(power.contains { $0.key == "PSTR" && $0.role == .systemTotal })
        XCTAssertTrue(power.contains { $0.key == "PPBR" && $0.role == .battery })
        XCTAssertTrue(power.contains { $0.key == "PDTR" && $0.role == .dcIn })
    }

    func testHIDRoleMapping() {
        XCTAssertEqual(SMCCatalog.hidRole(forProductName: "pACC MTR Temp Sensor3")?.role, .cpuPerformanceZone)
        XCTAssertEqual(SMCCatalog.hidRole(forProductName: "eACC MTR Temp Sensor1")?.role, .cpuEfficiencyZone)
        XCTAssertEqual(SMCCatalog.hidRole(forProductName: "gas gauge battery")?.role, .battery)
        XCTAssertNil(SMCCatalog.hidRole(forProductName: "Totally Unknown"))
    }

    func testCatalogKeysAreFourCharsAndUniquePerGeneration() {
        for spec in SMCCatalog.all { XCTAssertEqual(spec.key.utf8.count, 4, spec.key) }
        for gen in 1...6 {
            let chip = ChipFamily(generation: gen, tier: .base, brand: "Apple M\(gen)")
            let keys = SMCCatalog.specs(for: chip).map(\.key)
            XCTAssertEqual(keys.count, Set(keys).count, "chave duplicada na geração \(gen)")
        }
    }
}

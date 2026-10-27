import XCTest
@testable import OptiStatsCore

final class FanHelperProtocolTests: XCTestCase {
    func line(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Codec

    func testRoundTripRequestAndResponse() throws {
        let req = FanHelperRequest(id: 7, type: .setTarget, fan: 1, rpm: 3200)
        let data = try XCTUnwrap(FanHelperCodec.encodeLine(req))
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
        let decoded = FanHelperCodec.decodeRequest(data.dropLast())
        XCTAssertEqual(try decoded.get(), req)

        let resp = FanHelperResponse(id: 7, ok: true, helperBuild: 1, supported: true,
                                     fans: [FanHelperFanState(index: 0, rpm: 1200, minRPM: 1000, maxRPM: 6000, manual: false)])
        let rd = try XCTUnwrap(FanHelperCodec.encodeLine(resp))
        XCTAssertEqual(FanHelperCodec.decodeResponse(rd.dropLast()), resp)
    }

    func testRejectsBadVersionGarbageAndInvalidFields() {
        XCTAssertEqual(FanHelperCodec.decodeRequest(line(#"{"v":2,"id":1,"type":"hello"}"#)), .failure(.unsupportedVersion(2)))
        XCTAssertEqual(FanHelperCodec.decodeRequest(line("not json")), .failure(.notJSON))
        XCTAssertEqual(FanHelperCodec.decodeRequest(line(#"{"v":1,"id":1,"type":"writeKey","key":"ABCD"}"#)), .failure(.notJSON))
        XCTAssertEqual(FanHelperCodec.decodeRequest(line(#"{"v":1,"id":1,"type":"setTarget","rpm":3000}"#)), .failure(.invalidField("fan")))
        XCTAssertEqual(FanHelperCodec.decodeRequest(line(#"{"v":1,"id":1,"type":"setTarget","fan":-1,"rpm":3000}"#)), .failure(.invalidField("fan")))
        XCTAssertEqual(FanHelperCodec.decodeRequest(line(#"{"v":1,"id":1,"type":"setTarget","fan":99,"rpm":3000}"#)), .failure(.invalidField("fan")))
        XCTAssertEqual(FanHelperCodec.decodeRequest(line(#"{"v":1,"id":1,"type":"setTarget","fan":0}"#)), .failure(.invalidField("rpm")))
        XCTAssertEqual(FanHelperCodec.decodeRequest(Data(repeating: 0x41, count: FanHelperConstants.maxLineBytes + 1)), .failure(.tooLong))
    }

    func testAcceptsAllRequestTypes() throws {
        for t in ["hello", "readFans", "restoreAutomatic", "heartbeat"] {
            XCTAssertNoThrow(try FanHelperCodec.decodeRequest(line(#"{"v":1,"id":3,"type":"\#(t)"}"#)).get(), t)
        }
    }

    func testLineBufferSplitsAndLimits() {
        var b = FanHelperLineBuffer()
        XCTAssertEqual(b.append(line("{\"a\":1}\n{\"b\"")).count, 1)
        let rest = b.append(line(":2}\n\n"))
        XCTAssertEqual(rest, [line("{\"b\":2}")])
        XCTAssertFalse(b.overflowed)
        var big = FanHelperLineBuffer()
        _ = big.append(Data(repeating: 0x41, count: FanHelperConstants.maxLineBytes + 10))
        XCTAssertTrue(big.overflowed)
        XCTAssertTrue(big.append(line("{}\n")).isEmpty)
    }

    // MARK: Chaves

    func testWritableKeysAreAFixedList() {
        XCTAssertTrue(FanSMCKeys.isWritable("Ftst"))
        XCTAssertTrue(FanSMCKeys.isWritable("F0Tg"))
        XCTAssertTrue(FanSMCKeys.isWritable("F7md"))
        for bad in ["F8Tg", "F0Mx", "F0Mn", "F0Ac", "FNum", "TC0P", "F0TG", "F-1Tg", "", "Ftst "] {
            XCTAssertFalse(FanSMCKeys.isWritable(bad), bad)
        }
        XCTAssertEqual(FanSMCKeys.writableKeys.count, 1 + FanSMCKeys.maxFans * 3)
        XCTAssertTrue(FanSMCKeys.isValidFanIndex(0)); XCTAssertFalse(FanSMCKeys.isValidFanIndex(8)); XCTAssertFalse(FanSMCKeys.isValidFanIndex(-1))
    }

    // MARK: RPM

    func testValidateRejectsOutsideRange() {
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: 1200, max: 6000), .ok(3000))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 1200, min: 1200, max: 6000), .ok(1200))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 6000, min: 1200, max: 6000), .ok(6000))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 1199.9, min: 1200, max: 6000), .rejected(.outOfRange))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 6000.1, min: 1200, max: 6000), .rejected(.outOfRange))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 0, min: 1200, max: 6000), .rejected(.outOfRange))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: .nan, min: 1200, max: 6000), .rejected(.outOfRange))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: .infinity, min: 1200, max: 6000), .rejected(.outOfRange))
    }

    func testValidateRejectsUnknownOrIncoherentLimits() {
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: nil, max: 6000), .rejected(.limitsUnknown))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: 1200, max: nil), .rejected(.limitsUnknown))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: 6000, max: 6000), .rejected(.limitsUnknown))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: 6000, max: 1200), .rejected(.limitsUnknown))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: 1200, max: 50_000), .rejected(.limitsUnknown))
        XCTAssertEqual(FanRPMPolicy.validate(rpm: 3000, min: -5, max: 6000), .rejected(.limitsUnknown))
    }

    func testClampForUI() {
        XCTAssertEqual(FanRPMPolicy.clampForUI(100, min: 1200, max: 6000), 1200)
        XCTAssertEqual(FanRPMPolicy.clampForUI(9000, min: 1200, max: 6000), 6000)
        XCTAssertEqual(FanRPMPolicy.clampForUI(3000.4, min: 1200, max: 6000), 3000)
        XCTAssertEqual(FanRPMPolicy.clampForUI(0, min: 1234.5, max: 6000.5), 1235)
        XCTAssertEqual(FanRPMPolicy.clampForUI(99999, min: 1234.5, max: 6000.5), 6000)
        XCTAssertNil(FanRPMPolicy.clampForUI(3000, min: nil, max: 6000))
        XCTAssertNil(FanRPMPolicy.clampForUI(.nan, min: 1200, max: 6000))
        // Resultado do clamp sempre passa na validação estrita.
        let v = FanRPMPolicy.clampForUI(77777, min: 1234.5, max: 6000.5)!
        XCTAssertEqual(FanRPMPolicy.validate(rpm: v, min: 1234.5, max: 6000.5), .ok(v))
    }

    // MARK: Codificação SMC

    func testTargetEncodingRoundTripsThroughDecoder() throws {
        for rpm in [0.0, 1200, 2345, 6000, 9999] {
            let f = try XCTUnwrap(SMCFanTargetEncoding.encode(type: "flt ", rpm: rpm, size: 4))
            XCTAssertEqual(f.count, 4)
            XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "flt ", bytes: f)), rpm, accuracy: 0.001)
            let p = try XCTUnwrap(SMCFanTargetEncoding.encode(type: "fpe2", rpm: rpm, size: 2))
            XCTAssertEqual(try XCTUnwrap(SMCDecoder.decode(type: "fpe2", bytes: p)), rpm, accuracy: 0.001)
        }
        XCTAssertEqual(SMCFanTargetEncoding.encode(type: "flt ", rpm: 1000, size: 4)!, [0x00, 0x00, 0x7A, 0x44])  // Float(1000) LE
        XCTAssertEqual(SMCFanTargetEncoding.encode(type: "fpe2", rpm: 1000, size: 2)!, [0x0f, 0xa0])           // mesmo valor usado nos testes do Stats
    }

    func testTargetEncodingRefusesUnknownTypesAndBadInput() {
        XCTAssertNil(SMCFanTargetEncoding.encode(type: "ui16", rpm: 1000, size: 2))
        XCTAssertNil(SMCFanTargetEncoding.encode(type: "flt ", rpm: 1000, size: 2))
        XCTAssertNil(SMCFanTargetEncoding.encode(type: "fpe2", rpm: 20000, size: 2))
        XCTAssertNil(SMCFanTargetEncoding.encode(type: "flt ", rpm: .nan, size: 4))
        XCTAssertNil(SMCFanTargetEncoding.encode(type: "flt ", rpm: -1, size: 4))
        XCTAssertTrue(SMCFanTargetEncoding.matches(readBack: 3000.2, requested: 3000))
        XCTAssertFalse(SMCFanTargetEncoding.matches(readBack: 0, requested: 3000))
        XCTAssertFalse(SMCFanTargetEncoding.matches(readBack: nil, requested: 3000))
    }

    // MARK: Watchdog

    func testWatchdogExpiresOnlyWhenArmedAndSilent() {
        var w = FanWatchdog(timeout: 10)
        XCTAssertFalse(w.isExpired(at: 1000))          // desarmado nunca expira
        XCTAssertNil(w.remaining(at: 1000))
        w.arm(at: 100)
        XCTAssertFalse(w.isExpired(at: 109.9))
        XCTAssertTrue(w.isExpired(at: 110.1))
        w.beat(at: 108)
        XCTAssertFalse(w.isExpired(at: 117.9))
        XCTAssertTrue(w.isExpired(at: 118.1))
        XCTAssertEqual(w.remaining(at: 113)!, 5, accuracy: 1e-9)
        w.disarm()
        XCTAssertFalse(w.isExpired(at: 10_000))
        w.beat(at: 10_001)                              // heartbeat com watchdog desarmado não rearma
        XCTAssertFalse(w.armed)
    }

    // MARK: Teste de controle

    func testControlTestPlan() {
        XCTAssertEqual(FanControlTestPlan.target(current: 2000, min: 1200, max: 6000), 2300)
        XCTAssertEqual(FanControlTestPlan.target(current: 5900, min: 1200, max: 6000), 6000)   // limitado pelo máximo
        XCTAssertNil(FanControlTestPlan.target(current: 5950, min: 1200, max: 6000))            // sem margem conclusiva
        XCTAssertNil(FanControlTestPlan.target(current: 2000, min: nil, max: 6000))
        XCTAssertEqual(FanControlTestPlan.target(current: 500, min: 1200, max: 6000), 1200)   // nunca abaixo do mínimo
        XCTAssertTrue(FanControlTestPlan.passed(start: 2000, target: 2300, observed: 2200))
        XCTAssertFalse(FanControlTestPlan.passed(start: 2000, target: 2300, observed: 2050))
        XCTAssertFalse(FanControlTestPlan.passed(start: 2000, target: 2300, observed: nil))
    }
}

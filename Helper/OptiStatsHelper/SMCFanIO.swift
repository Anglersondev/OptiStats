import Foundation
import OptiStatsCore

struct SMCFanValue {
    var key: String
    var type: String
    var size: Int
    var bytes: [UInt8]
    var number: Double? { SMCDecoder.decode(type: type, bytes: bytes) }
}

/// Allows command sequencing to be tested without writing to physical hardware.
protocol SMCFanIO: AnyObject {
    var lastError: String? { get }
    func open() -> Bool
    func read(_ key: String) -> SMCFanValue?
    func write(_ key: String, bytes: [UInt8], size: Int) -> Bool
}

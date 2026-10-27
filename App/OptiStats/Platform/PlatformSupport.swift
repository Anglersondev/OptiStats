import Foundation
import Darwin
import IOKit
import OptiStatsCore

/// Auxiliares de baixo nível compartilhados pelos coletores (sysctl, IORegistry, Mach).
enum Sys {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix(while: { $0 != 0 })
        return String(decoding: bytes, as: UTF8.self)
    }

    static func int(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == 8 {
            var v: Int64 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        } else if size == 4 {
            var v: Int32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int(v)
        }
        return nil
    }

    static func uint64(_ name: String) -> UInt64? {
        var v: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0, size == 8 else { return nil }
        return v
    }

    static var machTimebase: MachTimebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MachTimebase(numer: info.numer, denom: info.denom)
    }
}

/// Acesso ao IORegistry (somente leitura).
enum IOReg {
    static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }

    static func property(of entry: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Itera os serviços de uma classe IOKit. `body` não deve reter `entry` (é liberado em seguida).
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    static func string(from value: Any?) -> String? {
        if let s = value as? String { return s }
        if let d = value as? Data {
            let bytes = d.prefix(while: { $0 != 0 })
            let s = String(decoding: bytes, as: UTF8.self)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

extension Dictionary where Key == String, Value == Any {
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    /// Inteiro com sinal; valores gravados como unsigned 64 bits (complemento de dois) viram negativos.
    func signedInt(_ key: String) -> Int64? {
        guard let n = self[key] as? NSNumber else { return nil }
        return Int64(bitPattern: n.uint64Value)
    }
}

/// Base comum dos coletores. `collect()`/`suspend()` rodam SEMPRE no executor serial do próprio coletor
/// (garantido pelo SamplingCoordinator), por isso o estado interno de cada subclasse dispensa travas.
class BaseCollector: Collector {
    let id: CollectorID
    let store: MetricsStore
    let clock: MonotonicClock

    init(id: CollectorID, store: MetricsStore, clock: MonotonicClock) {
        self.id = id; self.store = store; self.clock = clock
    }

    func collect() {}
    func suspend() {}

    func markAvailable() { store.setState(.available, for: id) }
    func markUnsupported(_ reasonKey: String) { store.setState(.unsupported(reason: L(reasonKey)), for: id) }
    func markFailed(_ message: String) { store.setState(.failed(message: message), for: id) }
}

func thermalLevel(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
    switch state {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .nominal
    }
}

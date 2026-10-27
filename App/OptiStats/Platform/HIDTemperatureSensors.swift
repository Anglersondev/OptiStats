import Foundation
import OptiStatsCore

/// Sensores de temperatura HID (Apple Silicon) por API PRIVADA, resolvida em tempo de execução com dlopen/dlsym.
/// Se qualquer símbolo faltar, `isAvailable` é falso e o chamador degrada (sem travar nem declarar valores).
/// Abordagem de matching (PrimaryUsagePage 0xff00 / PrimaryUsage 5, evento tipo 15) adaptada do Stats (MIT).
final class HIDTemperatureSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyPropertyFn = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias FloatValueFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private static let eventTypeTemperature: Int64 = 15
    private static let fieldTemperatureLevel: Int32 = Int32(15 << 16)

    private let create: CreateFn?
    private let setMatching: SetMatchingFn?
    private let copyServices: CopyServicesFn?
    private let copyProperty: CopyPropertyFn?
    private let copyEvent: CopyEventFn?
    private let floatValue: FloatValueFn?
    private var client: UnsafeMutableRawPointer?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        func sym<T>(_ name: String, as _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        create = sym("IOHIDEventSystemClientCreate", as: CreateFn.self)
        setMatching = sym("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self)
        copyServices = sym("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
        copyProperty = sym("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self)
        copyEvent = sym("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        floatValue = sym("IOHIDEventGetFloatValue", as: FloatValueFn.self)
    }

    deinit { release() }

    var isAvailable: Bool {
        create != nil && setMatching != nil && copyServices != nil && copyProperty != nil && copyEvent != nil && floatValue != nil
    }

    /// Libera o cliente HID (recurso caro). Recriado na próxima leitura.
    func release() {
        if let c = client { Unmanaged<AnyObject>.fromOpaque(c).release(); client = nil }
    }

    private func ensureClient() -> UnsafeMutableRawPointer? {
        if let client { return client }
        guard let create, let setMatching, isAvailable, let c = create(kCFAllocatorDefault) else { return nil }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(c, matching as CFDictionary)
        client = c
        return c
    }

    /// Lê (nome do produto, °C) de todos os sensores de temperatura HID. Vazio se indisponível.
    func readTemperatures() -> [(product: String, celsius: Double)] {
        guard let copyServices, let copyProperty, let copyEvent, let floatValue, let c = ensureClient(),
              let rawArray = copyServices(c) else { return [] }
        let services = Unmanaged<CFArray>.fromOpaque(rawArray).takeRetainedValue()
        var out: [(String, Double)] = []
        for i in 0..<CFArrayGetCount(services) {
            guard let sp = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = UnsafeMutableRawPointer(mutating: sp)
            var product = ""
            if let rawName = copyProperty(service, "Product" as CFString) {
                product = (Unmanaged<AnyObject>.fromOpaque(rawName).takeRetainedValue() as? String) ?? ""
            }
            guard !product.isEmpty, let rawEvent = copyEvent(service, Self.eventTypeTemperature, 0, 0) else { continue }
            let value = floatValue(rawEvent, Self.fieldTemperatureLevel)
            Unmanaged<AnyObject>.fromOpaque(rawEvent).release()
            out.append((product, value))
        }
        return out
    }
}

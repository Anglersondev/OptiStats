import Foundation
import Darwin
import SystemConfiguration
import OptiStatsCore

/// Rede: contadores de 64 bits por interface via `sysctl NET_RT_IFLIST2` (os de 32 bits de getifaddrs dão a volta em 4 GB).
/// O total só soma interfaces físicas ativas (Wi-Fi/Ethernet/celular) para não contar VPN/túnel/bridge em duplicidade.
final class NetworkCollector: BaseCollector {
    private struct Counters { var rx: UInt64; var tx: UInt64; var flags: Int32; var name: String }
    private var rxRates: [String: CounterRate] = [:]
    private var txRates: [String: CounterRate] = [:]
    private var baseline: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var kinds: [String: NetworkKind] = [:]
    private var seenNames: Set<String> = []

    init(store: MetricsStore, clock: MonotonicClock) { super.init(id: .network, store: store, clock: clock) }

    override func collect() {
        guard let list = Self.readCounters() else { markFailed(L("platform.reason.networkFailed")); return }
        let now = clock.now
        let names = Set(list.map(\.name))
        if !names.isSubset(of: seenNames) { refreshKinds(); seenNames.formUnion(names) }

        var rows: [NetworkInterfaceRate] = []
        var sumRx = 0.0, sumTx = 0.0, anyRate = false
        for c in list {
            let ifKind = kindOf(c.name)
            guard ifKind != .other || c.name.hasPrefix("en") else { continue }   // ignora awdl/llw/anpi/loopback…
            let up = (c.flags & Int32(IFF_UP)) != 0 && (c.flags & Int32(IFF_RUNNING)) != 0
            if baseline[c.name] == nil { baseline[c.name] = (c.rx, c.tx) }
            let base = baseline[c.name]!
            let rxr = rxRates[c.name] ?? CounterRate(); rxRates[c.name] = rxr
            let txr = txRates[c.name] ?? CounterRate(); txRates[c.name] = txr
            let rx = rxr.update(c.rx, at: now), tx = txr.update(c.tx, at: now)
            if up && (ifKind == .wifi || ifKind == .ethernet || ifKind == .cellular || ifKind == .other),
               let rx, let tx { sumRx += rx; sumTx += tx; anyRate = true }
            // Interfaces sem tráfego desde o início e inativas não poluem a lista.
            if !up && c.rx == base.rx && c.tx == base.tx && c.rx == 0 && c.tx == 0 { continue }
            rows.append(NetworkInterfaceRate(id: c.name, kind: ifKind, isUp: up, rxBytesPerSecond: rx, txBytesPerSecond: tx,
                                             totalRxBytes: c.rx >= base.rx ? c.rx - base.rx : 0,
                                             totalTxBytes: c.tx >= base.tx ? c.tx - base.tx : 0))
        }
        store.publish(network: NetworkSnapshot(timestamp: now, interfaces: rows,
                                               rxBytesPerSecond: anyRate ? sumRx : nil,
                                               txBytesPerSecond: anyRate ? sumTx : nil))
        markAvailable()
    }

    override func suspend() {
        for r in rxRates.values { r.reset() }
        for r in txRates.values { r.reset() }
    }

    private func kindOf(_ name: String) -> NetworkKind {
        if let k = kinds[name] { return k }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { return .vpn }
        if name.hasPrefix("bridge") { return .bridge }
        return .other
    }

    /// Tipo da interface pelo SystemConfiguration (Wi-Fi vs Ethernet); consultado só quando surge interface nova.
    private func refreshKinds() {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        let typeMap: [String: NetworkKind] = [
            kSCNetworkInterfaceTypeIEEE80211 as String: .wifi,
            kSCNetworkInterfaceTypeEthernet as String: .ethernet,
            kSCNetworkInterfaceTypeBridge as String: .bridge,
            kSCNetworkInterfaceTypePPP as String: .vpn,
            kSCNetworkInterfaceTypeVPN as String: .vpn,
            kSCNetworkInterfaceTypeL2TP as String: .vpn,
            kSCNetworkInterfaceTypeIPSec as String: .vpn,
            kSCNetworkInterfaceTypeWWAN as String: .cellular
        ]
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String? else { continue }
            kinds[bsd] = typeMap[type] ?? .other
        }
    }

    private static func readCounters() -> [Counters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var out: [Counters] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(header.ifm_msglen)
                guard msgLen > 0, offset + msgLen <= length else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, msgLen >= MemoryLayout<if_msghdr2>.size {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &nameBuf) != nil {
                        let name = String(decoding: nameBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if (h2.ifm_flags & Int32(IFF_LOOPBACK)) == 0 {
                            out.append(Counters(rx: h2.ifm_data.ifi_ibytes, tx: h2.ifm_data.ifi_obytes,
                                                flags: h2.ifm_flags, name: name))
                        }
                    }
                }
                offset += msgLen
            }
        }
        return out
    }
}

import Foundation

/// Classe de núcleo conforme `cluster-type` do IORegistry e/ou nome do `hw.perflevelN`.
/// Em chips mais novos há mais de duas classes (ex.: "Super", "Performance", "Efficiency"),
/// por isso o modelo é genérico e não presume apenas E/P.
public struct CoreClass: Hashable, Codable {
    public var key: String        // "E", "P", "M", "S", ... (cluster-type) ou "perflevelN"
    public var name: String       // nome apresentável (ex.: "Efficiency")
    public init(key: String, name: String) { self.key = key; self.name = name }
}

public struct PerfLevel: Equatable {
    public var index: Int
    public var name: String
    public var logicalCPUs: Int
    public init(index: Int, name: String, logicalCPUs: Int) {
        self.index = index; self.name = name; self.logicalCPUs = logicalCPUs
    }
}

public struct CPUNode: Equatable {
    public var logicalIndex: Int
    public var clusterType: String?   // "E"/"P"/... lido do IORegistry, se existir
    public init(logicalIndex: Int, clusterType: String?) {
        self.logicalIndex = logicalIndex; self.clusterType = clusterType
    }
}

public enum TopologyConfidence: Equatable {
    /// Contagens do IORegistry batem com `hw.perflevelN`: rótulos podem ser exibidos.
    case verified
    /// Não foi possível validar: exibir total e núcleos sem rótulos E/P.
    case unverified(reason: String)
}

public struct CoreTopology: Equatable {
    public var logicalCPUCount: Int
    public var physicalCPUCount: Int
    public var classes: [CoreClass: [Int]]   // índices lógicos por classe
    public var confidence: TopologyConfidence

    public var hasTrustedClasses: Bool {
        if case .verified = confidence, !classes.isEmpty { return true }
        return false
    }

    /// Classes em ordem estável (mais eficiente primeiro, como o Monitor de Atividade lista).
    public var orderedClasses: [CoreClass] {
        classes.keys.sorted { a, b in
            func rank(_ k: String) -> Int {
                switch k { case "E": return 0; case "M": return 1; case "P": return 2; case "S": return 3; default: return 4 }
            }
            return (rank(a.key), a.key) < (rank(b.key), b.key)
        }
    }

    /// Constrói e valida a topologia. Nunca assume que a sequência de índices identifica E/P.
    public static func build(logicalCPUCount: Int, physicalCPUCount: Int,
                             nodes: [CPUNode], perfLevels: [PerfLevel],
                             nameForClusterKey: (String) -> String = defaultName) -> CoreTopology {
        func unverified(_ reason: String) -> CoreTopology {
            CoreTopology(logicalCPUCount: logicalCPUCount, physicalCPUCount: physicalCPUCount,
                         classes: [:], confidence: .unverified(reason: reason))
        }
        guard !nodes.isEmpty else { return unverified("IORegistry sem nós cpu*") }
        guard nodes.allSatisfy({ $0.clusterType != nil }) else { return unverified("cluster-type ausente em algum núcleo") }
        guard nodes.count == logicalCPUCount else {
            return unverified("nós (\(nodes.count)) ≠ CPUs lógicas (\(logicalCPUCount))")
        }
        var byKey: [String: [Int]] = [:]
        for n in nodes { byKey[n.clusterType!, default: []].append(n.logicalIndex) }

        // Validação cruzada: o multiconjunto de contagens por classe deve igualar o dos perflevels.
        guard !perfLevels.isEmpty else { return unverified("hw.perflevel indisponível para validar") }
        let nodeCounts = byKey.values.map(\.count).sorted()
        let levelCounts = perfLevels.map(\.logicalCPUs).sorted()
        guard nodeCounts == levelCounts else {
            return unverified("contagens por classe \(nodeCounts) ≠ perflevels \(levelCounts)")
        }
        var classes: [CoreClass: [Int]] = [:]
        for (key, idx) in byKey {
            classes[CoreClass(key: key, name: nameForClusterKey(key))] = idx.sorted()
        }
        return CoreTopology(logicalCPUCount: logicalCPUCount, physicalCPUCount: physicalCPUCount,
                            classes: classes, confidence: .verified)
    }

    public static func defaultName(_ key: String) -> String {
        switch key {
        case "E": return "Efficiency"
        case "P": return "Performance"
        case "M": return "Performance"
        case "S": return "Super"
        default: return key
        }
    }

    /// Uso médio (0...1) por classe, a partir do uso por CPU lógica. Só quando a topologia é confiável.
    public func usage(perCore: [Double]) -> [(CoreClass, Double)] {
        guard hasTrustedClasses else { return [] }
        return orderedClasses.compactMap { cls in
            let values = (classes[cls] ?? []).compactMap { perCore.indices.contains($0) ? perCore[$0] : nil }
            guard !values.isEmpty else { return nil }
            return (cls, values.reduce(0, +) / Double(values.count))
        }
    }
}

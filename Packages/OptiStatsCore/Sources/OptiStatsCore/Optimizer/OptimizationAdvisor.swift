import Foundation

public struct AdvisorConfig: Equatable {
    public var swapLowBytes: UInt64 = 512 * 1024 * 1024
    /// Pressão (≥ atenção) precisa persistir por este tempo para recomendar ação.
    public var sustainedPressureSeconds: TimeInterval = 120
    public var activeSwapOutsPerSecond: Double = 5
    public var candidateMinFootprint: UInt64 = 300 * 1024 * 1024
    public var maxCandidates = 6
    public init() {}
}

public enum AssessmentReason: Equatable {
    case pressure(PressureBand)
    case swapInUse(bytes: UInt64)
    case activeSwapping(outsPerSecond: Double)
    case sustainedGrowth(groupName: String)
}

public enum MemoryAssessment: Equatable {
    /// "Sua memória está saudável; nenhuma ação necessária."
    case healthy
    /// Sinais leves: informar, sem recomendar encerramentos.
    case watch(reasons: [AssessmentReason])
    /// Pressão sustentada ou swap ativo: listar candidatos escolhíveis pelo usuário.
    case actionRecommended(reasons: [AssessmentReason])
    /// Sem dados confiáveis (ex.: pressão indisponível).
    case insufficientData
}

public enum RiskNote: Equatable {
    case mayLoseUnsavedWork
    case mayInterruptMedia
    case mayInterruptDownloads
    case manyHelpersShared      // vários processos auxiliares: o ganho real pode ser menor
    case growthSuspected
}

public struct ReclaimCandidate: Equatable {
    public var group: AppGroup
    /// LIMITE SUPERIOR rotulado como estimativa: footprint do grupo. O ganho real em "disponível" pode ser menor.
    public var estimatedReclaimBytes: UInt64
    public var risks: [RiskNote]
    public var growth: GrowthSuspicion?
}

public struct ProtectedEntry: Equatable {
    public var group: AppGroup
    public var verdict: ProtectionVerdict
}

public struct Advice: Equatable {
    public var assessment: MemoryAssessment
    public var candidates: [ReclaimCandidate]
    /// Maiores consumidores que NÃO podem ser sugeridos (e por quê).
    public var protectedTop: [ProtectedEntry]
}

public struct OptimizationAdvisor {
    public var config: AdvisorConfig
    public var policy: ProtectionPolicy
    public init(config: AdvisorConfig = AdvisorConfig(), policy: ProtectionPolicy = ProtectionPolicy()) {
        self.config = config; self.policy = policy
    }

    /// - Parameters:
    ///   - history: fotos recentes de memória (mais antiga → mais nova) para avaliar persistência.
    ///   - frontmostBundleID: app em primeiro plano agora.
    public func advise(history: [MemorySnapshot], groups: [AppGroup], growth: (String) -> GrowthSuspicion?,
                       frontmostBundleID: String?) -> Advice {
        guard let latest = history.last, latest.pressure != nil else {
            return Advice(assessment: .insufficientData, candidates: [], protectedTop: [])
        }
        var reasons: [AssessmentReason] = []
        let band = PressureBand(latest.pressure)

        // Persistência da pressão: todas as fotos da janela em ≥ atenção.
        let window = history.filter { $0.timestamp >= latest.timestamp - config.sustainedPressureSeconds }
        let span = (window.first.map { latest.timestamp - $0.timestamp }) ?? 0
        let sustained = band != .normal && span >= config.sustainedPressureSeconds * 0.8
            && window.allSatisfy { ($0.pressure ?? .normal) >= .warning }
        if band != .normal { reasons.append(.pressure(band)) }

        let swapUsed = latest.swap?.usedBytes ?? 0
        if swapUsed > config.swapLowBytes { reasons.append(.swapInUse(bytes: swapUsed)) }

        var activeSwapping = false
        if history.count >= 2, let rates = MemoryRates.between(history[max(0, history.count - 3)], latest),
           rates.swapOutsPerSecond >= config.activeSwapOutsPerSecond {
            reasons.append(.activeSwapping(outsPerSecond: rates.swapOutsPerSecond)); activeSwapping = true
        }

        var candidates: [ReclaimCandidate] = []
        var protectedTop: [ProtectedEntry] = []
        for g in groups {
            let ctx = AppRuntimeContext(isFrontmost: g.bundleIdentifier != nil && g.bundleIdentifier == frontmostBundleID)
            let verdict = policy.verdict(for: g, context: ctx)
            let suspicion = growth(g.id)
            if suspicion != nil { reasons.append(.sustainedGrowth(groupName: g.displayName)) }
            if verdict.isProtected {
                if protectedTop.count < 5, g.footprintBytes >= config.candidateMinFootprint {
                    protectedTop.append(ProtectedEntry(group: g, verdict: verdict))
                }
                continue
            }
            guard g.footprintBytes >= config.candidateMinFootprint else { continue }
            var risks: [RiskNote] = [.mayLoseUnsavedWork]
            if g.processCount > 4 { risks.append(.manyHelpersShared) }
            if suspicion != nil { risks.append(.growthSuspected) }
            candidates.append(ReclaimCandidate(group: g, estimatedReclaimBytes: g.footprintBytes, risks: risks, growth: suspicion))
        }
        // Suspeitos primeiro, depois maiores.
        candidates.sort {
            let a = $0.growth != nil, b = $1.growth != nil
            return a != b ? a : $0.estimatedReclaimBytes > $1.estimatedReclaimBytes
        }
        candidates = Array(candidates.prefix(config.maxCandidates))

        let assessment: MemoryAssessment
        if sustained || activeSwapping {
            assessment = .actionRecommended(reasons: dedupe(reasons))
        } else if band == .normal && swapUsed <= config.swapLowBytes && !reasons.contains(where: {
            if case .sustainedGrowth = $0 { return true } else { return false } }) {
            assessment = .healthy
        } else {
            assessment = .watch(reasons: dedupe(reasons))
        }
        // Sem pressão sustentada, não há candidatos "recomendados".
        let shown: [ReclaimCandidate]
        if case .actionRecommended = assessment { shown = candidates } else { shown = [] }
        return Advice(assessment: assessment, candidates: shown, protectedTop: protectedTop)
    }

    private func dedupe(_ r: [AssessmentReason]) -> [AssessmentReason] {
        var out: [AssessmentReason] = []
        for x in r where !out.contains(x) { out.append(x) }
        return out
    }
}

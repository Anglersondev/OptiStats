import Foundation

public enum ServiceRisk: String, Codable { case low, medium, high }
public enum ServiceDomain: String, Codable { case user, system }

/// Serviço launchd conhecido e descrito. Só serviços catalogados podem ser alterados pelo app.
public struct CatalogService: Equatable, Codable {
    public let label: String
    public let titleKey: String            // chave de localização
    public let domain: ServiceDomain
    public let risk: ServiceRisk
    public let warningKey: String?
    public init(label: String, titleKey: String, domain: ServiceDomain, risk: ServiceRisk, warningKey: String? = nil) {
        self.label = label; self.titleKey = titleKey; self.domain = domain; self.risk = risk; self.warningKey = warningKey
    }
}

/// Catálogo curado, conservador. NÃO inclui iCloud, App Store, atualizações, rede, segurança, áudio nem Finder/Dock.
/// Os rótulos vêm de serviços Apple de uso opcional; o conjunto inicial é pequeno de propósito e deve crescer com validação.
public enum ServiceCatalog {
    public static let all: [CatalogService] = [
        .init(label: "com.apple.Siri.agent", titleKey: "debloat.svc.siri", domain: .user, risk: .medium, warningKey: "debloat.warn.siriIcloud"),
        .init(label: "com.apple.assistantd", titleKey: "debloat.svc.assistant", domain: .user, risk: .medium),
        .init(label: "com.apple.photoanalysisd", titleKey: "debloat.svc.photoAnalysis", domain: .user, risk: .low),
        .init(label: "com.apple.mediaanalysisd", titleKey: "debloat.svc.mediaAnalysis", domain: .user, risk: .low),
        .init(label: "com.apple.suggestd", titleKey: "debloat.svc.suggestions", domain: .user, risk: .low),
        .init(label: "com.apple.knowledgeconstructiond", titleKey: "debloat.svc.knowledge", domain: .user, risk: .low),
        .init(label: "com.apple.parsecd", titleKey: "debloat.svc.searchSuggestions", domain: .user, risk: .low),
        .init(label: "com.apple.news.widget", titleKey: "debloat.svc.news", domain: .user, risk: .low),
        .init(label: "com.apple.gamed", titleKey: "debloat.svc.gameCenter", domain: .user, risk: .low),
        .init(label: "com.apple.ScreenTimeAgent", titleKey: "debloat.svc.screenTime", domain: .user, risk: .medium, warningKey: "debloat.warn.screenTime"),
        .init(label: "com.apple.ReportCrash", titleKey: "debloat.svc.crashReporter", domain: .user, risk: .low)
    ]
    public static func service(_ label: String) -> CatalogService? { all.first { $0.label == label } }
}

/// Estado de um serviço no domínio do usuário (lido de `launchctl print-disabled gui/<uid>`).
public enum ServiceState: String, Codable { case enabled, disabled, unknown }

public struct DisabledTable {
    /// Interpreta a saída de `launchctl print-disabled gui/<uid>`: linhas `"label" => disabled|enabled|true|false`.
    public static func parse(_ output: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=>", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].hasPrefix("\""), parts[0].hasSuffix("\"") else { continue }
            let label = String(parts[0].dropFirst().dropLast())
            let v = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ",; "))
            switch v { case "disabled", "true": out[label] = true; case "enabled", "false": out[label] = false; default: break }
        }
        return out
    }
}

/// Plano de debloat. Só gera comandos para serviços do USUÁRIO (sem sudo). Os de sistema só viram texto para o usuário.
public struct DebloatPlanner {
    public let uid: UInt32
    public init(uid: UInt32) { self.uid = uid }

    public func state(of label: String, table: [String: Bool]) -> ServiceState {
        guard let d = table[label] else { return .unknown }
        return d ? .disabled : .enabled
    }

    public func disableCommand(_ s: CatalogService) -> [String]? {
        guard s.domain == .user, ServiceCatalog.service(s.label) == s else { return nil }
        return ["launchctl", "disable", "gui/\(uid)/\(s.label)"]
    }
    public func enableCommand(_ s: CatalogService) -> [String]? {
        guard s.domain == .user, ServiceCatalog.service(s.label) == s else { return nil }
        return ["launchctl", "enable", "gui/\(uid)/\(s.label)"]
    }
    /// Texto copiável para o usuário rodar por conta própria (serviços de sistema).
    public func manualCommand(_ s: CatalogService, disable: Bool) -> String {
        "sudo launchctl \(disable ? "disable" : "enable") system/\(s.label)"
    }
}

/// Snapshot para restaurar o estado anterior.
public struct DebloatSnapshot: Codable, Equatable {
    public var date: Date
    public var previouslyDisabled: [String]   // rótulos que JÁ estavam desativados antes (não reativar)
    public var changed: [String]              // rótulos que o app desativou
    public init(date: Date, previouslyDisabled: [String], changed: [String]) {
        self.date = date; self.previouslyDisabled = previouslyDisabled; self.changed = changed
    }
    /// Rótulos a reativar ao restaurar: só os que o app mudou.
    public var toRestore: [String] { changed.filter { !previouslyDisabled.contains($0) } }
}

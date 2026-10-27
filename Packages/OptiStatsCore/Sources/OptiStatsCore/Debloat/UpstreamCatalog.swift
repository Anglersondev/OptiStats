import Foundation

// Catálogo do projeto mac-os-debloat (https://github.com/OleksandrKrupko/mac-os-debloat, MIT, (c) 2026 Oleksandr Krupko).
// Este arquivo só interpreta o texto do catálogo (EMBEDDED_LABELS do autor); não executa nada.

/// Presets do autor: `telemetry` ⊂ `balanced` ⊂ `all` (disable-all).
public enum DebloatPreset: String, Codable, CaseIterable { case telemetry, balanced, all }

/// Marca de preset de uma seção do catálogo. `none` = só entra em disable-all.
public enum SectionPreset: String, Codable { case telemetry, balanced, none }

/// Avisos fixos (derivados do label) sobre serviços que quebram recursos importantes.
public enum DebloatWarning: String, Codable, CaseIterable {
    case icloud, appStore, softwareUpdate, mobileAsset, keychain, airplay
}

public struct UpstreamItem: Equatable, Codable {
    public let label: String
    public let comment: String
    public let sipOff: Bool
    public let sectionTitle: String
    public let sectionPreset: SectionPreset

    public init(label: String, comment: String, sipOff: Bool, sectionTitle: String, sectionPreset: SectionPreset) {
        self.label = label; self.comment = comment; self.sipOff = sipOff
        self.sectionTitle = sectionTitle; self.sectionPreset = sectionPreset
    }

    /// Avisos fixos por substring do label (sem diferenciar maiúsculas).
    public var warnings: [DebloatWarning] {
        let l = label.lowercased()
        var out: [DebloatWarning] = []
        if l.contains("icloud") || l.contains("cloudd") || l.contains("bird") { out.append(.icloud) }
        if l.contains("appstore") { out.append(.appStore) }
        if l.contains("softwareupdate") { out.append(.softwareUpdate) }
        if l.contains("mobileasset") { out.append(.mobileAsset) }
        if l.contains("keychain") { out.append(.keychain) }
        if l.contains("airplay") { out.append(.airplay) }
        return out
    }

    /// telemetry = baixo; balanced = médio; só disable-all = alto. Qualquer aviso fixo eleva para alto.
    public var risk: ServiceRisk {
        if !warnings.isEmpty { return .high }
        switch sectionPreset {
        case .telemetry: return .low
        case .balanced: return .medium
        case .none: return .high
        }
    }
}

public struct UpstreamSection: Equatable, Codable {
    public let title: String
    public let preset: SectionPreset
    /// Versão mínima do macOS indicada por `[macos>=27]` (nil = qualquer).
    public let minMacOS: Int?
    public var items: [UpstreamItem]
    public init(title: String, preset: SectionPreset, minMacOS: Int?, items: [UpstreamItem] = []) {
        self.title = title; self.preset = preset; self.minMacOS = minMacOS; self.items = items
    }
}

public struct CatalogDiff: Equatable {
    public let added: [String]
    public let removed: [String]
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    public init(added: [String], removed: [String]) { self.added = added; self.removed = removed }
}

public struct UpstreamCatalog: Equatable {
    public let sections: [UpstreamSection]
    public init(sections: [UpstreamSection]) { self.sections = sections }

    public var items: [UpstreamItem] { sections.flatMap { $0.items } }
    public func item(_ label: String) -> UpstreamItem? { items.first { $0.label == label } }
    public func contains(_ item: UpstreamItem) -> Bool { self.item(item.label) == item }

    /// Itens de um preset. `balanced` inclui `telemetry`; `all` inclui tudo.
    public func presetItems(_ preset: DebloatPreset) -> [UpstreamItem] {
        items.filter { i in
            switch preset {
            case .all: return true
            case .balanced: return i.sectionPreset != .none
            case .telemetry: return i.sectionPreset == .telemetry
            }
        }
    }

    public func diff(from old: UpstreamCatalog) -> CatalogDiff { Self.diff(old: old, new: self) }

    public static func diff(old: UpstreamCatalog, new: UpstreamCatalog) -> CatalogDiff {
        let o = Set(old.items.map { $0.label }), n = Set(new.items.map { $0.label })
        return CatalogDiff(added: n.subtracting(o).sorted(), removed: o.subtracting(n).sorted())
    }

    /// Só `[A-Za-z0-9._-]`, não vazio. Qualquer outra coisa é rejeitada (nunca vira argumento de comando).
    public static func isValidLabel(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 200 else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122)
                || c == "." || c == "_" || c == "-"
        }
    }

    // MARK: Parser

    /// Interpreta o texto do catálogo. Cabeçalho de seção: `# === Título [balanced|telemetry] [macos>=27] ===`.
    /// Item: `label [sip-off]   # comentário`. Demais linhas `#` são comentários. Labels inválidos ou repetidos são ignorados.
    public static func parse(_ text: String) -> UpstreamCatalog {
        var sections: [UpstreamSection] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let header = parseHeader(line) { sections.append(header) }
                continue
            }
            // Item. Antes do primeiro "#": label + tags; depois: comentário.
            var head = line, comment = ""
            if let hash = line.firstIndex(of: "#") {
                head = String(line[line.startIndex..<hash])
                comment = String(line[line.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            }
            let tokens = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let label = tokens.first, isValidLabel(label), !seen.contains(label) else { continue }
            if sections.isEmpty { sections.append(UpstreamSection(title: "", preset: .none, minMacOS: nil)) }
            let sip = tokens.dropFirst().contains { $0.lowercased() == "[sip-off]" }
            seen.insert(label)
            let idx = sections.count - 1
            sections[idx].items.append(UpstreamItem(label: label, comment: comment, sipOff: sip,
                                                    sectionTitle: sections[idx].title, sectionPreset: sections[idx].preset))
        }
        return UpstreamCatalog(sections: sections.filter { !$0.items.isEmpty })
    }

    private static func parseHeader(_ line: String) -> UpstreamSection? {
        guard line.hasPrefix("# ===") else { return nil }
        var body = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        while body.hasSuffix("=") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)
        var preset: SectionPreset = .none
        var minMacOS: Int?
        // Tags `[...]` no fim do título.
        while body.hasSuffix("]"), let open = body.lastIndex(of: "[") {
            let tag = body[body.index(after: open)..<body.index(before: body.endIndex)].lowercased()
            if tag == "balanced" { preset = .balanced }
            else if tag == "telemetry" { preset = .telemetry }
            else if tag.hasPrefix("macos>="), let v = Int(tag.dropFirst(7)) { minMacOS = v }
            else { break }
            body = String(body[body.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !body.isEmpty else { return nil }
        return UpstreamSection(title: body, preset: preset, minMacOS: minMacOS)
    }

    // MARK: Script do autor

    /// Extrai o conteúdo do bloco `EMBEDDED_LABELS = """\ ... """` do script Python `debloat`.
    /// Devolve nil se o bloco não existir ou não contiver nenhum item válido.
    public static func extractEmbeddedLabels(fromScript script: String) -> String? {
        guard let name = script.range(of: "EMBEDDED_LABELS") else { return nil }
        guard let open = script.range(of: "\"\"\"", range: name.upperBound..<script.endIndex) else { return nil }
        var start = open.upperBound
        if script[start...].hasPrefix("\\\r\n") { start = script.index(start, offsetBy: 3) }
        else if script[start...].hasPrefix("\\\n") { start = script.index(start, offsetBy: 2) }
        guard let close = script.range(of: "\"\"\"", range: start..<script.endIndex) else { return nil }
        let block = String(script[start..<close.lowerBound])
        return parse(block).items.isEmpty ? nil : block
    }
}

public extension ServiceDomain {
    /// Domínio decidido pela localização do plist: LaunchDaemons → sistema; LaunchAgents → usuário (gui/<uid>).
    static func forPlist(atPath path: String) -> ServiceDomain? {
        if path.contains("/LaunchDaemons/") { return .system }
        if path.contains("/LaunchAgents/") { return .user }
        return nil
    }
}

public extension DebloatPlanner {
    /// Comando para um item do catálogo upstream. `nil` se o item não está no catálogo carregado, se o label tem
    /// caracteres inválidos, ou se o nível não permite o domínio (`auditOnly` nunca gera comando; `user` nunca toca o sistema).
    func disableCommand(_ item: UpstreamItem, domain: ServiceDomain, in catalog: UpstreamCatalog, level: Level) -> [String]? {
        upstreamCommand("disable", item, domain, catalog, level)
    }
    func enableCommand(_ item: UpstreamItem, domain: ServiceDomain, in catalog: UpstreamCatalog, level: Level) -> [String]? {
        upstreamCommand("enable", item, domain, catalog, level)
    }
    func manualCommand(_ item: UpstreamItem, domain: ServiceDomain, disable: Bool) -> String? {
        guard UpstreamCatalog.isValidLabel(item.label) else { return nil }
        let verb = disable ? "disable" : "enable"
        return domain == .system ? "sudo launchctl \(verb) system/\(item.label)" : "launchctl \(verb) gui/\(uid)/\(item.label)"
    }

    private func upstreamCommand(_ verb: String, _ item: UpstreamItem, _ domain: ServiceDomain,
                                 _ catalog: UpstreamCatalog, _ level: Level) -> [String]? {
        guard catalog.contains(item), UpstreamCatalog.isValidLabel(item.label) else { return nil }
        switch (level, domain) {
        case (.auditOnly, _), (.user, .system): return nil
        case (.user, .user), (.system, .user): return ["launchctl", verb, "gui/\(uid)/\(item.label)"]
        case (.system, .system): return ["launchctl", verb, "system/\(item.label)"]
        }
    }
}

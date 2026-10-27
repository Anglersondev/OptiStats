import Foundation
import OptiStatsCore

/// Localização com troca de idioma em tempo de execução (Automático / PT-BR / EN) sem reiniciar.
/// As strings ficam em tabelas separadas por área para que várias pessoas editem sem conflito.
final class Localizer {
    static let shared = Localizer()

    /// Ordem de busca. Cada área mantém o seu `.strings` (en.lproj e pt-BR.lproj).
    static let tables = ["Common", "Shell", "Popovers", "Platform"]

    private(set) var language: LanguageChoice = .system
    private(set) var locale: Locale = Locale.current
    private var primary: Bundle = Bundle.main
    private var fallback: Bundle = Bundle.main

    private init() { configure(language: .system) }

    func configure(language: LanguageChoice) {
        self.language = language
        let code: String
        switch language {
        case .ptBR: code = "pt-BR"
        case .en: code = "en"
        case .system:
            let preferred = Bundle.main.preferredLocalizations.first ?? "en"
            code = preferred.hasPrefix("pt") ? "pt-BR" : "en"
        }
        primary = Localizer.lprojBundle(code)
        fallback = Localizer.lprojBundle("en")
        locale = Locale(identifier: code.replacingOccurrences(of: "-", with: "_"))
    }

    static func lprojBundle(_ code: String) -> Bundle {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) { return b }
        return Bundle.main
    }

    func string(_ key: String) -> String {
        for bundle in [primary, fallback] {
            for table in Localizer.tables {
                let v = bundle.localizedString(forKey: key, value: nil, table: table)
                if v != key { return v }
            }
        }
        return key   // chave visível = string faltando (detectável em revisão)
    }
}

/// Atalhos: `L("ram.title")`, `L("ram.used", "16,7 GB")` (printf-style).
func L(_ key: String) -> String { Localizer.shared.string(key) }
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.string(key), locale: Localizer.shared.locale, arguments: args)
}

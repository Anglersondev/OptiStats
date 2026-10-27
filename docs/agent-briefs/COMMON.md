# Brief comum (OptiStats)
Repo: /home/claude/OptiStats (Swift 5 mode, macOS 13+, AppKit, sem SwiftUI). Spec: /root/.claude/uploads/99dc9c7a-cce9-5f04-8728-d73e69020b64/765762e4-PROMPT-MESTRE-OPTISTATS.md.
Referência MIT (adaptar com crédito, nunca copiar cegamente): clone de exelban/stats (procure em /tmp ou /mnt/project-files/optistats).
Regras:
- Leia primeiro: Packages/OptiStatsCore/Sources/OptiStatsCore/Platform/PlatformContracts.swift, Store/*, Sampling/*, Sensors/*, Preferences/*, e App/OptiStats/Services/AppEnvironment.swift e UI/Kit/*.
- NÃO altere o pacote OptiStatsCore sem necessidade; se precisar, mudança mínima e aditiva e avise no relatório. Rode `swift test` (toolchain: PATH=/tmp/claude-0/swiftdeb/root/usr/libexec/swift/bin; LD_LIBRARY_PATH=/tmp/claude-0/swiftdeb/root/usr/lib/x86_64-linux-gnu:/tmp/claude-0/swiftdeb/root/usr/lib:/tmp/claude-0/swiftdeb/root/usr/lib/swift/linux) — 132 testes devem continuar passando.
- Não há macOS aqui: o código de App/ não compila neste container. Escreva com extremo cuidado (APIs reais, sem inventar símbolos); revise duas vezes. APIs privadas só via dlopen/dlsym, com degradação para .unsupported. Sem escrita em SMC/ventoinhas. Sem telemetria. Sem processos residentes extras.
- Textos de UI via L("chave") (Localizer); adicione chaves em Resources/en.lproj e Resources/pt-BR.lproj (.strings) com o mesmo conjunto de chaves nos dois idiomas, em arquivo próprio da sua área para evitar conflito.
- Baixo consumo: nada de timers próprios; tudo pelo SamplingCoordinator/demanda.
- Escreva só nos diretórios da sua área. Não faça git commit. Termine com relatório curto: arquivos, decisões, riscos não validados.

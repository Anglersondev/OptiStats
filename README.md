# OptiStats (nome provisório)

Monitor nativo de barra de menus para macOS em Apple Silicon (M1 a M6) com gerenciador de RAM honesto. Swift + AppKit, 100% local, sem telemetria, sem helper privilegiado.

> **Estado atual (v1.0 em validação):** o núcleo (`Packages/OptiStatsCore`) tem 132 testes automatizados que passam em Linux. A camada AppKit/IOKit (`App/OptiStats`) foi escrita sem acesso a um Mac e **ainda não foi compilada nem testada em hardware real**. Veja `docs/INVENTARIO-FUNCIONALIDADES.md`. As metas de ≤60 MB de RAM e ≤1% de CPU em repouso **não foram medidas**.

## Recursos
- Indicadores personalizáveis na barra: CPU, GPU, RAM, temperaturas, potência, ventoinhas, grupos E/P, disco, rede, bateria.
- Popovers com gráficos, sensores, processos agrupados por app, energia e bateria.
- Amostragem adaptativa central (perfis Econômico, Equilibrado, Tempo Real, Personalizado): fonte oculta não é lida.
- Detecção em tempo de execução do chip, topologia E/P e sensores (nada fixo para um modelo). Rótulos E/P só quando verificados.
- Gerenciador de RAM: analisa, recomenda e, **só após confirmação**, pede encerramento normal de apps escolhidos. Nunca força, nunca promete uma quantidade liberada; o relatório mostra a variação global antes/depois sem atribuí-la à ação.
- Ventoinhas: **somente leitura** na v1. Smart Boost existe como máquina de estados testada, mas o atuador real não está habilitado.
- PT-BR e EN, troca em tempo de execução.

## Compilar
Requer macOS 13+ e Xcode 15+.
```
python3 scripts/generate_xcodeproj.py   # regenera OptiStats.xcodeproj
open OptiStats.xcodeproj                # ou: xcodebuild -scheme OptiStats -configuration Release build
swift test --package-path Packages/OptiStatsCore
```
O app não usa sandbox (necessário para AppleSMC/IOReport). Assinatura: ad-hoc por padrão; defina sua equipe para distribuir.

## Medir desempenho
`scripts/benchmark.sh [duração] [processo]` com o Mac ocioso. Compare com o Stats nas mesmas funções e registre em `docs/BENCHMARK.md`.

## Licenças
Ver `THIRD_PARTY_NOTICES.md` (Stats, MIT) e `docs/AUDITORIA-STATS.md`. A licença do OptiStats em si é escolha do autor (pendente).

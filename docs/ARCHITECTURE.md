# Arquitetura
- **OptiStatsCore** (SwiftPM, só Foundation/Dispatch, testável em Linux): modelos, fórmulas de memória, CPU/topologia, sensores, SamplingCoordinator, MetricsStore, otimizador, Smart Boost (máquina de estados), preferências, diagnóstico, formatação da barra.
- **Platform** (App): coletores reais atrás de `PlatformServices` (sysctl, mach, libproc, IOKit, SMC leitura, HID/IOReport via dlsym).
- **Services/AppEnvironment**: raiz de composição.
- **Shell**: NSStatusItem por indicador, PopoverHost, menu de contexto, Sobre. **Preferences**: janela em abas. **Popovers**: um por módulo sobre `ModulePopoverViewController`.
Fluxo: consumidores declaram demanda (oculto/barra/popover) → coordinator agenda um único timer com coalescência → coletores em filas seriais → `MetricsStore` → UI (render com coalescência de 0,15 s).
Segurança: sem escrita SMC, sem rede, sem telemetria; encerramento de apps só gracioso e confirmado, revalidando PID + horário de início.

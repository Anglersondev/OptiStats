# Inventário de funcionalidades (v1.0)

Legenda: **F** funcional (lógica testada em Linux) · **C** condicional ao hardware · **N** não suportada · **NT** não testada em hardware real.
Estado atual: a lógica do núcleo (`OptiStatsCore`) é testada automaticamente; a camada AppKit/IOKit **ainda não foi compilada nem testada em um Mac** — todo item de UI/plataforma é **NT** até a validação por CI macOS e no MacBook.

| Recurso | Núcleo | Plataforma/UI |
|---|---|---|
| Fórmulas de memória, pressão, swap | F | NT |
| CPU total, E/P (só se topologia verificada) | F | C, NT |
| Temperaturas SMC/HID, agregados | F | C, NT |
| Potência (IOReport) | F | C, NT |
| Ventoinhas — leitura | F | C, NT |
| Smart Boost (máquina de estados) | F | **N** (atuador indisponível; v1 é somente leitura) |
| Otimização segura de RAM (saída graciosa, com confirmação) | F | NT |
| Relatório antes/depois sem falsa atribuição | F | NT |
| Amostragem adaptativa e perfis | F | NT |
| Indicadores na barra, popovers, preferências | F (formatação) | NT |
| PT-BR / EN | chaves verificadas por script | NT |
| Metas ≤60 MB / ≤1% CPU | — | **não medidas** (ver `scripts/benchmark.sh`) |

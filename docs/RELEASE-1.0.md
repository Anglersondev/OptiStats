# OptiStats 1.0

## English

Native macOS menu bar monitoring for Apple Silicon, built in Swift and AppKit by Anglerson.

- CPU, GPU, memory, temperatures, fans, power, disk, network and battery indicators.
- Adaptive sampling with shared collectors and bounded history.
- Optional Automatic, Manual, 100% and Smart Boost fan controls, gated by helper installation and validation on the current Mac.
- Preferences → About with credits and a donation link.
- RAM guidance, disk/cache maintenance and optional Debloat service management.
- Improvements that avoid UI waits on helper communication, reduce history copying and prevent output-pipe deadlocks during maintenance.
- English and Brazilian Portuguese, with bilingual documentation and website.

Inspired by [Stats by exelban](https://github.com/exelban/stats), with its own sampling architecture and additional maintenance tools. Debloat uses the service catalog, comments and presets from [mac-os-debloat by Oleksandr Krupko](https://github.com/OleksandrKrupko/mac-os-debloat). Third-party MIT notices are preserved.

**Requirements:** macOS 13 or later, Apple Silicon. Open the DMG and drag OptiStats to Applications. This build is ad-hoc signed and not Apple notarized.

**Validation:** the app and helper compile locally in Release mode, and targeted history, simulated SMC restoration and process-output regression checks pass. Complete CI needs to be rerun after GitHub access is restored. Physical fan response and whole-app CPU/RAM consumption still require testing on the target Mac. See `docs/FINAL-REVIEW.md` for exact scope and measurements.

## Português brasileiro

Monitor nativo para a barra de menus do macOS em Apple Silicon, feito em Swift e AppKit por Anglerson.

- Indicadores de CPU, GPU, memória, temperaturas, ventoinhas, potência, disco, rede e bateria.
- Amostragem adaptativa, coletores compartilhados e histórico limitado.
- Automático, Manual, 100% e Smart Boost opcionais para ventoinhas, após instalar o helper e validar o controle neste Mac.
- Preferências → Sobre com créditos e doação.
- Orientação de RAM, manutenção de disco/cache e Debloat opcional.
- Ajustes para evitar esperas da interface pelo helper, reduzir cópias do histórico e impedir bloqueio dos canais de saída na manutenção.
- Inglês e português brasileiro, com site e documentação nos dois idiomas.

Inspirado no [Stats, de exelban](https://github.com/exelban/stats), com arquitetura própria de amostragem e ferramentas adicionais. O Debloat usa o catálogo, comentários e presets do [mac-os-debloat, de Oleksandr Krupko](https://github.com/OleksandrKrupko/mac-os-debloat). Os avisos MIT de terceiros estão preservados.

**Requisitos:** macOS 13 ou posterior, Apple Silicon. Abra o DMG e arraste o app para Aplicativos. A assinatura é ad-hoc; o app não é notarizado pela Apple.

**Validação:** app e helper compilam localmente em Release e passaram nas verificações específicas de histórico, restauração SMC simulada e saída de comandos. O CI completo precisa ser reexecutado quando o acesso ao GitHub voltar. A resposta física das ventoinhas e o consumo total de CPU/RAM ainda dependem de teste no Mac de destino. O escopo e as medições estão em `docs/FINAL-REVIEW.md`.

[Support / Apoiar Anglerson ☕](https://pixgg.com/Anglerson)

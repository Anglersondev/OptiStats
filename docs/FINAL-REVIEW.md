# Verificação da versão 1.0, build 2

Data: 2 de novembro de 2026. Código em Swift/AppKit, sem novas dependências de runtime.

## Correções e evidência

- SMC simulado: 33 verificações cobrem controle partindo de automático, destravamento Ftst após escrita aceita sem efeito, limites separados por ventoinha, falhas, restauração confirmada em modo 0/3 e persistência por modelo. Rodar `scripts/check_hardware_regressions.sh`; não escreve no hardware.
- Núcleo: 199 testes passaram em macOS e Linux no [CI da primeira revisão](https://github.com/Anglersondev/OptiStats/actions/runs/41540663450), incluindo sensores, timestamps, alvos salvos e revisão de RAM.
- App e helper: compilados localmente para arm64/macOS 13 em Release com Command Line Tools; assinatura ad-hoc verificada. O CI também compilou Debug/Release e gerou DMG.
- Localização e site: scripts de validação aprovados para inglês/pt-BR, links locais, metadados, hreflang e dados estruturados.

## Hardware físico

MacBook Pro com Apple M4 Pro, modelo Mac16,8, macOS 27.2. Os comandos foram enviados ao helper instalado, versão de protocolo 1, build 4.

1. Ambas as ventoinhas estavam em 0 RPM. Pedido de 7.826 RPM para cada uma levou as leituras a aproximadamente 7.820 RPM, sem iniciar um workload pesado.
2. A restauração foi confirmada pelo helper com `manualActive=false`; o SMC retornou modos automáticos 3, Ftst=0, alvos=0 e posteriormente RPM=0.
3. Com intenção 100% temporariamente salva, reabrir o app aplicou alvos 7.826 RPM às duas ventoinhas; leituras reais ficaram próximas de 7.818 RPM.
4. As preferências anteriores foram restauradas depois do ensaio. O teste não deixa controle manual ligado por padrão.
5. CPU: chaves antigas Tp01/Tp05 retornavam 2,2/1,5 e contaminavam a média. Com validação e agregados do firmware, uma leitura registrou média 56,83 °C e máxima 73,58 °C; GPU média 45,23 °C. Temperaturas variam com carga e resfriamento.

Não foi realizado reboot completo nem suspend/resume físico. A retomada após despertar usa o mesmo caminho de leitura dos limites/aplicação usado na abertura, mas exige validação física separada. Outros modelos não foram testados. A inspeção visual automatizada da interface não ficou disponível nesta sessão; compilação e testes não substituem revisão visual no Mac.

## Consumo

O benchmark agora usa deltas reais de CPU por intervalo e `proc_pid_rusage` para RSS/footprint físico, mantendo a identidade do processo. Não usa a média acumulada de `ps` como se fosse instantânea.

Ensaio inicial da nova compilação por 60 segundos: CPU média 0,185% de um núcleo, RSS médio 83,05 MiB e footprint físico médio 21,07 MiB. A sessão antiga mediu 0,386% e footprint 93,32 MiB em 30 segundos, mas tinha outra idade e histórico de uso da interface: esses números não provam uma redução percentual controlada.

A meta de 85–88 MB e 0,2–0,4% depende de indicadores, janelas e perfil. RSS e footprint são medidas diferentes; não há teto universal garantido. Para reproduzir: `scripts/benchmark.sh 300 OptiStats --output build/benchmark.json` com o Mac ocioso.

## Referências verificadas

- [Stats SMC](https://github.com/exelban/stats/blob/master/SMC/smc.swift): modos, Ftst, alvos e restauração.
- [OSHI SmcUtil](https://www.oshi.ooo/xref/oshi/util/platform/mac/SmcUtil.html): semântica dos agregados TCMb/TCMz, cruzada com leituras neste Mac. Implementação independente.
- [Dusty](https://github.com/yagcioglutoprak/dusty): orientação por footprint e apps inativos, sem encerramento automático.
- [mac-os-debloat](https://github.com/OleksandrKrupko/mac-os-debloat): catálogo embutido coincide com commit `1f3b1c82ddb12c0e333310c0d6c675f792320d12`; não foi executado nenhum preset Debloat neste ensaio.

O histórico Git é preservado. A atualização substitui o pacote da release 1.0 e mantém a numeração pública solicitada.

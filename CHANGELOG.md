# Changelog

## 1.0 — build 2 (2026-11-02)

- Remove o teste beta e o bloqueio de controle; mantém instalação opcional do helper e permissão manual explícita.
- Lembra Manual/100% por modelo e macOS e reaplica na abertura e após repouso. Automático apaga a escolha salva.
- Mantém os alvos manuais usando o heartbeat já existente caso o firmware os altere; Automático cancela essa manutenção.
- Tenta Ftst quando a escrita de modo é aceita sem assumir controle; restaura modos 0/3 e alvos próprios, detectando falhas de escrita.
- Corrige médias de CPU contaminadas por valores 1,5/2,2; prioriza TCMb/TCMz e separa fallback HID por classe de zona.
- Preserva idade real das temperaturas quando ventoinhas ou sensores elétricos publicam dados.
- Revisão de apps inativos inspirada no Dusty, sem novo polling nem dependências. Protege terminais, máquinas virtuais e contêineres.
- Histórico de crescimento de RAM reinicia quando o processo do app muda; notificações de atividade não atravessam reinícios.
- Liberação de objetos temporários por ciclo de coleta; benchmark mede CPU por intervalo, RSS e footprint físico.
- Catálogo Debloat conferido com upstream 1f3b1c82ddb12c0e333310c0d6c675f792320d12; atualizador manual preservado.
- README, site bilíngue, metadados SEO e instruções atualizados. Versão pública permanece 1.0; helper build 4.

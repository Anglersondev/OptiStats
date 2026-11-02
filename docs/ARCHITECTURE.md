# Arquitetura

- **OptiStatsCore**: SwiftPM, Foundation/Dispatch, modelos, fórmulas, sensores, agendador, histórico limitado, análise de RAM e Smart Boost. Sem dependências externas.
- **Platform**: sysctl, Mach, libproc e leitura IOKit/SMC/HID/IOReport. Workspace fornece atividade dos apps por notificações, sem polling adicional.
- **AppEnvironment**: composição, demandas e eventos de energia/repouso. O histórico de crescimento e a interface são atualizados na main.
- **Shell/Preferences/Popovers**: AppKit, indicadores na barra e views atualizadas com coalescência. Painéis cancelam sua demanda ao fechar.
- **Helper**: daemon privilegiado opcional com socket Unix local; somente ele escreve em uma lista fixa de chaves de ventoinha. Limites vêm do SMC. Heartbeat existe no app somente enquanto há controle manual; perda da conexão/heartbeat restaura o automático.

## Ventoinhas

A instalação e a permissão manual são explícitas. Não há teste beta nem selo de validação física. Comandos conferem o alvo por leitura de volta; escritas diretas de modo sem efeito tentam Ftst. Restaurar Automático zera modos e alvos pertencentes ao helper, mantendo restauração pendente quando necessário. O heartbeat existente também reconcilia alvos próprios se o firmware os alterar durante o destravamento compartilhado. Testes de sequência usam SMC injetável.

A intenção Manual/100% fica em UserDefaults por modelo e versão principal do macOS. Na abertura e após repouso o app relê os limites, resolve 100% para o máximo atual e envia os comandos fora da main. Automático e desinstalação apagam essa intenção. Sair ou suspender restaura o hardware e preserva a escolha para a próxima sessão. A retomada após ligar ocorre ao iniciar a sessão, com Iniciar no login habilitado.

## Sensores

Valores de CPU/GPU fora de 10–125 °C são descartados. Média/máxima da CPU priorizam TCMb/TCMz quando presentes e plausíveis; tabelas por geração e HID fornecem fallback. HID não é suprimido só porque outra classe da CPU está disponível. Publicações de RPM/eletricidade não rejuvenescem temperaturas anteriores nem duplicam seu histórico.

## Memória e Debloat

A revisão de RAM usa footprint por app, no mínimo 300 MB e uma hora observada em segundo plano, com apps protegidos excluídos. Um pedido de encerramento só ocorre após seleção e confirmação e revalida PID/horário de início. Não há encerramento forçado nem otimização automática. O fluxo de disco/cache é sob demanda.

Debloat interpreta apenas o catálogo EMBEDDED_LABELS do projeto original. O botão de atualização baixa texto por HTTPS; o Python upstream não é executado. Mudanças de serviços continuam opcionais e revisadas na interface.

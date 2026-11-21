# Changelog

## 1.2 — atualização de temperatura (build 2)

- Corrigida a atualização das temperaturas da CPU e GPU quando aparecem juntas em um indicador empilhado.
- A barra mantém a última temperatura medida, marcada com asterisco, por até um minuto se uma amostra falhar.
- Indicadores configurados só para temperatura deixam de consultar a utilização de CPU ou GPU em segundo plano.

## 1.2

- CI em Apple Silicon para macOS 26 e 27, com build, testes e validação do pacote.
- Retorno a Automático diante de leitura de RPM desatualizada, pressão térmica crítica ou perda do controle manual.
- Detecção de outro controlador, tratamento da chave de modo por ventoinha e recuperação de interrupções durante uma escrita.
- Helper sem consultas periódicas quando em repouso, conexão SMC compartilhada por demanda e atualização de RPM sem recalcular o histórico térmico.
- DMG com SHA-256, preservação das assinaturas, suporte opcional à notarização e publicação do site vinculada à release estável.

## 1.0 — interface e seleção manual de apps

- Painéis com cartões nativos, cabeçalhos com ícones e tipografia consistente; preferências com títulos fixos e navegação mais legível.
- Detalhes técnicos da memória recolhíveis e seleção com quantidade/consumo dos apps, sem novos coletores, timers ou dependências.
- Corrige a ausência da ação de encerrar quando nenhum app atende aos filtros de recomendação.
- Escolher apps lista aplicativos elegíveis sem exigir 300 MB, uma hora de inatividade ou pressão de memória.
- Encerrar selecionados permanece visível; pede confirmação e encerramento normal, preservando proteções e revalidação de identidade.
- Gerenciador de memória no início do painel, botões em duas linhas e explicação para listas vazias.

## 1.0 (2026-11-02)

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

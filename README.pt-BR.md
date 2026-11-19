# OptiStats — Monitor de sistema para macOS

**Monitor nativo e leve para a barra de menus do Apple Silicon, com orientação de RAM, controle de ventoinhas e Debloat opcional.** Criado por [Anglerson](https://github.com/Anglersondev) em Swift e AppKit.

[Baixar versão estável](https://github.com/Anglersondev/OptiStats/releases/latest) · [English](README.md) · [Relatar um bug](https://github.com/Anglersondev/OptiStats/issues)

## Recursos

- Indicadores personalizáveis de CPU, GPU, RAM, temperaturas, potência, ventoinhas, disco, rede e bateria.
- Gráficos de histórico, sensores e processos agrupados por aplicativo.
- Perfis Econômico, Equilibrado, Tempo Real e Personalizado. Fontes ocultas param de ser consultadas; os coletores compartilham um agendador.
- Análise da pressão de memória e revisão de apps grandes que ficaram uma hora em segundo plano. Inspirado no Dusty: footprint agrupado, apps protegidos, encerramento normal e resultado medido.
- Leitura de ventoinhas por padrão. Automático, Manual, **100%** e Smart Boost opcionais usam o helper privilegiado. As escolhas manuais são lembradas e reaplicadas ao abrir e despertar, mesmo com o Mac frio.
- Ferramentas de disco/cache e gerenciamento opcional de serviços do macOS pelo Debloat.
- Inglês e português brasileiro com troca em tempo de execução. Versão, créditos e doação em **Preferências → Sobre**.

## Novidades da 1.2

- O Smart Boost passa para Automático quando perde a leitura recente de RPM ou o macOS sinaliza pressão térmica crítica.
- O helper detecta conflitos com outro controlador e restaura os próprios alvos manuais em caso de interrupção. Em repouso, aguarda pedidos sem consultas periódicas.
- Temperatura, ventoinhas e potência compartilham a conexão com o SMC por demanda. Atualizações de RPM reaproveitam os agregados de temperatura e preservam a idade das amostras.
- Atualize o helper opcional para o build **5** em **Preferências → Ventoinhas** para usar Manual, 100% ou Smart Boost.
- CI em Apple Silicon no macOS 26 e 27. A instalação continua com alvo mínimo no macOS 13.

## Interface e seleção manual de apps

Painéis com seções visuais, cabeçalhos mais claros e títulos fixos nas preferências. Em Memória, use **Escolher apps → marcar a seleção → Encerrar selecionados**, sem exigir uma hora de inatividade ou pressão de memória. Apps protegidos continuam de fora. Os detalhes da memória expandem sob demanda; a frequência de coleta permanece igual.

## Download e requisitos

[Baixar a versão estável mais recente](https://github.com/Anglersondev/OptiStats/releases/latest). Abra o DMG e arraste o app para Aplicativos.

Requer **macOS 13 ou posterior e Apple Silicon**. Sensores e controle das ventoinhas dependem do Mac. A versão usa assinatura ad-hoc e não é notarizada pela Apple; o macOS pode exigir aprovação em Ajustes do Sistema → Privacidade e Segurança. O helper é opcional, necessário apenas para controlar as ventoinhas.

## Inspirado no Stats, com ferramentas adicionais

O OptiStats é um app independente inspirado no [Stats, de exelban](https://github.com/exelban/stats). Abordagens selecionadas de SMC, sensores, IOReport e controle de ventoinhas foram estudadas ou adaptadas com os créditos MIT. O OptiStats usa arquitetura própria de amostragem e acrescenta orientação de RAM, manutenção de disco/cache e interface de Debloat. Não é afiliado ao Stats.

O foco é baixo consumo: coleta por demanda, leituras compartilhadas, histórico limitado e trabalho fora da thread da interface. **Um consumo menor de CPU ou RAM que o Stats ainda não foi comprovado em comparação controlada.** Veja a [auditoria da implementação](docs/AUDITORIA-STATS.md).

## Debloat: origem e funcionamento

O catálogo de serviços, comentários e presets vem do **[mac-os-debloat, de Oleksandr Krupko](https://github.com/OleksandrKrupko/mac-os-debloat)**, sob licença MIT. O OptiStats inclui uma cópia do catálogo `EMBEDDED_LABELS` e implementa sua própria interface e lógica de aplicação; não executa o script Python original.

A aba consulta serviços presentes no Mac e permite revisar os presets Telemetria, Balanceado e Todos antes de confirmar alterações do launchd. O app guarda snapshots para restaurar ajustes compatíveis que ele próprio realizou. Desativar serviços pode afetar iCloud, App Store e atualizações do macOS; os serviços variam conforme a versão do sistema e as restrições do SIP continuam valendo. O Debloat é opcional e não roda continuamente.

A atualização do catálogo é **manual**: o botão baixa o catálogo do repositório original por HTTPS. O monitoramento permanece local, sem telemetria. As licenças MIT estão preservadas nos [avisos de terceiros](THIRD_PARTY_NOTICES.md).

A revisão de memória adapta ideias do [Dusty, de Toprak Yagcioglu](https://github.com/yagcioglutoprak/dusty), como revisar apps grandes e inativos em vez de prometer ganhos de RAM. A implementação fica dentro do OptiStats; o Dusty não é instalado nem executado.

## Compilar e validar

Com somente Command Line Tools, use `scripts/build_app.sh`. Use `scripts/check_hardware_regressions.sh` para simular escritas no SMC e ler a telemetria do Mac atual, sem privilégios de administrador. As [notas da 1.2](docs/RELEASE-1.2.md) incluem o fluxo de publicação e atualização do site.

No macOS com Xcode 15 ou posterior:

```sh
python3 scripts/generate_xcodeproj.py
xcodebuild -project OptiStats.xcodeproj -scheme OptiStats -configuration Release build CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/OptiStatsCore
python3 scripts/check_localization.py
```

O núcleo Swift recebe testes no Linux e macOS pelo CI, que também compila o app e o DMG. Essas verificações não validam a resposta física das ventoinhas; o comportamento e o consumo precisam ser medidos no Mac de destino.

## Medir desempenho

Com o app aberto e o Mac ocioso, execute `scripts/benchmark.sh 300 OptiStats`. Compare os mesmos indicadores e perfis de amostragem com outro monitor. Os resultados valem para a configuração medida, sem garantia universal de consumo.

## Créditos e apoio

Criado por **Anglerson**. [Apoiar o desenvolvimento ☕](https://pixgg.com/Anglerson).

Licenças MIT de terceiros em [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). A licença geral do OptiStats ainda não foi declarada; as licenças de terceiros se aplicam aos respectivos materiais.

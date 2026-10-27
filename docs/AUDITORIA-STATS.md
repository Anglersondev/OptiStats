# Auditoria do Stats (exelban/stats, commit 69efd1c, 26/10/2026)

Fonte estudada: repositório clonado (código-fonte). O `Contents2.zip` enviado é o bundle compilado do Stats 3.0.23 e foi usado só como referência de módulos/recursos.

| Área | Veredito | Observação |
|---|---|---|
| Arquitetura (módulos + readers com timers próprios) | **Reescrito** | OptiStats usa um único `SamplingCoordinator` com demanda por consumidor (ocultar = parar de ler). |
| Fórmula de memória "usada" | **Divergente, documentado** | Stats usa uma fórmula própria; OptiStats segue o estilo do Monitor de Atividade e mantém a do Stats como `alternativeUsedBytes` para reconciliação. |
| Catálogo de chaves SMC | **Adaptado (MIT)** | Reorganizado por geração M1–M6; chaves ausentes degradam para "indisponível". |
| Leitura HID/IOReport | **Adaptado conceitualmente** | via `dlopen/dlsym`, sem bridging header; falha → `.unsupported`. |
| Controle de ventoinhas (escrita SMC/helper privilegiado) | **Adaptado e isolado em helper opcional** | Leitura por padrão; escrita somente após permissão e teste neste Mac. Limites, watchdog e confirmação próprios. |
| Atualizador e telemetria | **Não adotados** | Sem telemetria. Há download manual do catálogo Debloat por HTTPS; helper opcional somente para ventoinhas. |
| Topologia E/P | **Reescrito** | Validada contra `hw.perflevelN`; rótulo só quando verificado. |

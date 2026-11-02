# OptiStats 1.0

## Português brasileiro

- **Correção do Spotlight:** o componente Siri AI (`com.apple.campo`), que também abre ⌘ + Espaço no macOS 27, agora é protegido contra encerramento pela RAM e desativação pelo Debloat. A Siri pode continuar desligada nos Ajustes do Sistema.

- **Debloat mais claro:** estados Habilitado/Desativado/Não encontrado, seleção separada do estado real e explicações ao passar o mouse. Serviços habilitados não são apresentados como necessariamente em execução. Interface e novos textos em inglês e português brasileiro; descrições originais do catálogo mantêm o texto do autor.

- **Interface renovada e nativa:** painéis com seções visuais, cabeçalhos com ícones e preferências com títulos fixos e navegação mais legível. Detalhes técnicos da RAM ficam recolhíveis; seleção mostra quantidade de apps e memória em uso. Sem novas bibliotecas, timers ou animações contínuas.

Monitor leve de sistema para macOS e Apple Silicon: CPU, GPU, RAM, temperatura, ventoinhas, bateria, rede e disco na barra de menus.

- **Ventoinhas a 100%, mesmo com o Mac frio:** destravamento corrigido para assumir o controle sem esperar carga pesada.
- **Manual/100% persistentes:** a escolha é reaplicada ao abrir o app e após despertar. Ative **Geral → Iniciar no login** para retomar após entrar na sessão.
- **Voltar ao Automático:** disponível em cada ventoinha e no botão **Restaurar automático**, no painel rápido e nas preferências. Apaga os alvos salvos e devolve o controle ao macOS. Sair, suspender ou perder a comunicação também devolve o controle.
- Removidos o botão de teste beta e seu bloqueio de uso. Permanecem a instalação opcional do helper, a permissão manual e os limites reais do hardware.
- **Temperatura da CPU corrigida:** prioriza média e máxima do firmware e descarta chaves que retornam valores implausíveis. Corrigidos o fallback HID e a idade do histórico térmico.
- **Encerrar apps pela RAM:** Escolher apps e Encerrar selecionados ficam visíveis no início do painel, com seleção manual sem esperar uma hora de inatividade. A confirmação, as proteções e o encerramento normal continuam valendo.
- **Revisão de RAM inspirada no Dusty:** apps grandes e inativos, com seleção e confirmação antes do encerramento normal. Sem outro serviço ou dependência; terminais e máquinas virtuais protegidos.
- Catálogo Debloat conferido com o projeto original; atualização manual do GitHub preservada.
- Português brasileiro e inglês; README e site bilíngue com metadados SEO atualizados.

**Atualização:** substitua o app e abra **Preferências → Ventoinhas → Atualizar helper** uma vez. Continua na versão **1.0**, helper **4**. macOS 13+, Apple Silicon. Assinatura ad-hoc, sem notarização Apple.

**Verificação:** 199 testes do núcleo passaram em macOS e Linux, além das regressões de SMC simulado. Em um MacBook Pro M4 Pro (Mac16,8, macOS 27.2), ventoinhas inicialmente paradas atingiram cerca de 7.820 RPM ao pedir o máximo de 7.826 RPM. A retomada na abertura e a devolução ao automático foram verificadas no hardware. O resultado depende do modelo; não representa validação de todos os Macs. Detalhes e limites em `docs/FINAL-REVIEW.md`.

## English

- **Spotlight fix:** Siri AI (`com.apple.campo`), which also hosts Cmd-Space on macOS 27, is now protected against RAM quit requests and Debloat disable commands. Siri can remain turned off in System Settings.

- Clearer Debloat states (Enabled/Disabled/Not found), selection separated from actual state and detailed hover help. Enabled services are not claimed to be running. All new UI text is available in English and Brazilian Portuguese; original catalog descriptions preserve the author’s wording.

- Refreshed native interface: grouped panel sections, icon headers, clearer preferences navigation and fixed pane titles. RAM details expand on request; manual app selection shows counts and memory in use. No added runtime libraries, polling or continuous animation.

Lightweight macOS menu bar system monitor for Apple Silicon, with CPU, GPU, RAM, temperatures, fan control, battery, disk and network.

- Fixed cold-fan acquisition; 100% no longer has to wait for a heavy workload.
- Manual/100% choices resume on launch and wake. Enable Launch at login to resume after signing in.
- Automatic is available per fan and through Restore automatic in the quick panel and preferences. It clears saved targets and hands control back to macOS.
- Removed the beta test button and validation gate. The optional privileged helper, explicit manual permission and hardware limits remain.
- Corrected CPU die average/maximum selection, implausible readings, HID fallback and thermal history timestamps.
- Choose apps and Quit selected remain visible near the top of the memory panel. Manual selection has no idle-time or memory-pressure requirement; protections and confirmation still apply.
- Dusty-inspired idle-app memory review with user selection, normal quit requests and protected background workloads; no added daemon or runtime dependency.
- Upstream Debloat catalog verified, manual GitHub catalog updates preserved. Updated bilingual documentation and SEO metadata.

**Upgrade:** replace the app, then update the helper once in Preferences → Fans. Public version stays **1.0**, helper build **4**. macOS 13+, Apple Silicon; ad-hoc signed, not Apple notarized.

Core tests passed on macOS and Linux. Cold-fan acceleration, launch-time resume and restoration to macOS Automatic were checked on one M4 Pro; other hardware still needs its own verification. See `docs/FINAL-REVIEW.md` for measurement scope.

Built by [Anglerson](https://github.com/Anglersondev). References: [Stats](https://github.com/exelban/stats), [mac-os-debloat](https://github.com/OleksandrKrupko/mac-os-debloat), [Dusty](https://github.com/yagcioglutoprak/dusty). MIT notices preserved.

# OptiStats 1.0 — build 2

## Português brasileiro

Monitor leve de sistema para macOS e Apple Silicon: CPU, GPU, RAM, temperatura, ventoinhas, bateria, rede e disco na barra de menus.

- **Ventoinhas a 100%, mesmo com o Mac frio:** destravamento corrigido para assumir o controle sem esperar carga pesada.
- **Manual/100% persistentes:** a escolha é reaplicada ao abrir o app e após despertar. Ative **Geral → Iniciar no login** para retomar após entrar na sessão.
- **Voltar ao Automático:** disponível em cada ventoinha e no botão **Restaurar automático**, no painel rápido e nas preferências. Apaga os alvos salvos e devolve o controle ao macOS. Sair, suspender ou perder a comunicação também devolve o controle.
- Removidos o botão de teste beta e seu bloqueio de uso. Permanecem a instalação opcional do helper, a permissão manual e os limites reais do hardware.
- **Temperatura da CPU corrigida:** prioriza média e máxima do firmware e descarta chaves que retornam valores implausíveis. Corrigidos o fallback HID e a idade do histórico térmico.
- **Revisão de RAM inspirada no Dusty:** apps grandes e inativos, com seleção e confirmação antes do encerramento normal. Sem outro serviço ou dependência; terminais e máquinas virtuais protegidos.
- Catálogo Debloat conferido com o projeto original; atualização manual do GitHub preservada.
- Português brasileiro e inglês; README e site bilíngue com metadados SEO atualizados.

**Atualização:** substitua o app e abra **Preferências → Ventoinhas → Atualizar helper** uma vez. Continua na versão **1.0**, build interno **2**, helper **4**. macOS 13+, Apple Silicon. Assinatura ad-hoc, sem notarização Apple.

**Verificação:** 199 testes do núcleo passaram em macOS e Linux, além das regressões de SMC simulado. Em um MacBook Pro M4 Pro (Mac16,8, macOS 27.2), ventoinhas inicialmente paradas atingiram cerca de 7.820 RPM ao pedir o máximo de 7.826 RPM. A retomada na abertura e a devolução ao automático foram verificadas no hardware. O resultado depende do modelo; não representa validação de todos os Macs. Detalhes e limites em `docs/FINAL-REVIEW.md`.

## English

Lightweight macOS menu bar system monitor for Apple Silicon, with CPU, GPU, RAM, temperatures, fan control, battery, disk and network.

- Fixed cold-fan acquisition; 100% no longer has to wait for a heavy workload.
- Manual/100% choices resume on launch and wake. Enable Launch at login to resume after signing in.
- Automatic is available per fan and through Restore automatic in the quick panel and preferences. It clears saved targets and hands control back to macOS.
- Removed the beta test button and validation gate. The optional privileged helper, explicit manual permission and hardware limits remain.
- Corrected CPU die average/maximum selection, implausible readings, HID fallback and thermal history timestamps.
- Dusty-inspired idle-app memory review with user selection, normal quit requests and protected background workloads; no added daemon or runtime dependency.
- Upstream Debloat catalog verified, manual GitHub catalog updates preserved. Updated bilingual documentation and SEO metadata.

**Upgrade:** replace the app, then update the helper once in Preferences → Fans. Public version stays **1.0**, internal build **2**, helper build **4**. macOS 13+, Apple Silicon; ad-hoc signed, not Apple notarized.

Core tests passed on macOS and Linux. Cold-fan acceleration, launch-time resume and restoration to macOS Automatic were checked on one M4 Pro; other hardware still needs its own verification. See `docs/FINAL-REVIEW.md` for measurement scope.

Built by [Anglerson](https://github.com/Anglersondev). References: [Stats](https://github.com/exelban/stats), [mac-os-debloat](https://github.com/OleksandrKrupko/mac-os-debloat), [Dusty](https://github.com/yagcioglutoprak/dusty). MIT notices preserved.

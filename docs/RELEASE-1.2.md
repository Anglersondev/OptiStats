# OptiStats 1.2

## Português brasileiro

- Compatibilidade em Apple Silicon com macOS 26 e 27. O alvo mínimo de instalação é macOS 13.
- Smart Boost volta ao Automático quando as leituras de RPM ficam desatualizadas ou quando o macOS indica pressão térmica crítica.
- O controle respeita limites de RPM do hardware, reconhece a chave de modo de cada ventoinha e evita assumir o controle de outra ferramenta. Em caso de interrupção, o helper tenta confirmar a devolução do controle ao macOS.
- Menos trabalho em segundo plano. O helper aguarda solicitações sem polling enquanto está em repouso, a conexão SMC é compartilhada por demanda e atualizações de RPM reaproveitam os agregados de temperatura.
- Pacote DMG acompanhado de SHA-256. A compilação padrão usa assinatura ad-hoc. Com um certificado Developer ID, o mantenedor pode criar um pacote notarizado.

Para atualizar, substitua o app e, se usar controle manual, abra **Preferências → Ventoinhas → Atualizar helper** para instalar o build **5**. A leitura padrão continua disponível sem o helper. Sensores e controle de ventoinhas dependem do modelo.

## English

- Apple Silicon support for macOS 26 and 27, with a macOS 13 minimum deployment target.
- Smart Boost returns control to macOS when fan RPM data goes stale or thermal pressure reaches critical.
- Fan control checks firmware RPM limits, discovers each fan's mode key and detects conflicts with other controllers. Interrupted commands trigger an attempt to verify restoration to Automatic.
- An idle helper waits for events without polling. Active collectors share the SMC connection, and fan-only updates reuse temperature aggregates.
- The DMG includes a SHA-256 checksum. Default builds are ad-hoc signed, with a Developer ID option for notarized distribution.

Replace the app to update. If you use manual control, install helper build **5** in **Preferences → Fans → Update helper**. The sensors and fan controls available depend on the Mac model.

## Maintainer release workflow

- Run the CI workflow on the release commit. It tests the Swift core on Linux and both macOS runners, validates the generated Xcode project, runs simulated fan regressions and builds the DMG.
- Tag the reviewed commit as `v1.2` and push the tag. After the checks pass, the workflow creates the GitHub release draft and attaches the DMG and checksum.
- To use Developer ID for distribution, set `OPTISTATS_CODESIGN_IDENTITY` to an installed Developer ID Application identity. Run `scripts/build_app.sh`, then run `scripts/make_dmg.sh build/native/OptiStats.app` with both that identity and `OPTISTATS_NOTARY_PROFILE`, a keychain profile for `notarytool`. Replace both draft assets with the resulting notarized DMG and its matching checksum.
- Publish the reviewed draft, then run `scripts/publish_site.sh` with the repository maintainer's Git and GitHub CLI credentials. It checks that this release is public and has both assets before updating the existing `gh-pages` branch. Run `scripts/publish_site.sh --check` to validate the site locally.

On a fan-equipped physical Mac, use `scripts/check_hardware_regressions.sh build/regression --require-telemetry --expect-fans` to check actual sensor values through the production collectors. Physical writes and thermal response require a separate, supervised test on the target Mac.

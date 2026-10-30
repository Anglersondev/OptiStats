# Changelog

## 1.0 (em validação)
- Sobre nas Preferências, com doação; controles manual e 100% das ventoinhas.
- Interface não espera pelo socket do helper; comparação do helper fora da renderização.
- Histórico atualizado sem cópia integral do buffer a cada amostra.
- Restauração das ventoinhas exige leitura confirmada e ignora respostas antigas após repouso/restauração.
- Saídas de comandos de manutenção lidas em paralelo para evitar bloqueio por pipe cheio.
- Primeira versão: núcleo testado, camada macOS ainda não validada em hardware.

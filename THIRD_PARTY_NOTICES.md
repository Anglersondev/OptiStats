# Avisos de terceiros / Third-party notices

## Stats — https://github.com/exelban/stats (MIT)

O OptiStats é uma implementação independente. Foram **estudados e adaptados conceitualmente** (não copiados em bloco) os seguintes
elementos do projeto Stats, cuja licença exige a preservação do aviso abaixo:

- catálogo de chaves SMC por geração de chip (`Sensors/SMCCatalog.swift`) — lista de chaves e nomes derivada de `Modules/Sensors/values.swift`;
- layout da estrutura de chamada ao `AppleSMC` e decodificação de tipos SMC (`Sensors/SMCDecoder.swift`, `Platform/SMC*.swift`);
- abordagem de leitura de temperaturas via `IOHIDEventSystemClient` e de potência via IOReport "Energy Model";
- abordagem de detecção de topologia de núcleos (E/P) via IORegistry.

Veja `docs/AUDITORIA-STATS.md` para o inventário completo do que foi reutilizado, reescrito ou descartado.

### Licença do Stats

MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## mac-os-debloat — https://github.com/OleksandrKrupko/mac-os-debloat (MIT)

O arquivo `App/OptiStats/Resources/debloat-catalog.txt` é uma cópia do catálogo `EMBEDDED_LABELS` desse projeto (lista de serviços launchd com
comentários e presets). O app o lê para exibir e aplicar a escolha do usuário; o código do autor não é reutilizado.

MIT License

Copyright (c) 2026 Oleksandr Krupko

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

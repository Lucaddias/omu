# 01 — Pesquisa: runtimes nativos de IA do Papagaio

> **Data da pesquisa e das consultas externas:** 2026-09-23 (UTC-3).
> **Escopo:** runtimes e modelos usados pelo pipeline local de áudio do Papagaio:
> `whisper.cpp`, `llama.cpp`, ONNX Runtime, Silero VAD e FluidAudio/Core ML.
> **Escopo explícito:** este documento é uma ficha técnica e um plano de
> manutenção; não é um benchmark e não substitui uma validação em dispositivo.
> **Arquivo produzido:** somente `audit/01-pesquisa/ai-runtimes.md`.

## 0. Resumo executivo

O Papagaio tem quatro caminhos de inferência local, com responsabilidades
claramente separadas:

1. **Whisper** (`whisper.cpp` v1.9.1) recebe PCM Float32 mono a 16 kHz e faz
   ASR com timestamps por token, GPU e Flash Attention.
2. **Qwen** (`llama.cpp` b9222) recebe o GGUF `Qwen3.5-9B-Q4_K_M`, pede
   offload de 999 layers para a GPU, janela de 32.768 tokens e gramática GBNF.
3. **Silero VAD** (commit `76e3dc4...`) roda em ONNX Runtime 1.24.2 no
   **CPU**, com estado recorrente e sem usar o Core ML.
4. **Diarização** usa FluidAudio 0.15.5 e quatro bundles Core ML
   `pyannote-speaker-diarization-community-1`; portanto, ONNX Runtime não é o
   executor da diarização.

A composição é confirmada no código, mas há quatro riscos que merecem
prioridade antes de uma atualização indiscriminada:

- **Pin antiquado:** Whisper, llama.cpp, ONNX Runtime e FluidAudio têm
  correções e mudanças de segurança/estabilidade publicadas depois dos pins
  locais. FluidAudio 0.15.6–0.15.8 também alteram a API de diarização usada
  pelo wrapper.
- **Pasta de modelos escolhida pelo usuário:** o app aceita um bookmark para
  uma pasta externa e, por padrão, o preflight verifica apenas tamanho. Isso
  deixa um GGUF arbitrário no mesmo processo que faz parsing C/C++.
- **URLs mutáveis:** pesos GGUF e artefatos Core ML usam `resolve/main`; a
  verificação dos hashes detecta troca de conteúdo, mas a política de
  resolução não é imutável.
- **Fronteira de segurança do llama.cpp:** existem 13 advisories oficiais,
  incluindo overflows de GGUF e RCE no backend RPC. O código do Papagaio não
  usa RPC, mas o carregador de GGUF continua sendo uma superfície de entrada
  não confiável quando o usuário escolhe uma pasta.

**Não há, nesta execução, afirmação de velocidade ou desempenho dos runtimes.**
Os comentários de código que dizem “minúsculo”, “~0,07 ms” ou “10–30 s” são
tratados como comentários não verificados, não como benchmark. A única
medição local usada para contexto é o microbenchmark sintético já registrado
no mapa, e ela não representa uma reunião real nem RTF de produção.

**Classificação geral:**

| Conclusão | Classificação |
|---|---|
| Papagaio combina Whisper/llama em Metal, ONNX/Silero em CPU e FluidAudio/Core ML em diarização | **CONFIRMADO** |
| Os quatro pins locais e seus papéis são os indicados no manifesto/script | **CONFIRMADO** |
| Os pins têm déficit de manutenção em relação às páginas oficiais consultadas em 2026-09-23 | **CONFIRMADO** (comparação de versões) |
| O modelo escolhido pelo usuário pode ser malicioso e alcançar o parser GGUF | **PROVÁVEL** (caminho de código confirmado; impacto depende do arquivo) |
| Atualizar FluidAudio diretamente para 0.16.1 sem adaptar o wrapper é seguro | **HIPÓTESE** a refutar; não fazer essa suposição |
| Carga residente, offload total para Metal, fluidez da UI e throughput são aceitáveis | **HIPÓTESE**; exigem benchmark e medição de memória |

## 1. Método, legibilidade e regra de evidência

### 1.1 Método

- `audit/00-mapa.md` foi lido integralmente, nas linhas 1–948, antes da
  redação. O próprio mapa define a convenção de confiança e diz que
  referências `arquivo:linha` apontam para evidência local
  **[L: `audit/00-mapa.md:9-25` — “CONFIRMADO — executei/medi”; “Referências
  `arquivo:linha` apontam para evidência local”]**.
- Foram lidos o manifesto SPM, os três `Package.resolved`, o bootstrap, os
  wrappers C/Swift, o ciclo de vida, o preflight, o downloader, o VAD, o
  diarizador, o pipeline e os metadados dos quatro bundles Core ML.
- Foram inspecionados os XCFrameworks já presentes: `Info.plist`, module maps,
  headers C, `file`, `otool -L`, `codesign -dvvv`, `shasum -a 256` e
  `strings`. Binários não têm números de linha; por isso a prova de hash,
  arquitetura e assinatura é identificada como **inspeção de arquivo
  binário**, com o comando e o trecho de saída, sem fingir uma citação de
  linha textual.
- Foram consultadas fontes oficiais do GitHub, Microsoft ONNX Runtime,
  Hugging Face e do próprio FluidAudio. Nenhuma dependência foi instalada,
  nenhum ZIP de runtime foi baixado e nenhum serviço real foi executado.
  O mapa confirma que o bootstrap não foi executado e que as medições de
 macro/RTF não foram feitas
  **[L: `audit/00-mapa.md:87-104` — “Não executei
  `bootstrap-runtimes.sh`”; `audit/00-mapa.md:819-822` — “Não medido: macro-benchmark
  com Qwen/Whisper, RTF de áudio real...”]**.

### 1.2 Legenda

As classes abaixo são as mesmas do mapa:

- **CONFIRMADO** — li a linha/arquivo ou executei uma inspeção local nesta
  execução; a citação local é mostrada no ponto do uso.
- **PROVÁVEL** — inferência forte a partir de código, headers, pins ou
  advisories, sem execução do caminho de produção.
- **HIPÓTESE** — risco ou hipótese de trabalho que precisa de teste.

Para afirmações externas, “CONFIRMADO” significa que a fonte oficial
publicada contém a afirmação; não significa que o comportamento foi medido
no Papagaio.

### 1.3 Regra para não confundir velocidade com evidência

- Não usar os números “~0,07 ms”, “10–30 s”, “3 GB” ou “6,2 GB” como
  benchmark. No código eles aparecem em comentários, por exemplo
  **[L: `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:28-30` — “A inferência
  é bloqueante e roda na CPU (o modelo de VAD é minúsculo: ~0,07 ms por quadro
  de 32 ms medido nesta máquina)”]** e
  **[L: `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:31-35` — “O
  modelo fica residente entre resumos: são ~6,2 GB, e recarregar leva 10–30 s”]**.
  Neste relatório eles são tratados como **comentário do código, não como
  medição validada**.
- O mapa mediu um caso sintético de Silero com 600 quadros e 0,031454584 s de
  mediana, mas também registra explicitamente que isso é o harness, não RTF de
  uma reunião
  **[L: `audit/00-mapa.md:789-806` — “vad.silero.lote | 0,031454584 | 600
  quadros de 512 amostras”; “é uma medição sintética desse harness, não RTF de
  uma reunião real”]**. Esse resultado não será extrapolado para o produto.

## 2. Manifestos, resolução e autoridade dos pins

### 2.1 O manifesto e os três arquivos de resolução

O pacote local declara uma única dependência SwiftPM remota: FluidAudio
exatamente em `0.15.5`; os runtimes C/C++ são `binaryTarget(path:)` e não
aparecem como dependências remotas no arquivo de resolução
**[L: `PapagaioCore/Package.swift:11-16` — “.package(url:
`https://github.com/FluidInference/FluidAudio.git`, exact: `0.15.5`)”;
`:18-27` — “binaryTarget(name: `whisper`...)”, “binaryTarget(name:
`llama`...)”, “binaryTarget(name: `onnxruntime`...)”]**.

Os três arquivos de resolução apontam para a mesma revisão do FluidAudio,
embora seus `originHash` de grafo sejam diferentes:

| Arquivo | Versão | Revisão | Linhas |
|---|---:|---|---|
| `PapagaioCore/Package.resolved` | 0.15.5 | `19600a485baa4998812e4654b70d2bab8f2c9949` | `:5-10` |
| `Loro.xcworkspace/xcshareddata/swiftpm/Package.resolved` | 0.15.5 | mesma | `:5-10` |
| `Loro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | 0.15.5 | mesma | `:5-10` |

A leitura literal desses três arquivos é a mesma
**[L: `PapagaioCore/Package.resolved:5-10` — “identity: fluidaudio”,
“revision: `19600a...`”, “version: `0.15.5`”; `Loro.xcworkspace/.../Package.resolved:5-10`
— mesmo trecho; `Loro.xcodeproj/.../Package.resolved:5-10` — mesmo trecho]**.
O mapa também registra que o build do projeto e o log de build registraram
`Checking out 0.15.5` **[L: `audit/00-mapa.md:61-85` — “os três
`Package.resolved` ... mesma revisão”; “Checking out 0.15.5 of package
`FluidAudio`”]**.

O checkout de `FluidAudio` usado para esta análise está em
`v0.15.5`/`19600a485...`; a inspeção Git local retornou `## HEAD (no branch)`,
`19600a485...` e `v0.15.5` **[CONFIRMADO por comando Git; o comando não tem
linha de arquivo]**. Isso evita confundir o código do checkout com a API da
release mais nova.

### 2.2 Pins efetivos dos quatro artefatos

| Componente | Pin efetivo | Onde a autoridade está | Evidência local |
|---|---|---|---|
| FluidAudio | `0.15.5`, commit `19600a485...` | `Package.swift` + três arquivos de resolução | `PapagaioCore/Package.swift:11-16`; `PapagaioCore/Package.resolved:5-10` |
| whisper.cpp XCFramework | tag `v1.9.1`, ZIP SHA `8c3ecbe7...` | bootstrap | `Scripts/bootstrap-runtimes.sh:47-52` |
| llama.cpp XCFramework | tag `b9222`, ZIP SHA `39b5d476...` | bootstrap | `Scripts/bootstrap-runtimes.sh:47-50` |
| ONNX Runtime XCFramework | `1.24.2`, ZIP SHA `f7100a99...` | bootstrap + `Info.plist` | `Scripts/bootstrap-runtimes.sh:53-57`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Resources/Info.plist:11-14` |
| Silero VAD | commit `76e3dc408eb2a5c655c34e230d2d5459b4439daa`, arquivo SHA `1a153a22...` | bootstrap | `Scripts/bootstrap-runtimes.sh:53-58`, `:295-297` |

As URLs são explícitas no script: llama
`https://github.com/ggml-org/llama.cpp/releases/download/b9222/llama-b9222-xcframework.zip`,
Whisper
`https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip`,
ONNX
`https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip` e Silero
`https://raw.githubusercontent.com/snakers4/silero-vad/76e3dc408eb2a5c655c34e230d2d5459b4439daa/src/silero_vad/data/silero_vad.onnx`
**[L: `Scripts/bootstrap-runtimes.sh:282-297` — “llama-b9222-xcframework.zip”,
“whisper-v1.9.1-xcframework.zip”, “pod-archive-onnxruntime-c-1.24.2.zip”, URL
raw do commit `76e3dc...`]**.

O manifesto declara que a pasta de XCFrameworks fica fora do Git, e o README
diz que o bootstrap verifica SHA-256
**[L: `.gitignore:1-21` — “Os XCFrameworks ... ficam FORA do git”; “baixados
pelo `Scripts/bootstrap-runtimes.sh` ... com verificação de SHA-256”;
`README.md:73-75` — “as versões fixadas e verifica o SHA-256 de cada
artefato”]**. Portanto, para whisper/llama/ONNX o `Package.resolved` não é a
autoridade de versão; a autoridade é o trio tag/URL/SHA no script.

## 3. Comparação com as versões publicadas em 2026-09-23

A comparação abaixo usa as páginas oficiais de release consultadas em
**2026-09-23**. “Mais recente” significa a release/pre-release mais recente
exibida pela fonte, não uma garantia de estabilidade ou compatibilidade.

| Runtime | Pin local | Release/pre-release mais recente consultada | Commit/tag da release | Leitura para o Papagaio |
|---|---|---|---|---|
| FluidAudio | `0.15.5` | `v0.16.1` (21/09/2026) | `b811a61569aa02691c99b808d08ee989b630c133` | **CONFIRMADO:** a release diz “No API changes” e corrige o Mac Catalyst. **PROVÁVEL:** a atualização não deve ser presumida compatível, porque `v0.15.6` já alterou `process()` para `prepare()`/`cluster()`. |
| whisper.cpp | `v1.9.1` | `v1.9.4` (11/09/2026) | `927cfce34f31707e17f2bff35c349632fb9e2c3a` | **CONFIRMADO:** pin está atrás de três releases; `v1.9.3` lista correções de OOB/overflow em áudio curto e header de tensor. |
| llama.cpp | `b9222` (19/05/2026) | `b11139` (23/09/2026, pre-release); versão semver mais recente `v0.4.1` (14/09/2026) | `b11139` = `42916d83...`; `v0.4.1` = `b29c606e...` | **CONFIRMADO:** `b11139` aparece como pre-release; portanto “mais novo” e “mais estável” não são sinônimos. `b9222` deve ser tratado como build snapshot, não como uma versão semver estável. |
| ONNX Runtime | `1.24.2` | `v1.30.0` (10/09/2026); mais recente da série 1.24: `v1.24.4` (17/03/2026) | `f2c39fe2...` / `2d924974...` | **CONFIRMADO:** `1.24.2` é anterior a correções de segurança/shape em `1.24.3`, `1.24.4`, `1.29.0` e `1.30.0`. O salto maior exige smoke test do modelo e da API C. |
| Silero VAD | commit `76e3dc4...` do modelo | `v6.2.3` (23/09/2026) | `5cd7945676eb32225748052e2e6a0580e4686a08` | **CONFIRMADO:** existe release mais nova. O arquivo local é pinado por commit porque o script afirma que a tag de release não cobre o artefato ONNX. |

### 3.1 O que mudou entre os pins

#### FluidAudio

- `v0.15.6` registrou a mudança de API “OfflineDiarizerManager: split
  `process()` into `prepare()`/`cluster()`”. A release também registrou
  correções de download e outras mudanças de diarização.
- `v0.15.7` registrou propagação de cancellation para os workers do
  diarizador offline e correção de outras bordas de ASR.
- `v0.15.8` registrou a alteração “Pin diarization artifacts to immutable
  revision”.
- `v0.16.1` diz “No API changes” em relação a `v0.15.8`, mas corrige o slice
  Mac Catalyst e atualiza a dependência de processing de texto.

O wrapper local continua compilando contra a API `prepareModels` + `process`
da revision `0.15.5` **[L: `PapagaioCore/.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift:24-67`
— “prepareModels” e “Attempting fallback download and compilation”; `:91-129`
— `process(_ url: URL...)`; `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:65-81`
— “try await gerente.prepareModels” e “gerente.process(audio...)”]**.
Isso é uma **incompatibilidade de API a verificar**, não uma prova de que a
release nova quebra o app.

#### whisper.cpp

`v1.9.1` é o build local e o header local fixa
`WHISPER_SAMPLE_RATE=16000` **[L:
`PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Headers/whisper.h:33-36`
— “#define WHISPER_SAMPLE_RATE 16000”, “WHISPER_CHUNK_SIZE 30”]**. A release
`v1.9.3` aparece como pre-release e lista, entre outras correções:

- heap out-of-bounds read em `log_mel_spectrogram` para áudio muito curto;
- rejeição de `n_dims` inválido em header de tensor para impedir
  stack-buffer-overflow em modelo malformado;
- hardening do loader GGML contra dimensões e tipos de metadados malformados.

Essas mudanças são diretamente relevantes porque o app aceita áudio
não vazio e o modelo vem de uma pasta que pode ser escolhida
pelo usuário **[L: `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:137-145`
— `guard !amostras.isEmpty`; `PapagaioCore/Sources/PapagaioCore/Runtime/PastaDeModelosDoUsuario.swift:3-13`
— “quem já usa `llama.cpp` ou `whisper.cpp` ... GGUF no disco”]**.
Conclusão: **PROVÁVEL** que o pin local não contém aquelas correções; o
alcance real deve ser testado com fixtures curtas e headers malformados.

#### llama.cpp

O release `b9222` é de 19/05/2026 e o `b11139` é de 23/09/2026, marcado
como **Pre-release**. A release semver `v0.4.1` é de 14/09/2026 e alterou,
entre outras coisas, `llama_sampler_chain_n()` de `int` para `int32_t`.
O wrapper local não chama diretamente essa função, mas a troca de tipos e
as mudanças de GGUF/modelos precisam de compilação e smoke test
**[L: `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:162-176` — cadeia
de sampler, gramática e `llama_sampler_chain_add`]**.

A política de segurança do llama.cpp manda não usar RPC, `ggml-rpc-server` e
`llama-server` em ambientes não confiáveis e recomendar hash de artefatos
baixados. O código Swift do Papagaio não contém uma tela de servidor/RPC; a
busca local encontrou apenas usos de JSON-RPC do MCP, não `llama-rpc`. Isso
reduz a exposição de rede, mas não elimina a superfície do parser GGUF.

#### ONNX Runtime

A release `1.24.2` já inclui uma correção de OOB em `ArrayFeatureExtractor`.
A `1.24.3` lista correções para `GatherCopyData`, `RoiAlign`, LoRA
malicioso e `Resize`; `1.29.0` e `1.30.0` ampliam hardening de carregamento,
shapes, memória, índices e validação. Portanto:

- `1.24.2` não deve ser descrita como vulnerável automaticamente a todos os
  problemas corrigidos depois;
- o pin está, contudo, **confirmadamente atrás** de um conjunto relevante de
  correções de robustez e validação;
- a API C local exige `GetApi(24)` e o header local define
  `ORT_API_VERSION 24` **[L:
  `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Headers/onnxruntime_c_api.h:37-42`
  — “#define ORT_API_VERSION 24”; `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:66-72`
  — “GetApi(24)”]**. Runtime, header e wrapper precisam ser atualizados como
  um conjunto.

#### Silero VAD

O release `v6.2.3` torna `torchaudio` opcional e ajusta o caminho de I/O;
isso não significa automaticamente que o `.onnx` local é diferente. O script
local deliberadamente fixa um commit do arquivo, não a tag
**[L: `Scripts/bootstrap-runtimes.sh:53-58` — “a tag de release não cobre o
artefato do modelo”; `:295-297` — URL `.../76e3dc.../silero_vad.onnx`]**.
A comparação de versão do repositório deve ser separada do hash do artefato.

## 4. Arquitetura local e fluxo de dados

### 4.1 Diagrama

```text
áudio / arquivo
    │
    ├─ AVAssetReader ──> PCM Float32 mono 16 kHz, em blocos
    │                         │
    │                         └─ energia + Silero VAD/ONNX CPU
    │                                  │
    │                                  └─ janelas de fala
    │                                           │
    │                                           └─ Whisper/Metal
    │
    ├─ diarização opcional ──> FluidAudio/Core ML (4 bundles)
    │
    └─ texto ──> llama.cpp/Metal + Qwen GGUF + GBNF
                       │
                       └─ grammar JSON ──> resumo/tradução
```

O formato canônico é confirmado no código
**[L: `PapagaioCore/Sources/PapagaioCore/Captura/FormatoAudio.swift:5-17` —
“PCM Float32, mono, 16 kHz, não intercalado”;
`PapagaioCore/Sources/PapagaioCore/Transcricao/DecodificadorDeAudio.swift:4-16`
— “O Whisper não reamostra por conta própria”]**. O decodificador entrega
blocos, em vez de manter uma reunião inteira em RAM
**[L: `PapagaioCore/Sources/PapagaioCore/Transcricao/DecodificadorDeAudio.swift:22-35`
— “A leitura em blocos ... uma hora de áudio ... centenas de MiB”; `:44-50`
— `processarEmBlocos`]**.

### 4.2 Papéis dos componentes

| Componente | Wrapper local | Backend | Evidência |
|---|---|---|---|
| ASR | `ContextoWhisper` / `WhisperEngine` | Metal + `whisper.cpp` | `ContextoWhisper.swift:108-123`; `WhisperEngine.swift:38-42` |
| LLM | `ContextoLlama` / `QwenEngine` | Metal + `llama.cpp` | `ContextoLlama.swift:71-99`; `QwenEngine.swift:4-10` |
| VAD | `SileroVAD` / `SessaoOnnx` | ONNX Runtime CPU | `SileroVAD.swift:4-11`; `SessaoOnnx.swift:24-30`, `:66-98` |
| Diarização | `DiarizadorFluidoOffline` | FluidAudio + Core ML | `DiarizadorFluidoOffline.swift:39-59` |
| Orquestração | `MotoresLocais`, `PipelineDeArquivo` | residency/fila/fases | `MotoresLocais.swift:5-16`; `PipelineDeArquivo.swift:95-190` |

A distinção ONNX/Core ML é explícita: o manifesto diz que ONNX Runtime roda o
Silero VAD na CPU e o wrapper de diarização importa `FluidAudio`
**[L: `PapagaioCore/Package.swift:24-27` — “ONNX Runtime ... roda o Silero VAD
em CPU”; `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:1-2,39-59`
— `import FluidAudio`, “pipeline pyannote community-1 em Core ML”]**.

### 4.3 Isolamento de módulos

Whisper e llama.cpp embutem uma versão diferente de `ggml`; o manifesto
declara que importá-los no mesmo contexto causa definições divergentes de
`ggml_type`. Por isso existem targets separados
`WhisperRuntime`, `LlamaRuntime` e `OnnxApi`
**[L: `PapagaioCore/Package.swift:29-55` — “os dois frameworks embutem versões
**diferentes** do ggml”; “separando os targets”; “o module C do onnxruntime não
atravessa a fronteira”]**.

Os module maps locais confirmam os links e headers: Whisper e llama expõem
`ggml-metal.h`, `Accelerate`, `Metal`, `Foundation` e `c++`; ONNX expõe o C
API por umbrella header
**[L: `PapagaioCore/Frameworks/whisper.xcframework/.../module.modulemap:1-17`
— “header `ggml-metal.h`”, “link framework `Metal`”; `llama.../module.modulemap:1-17`
— mesmos links; `onnxruntime.../module.modulemap:1-6` — “umbrella header
`onnxruntime_c_api.h`”]**.

## 5. Binários, slices, linking e assinatura

### 5.1 XCFrameworks presentes

Os três XCFrameworks foram reduzidos à slice
`macos-arm64_x86_64`; os `Info.plist` declaram exatamente uma biblioteca,
com `arm64` e `x86_64`
**[L: `PapagaioCore/Frameworks/llama.xcframework/Info.plist:5-21` — “LibraryIdentifier:
`macos-arm64_x86_64`”, “SupportedArchitectures: arm64, x86_64”;
`whisper.xcframework/Info.plist:5-21` — mesmo;
`onnxruntime.xcframework/Info.plist:5-21` — mesmo]**.

| Framework | Executável local | Formato/arquitetura observados | Dependências Mach-O observadas | Versão mínima no bundle |
|---|---|---|---|---:|
| llama | `llama.framework/Versions/A/llama` | Mach-O universal arm64/x86_64 | Metal, Accelerate, Foundation, libc++, libSystem | 13.3 |
| whisper | `whisper.framework/Versions/A/whisper` | Mach-O universal arm64/x86_64 | Metal, Accelerate, Core ML, Foundation, libc++, libSystem | 13.3 |
| ONNX Runtime | `onnxruntime.framework/Versions/A/onnxruntime` | archive universal arm64/x86_64 | otool apresenta um `ar archive` com `prelinked_objects.o` | 14.0 |

A afirmação sobre as versões mínimas e os executáveis é **CONFIRMADA** pelos `Info.plist`
aninhados
**[L: `llama.../Resources/Info.plist:5-30` — “CFBundleExecutable: `llama`”,
“MinimumOSVersion: `13.3`”; `whisper.../Resources/Info.plist:5-30` — “whisper”,
“13.3”; `onnxruntime.../Resources/Info.plist:5-20` — “1.24.2”, “MinimumOSVersion:
`14.0`”]**. O `file`, `otool -L` e `codesign` foram executados sobre esses
mesmos caminhos; por serem arquivos binários, a evidência é
`[CONFIRMADO — inspeção de arquivo binário, sem linha textual]`.

A compilação do pacote é para macOS 26
**[L: `PapagaioCore/Package.swift:1-6` — “swift-tools-version: 6.0”,
“platforms: [.macOS(`26.0`)]”]**, enquanto os binários anunciam mínimos
menores. Isso é compatível em princípio, mas o build final ainda precisa
ser testado no deployment target e na máquina de distribuição.

### 5.2 Poda, dSYM e assinatura

- O bootstrap remove slices não macOS e, por padrão, remove dSYMs; `DSYMS=1`
  preserva o dSYM de macOS
  **[L: `Scripts/bootstrap-runtimes.sh:18-29` — “Só a fatia de macOS”,
  “DSYMS=1”; `:60-102` — `podar_para_macos`, remoção de `dSYMs`]**.
- A inspeção local mostrou `llama` e `whisper` como binários com assinatura
  ad hoc/linker-signed e sem `TeamIdentifier`; o ONNX Runtime local não
  estava assinado. Isso é uma observação de checkout, não uma opinião sobre
  a assinatura final do `.app`. O bootstrap não valida assinatura Apple,
  notarização ou attestations; valida SHA-256 antes de extrair
  **[L: `Scripts/bootstrap-runtimes.sh:122-133` — “curl ...”,
  “verificando SHA-256”, “checksum de ... não confere”; `ci_scripts/ci_post_clone.sh:16-18`
  — o CI baixa os binários]**.
- **Risco PROVÁVEL:** um SHA fixado protege contra alteração do conteúdo
  publicado, mas não substitui uma assinatura de fornecedor nem uma
  verificação de proveniência. A release do llama.cpp `b11139` publica uma
  attestation; o script local não a consulta. Recomenda-se registrar a
  attestation/assinatura como evidência separada, sem trocar o hash ZIP por
  hash do binário extraído.

## 6. Checksums e cadeia de integridade

### 6.1 ZIP de distribuição versus binário extraído

O bootstrap calcula o hash do ZIP **antes** de extrair
**[L: `Scripts/bootstrap-runtimes.sh:122-137` — “baixando ... `curl`”,
“verificando SHA-256”, “extraindo”]**. Portanto, o hash do ZIP e o hash do
executável depois de `unzip` são objetos diferentes e não devem ser
comparados.

| Artefato | SHA-256 declarado do ZIP/arquivo | Evidência da declaração |
|---|---|---|
| llama `b9222` | `39b5d476d5716249fa9fcb7796b89f1a7dc6bd8828531b825efd936cdd51d4f7` | `Scripts/bootstrap-runtimes.sh:49-50` |
| whisper `v1.9.1` | `8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c` | `:51-52` |
| ONNX `1.24.2` | `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54` | `:56-57` |
| `silero_vad.onnx` | `1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3` | `:58`, `:295-297` |

Os ZIPs de llama/whisper não estão no checkout local e não foram baixados
nesta execução. Logo, os dois hashes ZIP são **declarados no script**, não
recalculados aqui. A auditoria não afirma que o servidor ainda entrega
bytes idênticos.

Hashes medidos nos executáveis/arquivos já extraídos, com
`shasum -a 256`, foram:

| Caminho local | SHA-256 medido |
|---|---|
| `PapagaioCore/Frameworks/llama.xcframework/.../llama` | `1ba1789deb679d61b8afee25d1f3727e5ec069d93d2239e90af2b982c2e44bd9` |
| `PapagaioCore/Frameworks/whisper.xcframework/.../whisper` | `50e9a18e22098bb673032ccb7205038de2cbd009fb67f969622bb939d0e89497` |
| `PapagaioCore/Frameworks/onnxruntime.xcframework/.../onnxruntime` | `1e57e861aae21b03780d796a5725288e16d68510a2916c26b3b479fa35c91b92` |
| `PapagaioCore/Sources/PapagaioCore/Resources/silero_vad.onnx` | `1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3` |

O último coincide com o hash do arquivo bruto porque não há etapa de
empacotamento; os três primeiros não devem ser comparados aos hashes ZIP.

### 6.2 ONNX Runtime: hash oficial independente

O manifesto oficial do pacote SPM da Microsoft, consultado em 2026-09-23,
declara a mesma URL e o mesmo SHA do pod archive `1.24.2`
(https://github.com/microsoft/onnxruntime-swift-package-manager/blob/main/Package.swift,
“Target.binaryTarget ... `pod-archive-onnxruntime-c-1.24.2.zip`” e SHA
`f7100a...`). Isso confirma a proveniência do hash declarado; não confirma o
conteúdo do ZIP local, que não foi baixado.

### 6.3 Modelos GGUF

`Preflight` fixa nomes, bytes e hashes dos dois pesos que o app reconhece
**[L: `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:19-36` —
`ggml-large-v3.bin`, 3.095.033.483 bytes, SHA
`64d182...`; `Qwen_Qwen3.5-9B-Q4_K_M.gguf`, 6.169.341.984 bytes, SHA
`d784ce...`; URLs `huggingface.co/.../resolve/main/...`]**.

| Modelo | Bytes esperados | SHA-256 esperado no código | Arquivo observado localmente |
|---|---:|---|---|
| Whisper large-v3 | 3.095.033.483 | `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2` | `~/Library/Application Support/Papagaio/Models/ggml-large-v3.bin` |
| Qwen3.5 9B Q4_K_M | 6.169.341.984 | `d784ce9eda1a5a7b51e8f705a9e6310844bf4f173654d115823c775fdea56d43` | `~/Library/Application Support/Papagaio/Models/Qwen_Qwen3.5-9B-Q4_K_M.gguf` |

A presença e os tamanhos locais são registrados no mapa
**[L: `audit/00-mapa.md:99-102` — “3.095.033.483 B” e
“6.169.341.984 B”]**. O `shasum` local mediu os mesmos dois hashes de
`Preflight`; isso é **CONFIRMADO por inspeção local**, mas a pasta padrão é
configurável.

### 6.4 Core ML: 21 arquivos e proveniência

O bootstrap baixa quatro `.mlmodelc` compilados e
`plda-parameters.json` a partir de `FluidInference/speaker-diarization-coreml`,
com SHA por arquivo
**[L: `Scripts/bootstrap-runtimes.sh:225-264` — “quatro `.mlmodelc` +
`plda-parameters.json`”; `:238-240` — URL `.../resolve/main`; `:241-264` —
 hashes por caminho]**. A tabela de hashes é extensa, mas é importante: a
integridade é por arquivo, não por um hash único do pacote.

Os quatro conjuntos são `Segmentation.mlmodelc`, `FBank.mlmodelc`,
`Embedding.mlmodelc` e `PldaRho.mlmodelc`. Os hashes locais coincidem com o
`provenance.json` oficial consultado. A API do Hugging Face informou, em
2026-09-23, que `main` estava no commit
`df2625ac79a7ac6b65ad868fee6d80f320da4232`; o `provenance.json` do mesmo
model card referencia o snapshot de artefatos
`1ed7a662fdc7109e36d822db793ee6eebdaf8594` e lista os mesmos hashes. A
fonte `PROVENANCE.md` também registra limitações: o checkout upstream exato
usado nas conversões de 2025 não foi gravado e os artefatos são
historicamente reconstruídos, sem atestação de build.

**Implicação de supply chain — CONFIRMADO:** a URL local usa `resolve/main`,
que pode passar a apontar para outro conjunto de bytes. A política de
imutabilidade deve trocar a base por uma revisão do repositório HF (por
exemplo, `df2625...`, após verificar cada caminho e hash) e registrar essa
revisão no script, no `Package.resolved`/manifesto de artefatos ou em um
lockfile equivalente. Não é seguro presumir que o campo `artifact_snapshot`
é uma tag Git resolúvel sem teste explícito.

## 7. Modelos, shapes e dtypes

### 7.1 Contrato de áudio

| Ponto | Valor | Evidência |
|---|---|---|
| Formato | PCM Float32, mono, 16 kHz, non-interleaved | `FormatoAudio.swift:5-17` |
| Entrada Whisper | `[Float]`, esperado pelo header como PCM Float32 | `ContextoWhisper.swift:98-100`; header local `whisper.h:33-36,45-47,74-75` |
| Threading | `activeProcessorCount - 2`, mínimo 1 | `ContextoWhisper.swift:137-142` |
| GPU | `use_gpu = true` | `ContextoWhisper.swift:108-115` |
| Flash Attention | `flash_attn = true` | mesmo |
| Timestamps | `no_timestamps = false`, `token_timestamps = true` | `ContextoWhisper.swift:147-166` |
| Unidades dos timestamps | t0/t1 do header são centésimos; o wrapper divide por 100 | `ContextoWhisper.swift:189-207` |

O header C local também declara que o mesmo `whisper_context` não deve ser
usado simultaneamente por várias threads
**[L: `PapagaioCore/Frameworks/whisper.xcframework/.../whisper.h:42-47` —
“thread-safe as long as the sample whisper_context is not used by multiple
threads concurrently”]**. O wrapper transforma o contexto em actor e o
mantém residente
**[L: `ContextoWhisper.swift:73-82` — “whisper_context não é thread-safe”,
“ator ... modelo fica residente”]**.

### 7.2 Silero VAD / ONNX Runtime

O contrato local é preciso:

| Elemento | Shape | Dtype | Evidência |
|---|---|---|---|
| `input` | `[1, 576]` = contexto 64 + quadro 512 | Float32 | `SileroVAD.swift:110-124` |
| `state` | `[2, 1, 128]` | Float32 | mesmo |
| `sr` | `[1]`, valor 16000 | Int64 | mesmo |
| `output` | probabilidade, primeira saída | Float32 | `SileroVAD.swift:130-137` |
| `stateN` | próximo estado | Float32 | mesmo |
| Quadro | 512 amostras = 32 ms a 16 kHz | Float32 | `SileroVAD.swift:13-29` |

O detector aplica primeiro um energy gate e passa candidatos ao Silero em lotes de 128
e zera estado/contexto no início de cada sequência
**[L: `DetectorDeAtividadeDeVoz.swift:29-34` — “quadrosPorLoteDoSilero =
128”; `:117-157` — energy gate e lotes; `:317-365` — `novaSequencia`, fila e
`finally` de saída]**. Isso evita que duas sequências intercalem o estado
recorrente; a fila explícita é necessária porque cada `await` reabre a
reentrância do actor
**[L: `FilaEstrita.swift:3-13` — “cada `await` ... libera a fila”; `DetectorDeAtividadeDeVoz.swift:50-60`
— “fila garante uma sessão por vez”]**.

O wrapper ONNX permite somente Float32 e Int64, copia os buffers para
memória própria e libera tudo ao fim do `Run`
**[L: `SessaoOnnx.swift:17-22` — “Valores em Float32 ou Int64, com ... dimensões
explícitas”; `:106-129` — “o ONNX Runtime não copia os dados de entrada”; `:132-181`
— alocação, `CreateTensorWithDataAsOrtValue`, `api.Run` e `defer`]**. A
saída é copiada de volta, mas o wrapper atualmente preenche `dimensoes: []` ao
devolver Float/Int64
**[L: `SessaoOnnx.swift:183-212` — “saida[nome] = .flutuante(...,
dimensoes: [])”]**. É uma limitação de validação de shape, não uma prova de
shape incorreta no modelo.

O runtime local usa a API C versão 24 e uma CPU arena
**[L: `SessaoOnnx.swift:66-80` — “GetApi(24)”, “CreateCpuMemoryInfo(OrtArenaAllocator,
OrtMemTypeCPU)”]**. O header oficial descreve `GetApi` e a assinatura de
`CreateCpuMemoryInfo`; a documentação de performance do ORT separa
profiling, memória e threads
(https://onnxruntime.ai/docs/performance/tune-performance/). A escolha de
`OrtArenaAllocator` deve ser validada com `AllocatorGetStats`/logs em uma
próxima versão; não é benchmark neste relatório.

### 7.3 llama.cpp / Qwen

O modelo local é reconhecido pelo nome fixo `Qwen_Qwen3.5-9B-Q4_K_M.gguf`, e
os metadados do GGUF local expõem `general.architecture = qwen35` e
entradas `qwen35.*` (observação `strings`, sem linha). O wrapper define:

- janela `32_768` tokens;
- entrada de um passe até `28_000` tokens;
- `n_batch = 2_048`;
- `n_ubatch = 512`;
- `n_gpu_layers = 999` como pedido de offload;
- gramática GBNF e sampler greedy;
- prefill fatiado em `tokensPorLote = 2_048`.

A configuração é literalmente visível
**[L: `ContextoLlama.swift:52-63` — “janela operacional de 32k”,
“teto de entrada”, “n_batch”; `:71-99` — “n_gpu_layers = 999”, “n_ctx =
janela”, “n_ubatch = 512”; `:151-189` — `llama_memory_clear`, prefill em
fatias, `llama_decode`; `:162-176` — gramática + greedy]**.

`QwenEngine` usa passe único até 28k tokens e map-reduce acima disso, com
chunks de 8.000 tokens
**[L: `QwenEngine.swift:4-23` — “janela de 32k”, “map-reduce”, “tokensPorChunk
= 8.000”; `:45-50` — escolha do modo; `:171-219` — blocos parciais e
consolidação]**. A gramática restringe a forma do JSON, mas não substitui
validação de conteúdo; a engine ainda valida citações contra a transcrição
**[L: `QwenEngine.swift:52-61` — “O modelo sugere; a transcrição decide”;
`:145-168` — reprompt somente se JSON não decodificar]**.

`llama_context_params` oficial descreve `n_batch` como máximo lógico e
`n_ubatch` como máximo físico, e `llama_decode` como operação que pode
restaurar o estado em erro
(https://github.com/ggml-org/llama.cpp/blob/b9222/include/llama.h). A
implementação local se apoia nesses limites; não foi medida a sua adequação ao
Qwen em uma reunião real.

### 7.4 Core ML / FluidAudio

Os metadados locais descrevem quatro modelos MLProgram:

| Modelo | Entrada(s) | Saída | Precisão/storage | Disponibilidade |
|---|---|---|---|---|
| Segmentation | áudio `[B,1,160000]`, B=1…32 | `log_probs` Float32 | Float32 | macOS 14+ |
| FBank | áudio `[B,1,160000]` | `fbank_features` Float32 | Float32 | macOS 14+ |
| Embedding | `fbank_features [B,1,80,998]` + `weights [B,589]` | embedding Float32 | storage Float16, mixed | macOS 14+ |
| PldaRho | embeddings `[B,256]`, B=1…32 | `rho` Float32 | Float32 | macOS 14+ |

As formas e a licença `CC-BY-4.0` estão nos metadados locais
**[L: `Segmentation.mlmodelc/metadata.json:3-24,47-70` — “pyannote community-1
segmentation (10 s ... batch 1-32)”, “Float32”, “macOS 14.0”, shapes
`[1,1,160000]`; `FBank.../metadata.json:3-24,46-68` — “80×998 features”;
`Embedding.../metadata.json:3-24,42-80` — “WeSpeaker ResNet34”, “Float16”,
`1...32 × 1 × 80 × 998`, `1 × 589`; `PldaRho.../metadata.json:3-24,34-61` —
“PLDA rho”, “Float32”, `[1,256]`]**.

Os metadados também registram conversão com PyTorch 2.8.0 e coremltools
9.0b1, e o package resource é copiado opacamente porque há nomes repetidos
dentro de `.mlmodelc`
**[L: `Segmentation.../metadata.json:73-80` — “torch==2.8.0”,
“coremltools.version: 9.0b1”; `PapagaioCore/Package.swift:73-81` — “cópia
opaca: o `.process` recursivo recusa arquivos com o mesmo nome”]**.

O manager FluidAudio local usa `OfflineDiarizerModels.load`, Core ML
`MLModel(contentsOf:)`, um prewarm assíncrono e pipeline de segmentação +
embeddings antes do clustering
**[L: `FluidAudio/.../OfflineDiarizerManager.swift:52-59` — `load` e
`initialize`; `:149-203` — tasks de segmentação/embedding; `:220-279` —
clustering; `:460-510` — prewarm]**. O wrapper converte segmentos para
`S1`, `S2` e segundos
**[L: `DiarizadorFluidoOffline.swift:71-95` — “speakerId”, “startTimeSeconds”,
“endTimeSeconds”]**.

O `ModelHub` local pode bloquear rede em modo offline
**[L: `FluidAudio/.../ModelHub.swift:23-41` — “Offline-only mode ... every
download surface ... throws”; `:100-107` — “In offline mode never delete cache
+ re-download”]**. O wrapper ativa `ModelHub.offlineMode = true` no init
**[L: `DiarizadorFluidoOffline.swift:52-59` — “ModelHub.offlineMode = true”]**.
A implementação do manager possui um caminho de fallback que, fora do modo
offline, tenta apagar e recarregar
**[L: `OfflineDiarizerManager.swift:60-87` — “Attempting fallback download and
compilation”]**. A combinação é offline no wrapper, mas deve ser coberta por
um teste que bloqueie rede e observe a falha, não apenas pela presença da
flag.

## 8. Ciclo de vida, concorrência e residência

### 8.1 O que é confirmado

- `ContextoWhisper` e `ContextoLlama` são actors porque os contexts C não são
  thread-safe; ambos mantêm ponteiros em uma `Caixa` para liberar no
  `deinit`
  **[L: `ContextoWhisper.swift:73-92`; `ContextoLlama.swift:31-46`]**.
- `MotoresLocais` tenta manter Whisper e Qwen mutuamente exclusivos por
  instância e descarrega um antes do outro
  **[L: `MotoresLocais.swift:5-16` — “nunca ficam residentes ao mesmo tempo”;
  `:39-80` — `descarregarResumoSemFila`/`descarregarTranscricaoSemFila`;
  `:122-136` — descargas]**.
- O ciclo de vida observa `warning` e `critical`, descarrega todos os
  residentes e tenta liberar antes do encerramento do app
  **[L: `CicloDeVidaDeModelos.swift:28-46` — “warning, critical”; `:67-77` —
  `descarregarTudo`; `:79-114` — descarga no `NSApplicationWillTerminateNotification`]**.
- A fila do VAD é estrita e cobre também a sequência de streaming
  **[L: `FilaEstrita.swift:3-37`; `DetectorDeAtividadeDeVoz.swift:50-65,106-115`]**.
- O pipeline verifica cancellation entre fases, mas os blocos nativos são
  síncronos; o próprio comentário admite que uma vez dentro do Whisper/Qwen
  não há interrupção imediata
  **[L: `PipelineDeArquivo.swift:107-113` — “uma vez dentro deles, nada os
  interrompe”; `:119-140,159-170,185-190` — checks entre fases]**.

### 8.2 Risco de exclusividade global

A exclusividade é uma invariante do actor `MotoresLocais`, não do processo
inteiro. O app cria um novo `MotoresLocais` por execução
**[L: `Papagaio/ViewModels/Biblioteca.swift:873-903` — `executarProcessamento` e
“os dois modelos somam”; `:894-903` — `let motores = MotoresLocais(...)`]**.
Assim, duas execuções que criem instâncias diferentes podem carregar
Whisper/Qwen residentes simultaneamente. Isso é **PROVÁVEL** a partir do desenho, não
uma medição de jetsam. O mapa recebeu o mesmo achado como A2-003
**[L: `audit/00-mapa.md:594-603` — “exclusividade Whisper/Qwen é por
instância ... app cria instâncias por operação”]**.

**Experimento obrigatório:** criar dois jobs concorrentes, registrar
`phys_footprint`, memória Metal, picos e tempo de término; comparar com um
coordenador global. Só depois decidir se é preciso mudar o invariante.

## 9. Bottlenecks e anti-padrões

Nenhum item abaixo é uma afirmação de velocidade observada. São mecanismos
confirmados no código e hipóteses de custo a medir.

| Mecanismo | Evidência | Hipótese de bottleneck | Experimento |
|---|---|---|---|
| Carga residente de dois GGUF grandes | `MotoresLocais` alterna Whisper/Qwen; app cria engines por operação | Pico de RAM/Metal e contenção se jobs concorrentes escaparem da fila | job concorrente, `phys_footprint`, `ioreg`, fila por fase |
| Prefill do Qwen | `n_batch=2048`, `n_ubatch=512`, tokens por lote 2048 | CPU/GPU sync e cópia em prompts longos | prompt de 1k/8k/28k/32k tokens, p50/p95, energy/Metal counters |
| Map-reduce | chunks de 8k e consolidação | mais chamadas, cópias de `String` e pico de contexto | fronteiras sintéticas de reuniões, instrumentar tokenização/decode por chunk |
| VAD por frame e energy gate | 512 amostras, lote máximo 128, ONNX CPU | custo por hora de áudio e muitos `await` se aumentar o batching | 1 min/10 min/1 h, CPU usage, número de `Run`, overhead por call |
| Streaming Whisper | blocos de 60 s, VAD cria janelas de até 60 s com overlap | cópia de arrays, perda de contexto nas fronteiras e custo de muitas janelas | janelas 10/30/60 s, overlap 0/200 ms, WER/timestamp seam |
| Diarização | quatro Core ML, segmentação+embedding paralelos e clustering | Core ML memory/ANE contention e CPU clustering | áudio 1/10/60 min, `PipelineTimings`, Instruments, RSS |
| Shutdown | descarga em Task com timeout de 2 s | unload parcial e assert de backend Metal na saída | fechar durante carga/decode, repetir 100 vezes, crash logs |
| Preflight | default só tamanho; SHA é opcional | GGUF/ONNX alterado com mesmo tamanho pode passar | arquivo malformado mesmo tamanho; `verificarChecksum: true` |
| URL `resolve/main` | pesos e Core ML usam main | bytes ou proveniência mudam sem revisão local | resolver HEAD imutável vs main e comparar todos os hashes |

Os comentários de ciclo de vida usam “vários segundos” e “meio minuto”
**[L: `CicloDeVidaDeModelos.swift:5-14` — “carregar o modelo do disco leva
vários segundos”; `ContextoLlama.swift:31-35` — “recarregar leva 10–30 s”]**.
Esses números são **não confirmados** nesta auditoria; só podem entrar em
relatório de performance depois de cronometrar carga a frio, carga morna e
descarga no hardware de destino.

## 10. Bugs, CVEs, advisories e depreciações

### 10.1 Advisories do llama.cpp

A página oficial do repositório exibiu **13 advisories** em 2026-09-23. A
tabela resume todas; o alcance completo e PoCs está em cada URL. `b9222` foi
comparado com os intervalos publicados: nenhum intervalo listado contém
`b9222`, mas isso não transforma o build em uma prova de segurança.

| Advisory | CVE/severidade | Intervalo publicado | Superfície | Relevância no Papagaio |
|---|---|---|---|---|
| [GHSA-3p4r-fq3f-q74v](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v) | CVE-2026-27940 / High | affected `<= b8145`; patched `>= b8146` | integer overflow no GGUF/tensor loader | **parser de modelo**; b9222 é posterior ao patch, mas advisories continuam relevantes para entrada não confiável |
| [GHSA-j8rj-fmpv-wcxw](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-j8rj-fmpv-wcxw) | CVE-2026-34159 / Critical | affected `<= b7991`; sem patch listado | RCE não autenticado no RPC `GRAPH_COMPUTE` | **rede/RPC não usada pelo app**; proibir se algum dia exposta |
| [GHSA-96jg-mvhq-q7q7](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-96jg-mvhq-q7q7) | CVE-2026-33298 / High | affected `< b7437`; patched `b7824` | integer overflow em tensor GGUF | **parser de modelo** |
| [GHSA-8947-pfff-2f3c](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8947-pfff-2f3c) | CVE-2026-21869 / Low (página) | affected `<= 55d4206c8`; patched `>= c78fb90` | OOB write em `llama-server` | **não exposto pelo wrapper** |
| [GHSA-vgg9-87g3-85w8](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-vgg9-87g3-85w8) | CVE-2025-53630 / High | affected `< 26a48ad`; patched `26a48ad` | OOB read/write no parser GGUF | **parser de modelo** |
| [GHSA-7rxv-5jhh-j6xx](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-7rxv-5jhh-j6xx) | CVE-2025-52566 / High | affected `< b5721`; patched `b5721` | overflow signed/unsigned no tokenizer | prompts/modelos; b9222 posterior |
| [GHSA-g4cc-763q-h9h6](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-g4cc-763q-h9h6) | sem CVE / Moderate | página reporta affected/patched `c33fe8b8` | over-read em `llama_model_load` | **parser de modelo**; manter a ressalva da página |
| [GHSA-8wwf-w4qm-gpqr](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8wwf-w4qm-gpqr) | CVE-2025-49847 / High | before `b5662`; patched `>= b5662` | overflow no vocabulary/token-to-piece | **parser/vocabulário** |
| [GHSA-wcr5-566p-9cwj](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-wcr5-566p-9cwj) | CVE-2024-42479 / Critical | `< b3561`; patched `>= b3561` | write-what-where em RPC | **RPC não usado** |
| [GHSA-5vm9-p64x-gqw9](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-5vm9-p64x-gqw9) | CVE-2024-42478 / Moderate | `< b3561`; patched `>= b3561` | address read em RPC | **RPC não usado** |
| [GHSA-mqp6-7pv6-fqjf](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-mqp6-7pv6-fqjf) | CVE-2024-42477 / Moderate | `< b3561`; patched `>= b3561` | type não validado em RPC | **RPC não usado** |
| [GHSA-49q7-2jmh-92fp](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-49q7-2jmh-92fp) | CVE-2024-41130 / Moderate | `<= b3426`; patched `b3427` | null pointer no parser GGUF | **parser de modelo** |
| [GHSA-p5mv-gjc5-mwqv](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-p5mv-gjc5-mwqv) | CVE-2024-32878 / High | affected `b2715`; patched `b2740` | free de variável não inicializada no parser GGUF | **parser de modelo** |

A conclusão-síntese é **PROVÁVEL**: o app não deve tratar “nenhum
advisory lista b9222” como prova de que o modelo arbitrário é seguro. O
caminho local permite que um arquivo escolhido pelo usuário chegue a
`llama_model_load_from_file`; a pasta é deliberadamente reutilizável para
modelos existentes
**[L: `PastaDeModelosDoUsuario.swift:3-13`; `MotoresLocais.swift:29-35`]**.

### 10.2 Whisper, ONNX, FluidAudio e Silero

- A página de advisories do `whisper.cpp` consultada não mostra advisories
  publicados. Isso é **ausência de registro**, não ausência de bugs; o
  changelog de `v1.9.3` ainda lista correções de OOB/overflow que estão
  depois do pin local.
- A página de advisories do ONNX Runtime também não mostra advisories
  publicados. As release notes, nesse caso, listam correções de segurança e
  hardening; a release local `1.24.2` é anterior a `1.24.3+`.
- FluidAudio e Silero não têm advisories publicados nas páginas oficiais
  consultadas. Novamente, isso não é atestado de segurança; os artefatos são
 dylib/Core ML/ONNX e o risco muda conforme a origem do arquivo.
- A proveniência do Core ML declara explicitamente limitações de reconstrução
  histórica. Isso é uma limitação de **reprovabilidade**, não um CVE.

### 10.3 Bugs e depreciações que afetam upgrades

| Item | Evidência externa/local | Impacto |
|---|---|---|
| FluidAudio `process()` → `prepare()`/`cluster()` | release `v0.15.6` e manager local `process()` | wrapper deve ser adaptado ou manter pin até compilar contra API nova |
| FluidAudio artifacts mutáveis | script usa `resolve/main`; release `v0.15.8` fala em pin imutável | trocar URL e reprodutibilidade |
| llama CLI `--mmap`/`--mlock`/`--direct-io` depreciados em favor de `--load-mode` | release `v0.4.1` | não afeta o wrapper C atual; importa se scripts/ferramentas passarem a usar CLI |
| ONNX WebGL/JSEP depreciado; WebGPU recomendado | release `v1.29.0` | não afeta o wrapper C CPU atual; não misturar com web |
| `llama_sampler_chain_n()` mudou para `int32_t` | release `v0.4.1` | smoke de compilação; wrapper atual não usa diretamente |
| ONNX API version 24 | header local e `SessaoOnnx` | não misturar header novo com runtime antigo |

## 11. Cadeia de suprimentos, modelos e confiança

### 11.1 O que o bootstrap realmente garante

O script:

1. baixa o ZIP/arquivo com `curl --fail`;
2. calcula SHA-256;
3. aborta se o hash não confere;
4. extrai/copia para um arquivo final e só então promove o resultado.

Isso está em `Scripts/bootstrap-runtimes.sh:122-149` e `:152-191`
**[L: `Scripts/bootstrap-runtimes.sh:125-133` — “esperado”/“obtido”;
`:173-181` — “arquivo válido só substitui o anterior depois de download e
checksum”]**. É um controle forte contra corrupção acidental e troca de
bytes, mas não cobre:

- assinatura do fornecedor;
- attestations GitHub;
- compilação reproduzível do XCFramework;
- confiança na fonte que hospeda o arquivo;
- conteúdo do modelo que o usuário coloca em uma pasta já existente.

### 11.2 Risco do diretório escolhido pelo usuário

O app guarda um bookmark com security scope e mantém o acesso aberto
**[L: `PastaDeModelosDoUsuario.swift:10-13,17-29` — “bookmark com escopo de
segurança”; `ModelosViewModel.swift:27-35` — `pastaEscolhida` ou pasta do
container]**. A UI permite escolher qualquer pasta
**[L: `CartaoDeModelos.swift:63-94` — “Escolher pasta…” e
`allowedContentTypes: [.folder]`]**.

O preflight padrão não calcula SHA:
**[L: `ModelosViewModel.swift:39-43` — “Verificação barata: tamanho em disco,
não SHA-256”; `Preflight.swift:99-103` — `verificarChecksum: Bool = false`; `:128-141` — só
calcula hash quando `verificarChecksum` é true]**. Portanto, um GGUF ou
modelo Whisper com o tamanho esperado pode ser aceito sem validação de
conteúdo. Isso é **CONFIRMADO no fluxo local**; a severidade é
**PROVÁVEL** porque depende do arquivo e do runtime.

O downloader oficial, por outro lado, valida tamanho e SHA dos arquivos que
ele baixa
**[L: `DownloadDeModelos.swift:184-195` — “tamanho”, “hash”, “checksumInvalido”]**.
A distinção é importante: **download controlado tem checksum; pasta
pré-existente não tem checksum por default**.

### 11.3 Proveniência e licença do Core ML

- `metadata.json` registra `Fluid Inference` como author, CC-BY-4.0, PyTorch
  2.8.0 e coremltools 9.0b1
  **[L: `Segmentation.../metadata.json:17-24,73-80`]**.
- `PROVENANCE.md` e `provenance.json` oficiais registram hashes dos artefatos,
  snapshot, ambiente de conversão e a limitação de que os artefatos antigos
  não têm checkout upstream histórico comprovado.
- `NOTICE.md` delimita o escopo CC-BY-4.0 aos artefatos Community-1
  derivados, exige atribuição a pyannote, WeSpeaker, BUT Speech@FIT e Fluid
  Inference e exclui artefatos legados. Isso deve ser conferido antes de
  empacotamento/distribuição, não tratado como detalhe de runtime.

## 12. Recomendações

### P0 — antes de gerar o build da release

1. **Criar um lock de runtime e artefatos.**
   - Fixar revisão HF imutável para todos os Core ML e trocar
     `resolve/main`.
   - Guardar tag, URL, SHA do ZIP, SHA do binário extraído, revisão do
     checkout de build e data de revisão.
   - Manter a distinção ZIP/binário em campos diferentes.
2. **Tratar pasta do usuário como entrada não confiável.**
   - Por padrão, exigir SHA dos dois GGUF, ou apresentar uma tela explícita
     “modelo não verificado” com aviso e opt-in.
   - Rejeitar nomes/arquivos que não estejam na lista explícita dos dois
     modelos permitidos.
   - Se o usuário realmente precisar de modelo arbitrário, executar o parser
     em processo isolado/sandbox e nunca misturar com o processo principal.
3. **Atualizar por componente, com smoke test.** Não fazer “upgrade de tudo”:
   - avaliar `whisper.cpp v1.9.4` e testar áudio curto, timestamp e header
     malformado;
   - avaliar ONNX Runtime pelo menos `v1.24.4` para correções da série e
     depois `v1.30.0` em branch dedicada, atualizando header, archive e
     `GetApi` juntos;
   - avaliar llama `v0.4.1`/`b11139` contra o contrato Qwen3.5 e advisories,
     mantendo o build noturno explicitamente identificado;
   - avaliar FluidAudio `v0.16.1` somente após adaptar/verificar a API
     `prepare()`/`cluster()` e o cancelamento.
4. **Não habilitar RPC/server no bundle ou na rede.** Manter o wrapper em
   processo e adicionar uma regra de teste/assinatura que falhe se
   `ggml-rpc`/`llama-server` for introduzido sem revisão.
5. **Validar o app final assinado.** Reassinar os frameworks e o app como
   um produto, verificar `codesign --verify --deep --strict`, hardened
   runtime, entitlements e arquitetura de cada slice. A assinatura observada nos
   arquivos locais não é o certificado final.

### P1 — robustez e operação

1. Criar um coordenador global de residência para impedir Whisper+Qwen
   simultâneos, ou provar por benchmark/stress test que a fila por instância
   é suficiente.
2. Validar shapes/dtypes no wrapper ONNX; preservar as dimensões recebidas em
   vez de devolvê-las como `[]`, e adicionar testes para output unexpected,
   NaN/Inf e state rollover.
3. Fazer preflight de Core ML para distinguir “layout existe” de “bundle
   carregável”. Hoje `disponivel` é somente uma checagem de existência
   **[L: `GerenciadorDeModelosDeDiarizacao.swift:40-55` — “É uma checagem de
   layout, não de conteúdo nem de carregamento”]**.
4. Adicionar testes de cancelamento durante `whisper_full`,
   `llama_decode`, VAD e Core ML; o pipeline só pode observar cancellation
   entre fases.
5. Registrar no CI a versão/commit de cada XCFramework e modelo, e falhar se
   uma URL `main` mudar de bytes sem revisão explícita.

### P2 — investigação de desempenho

Só executar depois de P0/P1, em clone limpo e máquina de destino:

- **carga a frio/morna** de Whisper, Qwen, Silero e quatro Core ML;
- RTF (`segundos de áudio / segundos de wall clock`) com áudios de 1 s,
  10 s, 1 min, 1 h, silêncio, ruído, dois canais e cenários de fala;
- p50/p95 de VAD, ASR, diarização, resumo e tradução;
- pico de `phys_footprint`, CPU/GPU/ANE, working set e disco;
- número de `llama_decode`, batches, `ONNX Runtime Run`, compilações Core ML;
- custo de troca Whisper↔Qwen e de jobs concorrentes;
- efeitos de `n_batch`, `n_ubatch`, número de threads, batch VAD e janela
  Whisper;
- comparação de qualidade (WER, timestamp error, diarization error e JSON
  validity), não apenas tempo.

O resultado deve publicar p95, distribuição e condições; um único tempo
médio não serve para SLA.

## 13. Onde procurar e como reproduzir a inspeção

### 13.1 Fontes locais

| Assunto | Caminho |
|---|---|
| Manifest SPM e binary targets | `PapagaioCore/Package.swift` |
| Resoluções do FluidAudio | `PapagaioCore/Package.resolved`; `Loro.xcworkspace/.../Package.resolved`; `Loro.xcodeproj/.../Package.resolved` |
| URLs, hashes, poda e module map | `Scripts/bootstrap-runtimes.sh` |
| Pesos, bytes, SHA e preflight | `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift` |
| Download e retomada | `PapagaioCore/Sources/PapagaioCore/Runtime/DownloadDeModelos.swift` |
| Whisper wrapper | `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift` |
| llama wrapper | `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift` |
| ONNX wrapper | `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift` |
| VAD | `PapagaioCore/Sources/PapagaioCore/Transcricao/SileroVAD.swift`, `DetectorDeAtividadeDeVoz.swift`, `FilaEstrita.swift` |
| Residency | `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift`, `MotoresLocais.swift` |
| Fluid wrapper | `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift` |
| Checkout FluidAudio | `PapagaioCore/.build/checkouts/FluidAudio/Sources/FluidAudio/...` |
| XCFrameworks | `PapagaioCore/Frameworks/*.xcframework` |
| Modelos Core ML | `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/` |
| Modelo local de benchmark WIP | `PapagaioCore/Benchmarks/`, não usar como baseline desta ficha |

### 13.2 Comandos somente de inspeção

Executados ou sugeridos, sem baixar artefatos:

```sh
plutil -p PapagaioCore/Frameworks/llama.xcframework/Info.plist
file PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/llama
otool -L PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/llama
codesign -dvvv PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework
shasum -a 256 <arquivo>
strings -a <gguf> | rg 'general.architecture|qwen35'
```

O comando `Scripts/bootstrap-runtimes.sh` **não** deve ser executado como
parte desta ficha: ele baixa/extrai/substitui artefatos. A reprodução de
performance também exige uma decisão explícita de ambiente; não foi feita
aqui.

## 14. Limitações e afirmações não verificadas

1. O mapa foi lido integralmente, mas o working tree já estava sujo e há
   arquivos WIP de benchmark; o mapa lista quatro modificados e vários
   grupos não rastreados
   **[L: `audit/00-mapa.md:556-575` — “baseline tinha 4 modificados + 6
   grupos não rastreados”]**. O relatório não presume que esses WIP sejam
   produto final.
2. Não foi executado `bootstrap-runtimes.sh`; os ZIPs de llama/whisper não
   foram baixados. Hashes ZIP são declarações do script, não medições
   locais.
3. Não foi executado o app, inferência real, diarização real, Core ML load,
   `llama-server` ou RPC. Não há afirmação de throughput, latência, RTF,
   memória ou estabilidade nesta execução.
4. O mapa não mediu macro-benchmark com Qwen/Whisper, p95, pico de memória
   ou custo de carga/descarga
   **[L: `audit/00-mapa.md:819-822`]**.
5. A documentação ONNX Runtime consultada na web é atual; a API 24 e o
   archive local 1.24.2 são a evidência local pinada. Documentação futura
   não deve ser aplicada retroativamente a 1.24.2 sem testar.
6. A proveniência dos Core ML não comprova o checkout upstream histórico
   das conversões de 2025; comprova hashes, snapshot e ambiente registrados.
7. `Info.plist` de llama/whisper mostra `CFBundleShortVersionString=1.0`; a
   identidade de runtime veio do script/tag, não de metadados de versão
   confiável embutida nesses bundles
   **[L: `llama.../Resources/Info.plist:13-20`; `whisper.../Resources/Info.plist:13-20`]**.
8. `Package.resolved` não fixa os XCFrameworks ou os GGUF; ele é
   autoritativo apenas para FluidAudio. A diretiva de bootstrap e a política
   de modelos precisam de um lock separado.
9. A API do FluidAudio pode mudar entre releases; a comparação de release
   não substitui compilação e teste de cancelamento/offline.
10. A ausência de advisory no GitHub não é equivalência a ausência de
    vulnerabilidade; especialmente para binários pré-empacotados, a
    superfície real é a soma do parser, backend, OS e modelo.
11. Alguns endpoints `api.github.com` retornaram 403 por rate limit durante a
    pesquisa; release pages HTML, raw URLs e Hugging Face foram usados como
    fontes alternativas. Isso limita a comparação diferencial automatizada,
    não a leitura das fontes citadas.
12. Nenhuma alteração de produção, configuração, dependência, serviço ou
    banco foi feita. O único arquivo escrito por esta atividade é este
    relatório.

## 15. Registro de fontes oficiais consultadas

Todas as fontes abaixo foram acessadas em **2026-09-23**. O ponto indicado
é uma paráfrase do que foi consultado, não uma citação reproduzida.

| ID | URL, versão/commit e data | Ponto consultado |
|---|---|---|
| E1 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5 — `v0.15.5`, `19600a485...`, 07/07/2026 | ModelHub/download stack, diarização, VAD e release que originou o checkout local |
| E2 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6 — `v0.15.6`, `4dbf4f9...`, 19/08/2026 | `OfflineDiarizerManager` `process()` dividido em `prepare()`/`cluster()` |
| E3 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7 — `v0.15.7`, `41540ea...`, 10/09/2026 | cancellation do diarizador offline e correções de borda |
| E4 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8 — `v0.15.8`, `87a39df...`, 20/09/2026 | pin de artefatos de diarização em revisão imutável |
| E5 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.16.1 — `v0.16.1`, `b811a615...`, 21/09/2026 | “No API changes”, correção Mac Catalyst e Nemo processing |
| E6 | https://github.com/FluidInference/FluidAudio/security/advisories — página oficial, 23/09/2026 | não havia advisories publicados no repositório |
| E7 | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.1 — `v1.9.1`, `f049fff...`, 19/06/2026 | release local e commit de origem |
| E8 | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.3 — `v1.9.3`, `371b5a7...`, 20/08/2026 | pre-release; OOB/overflow em áudio curto e header de tensor |
| E9 | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4 — `v1.9.4`, `927cfce...`, 11/09/2026 | release mais recente consultada e correções de Metal/decoder/mel |
| E10 | https://github.com/ggml-org/whisper.cpp/security/advisories — página oficial, 23/09/2026 | não havia advisories publicados |
| E11 | https://github.com/ggml-org/llama.cpp/releases/tag/b9222 — `b9222`, `9a532ae4...`, 19/05/2026 | build local e asset XCFramework |
| E12 | https://github.com/ggml-org/llama.cpp/releases/tag/b11139 — `b11139`, `42916d83...`, 23/09/2026 | build mais recente consultado, marcado pre-release, e URL XCFramework |
| E13 | https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.1 — `v0.4.1`, `b29c606e...`, 14/09/2026 | release semver mais recente, APIs, modelos e depreciações de CLI |
| E14 | https://github.com/ggml-org/llama.cpp/security — política oficial, 23/09/2026 | risco de modelos não confiáveis, RPC, hash e isolamento |
| E15 | https://github.com/ggml-org/llama.cpp/security/advisories e páginas `?page=1`/`?page=2` — 13 advisories, 23/09/2026 | lista, severidade, CVEs e intervalos de versões |
| E16 | https://github.com/microsoft/onnxruntime/releases/tag/v1.24.2 — `v1.24.2`, `058787c...`, 19/02/2026 | release pinada e correção de OOB em `ArrayFeatureExtractor` |
| E17 | https://github.com/microsoft/onnxruntime/releases/tag/v1.24.3 — `v1.24.3`, `3a728b7...`, 05/03/2026 | correções de `GatherCopyData`, `RoiAlign`, LoRA e `Resize` |
| E18 | https://github.com/microsoft/onnxruntime/releases/tag/v1.24.4 — `v1.24.4`, `2d92497...`, 17/03/2026 | correções pontuais da série 1.24 |
| E19 | https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0 — `v1.29.0`, `2e2543f...`, 12/08/2026 | hardening de shapes/inputs, paths e depreciação de WebGL/JSEP |
| E20 | https://github.com/microsoft/onnxruntime/releases/tag/v1.30.0 — `v1.30.0`, `f2c39fe...`, 10/09/2026 | release mais recente, hardening de loading/memória/validação |
| E21 | https://github.com/microsoft/onnxruntime-swift-package-manager/blob/main/Package.swift — manifest SPM, 23/09/2026 | URL e SHA oficial do pod archive `1.24.2` |
| E22 | https://onnxruntime.ai/docs/api/c/struct_ort_api.html — documentação C API, 23/09/2026 | `GetApi`, `CreateCpuMemoryInfo`, `Run` e contrato de tensores |
| E23 | https://onnxruntime.ai/docs/performance/tune-performance/ — documentação de performance, 23/09/2026 | profiling, memória e threads como eixos de experimento |
| E24 | https://github.com/snakers4/silero-vad/releases/tag/v6.2.3 — `v6.2.3`, `5cd7945...`, 23/09/2026 | release mais recente; `torchaudio` opcional |
| E25 | https://github.com/snakers4/silero-vad/security/advisories — página oficial, 23/09/2026 | não havia advisories publicados |
| E26 | https://raw.githubusercontent.com/snakers4/silero-vad/76e3dc408eb2a5c655c34e230d2d5459b4439daa/src/silero_vad/utils_vad.py — commit local, 23/09/2026 | contrato ONNX: 512 amostras, contexto 64, state `[2,batch,128]`, `sr` Int64 |
| E27 | https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml — resposta HF, 23/09/2026 | revision `main` `df2625ac...` e lista de arquivos |
| E28 | https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/main/provenance.json — provenance HF, 23/09/2026 | snapshot `1ed7a...`, hashes, ambiente e limitações |
| E29 | https://huggingface.co/FluidInference/speaker-diarization-coreml/raw/main/PROVENANCE.md e `NOTICE.md` — 23/09/2026 | source mapping, conversão Community-1 e escopo de licença |

## 16. Conclusão técnica

A base local é coerente quanto ao desenho: três runtimes nativos foram
isolados para evitar conflito de `ggml`, ONNX trata o VAD em CPU, Core ML
trata a diarização e os modelos grandes são mantidos sob um ciclo de vida
explícito. O maior risco não é uma incompatibilidade de shape já visível,
mas a combinação de **runtime C antigo + entrada de modelo controlada pelo
usuário + URL de distribuição mutável + ausência de validação de
checksum por default**.

A próxima mudança segura é uma série de passos de manutenção:
primeiro lock/provenance e validação de entrada; depois smoke tests de
segurança e API; somente então upgrades de runtime; e, em separado,
medição de desempenho com fixtures e métricas declaradas. Até que essa
medição exista, qualquer afirmação de “rápido”, “leve” ou “sem gargalo”
deve ser classificada como **HIPÓTESE**.

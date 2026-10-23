# V-P2 — Verificação independente de `ai-runtimes.md`

> **Objeto:** `audit/01-pesquisa/ai-runtimes.md`<br>
> **Corte externo:** 2026-09-23T19:29:57Z`<br>
> **Veredito:** a arquitetura local, os pins, os checksums declarados, a maior parte dos contratos de shapes/dtypes e a maior parte das recomendações são sustentados. A ficha, porém, contém duas divergências objetivas e um conjunto relevante de ajustes e qualificações de segurança/runtime.

## 1. Escopo, método e regra de classificação

A verificação foi refeita sem aceitar a ficha como evidência. Foram relidos o manifesto SPM, os três `Package.resolved`, o bootstrap, os wrappers C/Swift, o preflight/downloader, o ciclo de vida, o VAD, a diarização, os metadados Core ML, os headers/plists e as permissões. As páginas oficiais foram reabertas e as respostas foram confrontadas com o código real.

Não foram executados `Scripts/bootstrap-runtimes.sh`, o app, inferência, diarização real, `MLModel(contentsOf:)`, `llama-server`, RPC ou build/assinatura final. Não foram baixados ZIPs ou modelos. Foram usados somente arquivos já presentes, inspeções locais, `HEAD`, GitHub API e páginas/documentos oficiais. Páginas `latest`, branches e `resolve/main` são mutáveis; as afirmações “mais recente” abaixo valem apenas para o corte registrado.

Classes usadas:

- **CONFIRMADO** — a fonte oficial e/ou a inspeção local sustentam a afirmação no escopo declarado.
- **CONFIRMADO COM AJUSTE** — o núcleo é verdadeiro, mas a ficha precisa limitar alcance, provedor, comprovação ou redação.
- **REFUTADO** — a afirmação, tal como escrita e sem a ressalva que a tornaria correta, é falsa.
- **INCONCLUSIVO** — os dados disponíveis não permitem confirmar o efeito de runtime, segurança ou concorrência alegado.

Locator de binário não tem linha textual. Nesses casos, o relatório identifica o caminho e o comando; nunca atribui linha a bytes. `Info.plist`, headers e código-fonte são usados apenas como localizadores textuais complementares.

## 2. Contagens

| Unidade | CONFIRMADO | CONFIRMADO COM AJUSTE | REFUTADO | INCONCLUSIVO | Total |
|---|---:|---:|---:|---:|---:|
| Claims técnicos `C01–C41` | 29 | 8 | 2 | 2 | 41 |
| Advisories `A01–A13` | 10 | 3 | 0 | 0 | 13 |
| Recomendações `R01–R13` | 10 | 3 | 0 | 0 | 13 |
| Omissão de localizador `O01` | 1 | 0 | 0 | 0 | 1 |
| **Total** | **50** | **14** | **2** | **2** | **68** |

Outros contadores:

- **59 URLs oficiais distintas** inspecionadas; 56 retornaram corpo/HEAD/API diretamente e 3 páginas Apple foram confirmadas por excerto oficial indexado.
- **13 advisories** do llama.cpp, **12 com CVE** e **1 sem CVE**.
- **0 dos 13 advisories** coloca `b9222` no intervalo afetado; a natureza/reachability é tratada por advisory.
- **27 arquivos locais** tiveram SHA-256 recalculado: 3 binários extraídos, Silero ONNX, 2 GGUF e 21 arquivos Core ML.
- **3 ZIPs de distribuição** não estão no checkout e não tiveram hash recalculado; seus hashes foram apenas comparados à declaração local e aos metadados oficiais.
- **21/21 hashes Core ML** coincidem entre bootstrap, `provenance.json` e arquivos locais; não há arquivo extra nem faltante no conjunto de 21.
- **2 URLs mutáveis** de pesos usam `resolve/main`; o conjunto Core ML usa uma terceira base `resolve/main` com 21 caminhos.

## 3. Divergências para o Árbitro

1. **D1 — `REFUTADO`: FluidAudio `v0.16.1` não era a release mais recente no corte.** A release oficial mais recente era `v0.17.1`, marcada `Latest`; `v0.17.0` já havia sido publicada. `v0.17.1` é uma release que altera somente metadados e diz que o SPM pode permanecer em `v0.17.0`. Ver `C26`, `S05–S07`.
2. **D2 — `REFUTADO`: a atomicidade do bootstrap é generalizada demais.** `baixar_arquivo` promove arquivo simples com temporário + `mv`, mas `baixar` copia o XCFramework diretamente para o destino e só depois poda. Uma interrupção pode deixar um framework parcial. Ver `C14`, `Scripts/bootstrap-runtimes.sh:107-116,139-149,173-181`.
3. **D3 — `CONFIRMADO COM AJUSTE`: “CPU e não Core ML” precisa ser qualificado.** A sessão C não registra o execution provider Core ML e, pela documentação oficial, usa o provider CPU; entretanto, o binário ONNX local contém símbolos `CoreMLExecutionProvider`. A redação correta é: “o caminho configurado usa o provider CPU; o pacote contém, mas não registra, Core ML”. Ver `C06`, `S44`.
4. **D4 — `CONFIRMADO COM AJUSTE`: GPU, Flash Attention e offload total são pedidos, não medições.** `use_gpu`, `flash_attn` e `n_gpu_layers=999` estão no código; não foi provado que cada operador ou modelo ficou integralmente no Metal. Ver `C04–C05`.
5. **D5 — `CONFIRMADO COM AJUSTE`: advisories não demonstram um advisory alcançável no pin.** `b9222` está fora dos intervalos afetados. Em especial, GHSA-3p4r declara que o caminho principal `llama_model_loader` usa `no_alloc=true` e não é afetado. Release notes de hardening não devem ser convertidas em CVE. Ver `A01–A13`, `C28–C30`, `C39–C40`.
6. **D6 — `CONFIRMADO COM AJUSTE` e `INCONCLUSIVO`: o risco de residência precisa considerar a fila real.** A fila normal de `Biblioteca` serializa jobs, portanto dois processamentos normais não concorrem por essa via. Porém, ditado e diarização de transcrição existente criam novos `MotoresLocais` e podem cruzar a execução principal. A residência simultânea real não foi medida. Ver `C32–C33`.
7. **D7 — `CONFIRMADO COM AJUSTE`: “rejeitar nomes arbitrários” é redundante e insuficiente.** `Preflight` e as engines já procuram dois nomes fixos; um arquivo malicioso renomeado para o nome esperado e com o tamanho correto ainda passa sem SHA. Ver `R03`, `C23`.
8. **D8 — omissão material:** o registro de residentes de `CicloDeVidaDeModelos` é um dicionário por identificador; duas instâncias do mesmo tipo sobrescrevem a anterior. A ficha não registra esse risco ao recomendar coordenador global. Ver `C41`.
9. **D9 — qualificação de provenance:** `main` do Core ML estava em `df2625ac…`, enquanto `provenance.json` registra `artifact_snapshot=1ed7a662…`. São identificadores de contextos diferentes, não uma contradição; ambos devem ser gravados separadamente. O provenance também lista caminhos que o bootstrap não embute (por exemplo, `PLDA`, `mlpackages` e `xvector-transform`); a comparação de 21 arquivos é do subconjunto realmente estagiado. Ver `C20`.

## 4. Checksums e provenance

### 4.1 Matriz de objetos e níveis de prova

| Objeto | Hash declarado / oficial | Hash recalculado localmente | Conclusão |
|---|---|---|---|
| llama `b9222` ZIP | `39b5d476d5716249fa9fcb7796b89f1a7dc6bd8828531b825efd936cdd51d4f7` no script; mesmo digest e 203.536.578 B na GitHub Release API (`S14`) | ZIP ausente; não recalculado | **CONFIRMADO** como declaração que coincide com os metadados oficiais; não prova um ZIP local. O binário extraído é outro objeto: `1ba1789deb679d61b8afee25d1f3727e5ec069d93d2239e90af2b982c2e44bd9`. |
| whisper `v1.9.1` ZIP | `8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c` no script; mesmo digest e 50.438.515 B na GitHub Release API (`S56`) | ZIP ausente; não recalculado | **CONFIRMADO** como declaração oficial. O binário extraído é `50e9a18e22098bb673032ccb7205038de2cbd009fb67f969622bb939d0e89497`, não comparável ao ZIP. |
| ONNX Runtime `1.24.2` pod ZIP | `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54` no script e no manifesto SPM oficial (`S41`) | ZIP ausente; não recalculado | **CONFIRMADO** como declaração oficial. O binário extraído é `1e57e861aae21b03780d796a5725288e16d68510a2916c26b3b479fa35c91b92`. |
| `silero_vad.onnx` no commit | `1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3` no script | Mesmo hash; 2.327.524 B | **CONFIRMADO** local. A API upstream fornece tamanho e Git blob SHA, não um SHA-256 oficial; não houve download. |
| Whisper large-v3 | Preflight: `64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2`, 3.095.033.483 B; `x-linked-size` e `x-linked-etag` HF iguais no corte (`S54`) | Mesmo hash e tamanho | **CONFIRMADO** para o arquivo local e para os metadados HF no corte; não transforma `main` em pin imutável. |
| Qwen3.5-9B-Q4_K_M | Preflight: `d784ce9eda1a5a7b51e8f705a9e6310844bf4f173654d115823c775fdea56d43`, 6.169.341.984 B; `x-linked-size` e `x-linked-etag` HF iguais no corte (`S55`) | Mesmo hash e tamanho | **CONFIRMADO** para o arquivo local e para os metadados HF no corte; não transforma `main` em pin imutável. |
| 21 arquivos Core ML | 21 hashes no script; os mesmos 21 caminhos/hashes existem em `provenance.json` (`S50`) | 21/21 hashes e tamanhos coincidem; conjunto local exato de 21 arquivos | **CONFIRMADO**. O provenance lista também caminhos não estagiados; `main=df2625ac79a7ac6b65ad868fee6d80f320da4232` e `artifact_snapshot=1ed7a662fdc7109e36d822db793ee6eebdaf8594` são identificadores de contextos diferentes. |

### 4.2 SHA-256 local dos 21 arquivos Core ML

Os valores abaixo foram recalculados no checkout e coincidem com `Scripts/bootstrap-runtimes.sh:243-263` e com `provenance.json`:

```text
Embedding.mlmodelc/analytics/coremldata.bin  8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682
Embedding.mlmodelc/coremldata.bin             4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004
Embedding.mlmodelc/metadata.json              1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5
Embedding.mlmodelc/model.mil                  22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3
Embedding.mlmodelc/weights/weight.bin         99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b
FBank.mlmodelc/analytics/coremldata.bin       0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a
FBank.mlmodelc/coremldata.bin                 57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759
FBank.mlmodelc/metadata.json                  2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a
FBank.mlmodelc/model.mil                      27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed
FBank.mlmodelc/weights/weight.bin             9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36
PldaRho.mlmodelc/analytics/coremldata.bin     8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7
PldaRho.mlmodelc/coremldata.bin               4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418
PldaRho.mlmodelc/metadata.json                b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945
PldaRho.mlmodelc/model.mil                    83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041
PldaRho.mlmodelc/weights/weight.bin           80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36
Segmentation.mlmodelc/analytics/coremldata.bin 64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb
Segmentation.mlmodelc/coremldata.bin           ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc
Segmentation.mlmodelc/metadata.json            88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124
Segmentation.mlmodelc/model.mil                d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f
Segmentation.mlmodelc/weights/weight.bin       c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2
plda-parameters.json                           38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f
```

### 4.3 Regra de interpretação

- **ZIP** é o objeto publicado no release e recebe o hash de distribuição.
- **Binário extraído** é outro objeto; seu hash não deve ser comparado ao hash do ZIP.
- **Modelo GGUF** é um terceiro objeto, com 3,1/6,2 GB e metadados HF próprios.
- **Core ML** possui 21 arquivos; não existe um hash único válido para “o pacote inteiro” sem definir uma árvore ou serialização.
- `provenance.json` demonstra hashes e ambiente, mas declara `exact_historical_revision_verified=false` e `status=historically-reconstructed`; não é atestação de build.

## 5. Matriz de claims técnicos

| ID | Claim verificável | Fonte oficial e resposta usada | Localizador real | Classe |
|---|---|---|---|---|
| C01 | O app combina Whisper/llama.cpp, ONNX/Silero e FluidAudio/Core ML em papéis separados. | `S44`: o Core ML EP precisa de registro explícito; o código local configura a sessão ONNX sem esse registro. | `PapagaioCore/Package.swift:12-37`; `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:108-175`; `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:67-98`; `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:39-81`. | **CONFIRMADO** — o caminho ONNX configurado é CPU; os símbolos Core ML do pacote não mudam essa separação. |
| C02 | FluidAudio está em `0.15.5`, commit `19600a485…`, nos três arquivos de resolução. | `S01`: tag `v0.15.5`, commit `19600a4…`, release de 07/07/2026. | `PapagaioCore/Package.swift:11-16`; `PapagaioCore/Package.resolved:5-10`; `Loro.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-10`; `Loro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-10`. | **CONFIRMADO** |
| C03 | Os pins efetivos são llama `b9222`, whisper `v1.9.1`, ONNX `1.24.2`, Silero `76e3dc4…`, com URLs e SHA no bootstrap. | `S14` e `S56`: artefatos e digest dos dois XCFramework; `S41`: URL/SHA do pod ONNX; `S48`: arquivo Silero no commit. | `Scripts/bootstrap-runtimes.sh:47-58,282-297`. | **CONFIRMADO** |
| C04 | Whisper recebe Float32 16 kHz, solicita GPU/Flash Attention e timestamps por token. | `S09`: release `v1.9.1`; o header local fixa 16 kHz. | `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:98-100,108-115,137-175,189-191`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Headers/whisper.h:33-36,45-46,74-75`. | **CONFIRMADO COM AJUSTE** — o código solicita GPU/FA; a execução efetiva em cada operador não foi medida. |
| C05 | llama usa Qwen3.5, janela 32k, `n_gpu_layers=999`, batch/ubatch e gramática. | `S16`: a release documenta API/Qwen3.5; `S33`: header do pin. | `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:52-99,151-189`; `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:29-34`; `PapagaioCore/Sources/PapagaioCore/Sumarizacao/QwenEngine.swift:18-23,45-50`. | **CONFIRMADO COM AJUSTE** — 999 é pedido de offload, não prova de offload total. |
| C06 | Silero usa ONNX Runtime em CPU e não registra Core ML. | `S44`: “CoreML EP must be explicitly registered”; CPU é o provider padrão. | `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:67-86,167-175`; `PapagaioCore/Package.swift:24-27`; inspeção `strings` encontrou `_OrtSessionOptionsAppendExecutionProvider_CoreML` no binário. | **CONFIRMADO COM AJUSTE** — a sessão não registra Core ML; o binário inclui o EP. |
| C07 | Diarização usa quatro bundles Core ML via FluidAudio; ONNX Runtime não é o executor dessa etapa. | `S01` e `S49–S52`: FluidAudio/Community-1 e provenance dos artefatos. | `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:39-59,65-81`; `PapagaioCore/.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerModels.swift:90-142`; `PapagaioCore/Package.swift:61-80`. | **CONFIRMADO** |
| C08 | O formato canônico é PCM Float32 mono 16 kHz e o transcodificador trabalha em blocos. | `S09` sustenta o release do Whisper; o header local fixa 16 kHz e o formato canônico é contrato local. | `PapagaioCore/Sources/PapagaioCore/Captura/FormatoAudio.swift:5-18`; `PapagaioCore/Sources/PapagaioCore/Transcricao/DecodificadorDeAudio.swift:44-63`; `PapagaioCore/Sources/PapagaioCore/Transcricao/WhisperEngine.swift:82-123`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Headers/whisper.h:33-36`. | **CONFIRMADO** |
| C09 | Whisper e llama ficam em targets Swift separados para evitar conflito de `ggml`; ONNX tem módulo C próprio. | `S33` é a API C do pin; a necessidade de isolar os headers é fato local de build. | `PapagaioCore/Package.swift:29-55`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Modules/module.modulemap:1-17`; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Modules/module.modulemap:1-6`. | **CONFIRMADO** |
| C10 | Os XCFrameworks têm uma slice macOS `arm64_x86_64` e anunciam mínimos 13.3/14.0. | `S14`, `S56` e `S41` confirmam os artefatos; os metadados locais confirmam slices e mínimos. | `PapagaioCore/Frameworks/llama.xcframework/Info.plist:5-21`; `PapagaioCore/Frameworks/whisper.xcframework/Info.plist:5-21`; `PapagaioCore/Frameworks/onnxruntime.xcframework/Info.plist:5-21`; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Resources/Info.plist:5-30`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Resources/Info.plist:5-30`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Resources/Info.plist:9-20`. | **CONFIRMADO** |
| C11 | Os três artefatos locais são universais arm64/x86_64; ONNX é um archive estático `ar` e as dependências locais são as descritas. | `S14`, `S56` e `S41`; `file`/`otool` são inspeções dos artefatos já presentes. | `file` e `otool -L` em `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/llama`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/whisper`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime`; plists `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Resources/Info.plist:5-20`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Resources/Info.plist:5-20`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Resources/Info.plist:5-20`. | **CONFIRMADO** |
| C12 | llama/whisper locais são ad-hoc/linker-signed sem TeamIdentifier; ONNX não está assinado. | `S57`: a origem do XCFramework deve ser inspecionada; `S58–S59`: assinatura de código aninhado e hardened runtime. | `codesign -dvvv PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework`; `codesign -dvvv PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework`; `codesign -dvvv PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework`; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Resources/Info.plist:7-22`; `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Resources/Info.plist:7-22`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Resources/Info.plist:9-20`. | **CONFIRMADO** |
| C13 | No caminho de download, o bootstrap valida SHA antes de extrair/copiar; o hash publicado é conferido. | `S14`, `S56` e `S41` confirmam os hashes publicados; `S48` confirma o objeto Silero. | `Scripts/bootstrap-runtimes.sh:122-149,152-191`; `PapagaioCore/Sources/PapagaioCore/Runtime/DownloadDeModelos.swift:168-195`. | **CONFIRMADO** — desde que o ramo de download não seja pulado. |
| C14 | O bootstrap sempre promove somente arquivos válidos para o destino final de forma atômica. | `S14/S56`: os assets existem; a atomicidade é um controle local. | `Scripts/bootstrap-runtimes.sh:139-149` (`cp -R` direto) versus `:173-181` (temporário + `mv`). | **REFUTADO** — a atomicidade vale para `baixar_arquivo`, não para XCFrameworks. |
| C15 | Um XCFramework existente com `Info.plist` real é aceito sem nova validação. | `S14/S56` mostram que o asset publicado tem digest imutável, mas o script local não consulta o digest ao pulá-lo. | `Scripts/bootstrap-runtimes.sh:107-116`. | **CONFIRMADO** — é uma omissão de risco não descrita na ficha. |
| C16 | O SHA do pod ONNX 1.24.2 é o mesmo no manifesto SPM oficial. | `S41`: resposta do `Package.swift` contém URL, `1.24.2` e `f7100a…0b54`. | `Scripts/bootstrap-runtimes.sh:56-57`; `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:66-72`; `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Headers/onnxruntime_c_api.h:37-42`. | **CONFIRMADO** |
| C17 | Os dois pesos têm tamanho/SHA esperados e os dois arquivos locais têm exatamente esses valores. | `S54` e `S55`: HEAD HF retornou `x-linked-size` e `x-linked-etag` iguais ao código. | `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:19-36`; `stat` e `shasum -a 256` nos dois arquivos em `~/Library/Application Support/Papagaio/Models/`. | **CONFIRMADO** |
| C18 | As URLs dos pesos são mutáveis `resolve/main`; trocar a branch pode mudar bytes/revisão. | `S53`: documentação HF diz que `refs/main` muda e commit hash é imutável. | `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:26,33`. | **CONFIRMADO** |
| C19 | Os 21 Core ML locais coincidem com os hashes por arquivo do bootstrap e da provenance. | `S50`: `provenance.json` lista hashes, snapshot e ambiente. | `Scripts/bootstrap-runtimes.sh:225-274`; 21 `metadata.json`/binaries sob `ModelosDeDiarizacao/`; comparação local SHA-256. | **CONFIRMADO** |
| C20 | O lock de provenance deve distinguir `main` do Core ML de `artifact_snapshot`. | `S49`: `main=df2625ac…`; `S50`: `artifact_snapshot=1ed7a662…`; `S51`: o snapshot de artefatos é um contexto separado. | `Scripts/bootstrap-runtimes.sh:238-264`. | **CONFIRMADO COM AJUSTE** — são identificadores diferentes; a ficha deve preservar ambos explicitamente. |
| C21 | Os quatro metadados Core ML descrevem Community-1, tipos/precisão, shapes de entrada e schemas de saída, macOS 14+, CC-BY e torch 2.8/coremltools 9.0b1. | `S50–S52`: provenance, `PROVENANCE.md` e `NOTICE.md` oficiais. | `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/diarizacao/speaker-diarization/Segmentation.mlmodelc/metadata.json:3-24,47-80`; `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/diarizacao/speaker-diarization/FBank.mlmodelc/metadata.json:3-24,46-78`; `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/diarizacao/speaker-diarization/Embedding.mlmodelc/metadata.json:3-24,42-88`; `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/diarizacao/speaker-diarization/PldaRho.mlmodelc/metadata.json:3-24,39-68`. | **CONFIRMADO** — os `outputSchema` têm `shape: []`; os shapes enumerados estão nos `inputSchema`. |
| C22 | O app permite escolher uma pasta acessível, guarda bookmark com escopo de segurança e mantém o acesso aberto. | `S57`–`S59` não substituem esta prova local; a entitlement é local. | `PapagaioCore/Sources/PapagaioCore/Runtime/PastaDeModelosDoUsuario.swift:10-50`; `Papagaio/ViewModels/ModelosViewModel.swift:19-55`; `Papagaio/Funcionalidades/Biblioteca/CartaoDeModelos.swift:63-95`; `Config/Papagaio.entitlements:19-32`. | **CONFIRMADO** |
| C23 | A pasta pré-existente é validada por tamanho por padrão, e os motores usam nomes fixos. | `S17`: llamaCPP recomenda isolamento para modelos não confiáveis. | `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:99-140`; `Papagaio/ViewModels/ModelosViewModel.swift:39-43`; `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:29-35`. | **CONFIRMADO** |
| C24 | Um GGUF malicioso na pasta escolhida realmente pode executar RCE no processo atual. | `S17` recomenda sandbox para modelos desconhecidos; `S20–S32` documentam o parser e RCE, mas `b9222` está fora dos intervalos. | `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`; `PapagaioCore/Sources/PapagaioCore/Runtime/PastaDeModelosDoUsuario.swift:17-50`. | **INCONCLUSIVO** — o caminho de entrada é real; nenhum PoC foi executado e o impacto depende do arquivo/binário. |
| C25 | O downloader controlado valida tamanho e SHA para os pesos configurados; a diferença é pasta preexistente versus download. | `S53` fundamenta os checksums do Hub; a implementação local é a evidência decisiva. | `PapagaioCore/Sources/PapagaioCore/Runtime/DownloadDeModelos.swift:82-87,168-195`; `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:128-140`. | **CONFIRMADO** |
| C26 | FluidAudio `v0.16.1` é a release mais recente consultada em 2026-09-23. | `S05`: `v0.16.1`; `S06`: `v0.17.0`; `S07`: `v0.17.1` aparece como `Latest` e altera somente metadados. | `PapagaioCore/Package.swift:15`; `PapagaioCore/Package.resolved:5-10`. | **REFUTADO** — no corte, a latest é `v0.17.1`; para SPM, o alvo prático novo é `v0.17.0` ou posterior. |
| C27 | FluidAudio 0.15.6–0.15.8/0.16.1 registram as mudanças de API, cancelamento e pin imutável indicadas. | `S02`–`S05`: as release notes confirmam as mudanças específicas. | checkout `PapagaioCore/.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift:29-129`; wrapper `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:65-81`. | **CONFIRMADO** — a quebra `process()`→`prepare()/cluster()` aparece em `v0.15.6`; não se deve atribuí-la a todas as releases. |
| C28 | Whisper `v1.9.1` está atrás de releases posteriores que corrigem OOB/overflow e hardening de loader. | `S10`: `v1.9.3` lista OOB de áudio curto, header tensor e hardening GGML; `S11`: `v1.9.4` é latest. | `PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/Headers/whisper.h:33-36`; `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:137-175`; `Scripts/bootstrap-runtimes.sh:51-52`. | **CONFIRMADO COM AJUSTE** — são correções de release, não advisories/CVEs; `v1.9.3` aparece como pre-release. |
| C29 | O nightly `b11139` do llama é mais novo que `b9222` e está marcado como pre-release; `v0.4.1` é a latest semver. | `S15`: `b11139`, `Pre-release`, atestação; `S16`: `v0.4.1` latest; `S34`: comparação confirma descendência do fix `c33fe8b`. | `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:162-189`; `Scripts/bootstrap-runtimes.sh:49-50`. | **CONFIRMADO** |
| C30 | ONNX `1.24.2` está atrás de hardening posterior, e header/runtime devem ser atualizados juntos. | `S35–S39`: notas de 1.24.2–1.30.0; `S40`: página de advisories sem advisories publicados; `S41–S44`: API/provedor. | `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:66-98,183-212`; header `PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/Headers/onnxruntime_c_api.h:37-42`. | **CONFIRMADO COM AJUSTE** — release notes de segurança não provam que o Silero local é vulnerável; `1.24.4` é dívida de série, não CVE específico. |
| C31 | Silero tem release `v6.2.3`, mas o artefato local é pinado por commit porque a tag não cobre o `.onnx`. | `S45`: `v6.2.3` torna torchaudio opcional; `S46`: sem advisories; `S47–S48`: contrato e objeto no commit. | `Scripts/bootstrap-runtimes.sh:53-58,295-297`; `PapagaioCore/Sources/PapagaioCore/Transcricao/SileroVAD.swift:110-137`. | **CONFIRMADO** — release do repositório não é upgrade automático do artefato ONNX. |
| C32 | A exclusividade Whisper/Qwen é por instância, enquanto a fila normal de arquivos serializa o processamento. | `S17` é a recomendação de isolamento; o desenho da fila é local. | `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:16-24,39-80,138-177`; `Papagaio/ViewModels/Biblioteca.swift:823-838,852-860,988-1008`. | **CONFIRMADO COM AJUSTE** — não afirmar que dois jobs normais correm juntos; há caminhos auxiliares que criam instâncias. |
| C33 | Dois modelos pesados ficam residentes simultaneamente no processo em uma execução concorrente real. | `S17` descreve risco de modelos não confiáveis, não mede esta aplicação. | `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:39-80`; `Papagaio/ViewModels/Biblioteca.swift:852-860,988-1008`; não há execução concorrente nesta auditoria. | **INCONCLUSIVO** — risco de design confirmado; ocorrência real, pico e jetsam não medidos. |
| C34 | A exclusão mútua dos contexts e o cancelamento entre fases estão implementados; blocos nativos são síncronos. | `S33` e headers oficiais sustentam os contratos C; cancelamento é local. | `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:73-92`; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:31-46`; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:107-190`. | **CONFIRMADO** |
| C35 | `ModelHub.offlineMode=true` impede downloads do FluidAudio em runtime. | `S01` descreve a pilha ModelHub; o checkout local é decisivo. | `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:47-59`; `PapagaioCore/.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/Download/ModelHub.swift:23-40,100-107`; `PapagaioCore/.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift:60-87`. | **CONFIRMADO COM AJUSTE** — a rede é bloqueada, mas o fallback do gerenciador tenta limpar o cache antes da segunda carga; “offline” não é “não destrutivo”. |
| C36 | O wrapper ONNX copia entradas/saídas, mas perde dimensões de saída (`[]`). | `S42`: contrato C de tensor shape; limitação é Swift local. | `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:106-181,183-212`; `PapagaioCore/Sources/PapagaioCore/Transcricao/SileroVAD.swift:116-137`. | **CONFIRMADO** |
| C37 | `GerenciadorDeModelosDeDiarizacao.disponivel` checa existência/layout, não carregamento Core ML. | `S01` e `S51` explicam provenance/compilação; o código local é a prova. | `PapagaioCore/Sources/PapagaioCore/Diarizacao/GerenciadorDeModelosDeDiarizacao.swift:40-55`; `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:61-81`. | **CONFIRMADO** |
| C38 | RPC/`llama-server` não está no bundle de código examinado. | `S17`: a política de segurança do llama.cpp proíbe RPC/server em rede não confiável; `S18–S19` listam apenas advisories. | `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-99`; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`; busca local `rg` sem ocorrências em código de produção. | **CONFIRMADO** |
| C39 | Há 13 advisories oficiais do llama.cpp e nenhum intervalo contém `b9222`. | `S18–S19`: 10 + 3 advisories; cada `S20–S32` traz intervalo/CVE. | `Scripts/bootstrap-runtimes.sh:49-50`; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`. | **CONFIRMADO** — “histórico” não significa “seguro”. |
| C40 | Whisper/ONNX/FluidAudio/Silero não têm advisories publicados, mas release notes de hardening não são CVEs. | `S08`, `S12`, `S40`, `S46`: as páginas dizem “There aren't any published security advisories”. | `Scripts/bootstrap-runtimes.sh:282-297`; `PapagaioCore/Package.swift:11-27`. | **CONFIRMADO** |
| C41 | O registro global de residentes pode sobrescrever duas instâncias do mesmo identificador. | `S17` é apenas política geral; fato local de lifecycle. | `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift:53-55,67-75`; `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:48,64`; `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:145-147`. | **CONFIRMADO** — omissão material da ficha. |

## 6. Matriz de advisories/CVEs

> “Pin afetado?” é decidido pelo intervalo oficial e pela relação do commit/tag, não por ser uma release “recente”. `b9222` corresponde ao commit `9a532ae4…` e é posterior aos patches dos advisories abajo; para `GHSA-g4cc`, o compare oficial `c33fe8b…b9222` mostra 3.573 commits e o fix `c33fe8b` está no ancestry.

| ID | Advisory / CVE / severidade | Intervalo oficial e natureza | `b9222` | Reachability no Papagaio | Classe / localizador |
|---|---|---|---|---|---|
| A01 | [GHSA-3p4r-fq3f-q74v](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v) (S20), CVE-2026-27940, High | afetado `<= b8145`; corrigido `>= b8146`; integer overflow em `gguf_init_from_file_impl`, heap write/RCE. A página afirma que o main loader usa `no_alloc=true` e **não é afetado**. | Não afetado; posterior a `b8146`. | O app chama `llama_model_load_from_file`, não o caminho `no_alloc=false` citado como afetado. O risco genérico do parser continua sendo uma questão de política, não deste advisory. | **CONFIRMADO COM AJUSTE**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`. |
| A02 | GHSA-j8rj-fmpv-wcxw (S21), CVE-2026-34159, Critical | affected `<= b7991`; sem patch; RCE RPC `GRAPH_COMPUTE`, sem autenticação. | Não afetado por intervalo. | RPC não registrado/não usado. Não habilitar RPC continua correto. | **CONFIRMADO**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-99`; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`. |
| A03 | GHSA-96jg-mvhq-q7q7 (S22), CVE-2026-33298, High | affected `< b7437`; patched `b7824`; overflow em `ggml_nbytes` ao parsear tensor GGUF. | Não afetado; posterior a `b7824`. | Parser GGUF é caminho geral, mas este advisory não é alcançável no pin. | **CONFIRMADO**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`. |
| A04 | GHSA-8947-pfff-2f3c (S23), CVE-2026-21869, Low na página | affected `<= 55d4206c8`; fixed `>= c78fb90`; OOB write em `llama-server` via `n_discard`. | Não afetado; posterior. | `llama-server` não é importado/empacotado. | **CONFIRMADO**; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`; busca local sem server. |
| A05 | GHSA-vgg9-87g3-85w8 (S24), CVE-2025-53630, High | affected `< 26a48ad`; fixed `26a48ad`; integer overflow/OOB no parser GGUF. | Não afetado; `b9222` é descendente do fix. | Parser local existe, mas pin está fora do intervalo. | **CONFIRMADO**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`; `S34`. |
| A06 | GHSA-7rxv-5jhh-j6xx (S25), CVE-2025-52566, High | affected `< b5721`; fixed `b5721`; signed/unsigned overflow em tokenização de input humano. | Não afetado; posterior a `b5721`. | O wrapper limita prompt a `tokens.count < janela-maxTokens`; o PoC da advisory exige payload acima de `INT32_MAX`, não demonstrado no app. | **CONFIRMADO COM AJUSTE**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:155-159,223-247`. |
| A07 | GHSA-g4cc-763q-h9h6 (S26), sem CVE, Moderate | affected `c33fe8b8`; patched `c33fe8b8`; over-read de special token/vocab em `llama_model_load`/print info. | O advisory metadata tem affected e patched iguais; `b9222` contém o commit de fix, portanto não é a versão afetada. | `llama_model_load_from_file` existe, mas o PoC é `llama-cli`/`print_info`; não foi demonstrado no wrapper. | **CONFIRMADO COM AJUSTE**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`; `S26`, `S34`. |
| A08 | GHSA-8wwf-w4qm-gpqr (S27), CVE-2025-49847, High | “all versions before patch”; fixed `>= b5662`; overflow em vocabulary/token-to-piece por GGUF malicioso. | Não afetado; posterior a `b5662`. | Parser/vocab local existe, mas pin não está no intervalo. | **CONFIRMADO**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82,223-263`. |
| A09 | GHSA-wcr5-566p-9cwj (S28), CVE-2024-42479, Critical | affected `< b3561`; fixed `>= b3561`; write-what-where em `rpc_server::set_tensor`. | Não afetado; posterior a `b3561`. | RPC não é caminho de código. | **CONFIRMADO**; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`. |
| A10 | GHSA-5vm9-p64x-gqw9 (S29), CVE-2024-42478, Moderate | affected `< b3561`; fixed `>= b3561`; arbitrary address read em `rpc_server::get_tensor`. | Não afetado; posterior a `b3561`. | RPC não é caminho de código. | **CONFIRMADO**; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`. |
| A11 | GHSA-mqp6-7pv6-fqjf (S30), CVE-2024-42477, Moderate | affected `< b3561`; fixed `>= b3561`; type não validado em `rpc_tensor`/RPC. | Não afetado; posterior a `b3561`. | RPC não é caminho de código. | **CONFIRMADO**; `PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/Modules/module.modulemap:1-17`. |
| A12 | GHSA-49q7-2jmh-92fp (S31), CVE-2024-41130, Moderate | affected `<= b3426`; fixed `b3427`; null dereference em `gguf_init_from_file`. | Não afetado; posterior a `b3427`. | Parser GGUF existe, mas pin está fora do intervalo. | **CONFIRMADO**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`. |
| A13 | GHSA-p5mv-gjc5-mwqv (S32), CVE-2024-32878, High | affected `b2715`; fixed `b2740`; free de variável não inicializada no parser GGUF. | Não afetado; `b9222` não é `b2715` e é posterior a `b2740`. | Parser GGUF existe, mas pin está fora do intervalo. | **CONFIRMADO**; `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:79-82`. |

**Síntese de advisories:** há 13 advisories oficiais, 12 CVEs, 5 relacionadas a RPC/server e 8 a GGUF/token/vocab. Nenhuma é “CVE do pin local” por simples release posterior; a recomendação de não tratar `b9222` como prova de segurança continua válida.

## 7. Matriz de recomendações

| ID | Recomendação da ficha | Avaliação independente | Classe |
|---|---|---|---|
| R01 | Criar lock de runtime/artefatos, fixar revisão HF e guardar ZIP, binário, checkout e data em campos distintos. | `S53` confirma que o commit é imutável; `S49–S52` dão revision e provenance; a distinção objeto/hash é necessária. | **CONFIRMADO** |
| R02 | Exigir SHA dos GGUF ou mostrar “não verificado” com opt-in. | `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:128-140` mostra o default inseguro; `S54–S55` fornecem hashes oficiais. | **CONFIRMADO** |
| R03 | Rejeitar nomes de arquivo fora da allowlist. | `S17` recomenda isolamento; `Preflight` e `MotoresLocais` já usam dois nomes fixos, mas a recomendação não impede conteúdo malicioso com tamanho correto. | **CONFIRMADO COM AJUSTE** — manter como UX explícita, mas exigir SHA/isolamento. |
| R04 | Se houver modelo arbitrário, executar o parser em processo isolado/sandbox. | `S17` manda isolar modelos não confiáveis; o app já tem App Sandbox, mas o parser no mesmo processo continua sendo a superfície. | **CONFIRMADO** |
| R05 | Atualizar componente a componente: Whisper 1.9.4, ONNX 1.24.4→1.30, llama 0.4.1/nightly, Fluid 0.16.1 após API. | `S05–S16` mostram a direção; `0.16.1` ficou desatualizada, então usar `0.17.0/0.17.1` como avaliação, mantendo smoke de API/cancelamento. | **CONFIRMADO COM AJUSTE** |
| R06 | Não habilitar RPC/server. | `S17` recomenda não usar RPC/server em rede não confiável; `C38` confirma ausência atual. | **CONFIRMADO** |
| R07 | Validar o `.app` final assinado, nested code, hardened runtime e entitlements. | `S57–S59` sustentam inspeção de origem, assinatura e notarização; a assinatura local não representa o bundle final. | **CONFIRMADO** |
| R08 | Criar coordenador global de residência ou provar a fila por stress test. | `S17` recomenda isolamento; a fila normal serializa, mas caminhos auxiliares criam instâncias e `C41` mostra colisão no registro. | **CONFIRMADO COM AJUSTE** — coordenador/experimento continua recomendado. |
| R09 | Preservar dimensões de saída e testar output inesperado, NaN/Inf e rollover. | `S42` é o contrato C; `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:183-212` perde shape e não há validação de finitude. | **CONFIRMADO** |
| R10 | Fazer preflight de Core ML que carregue os bundles, não só layout. | `S51` distingue artefato compilado/provenance; `PapagaioCore/Sources/PapagaioCore/Diarizacao/GerenciadorDeModelosDeDiarizacao.swift:40-55` só faz checagem de existência. | **CONFIRMADO** |
| R11 | Adicionar cancelamento durante `whisper_full`, `llama_decode`, VAD e Core ML. | `S33`/`S42` documentam os contratos; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:107-113` admite bloqueio síncrono e não há prova de interruptibilidade nativa. | **CONFIRMADO** |
| R12 | Registrar versão/commit de XCFramework/modelo no CI e falhar se `main` mudar. | `S53` descreve `main` como mutável; `S53` e `S50` dão o mecanismo para comparar. | **CONFIRMADO** |
| R13 | Executar P2 de performance/qualidade somente depois de P0/P1, com p50/p95, RSS/Metal/ANE e WER/erros. | A ficha não fez benchmark; `S43` descreve eixos oficiais de profiling/memória/threads. | **CONFIRMADO** |

## 8. Omissões e qualificadores

| ID | Omissão encontrada | Evidência | Classe |
|---|---|---|---|
| O01 | “Onde procurar” omite o caminho completo da entrada não confiável e da coordenação: `PapagaioCore/Sources/PapagaioCore/Runtime/PastaDeModelosDoUsuario.swift`, `Papagaio/ViewModels/ModelosViewModel.swift`, `Papagaio/Funcionalidades/Biblioteca/CartaoDeModelos.swift`, `Config/Papagaio.entitlements`, `PapagaioCore/Sources/PapagaioCore/Diarizacao/GerenciadorDeModelosDeDiarizacao.swift`, `PapagaioCore/Sources/PapagaioCore/Transcricao/WhisperEngine.swift`, `PapagaioCore/Sources/PapagaioCore/Transcricao/DecodificadorDeAudio.swift`, `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift`, `Papagaio/ViewModels/Biblioteca.swift`, além de headers/plists. Isso impede reproduzir as afirmações de segurança, provider, exclusividade e assinatura a partir da própria lista. | `audit/01-pesquisa/ai-runtimes.md:900-920`; os localizadores listados acima. | **CONFIRMADO** |

## 9. Matriz de URLs oficiais e resposta observada

| Fonte | URL oficial | Resposta/conteúdo observado no corte |
|---|---|---|
| S01 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.5 | `v0.15.5`, `19600a4`, 07/07/2026; ModelHub, download e diarização. |
| S02 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6 | Corpo da release: `OfflineDiarizerManager: split process() into prepare()/cluster()`. |
| S03 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.7 | Corpo da release: cancelamento propagado ao diarizador offline. |
| S04 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.8 | Corpo da release: “Pin diarization artifacts to immutable revision”. |
| S05 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.16.1 | 21/09, `b811a61`; “No API changes” e correção do Catalyst. |
| S06 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.0 | 23/09, `3ca01bb`; Nemotron 3 Diarization. |
| S07 | https://github.com/FluidInference/FluidAudio/releases/tag/v0.17.1 | 23/09, `5c51c5c`, marcada `Latest`; metadata-only, e o SPM pode permanecer em `0.17.0`. |
| S08 | https://github.com/FluidInference/FluidAudio/security/advisories | “There aren't any published security advisories”. |
| S09 | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.1 | `f049fff`, release de 19/06/2026. |
| S10 | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.3 | Pre-release; OOB de áudio curto, `n_dims` e hardening de GGML. |
| S11 | https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4 | `927cfce`, latest, 11/09/2026. |
| S12 | https://github.com/ggml-org/whisper.cpp/security/advisories | “There aren't any published security advisories”. |
| S13 | https://github.com/ggml-org/llama.cpp/releases/tag/b9222 | `9a532ae`, 19/05/2026; artefato XCFramework. |
| S14 | https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b9222 | JSON: artefato `llama-b9222-xcframework.zip`, `digest=sha256:39b5…d4f7`, 203.536.578 B. |
| S15 | https://github.com/ggml-org/llama.cpp/releases/tag/b11139 | `42916d8`, `Pre-release`, 23/09; atestação listada. |
| S16 | https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.1 | Latest semver; `llama_sampler_chain_n()` para `int32_t`; flags da CLI depreciadas. |
| S17 | https://github.com/ggml-org/llama.cpp/security | Política: sandbox para modelos não confiáveis; não usar RPC/server em rede não confiável; confirmar hashes. |
| S18 | https://github.com/ggml-org/llama.cpp/security/advisories?page=1 | 10 advisories listados. |
| S19 | https://github.com/ggml-org/llama.cpp/security/advisories?page=2 | 3 advisories listados. |
| S20 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v | High, CVE-2026-27940, `<=b8145`, correção `b8146`; main loader com `no_alloc=true` não afetado. |
| S21 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-j8rj-fmpv-wcxw | Critical, CVE-2026-34159, RPC, `<=b7991`, sem patch. |
| S22 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-96jg-mvhq-q7q7 | High, CVE-2026-33298, `<b7437`, correção `b7824`. |
| S23 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8947-pfff-2f3c | Low, CVE-2026-21869, llama-server, `<=55d4206c8`, correção `c78fb90`. |
| S24 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-vgg9-87g3-85w8 | High, CVE-2025-53630, `<26a48ad`, correção `26a48ad`. |
| S25 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-7rxv-5jhh-j6xx | High, CVE-2025-52566, `<b5721`, correção `b5721`. |
| S26 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-g4cc-763q-h9h6 | Moderate, sem CVE, afetado/corrigido `c33fe8b8`; over-read de vocab. |
| S27 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8wwf-w4qm-gpqr | High, CVE-2025-49847, antes de `b5662`, correção `b5662`. |
| S28 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-wcr5-566p-9cwj | Critical, CVE-2024-42479, RPC, `<b3561`, correção `b3561`. |
| S29 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-5vm9-p64x-gqw9 | Moderate, CVE-2024-42478, RPC, `<b3561`, correção `b3561`. |
| S30 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-mqp6-7pv6-fqjf | Moderate, CVE-2024-42477, RPC, `<b3561`, correção `b3561`. |
| S31 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-49q7-2jmh-92fp | Moderate, CVE-2024-41130, `<=b3426`, correção `b3427`. |
| S32 | https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-p5mv-gjc5-mwqv | High, CVE-2024-32878, afetado `b2715`, correção `b2740`. |
| S33 | https://raw.githubusercontent.com/ggml-org/llama.cpp/b9222/include/llama.h | Header `llama_context_params`, `n_batch`, `n_ubatch` e `llama_model_load_from_file`. |
| S34 | https://github.com/ggml-org/llama.cpp/compare/c33fe8b8...b9222 | Resposta do compare: base `c33fe8b8`, head `b9222`, 3.573 commits; o fix está no ancestry. |
| S35 | https://github.com/microsoft/onnxruntime/releases/tag/v1.24.2 | Notas de segurança; correção de OOB em `ArrayFeatureExtractor`. |
| S36 | https://github.com/microsoft/onnxruntime/releases/tag/v1.24.3 | Correções de segurança: GatherCopyData, RoiAlign, LoRA e Resize. |
| S37 | https://github.com/microsoft/onnxruntime/releases/tag/v1.24.4 | Correções pontuais da série 1.24; `S40` não mostra advisories publicados. |
| S38 | https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0 | Latest na série consultada: hardening de paths, shapes, validação de entrada e depreciação de WebGL/JSEP. |
| S39 | https://github.com/microsoft/onnxruntime/releases/tag/v1.30.0 | Latest; hardening de carregamento de modelos, memória e shapes/rank/index. |
| S40 | https://github.com/microsoft/onnxruntime/security/advisories | “There aren't any published security advisories”. |
| S41 | https://raw.githubusercontent.com/microsoft/onnxruntime-swift-package-manager/refs/heads/main/Package.swift | URL e SHA `f7100a…0b54` para o pod archive `1.24.2`. |
| S42 | https://onnxruntime.ai/docs/api/c/struct_ort_api.html | Documentação da C API para `GetApi`, shape de tensor, `CreateCpuMemoryInfo`, `Run` e estatísticas do allocator. |
| S43 | https://onnxruntime.ai/docs/performance/tune-performance/ | Eixos oficiais de performance: latência, throughput, memória, profiling e gestão de threads. |
| S44 | https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html | O EP Core ML precisa ser registrado explicitamente; pacotes arm64 oficiais podem contê-lo. |
| S45 | https://github.com/snakers4/silero-vad/releases/tag/v6.2.3 | Latest; `torchaudio` opcional; a release declara que o modelo em si não mudou. |
| S46 | https://github.com/snakers4/silero-vad/security/advisories | “There aren't any published security advisories”. |
| S47 | https://raw.githubusercontent.com/snakers4/silero-vad/76e3dc408eb2a5c655c34e230d2d5459b4439daa/src/silero_vad/utils_vad.py | 512 amostras, contexto 64, state `[2,batch,128]`, `sr` Int64. |
| S48 | https://api.github.com/repos/snakers4/silero-vad/contents/src/silero_vad/data/silero_vad.onnx?ref=76e3dc408eb2a5c655c34e230d2d5459b4439daa | JSON: arquivo, 2.327.524 B, Git blob `80c5592…`, raw URL imutável. |
| S49 | https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml | JSON: `main` = `df2625ac79a7ac6b65ad868fee6d80f320da4232`, lista dos 21 arquivos. |
| S50 | https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/main/provenance.json | JSON: hashes, `artifact_snapshot=1ed7a662…`, ambiente, caminhos e limitações. |
| S51 | https://huggingface.co/FluidInference/speaker-diarization-coreml/raw/main/PROVENANCE.md | Histórico de conversão, mapeamento das fontes, “not build-attested” e limitações. |
| S52 | https://huggingface.co/FluidInference/speaker-diarization-coreml/raw/main/NOTICE.md | Escopo CC-BY-4.0, atribuições e exclusões de artefatos legados. |
| S53 | https://huggingface.co/docs/huggingface_hub/main/en/guides/manage-cache | Commit é imutável; `main` é resolvido e pode mudar; `resolve_revision`/verificação de checksum. |
| S54 | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin | HEAD: `x-repo-commit=5359861c…`, `x-linked-size=3095033483`, `x-linked-etag=64d182…d1e2`. |
| S55 | https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF/resolve/main/Qwen_Qwen3.5-9B-Q4_K_M.gguf | HEAD: `x-repo-commit=182be2fd…`, `x-linked-size=6169341984`, `x-linked-etag=d784ce…6d43`. |
| S56 | https://api.github.com/repos/ggml-org/whisper.cpp/releases/tags/v1.9.1 | JSON: artefato `whisper-v1.9.1-xcframework.zip`, digest `8c3ecbe7…1a4c`, 50.438.515 B. |
| S57 | https://developer.apple.com/documentation/xcode/verifying-the-origin-of-your-xcframeworks | Excerto oficial: o build system verifica mudanças de assinatura/identidade em XCFrameworks. |
| S58 | https://developer.apple.com/documentation/security/resolving-common-notarization-issues | Excerto oficial: `codesign -vvv --deep --strict`; hardened runtime/entitlements são exigidos para notarização. |
| S59 | https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac | Excerto oficial: assinar separadamente o código aninhado; `--deep` não substitui a assinatura correta. |

## 10. Limitações e escopo negativo

- Nenhum ZIP, GGUF ou modelo foi baixado; as conclusões de hash local se aplicam aos arquivos que já estavam no checkout/Application Support.
- `curl -I`/GitHub API e páginas HTML não substituem uma atestação verificável do artefato final.
- Não foi executado o app nem observado qual provider/Metal/ANE foi efetivamente selecionado em uma inferência real.
- Não foi executado fuzzing, PoC de advisory, `llama-server`, RPC, `codesign --verify` do `.app` ou notarização.
- A árvore de trabalho já estava suja; a auditoria não alterou os quatro modificados preexistentes nem os arquivos WIP. Os localizadores deste relatório apontam para o estado observado da árvore, não para um commit limpo.
- O texto original e as páginas “latest” podem mudar depois do corte; em especial, `v0.17.1` torna a tabela de releases da ficha desatualizada.
- Para os binários, `file`, `otool`, `codesign` e SHA não têm linha. `Info.plist`, headers e código-fonte fornecem os localizadores textuais citados; eles não substituem a inspeção binária.

## 11. Reprodução das inspeções locais

```sh
# hashes de binários e arquivo já presente
shasum -a 256 PapagaioCore/Frameworks/llama.xcframework/macos-arm64_x86_64/llama.framework/Versions/A/llama
shasum -a 256 PapagaioCore/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/whisper
shasum -a 256 PapagaioCore/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64/onnxruntime.framework/Versions/A/onnxruntime
shasum -a 256 PapagaioCore/Sources/PapagaioCore/Resources/silero_vad.onnx

# hashes dos modelos já existentes
shasum -a 256 "$HOME/Library/Application Support/Papagaio/Models/ggml-large-v3.bin"
shasum -a 256 "$HOME/Library/Application Support/Papagaio/Models/Qwen_Qwen3.5-9B-Q4_K_M.gguf"

# metadados Core ML e 21 hashes
python3 - <<'PY'
from pathlib import Path
import hashlib
root = Path("PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/diarizacao/speaker-diarization")
for p in sorted(x for x in root.rglob("*") if x.is_file()):
    print(p.relative_to(root), p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
PY

# formato, dependências e assinatura dos binários
file PapagaioCore/Frameworks/*/macos-arm64_x86_64/*.framework/Versions/A/*
otool -L <framework>/Versions/A/<binary>
codesign -dvvv <framework>
```

Nenhum comando acima executa o bootstrap, baixa modelo ou inicia serviço.

## 12. Conclusão

A ficha é tecnicamente sólida como inventário e como plano de manutenção, e a maior parte dos hashes, pins, wrappers e contratos sobrevive à verificação independente. As correções prioritárias para o Árbitro são: (1) atualizar o corte de FluidAudio para `v0.17.1`/`v0.17.0`; (2) separar a atomicidade de `baixar_arquivo` da cópia de XCFramework; (3) qualificar CPU versus Core ML, GPU solicitado versus GPU observado e release note versus CVE/advisory; (4) substituir a afirmação simples de concorrência por um experimento de stress; (5) acrescentar os caminhos de entrada, ciclo de vida global e provenance ao índice de localizadores. Essas correções não invalidam a arquitetura; apenas impedem que um snapshot de código seja tratado como prova de segurança, performance ou compatibilidade de runtime.

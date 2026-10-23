# P5 — Pesquisa: ferramentas de build/CI, runtimes de IA locais e supply chain

**Data das consultas:** 23/09/2026 (todas as URLs acessadas nesta data, salvo indicação).
**Modo:** relatório somente-leitura. Nenhum código de produção alterado, nenhuma dependência atualizada, nenhum comando destrutivo executado. Neste relatório **não há valores completos de segredo** — onde há segredo, só o local e o prefixo mascarado.

---

## 0. Método e cobertura (o que rodou, com o quê)

| Ação | Ferramenta/comando | Resultado |
|---|---|---|
| Vulnerabilidades SwiftPM/Actions/PyPI | **OSV API** `POST https://api.osv.dev/v1/querybatch` (query por `ecosystem`+`version`) | 5 consultas (ver §5) |
| Vulnerabilidades GitHub Actions e Swift | **GitHub Advisory DB REST** `GET https://api.github.com/advisories?ecosystem=actions\|swift` | 55 advisories (actions) e 62 (swift) listados e filtrados por pacote |
| Advisories dos runtimes C++ | Páginas + API dos repositórios (`/security/advisories`, `/security-advisories`) | llama.cpp: 13; whisper.cpp: 0; onnxruntime: 0 publicados |
| Sanidade da API OSV | consulta `lodash@4.17.11` (npm) | 7 GHSAs → API OK |
| Existência da versão PyPI do ONNX | `GET https://pypi.org/pypi/onnxruntime/1.24.2/json` | HTTP 200 (versão existe) |
| Release notes das versões fixadas | páginas de releases dos 5 upstreams + tag específica | ver §1 e §5 |
| Manifestos auditáveis | busca por `requirements*.txt`, `pyproject.toml`, `package.json`, `Pipfile`, `poetry.lock` | **0** → `pip-audit`/`npm audit` sem alvo |
| Ferramentas locais | `which osv-scanner pip-audit npm` | osv-scanner **ausente**, pip-audit **ausente**, npm presente (sem package.json) |
| Caça a segredos | `grep -E` com padrões (AIza…, ghp_…, GOCSPX-, sk-, xox…, AKIA…, Bearer …), `git log -S`, `git check-ignore` | ver §6.4 |
| Linhagem do workspace | `git log`, `git remote -v`, `git status`, `xcodebuild -version`, `swift --version` | ver §1.7 |

**Limitação honesta:** o `osv-scanner` e o `pip-audit` não estão instalados e não foram instalados (modo relatório). A checagem OSV foi feita pela API pública. A API `GET /v1/ecosystems` do OSV devolveu 404 nesta execução — a validade de cada `ecosystem` usada foi confirmada por contraprova (lodash/npm devolveu 7 resultados; `ecosystem=swift` do GitHub devolveu 200 com 62 advisories; `ecosystem=actions` devolveu 55).

---

## 1. Versões usadas vs. atuais (e o que mudou entre elas)

### 1.1 Tabela-resumo (tudo lido nesta execução; upstream consultado em 23/09/2026)

| Dependência | Versão fixada (nossa, arquivo:linha) | Última disponível em 23/09/2026 | Atraso | Fonte da versão atual |
|---|---|---|---|---|
| FluidAudio (única SwiftPM) | **0.15.5** — `PapagaioCore/Package.swift:15` (`exact:`); pinado em 3 `Package.resolved` (`PapagaioCore/Package.resolved:9-10`, `Loro.xcworkspace/xcshareddata/swiftpm/Package.resolved:9-10`, `Loro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:9-10` — revisão `19600a485b…`) | **v0.16.1** (21/09/2026) | 4 releases (0.15.6, 0.15.7, 0.16.0, 0.16.1) | github.com/FluidInference/FluidAudio/releases |
| whisper.cpp | **v1.9.1** — `Scripts/bootstrap-runtimes.sh:51-52` (tag + SHA-256) | **v1.9.4** (11/09/2026) | 3 releases (v1.9.2 04/08, v1.9.3 20/08, v1.9.4 11/09) | github.com/ggml-org/whisper.cpp/releases |
| llama.cpp | **b9222** (19/05/2026) — `Scripts/bootstrap-runtimes.sh:49-50` | **b11139** (23/09/2026) | ~1.917 builds nightly (~4 meses) | github.com/ggml-org/llama.cpp/releases |
| ONNX Runtime | **1.24.2** — `Scripts/bootstrap-runtimes.sh:56-57` | **v1.30.0** (10/09/2026); última patch da linha 1.24 é **1.24.4** (17/03/2026) | 6 minors + 2 patches da linha | github.com/microsoft/onnxruntime/releases |
| Silero VAD (modelo `.onnx`) | commit `76e3dc408eb2…` — `Scripts/bootstrap-runtimes.sh:296` (URL) + SHA-256 `1a153a22…` em `:58` | repo em **v6.2.3** (23/09/2026) | modelo pinado em commit de **16/07/2026** (GitHub API do commit) | github.com/snakers4/silero-vad/releases + API do commit |
| `actions/checkout` | **@v4** (tag flutuante de major) — `.github/workflows/ci.yml:14` e `ci.yml:26` | linha v4 = **v4.4.0**; projeto = **v7.0.1** (20/07/2026) | 3 majors (v5, v6, v7) | github.com/actions/checkout/releases |
| Xcode (dev local) | **27.0 beta 1, build 27A5194q**, Swift 6.4 `6.4.0.20.104` (medido: `xcodebuild -version`, `swift --version`) | **Xcode 27 GM 27A266a** (14/09/2026); já há 27.1 beta (18/09) e 27.2 beta | 5 betas + GM atrás; +2 betas de ponto | developer.apple.com/news/releases; xcodereleases.com (secundária) |
| Runner CI | `runs-on: macos-26` — `ci.yml:12` e `ci.yml:24` | imagem `macos-26` padrão = **Xcode 26.6 (17F113)** desde 21/07/2026; Xcode 27 só "public preview"; changelog 10/09/2026 fala em runner image de Xcode 27 em macOS 27 | CI ≠ toolchain local | github.com/actions/runner-images `macos-26-Readme.md` (oficial) |

### 1.2 FluidAudio 0.15.5 → 0.16.1: o que mudou (release notes parafraseados)

- **0.15.6 (19/08/2026)** — entre outras: `OfflineDiarizerManager` ganha `prepare()/cluster()` (quebra de API menor no nosso wrapper `DiarizationRuntime`), **correções de clustering pyannote-parity** (limiar/attribution, PR #802), "integer overflow in AudioSourceFactory frame count" (#813), aviso de builds macOS com BNNS instável (#818), e vários fixes de download (retry em erro de rede, cache preservado).
- **0.15.7 (10/09/2026)** — **diarização**: `propagate cancellation to workers` (#886), "hold speaker caps against both cluster censuses" (#891), warn em macOS 14 BNNS (#885), fix de build macOS x86_64 (#876).
- **0.16.0 (tag v0.15.8, 20/09/2026)** — **"Pin diarization artifacts to immutable revision" (#939)**: o upstream deixou de baixar artefatos de diarização de `main` mutável. Nosso bootstrap ainda baixa de `resolve/main` (guardado por SHA-256 por arquivo, §2.6).
- **0.16.1 (21/09/2026)** — fix de link do Mac Catalyst; sem mudanças de API.
- **Impacto em nós:** usamos só `OfflineDiarizerManager`/diarização; os fixes de clustering/cancelamento de 0.15.6/0.15.7 são **qualidade de diretiva de locutor** diretamente relevante. O `exact: "0.15.5"` (`Package.swift:15`) está coerente com a justificativa documentada no próprio arquivo (`Package.swift:12-14` — "a API do OfflineDiarizerManager muda entre releases").

### 1.3 whisper.cpp v1.9.1 → v1.9.4: o que mudou

- **v1.9.1** foi publicado em **19/06/2026** (release notes da tag: só bump de CI + `release : v1.9.1`).
- **v1.9.3 (20/08/2026)** traz dois **fixes de segurança** que a v1.9.1 **não** tem (sem CVE/GHSA publicados, mas exploração por input):
  - `whisper : heap out-of-bounds read in log_mel_spectrogram on very short audio (#3956)`;
  - `whisper,parakeet : reject invalid n_dins in tensor header to prevent stack-buffer-overflow on malformed model files (#3957)`.
- **v1.9.4 (11/09/2026)** — `whisper : default-initialize whisper_mel to avoid uninitialized read (#3981)`, `re-seed decoder 0 between calls (#4025)`, `call encoder_begin_callback before language auto-detect (#3936)`, sync ggml 0.22→0.23, tunings Metal. Sem breaking change de API C para o nosso wrapper `WhisperRuntime`.
- **Atenção (release notes, aviso do mantenedor):** semver do ggml-org é "work in progress" (nota em v1.9.3 apontando ggml/discussions/1579) — não trate minor como puramente compatível sem testar.

### 1.4 llama.cpp b9222 → b11139: o que mudou

- **b9222 = 19/05/2026** (página da tag; commit `9a532ae`). É um **nightly tag**, não um release com semver — release notes da tag só traz o PR do dia.
- Entre b9222 e b11139 (~4 meses de nightlies) destaque relevante ao nosso uso (backend Metal em Mac):
  - **hardening de parser GGUF** — `gguf : harden loader against malformed tensor dims and metadata types` (llama/25596), que aparece no changelog sincronizado do whisper v1.9.3 — indício forte de que **é posterior a b9222** (PR 25596 > 22822, o PR do dia de b9222);
  - dezenas de fixes/tunings Metal (`metal : fix memory query under low-memory conditions` llama/27701, `metal : fix null-pipeline crash for F16 src1 mul_mat` llama/25648, `metal : add metallib build support for xcframework` llama/28163 — este último muda como o xcframework empacota kernels);
  - releases modernos passaram a publicar **attestations** dos artefatos (ex.: `github.com/ggml-org/llama.cpp/attestations/49582694` em b11139) — algo que o binário de b9222 não tinha.
- **Motivo da fixação no nosso código:** `Scripts/bootstrap-runtimes.sh:47-48` documenta que a tag fixada é a que suporta a arquitetura `qwen35` do Qwen3.5 — atualização exige trocar tag **e** SHA-256 juntos (`:47`, `:50`).

### 1.5 ONNX Runtime 1.24.2 → 1.30.0: o que mudou

- Linha 1.24 recebeu patch até **1.24.4 (17/03/2026)** — nossos release notes lidos: 1.24.4 é bugfix (PCI/GPU discovery, null-deref de plugin EP, MetaDef duplicado) **sem** fix de segurança. Ou seja: dentro da linha 1.24 não há security patch perdido; fora da linha, há:
- **v1.29.0 (12/08/2026)** — seção "Security Fixes": path traversal no refit de engines TensorRT/NvTensorRTRTX (#29396), validação do atributo `k` do MoE CPU (#29907), "CPU TensorScatter security issue" (#29916). **Notoriedade para nós:** TensorRT não existe em macOS — esses dois primeiros não são aplicáveis ao nosso uso (Silero VAD em CPU via pod archive).
- **v1.30.0 (10/09/2026)** — hardening extenso de *model loading* (profundidade de grafo limitada, canonicalização de external-data, validação de shapes/rank de `Split/Scan/GatherND/ScatterND/Conv/…`, allowlist de dtypes de LoRA) + ganhos CPU (kernels LinearAttention fusionados AVX-512/NEON, AVX2 LayerNorm/RMSNorm) + **"Pinned GitHub Actions to full-length commit SHAs"** no próprio repo da Microsoft (#32176) — ironicamente a prática que a nossa CI não faz.
- Compilamos o **pod archive** `pod-archive-onnxruntime-c-1.24.2` (`bootstrap-runtimes.sh:290-292`), não o wheel PyPI — mas a versão 1.24.2 existe no PyPI (HTTP 200), o que valida a consulta OSV por PyPI como proxy (§5).

### 1.6 Silero VAD: versão do modelo

- Fixamos o arquivo `silero_vad.onnx` de um **commit**, não de uma release (`bootstrap-runtimes.sh:295-297`): commit `76e3dc408eb2a5c655c34e230d2d5459b4439daa`, data **16/07/2026** (GitHub API, commit assinado/verificado por PGP do mantenedor `adamnsandle`), mensagem "Merge PR #784 — Add offline ONNX sequence export example".
- Releases do repo: v6.2.2 (17/09/2026) e v6.2.3 (23/09/2026) — mudanças de **empacotamento** (modelo sequence novo, torchaudio/onnxruntime opcionais no pip); release notes não anunciam troca do `silero_vad.onnx` stock. FluidAudio 0.15.5 (o que usamos) menciona "Update Silero VAD CoreML artifact to v6.2.1" — artefato *CoreML deles*, não o nosso ONNX.
- O comentário do próprio script admite o motivo: "a tag de release não cobre o artefato do modelo" (`bootstrap-runtimes.sh:53-55`).
- **Não verifiquei:** se o blob `silero_vad.onnx` do commit 76e3dc4 é byte-igual ao do HEAD em 23/09/2026 (não baixei os dois blobs para comparar). Digo: não coberto.

### 1.7 Toolchain (Xcode/CI)

- **Local:** Xcode **27.0 beta 1 (27A5194q)** — casa com a linha "Beta 1, 8 Jun 2026, Swift 6.4 (6.4.0.20.104)" do xcodereleases.com e com o `swift --version` medido (`swiftlang-6.4.0.20.104`). Xcode 27 **GM (27A266a) saiu em 14/09/2026** (feed oficial Releases da Apple, citado por fonte secundária com URL do feed; 9to5mac 18/09 confirmou 27.1 beta; a própria Apple listou "Xcode 27 beta 6 (27A5252f), August 24, 2026" em developer.apple.com/news/releases).
- **CI:** `runs-on: macos-26` (`ci.yml:12,24`) **sem nenhuma seleção de Xcode** (grep `xcode-select|setup-xcode` no `ci.yml` → 0 ocorrências; arquivo lido integralmente, 51 linhas). O readme oficial da imagem diz: Xcode padrão do macOS 26 passou a ser **26.6 em 21/07/2026** e "Xcode 27 is now available as a public preview" (issue 14404). **Consequência:** a CI compila com Swift 6.3.x/SDK 26.x enquanto o dev local compila com Swift 6.4/SDK 27.0 beta — builds não são reproduzíveis entre local e CI, e o toolchain da CI muda sozinho quando o GitHub atualiza a imagem.
- O scheme já foi salvo pelo Xcode 27 (`LastUpgradeVersion = "2700"`, `Loro.xcscheme:3`), e o deployment target é 26.0 (`pbxproj:353,376,407,431`).

---

## 2. Gargalos conhecidos e anti-padrões de build/CI (evidência `arquivo:linha`)

### 2.1 Bootstrap de runtimes baixando tudo a cada CI, sem cache — **gravíssimo para tempo**
- Os **dois jobs** rodam `./Scripts/bootstrap-runtimes.sh` (`ci.yml:16-17` e `ci.yml:28-29`). O próprio script/documentação estima **~1 GB** de XCFrameworks (`ci_scripts/ci_post_clone.sh:11`, `:16`; `Package.swift:19-21` "~1 GB + 52 MB do ONNX").
- Nenhum `actions/cache`/`cache:` no workflow (grep `actions/cache|cache:` em `ci.yml` → **0**). Cada push/PR paga 2 downloads completos de ~1 GB + ~21,5 MB de diarização + 2,3 MB do Silero.
- `curl -sSL --fail` **sem `--retry`** (`bootstrap-runtimes.sh:123`, `:161`) — uma falha de rede efêmera derruba o job inteiro (embora `--fail` + `set -euo pipefail` em `:36` sejam corretos).
- Mitigação correta já presente: skip quando o artefato local confere (`bootstrap-runtimes.sh:107-120`, `:155-158`) — só não ajuda em runner efêmero.

### 2.2 Workspace derivado sem cache e build duplicado
- Step de testes usa `-derivedDataPath /private/tmp/papagaio-ci-app-tests` (`ci.yml:42`); o step de build seguinte **não** passa `-derivedDataPath` (`ci.yml:44-51`) → cai no DerivedData padrão do runner. São **dois builds frios** por job; e `xcodebuild test` já compila o app — o step `xcodebuild build` só acrescenta a variante `generic/platform=macOS`.
- Sem cache de SPM: o clone do FluidAudio e os `.build`/`SourcePackages` são refeitos sempre (0 ocorrências de cache no workflow). Ver §4.2 para a receita oficial.

### 2.3 Segurança/robustez do workflow
- **Sem `permissions:`** em nenhum nível (grep `permissions:` no repositório → 0) — o `GITHUB_TOKEN` herda as permissões default do repo (recomendação oficial: `contents: read`, §4.1).
- **`actions/checkout@v4` por tag flutuante**, 2 usos (`ci.yml:14`, `ci.yml:26`), **não pinado por SHA** (§4.1: SHA full é "único jeito imutável").
- **Sem Dependabot**: `.github/` contém só `pull_request_template.md` e `workflows/ci.yml` (listado nesta execução) — nenhum `dependabot.yml` → actions e SwiftPM nunca recebem PR de update automático.
- `-skipPackagePluginValidation` nos dois comandos xcodebuild (`ci.yml:39`, `ci.yml:50`) — desliga a validação de assinatura/anterioridade de plugins de pacotes SwiftPM. **Não confirmei** a redação oficial (o grep no `man xcodebuild` local não achou o flag nesta execução) — marco como não-confirmado por fonte oficial, risco conhecido: qualquer plugin SPM malicioso não seria barrado.
- Trigger é `pull_request` (não `pull_request_target`) — **bom**: fora do vetor de "pwn request" (§4.1).
- Sem `upload-artifact` de xcresult/log (workflow inteiro lido) → falha de teste na CI exige reprovar localmente.

### 2.4 Testes
- **Serializados por padrão:** `swift test --no-parallel` (`Scripts/testa-papagaio-core.sh:56` e `:59`) — deliberado e documentado (workaround de File Provider/codesign, `:27-33`, retry 5× em `:80-92`). Custo: suíte SPM roda 1 thread.
- **Sem test plan:** `find . -name '*.xctestplan'` → **0**. O scheme tem 1 `TestableReference` (`Loro.xcscheme:37-48`) e dependência de build paralela (`:6`).
- **Testes Python fora da CI:** `Scripts/tests/test_scripts.py` existe (unittest da stdlib — imports em `:1-9`), mas o `ci.yml` não os referencia (grep `python|unittest|pytest` no workflow → 0). Ou seja: regressões dos scripts de bootstrap/teste não são pegas na CI.
- Code signing **desativado** na CI: `CODE_SIGNING_ALLOWED=NO` (`ci.yml:40`, `:51`), `CODE_SIGNING_REQUIRED=NO` (`ci.yml:41`) — nunca validamos que entitlements + hardened runtime assinam de fato (o app tem `ENABLE_HARDENED_RUNTIME = YES`, `pbxproj:452,492`, e entitlements em `Config/Papagaio.entitlements`).

### 2.5 Warnings e diagnóstico
- **Nenhum warning é erro:** grep `GCC_TREAT_WARNINGS_AS_ERRORS|SWIFT_TREAT_WARNINGS_AS_ERRORS` no `project.pbxproj` → **0**. (A baseline desta auditoria em `audit/00-mapa.md:319,427` mediu 121 warnings num build limpo — 120 de headers vendored do onnxruntime — medição de outro agente, não repetida aqui.)
- Erros suprimidos em pontos críticos: `PlistBuddy … 2>/dev/null || true` (`bootstrap-runtimes.sh:84,88,91,94`), `codesign … 2>/dev/null` (`testa-papagaio-core.sh:55`) — se o pruning do XCFramework falhar silenciosamente, o sintoma aparece tarde (SPM "does not contain a binary artifact", documentado em `ci_post_clone.sh:7-9`).

### 2.6 Supply chain do bootstrap (pontos fortes e fracos)
- **Fortes:** tudo é **versão + SHA-256 fixados** e verificados antes de extrair (`bootstrap-runtimes.sh:49-58` para tags/hashes; verificação em `:125-133` e `:163-171`; cópia atômica via `mktemp`+`mv` em `:176-181`); **0 ocorrências de `curl | sh`** no repositório (grep `curl … | (sh|bash)` → 0); binários fora do git (`.gitignore:9,15,21`).
- **Fraco:** os modelos de diarização vêm de URL **mutável** `https://huggingface.co/…/resolve/main` (`bootstrap-runtimes.sh:238`) — protegida apenas pelos 21 SHA-256 por arquivo gerados "em 2026-08-11 a partir do HEAD do repo" (`:241-264`). Se o HuggingFace repo mudar, o build **quebra alto** (comportamento desejado, `:234-237`), mas qualquer atualização upstream exige regerar hashes manualmente. O upstream FluidAudio corrigiu o lado dele em 0.16.0 ("Pin diarization artifacts to immutable revision").
- Os frameworks patcheamos por cima (module map do ONNX injetado, `bootstrap-runtimes.sh:199-223`) — aceito e documentado, mas é código nosso dentro de binário de terceiro.

### 2.7 Artefatos grandes
- XCFrameworks completos têm ~1,2 GB (7 plataformas + dSYM) e o script **poda para só macOS sem dSYM** (`bootstrap-runtimes.sh:18-26`, `:65-102`) — boa decisão; o gargalo remanescente é a rede por job (§2.1).
- Xcode Cloud repete o mesmo custo a cada build (`ci_scripts/ci_post_clone.sh:16-18`) e o próprio comentário aponta o caminho: hospedar zips reempacotados e usar `binaryTarget(url:checksum:)` (cacheado pelo Xcode Cloud).

---

## 3. Deprecações que o build pode estar usando

| Item | Onde (nosso código) | Situação |
|---|---|---|
| `-undefined dynamic_lookup` em `OTHER_LDFLAGS` | `project.pbxproj:354-357` e `:377-380` (target PapagaioTests) | **Deprecado pelo novo linker da Apple** (Xcode 15+): o `ld` novo avisa `ld: warning: -undefined dynamic_lookup may not work with chained fixups` e descreve a opção como deprecated no man page. Fontes: Apple Developer Forums thread 773907 (secundária, cita "defeats the two-level namespace"), issue do Bazel #16413 e SO (secundárias). Também enfraquece a two-level namespace. Uso legitimo seria `@rpath`/link explícito — o próprio projeto já usa rpath no teste SPM (`Package.swift:100-102`). **Não achei aviso no build da auditoria** (o build limpo do mapa não listou warnings de linker), então é deprecação latente, não erro. |
| `ALWAYS_SEARCH_USER_PATHS = NO` | `project.pbxproj:392`, `:422` | Setting **legado** (o header-map com YES não é suportado pelo build system novo desde Xcode 10; Apple Xcode 10 Build System Release Notes). Estar `= NO` é o estado **correto/recomendado** (WebKit bug 172691 e docs). Nada a fazer além de não religar. |
| `COMBINE_HIDPI_IMAGES = YES` | `project.pbxproj:449`, `:489` | Setting antigo de assets. **Não consegui confirmar deprecação oficial nesta execução** (o snippet "deprecated as of Xcode 8.3" da página de build settings da Apple veio sem identificação do item no resultado de busca) — marco como **não confirmado**; baixo impacto. |
| `SWIFT_STRICT_CONCURRENCY = complete` | `project.pbxproj:414`, `:436` | **Redundante**: o projeto já usa Swift 6 language mode em tudo (`SWIFT_VERSION = 6.0` em `:361,384,415,437`; `.swiftLanguageMode(.v6)` em `Package.swift:42,47,52,64,82,87,92`), no qual checagem de concorrência completa é o padrão. Inofensivo, mas é ruído de configuração. |
| `actions/checkout@v4` | `ci.yml:14`, `ci.yml:26` | Três majors atrás. Mudanças oficiais desde: **v5** = runtime node24 (exige runner ≥ v2.327.1); **v6** = `persist-credentials` passa a gravar em arquivo sob `$RUNNER_TEMP` em vez de `.git/config` (melhoria de segurança de credencial); **v7** = recusa checkout de PR de fork em `pull_request_target`/`workflow_run` por default (README do checkout + changelog de 18/06/2026). Nossa CI usa `pull_request` e não faz push — upgrade é de segurança/higiene, não de funcionalidade. |
| `ci_scripts/ci_post_clone.sh` com só `set -e` | `ci_post_clone.sh:20` | Padrão fraco vs. `set -euo pipefail` usado nos demais scripts (`bootstrap-runtimes.sh:36`, `testa-papagaio-core.sh:3`, `bench-papagaio.sh:16`). `sh` POSIX não tem `pipefail`, mas o script poderia ser `#!/bin/bash` + `pipefail`. |
| Sem Dependabot/Renovate | `.github/` (listado) | Actions e SwiftPM ficam parados por conta própria — a deprecação vira endividamento silencioso (ver §1.1). |

**Verificado e *não* problemático:** `ENABLE_USER_SCRIPT_SANDBOXING = YES` (`pbxproj:400,430`), `ENABLE_HARDENED_RUNTIME = YES` (`:452,492`), `DEBUG_INFORMATION_FORMAT` dwarf/dwarf-with-dsym coerentes (`:397,427`), `GENERATE_INFOPLIST_FILE` + `INFOPLIST_FILE` (`:455,495`) é combinação suportada.

---

## 4. Recomendações oficiais de build/CI (fontes primárias)

### 4.1 GitHub Actions — segurança do workflow
1. **Pinear actions por SHA de commit completo** — "Pinning an action to a full-length commit SHA is currently the only way to use an action as an immutable release" (*Secure use reference*, docs.github.com, conteúdo capturado nesta execução). Pin por tag "é conveniente" mas tag pode ser movida.
2. **Permissão mínima do `GITHUB_TOKEN`** — "set the default permission for the GITHUB_TOKEN to read access only for repository contents" (mesma fonte) e o README do próprio `actions/checkout` recomenda `permissions: contents: read` (capturado).
3. **Segredos** — nunca em texto plano em workflow; rotacionar periódicamente; não usar dado estruturado como secret (mesma fonte).
4. Nossa CI usa `pull_request` (seguro) — alinhado ao alerta do changelog oficial de 18/06/2026 sobre `pull_request_target`/pwn requests (que motivou o checkout v7).
5. **Dependabot para actions** é o mecanismo oficial de manter `uses:` atualizado (Secure use reference, seção "Using Dependabot version updates").

### 4.2 GitHub Actions — cache
- `actions/cache` (README oficial do repo GitHub-maintained, capturado): chave com `hashFiles('**/lockfiles')`, limite de **10 GB por repo**, cache sem uso em 7 dias é evictado; existe **exemplo oficial para "Swift - Swift Package Manager"** no `examples.md`. Doc oficial apontada pelo README: *"Caching dependencies to speed up workflows"* (`docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows` — o link literal saiu do README; minha tentativa direta de URL antiga deu 404 nesta execução).
- Aplicação ao nosso caso: cachear (a) `PapagaioCore/Frameworks/` + `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/` **já validados** (o próprio bootstrap pula download quando o SHA confere — `bootstrap-runtimes.sh:107-120,155-158`), (b) `~/Library/Caches/org.swift.swiftpm` / `SourcePackages`, (c) DerivedData com chave `github.sha` + `restore-keys`.
- Ferramenta comunitária conhecida para DerivedData+mtime em CI: `irgaly/xcode-cache` (secundária, mencionada só como exemplo — não adotar sem revisão).

### 4.3 Apple
- **Hardened Runtime obrigatório para notarização** — "Apple only notarizes macOS apps that enable the Hardened Runtime capability" (developer.apple.com/documentation/xcode/configuring-the-hardened-runtime; conteúdo capturado via índice/busca). Nosso `ENABLE_HARDENED_RUNTIME = YES` (`pbxproj:452,492`) está correto.
- **Build settings reference**: `developer.apple.com/documentation/xcode/build-settings-reference` (página existe; conteúdo completo não renderizou nesta execução — honestidade: usei como índice).
- **Xcode 27**: release notes oficiais em `developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes` (não renderizou nesta execução); vigência confirmada por fontes oficiais indiretas: feed Releases da Apple (Xcode 27 GM 27A266a, 14/09/2026), `developer.apple.com/news/releases` (beta 6 em 24/08/2026) e Apple Newsroom 09/06/2026 ("Xcode 27 … Apple silicon only, 30% smaller"). Xcode 27.1 beta notes (developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes): "requires a Mac running macOS Tahoe 26.6 or later", Swift 6.4, SDKs 27 — via índice na busca.
- **Runner images (GitHub, oficial):** `images/macos/macos-26-Readme.md` — tabela de Xcodes (26.6 default, 26.0.1…26.5), anúncio "Xcode 27 is now available as a public preview", mudança de default para 26.6 em 21/07/2026, SBOMs dos images em `github.com/actions/runner-images/releases` (mencionado no Secure use reference).
- **TN2339** (*Building from the Command Line with Xcode FAQ*, arquivo/arquivada): oficial para `xcode-select -switch` — reforça que CI deve fixar o Xcode explicitamente (não fazemos; §2.3).

---

## 5. CVEs / advisories — checagem executada (23/09/2026)

### 5.1 Consultas OSV API (`POST api.osv.dev/v1/querybatch`) — resultado

| # | Query | Resultado |
|---|---|---|
| 1 | `package.name=FluidAudio`, `ecosystem=SwiftURL`, `version=0.15.5` | **0 vulnerabilities** (`{}`) |
| 2 | `package.name=actions/checkout`, `ecosystem=GitHub Actions`, `version=v4` | **0 vulnerabilities** (`{}`) |
| 3 | `package.name=onnxruntime`, `ecosystem=PyPI`, `version=1.24.2` | **0 vulnerabilities** (`{}`; versão confirmada existente no PyPI, HTTP 200) |
| 4 | `package.name=llama.cpp`, `ecosystem=OSS-Fuzz`, `version=b9222` | `{}` — **ecosystem provavelmente inválido**: **não conto como cobertura**; a checagem real de llama.cpp foi a 5.3 |
| 5 | Sanidade: `lodash@4.17.11` (npm) | **7 GHSAs** (GHSA-29mw-wpgm-hmr9, GHSA-35jh-r3h4-6jhm, GHSA-f23m-r3pf-42rh, GHSA-jf85-cpcp-j695, GHSA-p6mc-m468-83gw, GHSA-r5fr-rjxr-66jc, GHSA-xxjr-mmjv-4gpg) → API operante |

### 5.2 GitHub Advisory DB REST (`GET api.github.com/advisories`) — resultado

- `?ecosystem=actions&per_page=100` → **55 advisories**; nenhum tem `package.name == actions/checkout` → **actions/checkout@v4: 0 advisories**. (Vários afetam outras actions — ex.: GHSA-cxww-7g56-2vh6 `actions/download-artifact`, GHSA-mrrh-fwg8-r2c3 `tj-actions/changed-files` — nenhum em uso no nosso workflow: único `uses:` é `actions/checkout`.)
- `?ecosystem=swift&per_page=100` → **62 advisories**, pacotes listados (swift-nio, vapor, Sparkle, yyjson, Zip…); **nenhum menciona FluidAudio/FluidInference** → **FluidAudio 0.15.5: 0 advisories**.
- Buscas `keyword=llama|onnx|whisper` devolveram o mesmo conjunto genérico (o filtro não funcionou como esperado) — **não usei** esse resultado; a cobertura veio de 5.3/5.4.

### 5.3 llama.cpp — página + API de advisories do repo (fonte primária do mantenedor)

`github.com/ggml-org/llama.cpp/security/advisories` + `GET /repos/ggml-org/llama.cpp/security-advisories` → **13 advisories publicados** (todos do mantenedor `ggerganov`). Faixas relevantes (extraídas nesta execução):

| GHSA | CVE | Severidade | Faixa afetada | Afeta **b9222**? |
|---|---|---|---|---|
| GHSA-3p4r-fq3f-q74v | CVE-2026-27940 | high | `<= b8145` | **Não** (b9222 > b8145) |
| GHSA-j8rj-fmpv-wcxw (RPC RCE) | CVE-2026-34159 | critical | `<= b7991` | **Não** (e não usamos RPC) |
| GHSA-96jg-mvhq-q7q7 | CVE-2026-33298 | high | `< b7437` | **Não** |
| GHSA-8947-pfff-2f3c | CVE-2026-21869 | low | commit `<= 55d4206c8` (jan/2026) | **Não** |
| GHSA-vgg9-87g3-85w8 | CVE-2025-53630 | high | `< 26a48ad` (jul/2025) | **Não** |
| GHSA-7rxv-5jhh-j6xx (tokenizer) | CVE-2025-52566 | high | `< b5721` | **Não** |
| GHSA-g4cc-763q-h9h6 | — | medium | `c33fe8b8` | **Não** (commit de 2025) |
| GHSA-8wwf-w4qm-gpqr (vocab GGUF) | CVE-2025-49847 | high | "All versions before patch" (jun/2025) | **Prov. não** (patch anterior a mai/2026) |
| GHSA-wcr5-566p-9cwj / GHSA-5vm9-p64x-gqw9 / GHSA-mqp6-7pv6-fqjf | CVE-2024-42479/42478/42477 | crit/mod/med | `< b3561` | **Não** |
| GHSA-49q7-2jmh-92fp | CVE-2024-41130 | medium | `<= b3426` | **Não** |
| GHSA-p5mv-gjc5-mwqv | CVE-2024-32878 | high | `b2715` | **Não** |

**Resultado: 0 de 13 advisories cobrem b9222** pelo critério "faixa publicada ≤ build anterior a b9222". Reserva honesta: GHSA-8wwf não publica identificador de patch ("All versions before patch") — classifiquei como "provavelmente não" pela data (jun/2025 ≪ mai/2026). Risco residual real do nosso caso: **modelo GGUF malicioso** é o vetor desses advisories; nós carregamos modelo do usuário? (Fora do escopo deste pesquisador — sinalizo ao verificador: se o app importa GGUF de terceiros, o parser do b9222 é o alvo.)

### 5.4 whisper.cpp / ONNX Runtime — advisories dos repos + release notes

- `github.com/ggml-org/whisper.cpp/security/advisories` → **"There aren't any published security advisories"** (capturado). Porém os **release notes da v1.9.3** (fonte primária) trazem 2 correções de segurança **sem CVE** aplicáveis a input malicioso curto/modelo corrompido (§1.3). **Conclusão: v1.9.1 carece de 2 fixes de segurança; sem advisory contá-vel — "0 advisory, 2 fixes listados no release notes".**
- `github.com/microsoft/onnxruntime/security/advisories` → **"There aren't any published security advisories"** (capturado). Compensação: release notes 1.29.0/1.30.0 listam "Security Fixes" sem CVE público (§1.5). OSV(PyPI, 1.24.2) = 0.
- Silero VAD: **não coberto por ferramenta** (é um artefato `.onnx` de um repo, sem pacote em nenhuma DB). O que checquei: release notes v6.2→v6.2.3 (nenhuma entrada de segurança) + checksum SHA-256 fixado (`bootstrap-runtimes.sh:58`) + commit assinado/verificado (GitHub API).

### 5.5 Manifestos sem gerenciador auditável

- Python: **0** `requirements*.txt`/`pyproject.toml`/`Pipfile`/`poetry.lock` no repo. `Scripts/tests/test_scripts.py` usa só stdlib (`:1-9`: os, pathlib, shutil, subprocess, tempfile, unittest, xml.etree) → `pip-audit` sem alvo (e não instalado).
- Node: **0** `package.json` → `npm audit` sem alvo (npm instalado, não executado).
- Ruby: `Scripts/adiciona-target-de-testes.rb:1-4` exige a gem `xcodeproj`, mas **não há Gemfile/lock** (busca → 0) → gem **sem versão fixada**, não auditável aqui; os testes pulam se a gem faltor (`Scripts/tests/test_scripts.py:90-92`).

---

## 6. "Onde procurar no nosso código" — buscas executadas (contagens e exemplos)

### 6.1 Pinagem de actions e versões
| Busca | Contagem | Exemplos |
|---|---|---|
| `uses:\s*\S+` em todo o repo | **2** | `.github/workflows/ci.yml:14` e `:26` — `actions/checkout@v4` (tag de major flutuante, **sem SHA**) |
| `permissions:` | **0** | — |
| `secrets.` / `GITHUB_TOKEN` | **0** | — |
| `b9222` | **1** | `Scripts/bootstrap-runtimes.sh:49` |
| `1.24.2` | **1** (+1 URL) | `Scripts/bootstrap-runtimes.sh:56`, URL `:291` |
| `v1.9.1` | **1** | `Scripts/bootstrap-runtimes.sh:51` |
| `0.15.5` | **4+** | `PapagaioCore/Package.swift:15`; `Package.resolved` dos 3 workspaces (linha 10 de cada) |
| SHA-256 de artefatos | 4 fixos + 21 de diarização | `bootstrap-runtimes.sh:50,52,57,58` e `:242-264` |
| `refs/tags` / `revision:` em manifestos | 3 revisões SPM idênticas | `19600a485baa4998812e4654b70d2bab8f2c9949` nos 3 `Package.resolved` (mas `originHash` **diferentes**: linhas 2 de cada → risco de drift/merge) |

### 6.2 Padrões perigosos de script
| Busca | Contagem |
|---|---|
| `curl … \| sh` / `\| bash` | **0** |
| `wget` | 0 |
| `curl` em scripts | 2+2 chamadas (`bootstrap-runtimes.sh:123,161`; downloads oficiais em `:282-299`) — todas com `--fail`, todas com verificação SHA-256 posterior |
| `sudo` | 0 |

### 6.3 Permissões e configurações de CI
- Workflow único: `.github/workflows/ci.yml` (51 linhas, lido integralmente). Grep `xcode-select|setup-xcode|actions/cache|cache:` → **0**. Sem `upload-artifact`, sem `timeout-minutes`, sem `strategy`, sem `concurrency`.
- Sem `.xctestplan` (find → **0**); sem `dependabot.yml` (`.github/` listado).
- Runner: `macos-26` (`ci.yml:12,24`). Code signing off: `ci.yml:40,41,51`.

### 6.4 Caça a segredos — **ACHADO (local mascarado; valor nunca reproduzido)**
1. **Padrões no working tree** (`AIza…|ghp_|github_pat_|sk-|xox…|GOCSPX-|AKIA…|Bearer …` e `api_key/secret/token/password =` com valor ≥16) → **0 em arquivos rastreáveis**. *Ressalva técnica:* o ripgrep respeita `.gitignore`, então **não** alcança `Config/Secrets.xcconfig`.
2. **`Config/Secrets.xcconfig:5`** contém `GOOGLE_CLIENT_SECRET = GOCSPX-wx7b3H…[MASCARADO]` (local apenas). Status: **gitignored** (`.gitignore:30`, confirmado por `git check-ignore -v`) e **nunca versionado** (`git log --all -- Config/Secrets.xcconfig` → vazio). Valor atual ≠ qualquer valor do histórico (comparação por prefixo de 6 chars).
3. **⚠ ACHADO PRINCIPAL — segredo no histórico do git:** `git log --all -S 'GOCSPX-'` encontra **2 commits**:
   - `41c48eb6cb1eb9ec7a035d468840593bb6096228` — 26/08/2026 — "Google Calendar funcional": **introduziu `GOOGLE_CLIENT_SECRET` em `Config/SETUP-GOOGLE.md`** (arquivo versionado);
   - `e2eceb38199806fd2a9a919db9f4fa1cf95fb64a` — 27/08/2026 — "security: remove segredo OAuth do bundle": removeu.
   - O arquivo atual `Config/SETUP-GOOGLE.md` **não** contém segredo (grep `GOCSPX|CLIENT_SECRET` → vazio; o doc atual até afirma "não incorpora `client_secret`", `SETUP-GOOGLE.md:4-6`).
   - O valor histórico é **diferente** do valor local atual (comparação por prefixo mascarado) → indício de que já houve rotação, **não confirmado**.
   - O repo **tem remote `origin = https://github.com/Lucaddias/Papagaio.git`** (`git remote -v`). A API anônima do GitHub não retornou metadados do repo (`private/created/pushed` = null → 404 anônimo, provável repo **privado**, mas **não confirmado**). Se o repo (ou um fork) for público ou o histórico já foi pushado, o client secret antigo esteve exposto.
   - **Ação recomendada (sem executar aqui):** confirmar no Google Cloud Console que o client secret de ago/2026 está revogado/rotacionado; se o repo for público, considerar `git filter-repo` para purgar `Config/SETUP-GOOGLE.md` daquele commit + force-push (com aviso: quebra clones).
4. **Identificador não-secreto:** `DEVELOPMENT_TEAM = 8CTC75M93B` (`pbxproj:347,370,451,491`) — Team ID público, ok versionado; CI o ignora via `CODE_SIGNING_ALLOWED=NO`.
5. `tmp/keys.json` e `tmp/missing_keys.json` versionados — **não são credenciais**: listas de strings de tradução (`%@ cópia`, mensagens de UI), verificado por leitura mascarada.

---

## 7. Recomendações priorizadas (síntese para o verificador)

1. **P0 — supply chain:** apurar rotação do OAuth client secret de ago/2026 (§6.4.3) e, se o repo GitHub for público, purgar o histórico.
2. **P1 — CI determinística:** fixar o Xcode na CI (ex.: `xcode-select`/`setup-xcode` para 27 GM quando o image sair) e alinhar ao toolchain local — hoje: local beta 1 vs CI 26.6 (§1.7).
3. **P1 — velocidade:** cachear no workflow os artefatos do bootstrap já SHA-validados + SPM/DerivedData (§2.1, §2.2, §4.2) — deve cortar a maior parte de 2×~1 GB por run.
4. **P1 — higiene de actions:** pinar `actions/checkout` por SHA + `permissions: contents: read` + `dependabot.yml` com ecosystem `github-actions` (§4.1).
5. **P2 — versões:** avaliar FluidAudio 0.16.1 (fixes de diarização diretamente úteis, §1.2), whisper.cpp ≥ v1.9.4 (2 fixes de segurança, §1.3), ONNX 1.24.4+ (só se necessário; linha 1.24 sem patch de segurança), llama b9222 → build recente (hardening GGUF + attestations, §1.4) **com** troca do SHA-256 e revalidação `qwen35`.
6. **P2 — testes:** adicionar test plan, subir os testes Python para a CI, e publicar xcresult como artifact.
7. **P3:** remover `-undefined dynamic_lookup`, `SWIFT_STRICT_CONCURRENCY` redundante, adicionar `pipefail` no `ci_post_clone.sh` (§3).

---

## 8. Fontes (regra 4: URL, versão, data de acesso 23/09/2026, ponto parafraseado)

**Oficiais (mantenedor/GitHub/Apple):**
1. https://github.com/FluidInference/FluidAudio/releases — releases v0.15.5→v0.16.1 — *acesso 23/09/2026* — datas e conteúdo das mudanças de diarização/download (§1.2).
2. https://github.com/ggml-org/whisper.cpp/releases (e `/releases/tag/v1.9.1`, `/releases/tag/v1.9.3`) — v1.9.1 (19/06/2026) a v1.9.4 (11/09/2026) — *23/09/2026* — fixes #3956/#3957/#3981; aviso de semver WIP.
3. https://github.com/ggml-org/llama.cpp/releases (e `/releases/tag/b9222`) — b9222 (19/05/2026), b11139 (23/09/2026) — *23/09/2026* — nightlies, attestations, assets.
4. https://github.com/microsoft/onnxruntime/releases (e `/releases/tag/v1.24.4`) — v1.24.4 (17/03/2026), v1.29.0 (12/08/2026), v1.30.0 (10/09/2026) — *23/09/2026* — "Security Fixes", hardening de model loading, pin SHA de actions.
5. https://github.com/snakers4/silero-vad/releases — v6.2→v6.2.3 — *23/09/2026* — mudanças de empacotamento do pacote pip.
6. https://api.github.com/repos/snakers4/silero-vad/commits/76e3dc408eb2a5c655c34e230d2d5459b4439daa — *23/09/2026* — commit do modelo fixado: 16/07/2026, assinatura PGP verificada.
7. https://github.com/actions/checkout/releases (v7.0.1, v6.1.0, v5.1.0, v4.4.0, v7.0.0) — *23/09/2026* — datas e breaking changes por major.
8. https://github.com/actions/checkout/blob/main/README.md — Checkout v7/v6/v5/v4 — *23/09/2026* — node24, `$RUNNER_TEMP` p/ credenciais, recusa de fork-PR, `permissions: contents: read` recomendado.
9. https://github.blog/changelog/2026-06-18-safer-pull_request_target-defaults-for-github-actions-checkout/ — 18/06/2026 (edit. 15/07/2026) — *23/09/2026* — backport enforcement 20/07/2026; escopo p/ tags flutuantes.
10. https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions (renderiza "Secure use reference") — *23/09/2026* — SHA pin, permissão mínima do token, segredos, SBOMs de runner.
11. https://github.com/actions/cache/blob/main/README.md — cache v6/v5/v4 — *23/09/2026* — keys com hashFiles, 10 GB/7 dias, exemplo SPM; link oficial do guia "Caching dependencies to speed up workflows".
12. https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md — image 20260824.0517.1 — *23/09/2026* — Xcode 26.6 default (21/07/2026), Xcode 27 preview, tabela de SDKs.
13. https://github.com/ggml-org/llama.cpp/security/advisories + API `/repos/ggml-org/llama.cpp/security-advisories` — 13 GHSAs (2024-2026) — *23/09/2026* — faixas/versões afetadas.
14. https://github.com/ggml-org/whisper.cpp/security/advisories — *23/09/2026* — 0 advisories publicados.
15. https://github.com/microsoft/onnxruntime/security/advisories — *23/09/2026* — 0 advisories publicados.
16. https://api.osv.dev/v1/querybatch — *23/09/2026* — 5 queries documentadas em §5.1.
17. https://api.github.com/advisories?ecosystem=actions|swift — *23/09/2026* — 55 e 62 advisories; 0 p/ actions/checkout e FluidAudio.
18. https://pypi.org/pypi/onnxruntime/1.24.2/json — *23/09/2026* — HTTP 200 (versão existe).
19. https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime — *23/09/2026* — notarização exige Hardened Runtime (conteúdo via índice/busca).
20. https://developer.apple.com/documentation/xcode/build-settings-reference — *23/09/2026* — índice de build settings (página não renderizou fully).
21. https://developer.apple.com/news/releases — *23/09/2026* — Xcode 27 beta 6 em 24/08/2026; (feed Releases da Apple com Xcode 27 27A266a em 14/09/2026, citado por fonte #23).
22. https://developer.apple.com/library/archive/technotes/tn2339/_index.html (TN2339) — arquivada — *23/09/2026* — seleção de Xcode via `xcode-select` em CI.
23. https://xcodereleases.com/ — **secundária** — *23/09/2026* — linha Beta 1 = 27A5194q (08/06/2026, Swift 6.4 6.4.0.20.104) p/ casar com o toolchain medido localmente.
24. https://www.apple.com/my/newsroom/2026/06/apple-aids-app-development-with-new-intelligence-frameworks-and-advanced-tools — Apple Newsroom, 09/06/2026 — *23/09/2026* — anúncio Xcode 27 (Apple silicon only, betas a partir de 09/06).
25. https://9to5mac.com/2026/09/18/apple-releases-xcode-27-1-beta… — **secundária** — *23/09/2026* — Xcode 27.1 beta em 18/09/2026.
26. https://mjtsai.com/blog/2026/06/09/xcode-27-announced — **secundária (blog)** — *23/09/2026* — resume release notes Xcode 27 beta (Swift 6.4, SDKs 27, requer macOS 26.4+).
27. https://developer.apple.com/forums/thread/773907 + https://github.com/bazelbuild/bazel/issues/16413 + SO q/77525544 — **secundárias** — *23/09/2026* — deprecation/risco de `-undefined dynamic_lookup` no linker novo.
28. https://github.com/irgaly/xcode-cache — **secundária** — *23/09/2026* — exemplo comunitário de cache de DerivedData/SourcePackages (não adotar sem revisão).

**Fontes locais:** todos os `arquivo:linha` citados foram lidos nesta execução (`.github/workflows/ci.yml`, `Scripts/bootstrap-runtimes.sh`, `Scripts/testa-papagaio-core.sh`, `Scripts/tests/test_scripts.py`, `ci_scripts/ci_post_clone.sh`, `PapagaioCore/Package.swift`, os 3 `Package.resolved`, `Loro.xcodeproj/project.pbxproj`, `Loro.xcscheme`, `Config/{Base.xcconfig,Secrets.xcconfig,Secrets.example.xcconfig,SETUP-GOOGLE.md,Papagaio.entitlements}`, `.gitignore`, `git log/status/remote`). Medição de warnings/builds citada de `audit/00-mapa.md` é de outro agente da mesma auditoria (marcada como tal).

---

## 9. O que NÃO verifiquei (honestidade)

1. **Conteúdo byte a byte** dos binários baixados vs. os atuais (whisper/llama/onnx da tag fixada); confio no SHA-256 do repositório, não recalculei contra a release (não baixei ~1 GB).
2. **Identidade do `silero_vad.onnx`** pinado vs. HEAD do repo (§1.6).
3. **Visibilidade/estado do repo GitHub remoto** (API anônima → 404) e se o secret de ago/2026 **foi** rotacionado de fato.
4. Redação oficial do flag `-skipPackagePluginValidation` (man local não retornou o trecho).
5. Deprecação oficial de `COMBINE_HIDPI_IMAGES` (não confirmada).
6. Conteúdo completo das páginas Apple de Xcode 27 release notes e "Improving the speed of incremental builds" (não renderizaram; usei índices/busca).
7. Execução de `npm audit`/`pip-audit`/`osv-scanner` reais (sem manifestos/sem ferramentas instaladas).
8. Logs da CI no GitHub (não acessados) — não confirmei se a CI está verde/vermelha.
9. Estado real dos testes (não executei `swift test`/`xcodebuild test` — modo relatório).
10. Existência de advisories para o **modelo ONNX do Silero** e para os **`.mlmodelc` de diarização** (não há DB que os cubra — declarado "não coberto por ferramenta"; checagem feita: release notes do repo e URL/versionagem por SHA).

# Pesquisa P4 — Build, CI, SwiftPM, bootstrap, binários, assinatura e supply chain

- **Projeto:** Ōmu (Papagaio/Loro), app macOS
- **Data da pesquisa:** 23/09/2026
- **HEAD observado:** `6138e1d1d94c3daf15b5a645930336903ef15b98`
- **Modo:** relatório somente-leitura; somente este arquivo foi criado
- **Escopo:** toolchain, manifests/lockfiles, testes, GitHub Actions, Xcode Cloud, bootstrap, binários/modelos, assinatura/notarização, CVEs/advisories e proveniência
- **Fora do escopo:** vulnerabilidades funcionais/do domínio do app; nenhum achado de produto foi emitido como vulnerabilidade
- **Segredos:** nenhum valor nem prefixo de credencial é reproduzido

> **Legenda de confiança**
>
> - **CONFIRMADO** — arquivo, comando local ou fonte primária lida/medida nesta pesquisa.
> - **PROVÁVEL** — inferência forte, sem medir o efeito no ambiente real.
> - **HIPÓTESE** — hipótese plausível ainda não verificada.
> - **NÃO VERIFICADO** — ponto explicitamente deixado sem afirmação.
>
> Referências `arquivo:linha` são evidência local. Saídas de comandos locais são
> Reproduzidas literalmente, sem guardar log temporário. Nenhum temporário foi criado.

---

## Resumo executivo

1. **CONFIRMADO — segredo OAuth historicamente versionado:** dois commits de
   agosto/2026 introduziram e depois removeram um client secret de
   `Config/SETUP-GOOGLE.md`. O arquivo local `Config/Secrets.xcconfig` está
   ignorado e nunca versionado, mas a rotação do valor histórico **não pôde ser
   verificada** neste modo. É a ação P0 condicional antes de apagar histórico.
2. **CONFIRMADO — bons controles já existentes:** FluidAudio é `exact: "0.15.5"`
   e as três entradas `Package.resolved` fixam a mesma revisão; os quatro
   downloads do bootstrap têm SHA-256; os 21 arquivos de diarização têm SHA-256
   individual; os pesos GGUF são validados por tamanho e SHA-256; não há
   `curl | sh`; o trigger é `pull_request`, não `pull_request_target`.
3. **CONFIRMADO — Actions sem advisory conhecido, mas cadeia de suprimentos mutável:**
   `actions/checkout@v4` é uma tag móvel de major e não está pinado por SHA;
   o workflow também não declara `permissions:`. Isso é uma falha de hardening,
   **não** uma vulnerabilidade comprovada: as páginas do mantenedor e a OSV
   retornaram zero advisories para checkout.
4. **CONFIRMADO — toolchain local e CI divergem:** local usa Xcode
   `27A5194q`/Swift `6.4.0-dev`; o workflow escolhe apenas `macos-26`, cujo
   padrão documentado era Xcode `26.6 (17F113)`. A correspondência com a série
   Swift 6.3 é **PROVÁVEL**; o patch exato do Swift no runner não foi confirmado.
5. **CONFIRMADO — runtimes locais sem assinatura:** os três XCFrameworks já
   extraídos responderam `code object is not signed at all`. O app declara
   Hardened Runtime, mas também `com.apple.security.cs.disable-library-validation`,
   e a CI desliga assinatura. Isso **não prova** que um app Release assinado
   esteja inválido; prova que a CI não verifica essa cadeia.
6. **CONFIRMADO — bootstrap de XCFramework aceita diretório existente apenas por
   `Info.plist` e copia `cp -R` diretamente ao destino.** Um diretório parcial
   ou alterado pode ser aceito; a próxima execução não recalcula os hashes.
   Arquivos simples, em contraste, usam `mktemp` + `mv`.
7. **CONFIRMADO — whisper.cpp `v1.9.1` não contém correções de memória
  publicadas em `v1.9.3`/`v1.9.4`:** OOB read com áudio curto, stack overflow com
   header de modelo malformado e leitura não inicializada. Não há GHSA/CVE publicado
   para whisper.cpp, mas a diferença de hardening é oficial.
8. **CONFIRMADO — llama.cpp `b9222` não é alcançado por nenhum dos 13
   advisories publicados:** o mais recente tem faixa afetada `<= b8145`, com patch
   `>= b8146`; `b9222` é posterior. `b9222` é nightly; a versão estável atual
   observada é `v0.4.1`, não `b11139`.
9. **CONFIRMADO — `-skipPackagePluginValidation` aparece duas vezes, mas o
   grafo exato atual tem zero targets de plugin.** Portanto, não há risco atual
   demonstrado por essa flag neste commit. Ainda assim, removê-la é proteção
   contra a introdução futura de um plugin SwiftPM.
10. **CONFIRMADO — CI não é suficientemente determinística nem completa:** sem seleção de
    Xcode, cache, `timeout-minutes`, artefato `xcresult`, Dependabot, teste
    Python dos scripts ou gate de warnings como erro. Esses itens são lacunas de
    qualidade/disponibilidade; não foram classificados como CVEs.

---

## 1. Versões, comandos e estado atual

### 1.1 Toolchain local, CI e estabilidade em 23/09/2026

| Item | Estado usado/encontrado | Estado oficial atual | Confiança/observação |
|---|---|---|---|
| Xcode local | `Xcode 27.0`, build `27A5194q`, em `/Applications/Xcode-beta.app` | **Xcode 27.0 `27A266a`**, lançado em 14/09/2026; 27.1/27.2 eram beta | **CONFIRMADO** local; build local é beta 1, não a build estável |
| Swift local | `Apple Swift version 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)` | **Swift 6.4**, lançado em 15/09/2026 | **CONFIRMADO** |
| SwiftPM local | `Swift Package Manager - Swift 6.4.0-dev`; default `swiftbuild` | SwiftPM 6.4 usa Swift Build como default e gera SBOM SPDX/CycloneDX | **CONFIRMADO**; a string `-dev` vem da build beta do Xcode |
| Manifest do pacote | `// swift-tools-version: 6.0`; todos os alvos Swift usam `.swiftLanguageMode(.v6)` | Swift 6.4 não torna `swift-tools-version: 6.0` inválido | **CONFIRMADO**; 6.0 é a versão de tools, não o patch executado |
| Projeto/scheme | `CreatedOnToolsVersion = 27.0`, `LastUpgradeVersion = "2700"` | Xcode 27.0 GA | **CONFIRMADO** |
| CI | `runs-on: macos-26`, sem `xcode-select`, `maxim-locator/get-xcode` ou setup equivalente | README oficial da imagem: default **Xcode 26.6 `17F113`**; imagem consultada `20260824.0517.1` | **CONFIRMADO** para Xcode; **PROVÁVEL** para série Swift 6.3, sem patch exato |

Comandos e trechos reais:

```text
$ swift --version
swift-driver version: 1.167 Apple Swift version 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)
Target: arm64-apple-macosx27.0.0

$ swift package --version
Swift Package Manager - Swift 6.4.0-dev

$ xcodebuild -version
Xcode 27.0
Build version 27A5194q

$ xcode-select -p
/Applications/Xcode-beta.app/Contents/Developer
```

Evidência do projeto:

```text
PapagaioCore/Package.swift:1
// swift-tools-version: 6.0

Loro.xcodeproj/project.pbxproj:249-253
LastSwiftUpdateCheck = 2700;
LastUpgradeCheck = 2700;
CreatedOnToolsVersion = 27.0;

Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:2-4
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.3">
```

O workflow não fixa o Xcode:

```yaml
# .github/workflows/ci.yml:10-17
test-papagaio-core:
  name: Testes do PapagaioCore (SPM)
  runs-on: macos-26
  steps:
    - uses: actions/checkout@v4
    - name: Bootstrap runtimes (Silero VAD)
      run: ./Scripts/bootstrap-runtimes.sh
```

A imagem `macos-26` documentada em 23/09/2026 listava:

```text
26.6 (default) | 17F113 | /Applications/Xcode_26.6.app | /Applications/Xcode.app
```

Isso torna o build local e o da CI **não reproduzíveis entre si** e faz a CI
mudar quando a imagem do runner muda. A build Debug local medida pela baseline
passou em **48,34 s**; esse número não mede a CI
(`audit/00-mapa.md:436-446`).

### 1.2 Dependências exatas e comparação com o atual

| Dependência/artefato | Fixado no projeto | Evidência local | Atual em 23/09/2026 | Avaliação de segurança/cadeia de suprimentos |
|---|---|---|---|---|
| FluidAudio | `0.15.5`, revisão `19600a485baa4998812e4654b70d2bab8f2c9949` | `Package.swift:12-15`; três `Package.resolved:5-10` | `0.16.1`, 21/09 | 4 releases atrás; OSV e página de advisories: 0 publicados para `0.15.5` |
| whisper.cpp | `v1.9.1` | `bootstrap-runtimes.sh:51-52` | `v1.9.4`, 11/09 | 3 releases atrás; `v1.9.3`/`v1.9.4` contêm correções de memória ausentes em `v1.9.1` |
| llama.cpp | `b9222`, build nightly de 19/05 | `bootstrap-runtimes.sh:49-50` | release estável `v0.4.1`, 14/09; nightly observado `b11139`, 23/09 | Nenhum dos 13 advisories publicados alcança `b9222`; atualizar exige novo hash e regressão de `qwen35` |
| ONNX Runtime C | `1.24.2` | `bootstrap-runtimes.sh:56-57` | `1.30.0`, 10/09 | `1.29`/`1.30` trazem hardening ausente; parte é CUDA-only e não se aplica ao pod macOS CPU |
| Silero VAD ONNX | commit `76e3dc408eb2a5c655c34e230d2d5459b4439daa` | `bootstrap-runtimes.sh:58,295-297` | repo `v6.2.3`; blob pinado é de 16/07 | commit e SHA-256 fortes; não há DB de advisories para o blob |
| Diarização CoreML | 21 arquivos de `resolve/main` + SHA-256 por arquivo | `bootstrap-runtimes.sh:238-264,266-274` | repo HF `df2625ac…`; snapshot dos artefatos `1ed7a662…` | hashes conferem, mas `provenance.json` declara reconstrução histórica, não um build histórico reproduzível |
| `actions/checkout` | `@v4` | `ci.yml:14,26` | `v7.0.1`, 20/07 | 3 majors atrás; 0 advisories, mas tag móvel |
| Pesos Whisper/Qwen | tamanho + SHA-256 + URL HF `resolve/main` | `Preflight.swift:19-36`; validação em `DownloadDeModelos.swift:82-87,168-194` | URLs podem mudar | integridade dos bytes é forte; disponibilidade/reprodução melhora com revisão imutável |

Trechos de pinagem:

```swift
// PapagaioCore/Package.swift:12-15
// Versão fixada: a API do OfflineDiarizerManager muda entre releases.
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
```

```json
// PapagaioCore/Package.resolved:5-10
"identity" : "fluidaudio",
"kind" : "remoteSourceControl",
"location" : "https://github.com/FluidInference/FluidAudio.git",
"state" : {
  "revision" : "19600a485baa4998812e4654b70d2bab8f2c9949",
  "version" : "0.15.5"
}
```

A mesma identidade/revisão/versão aparece em:

- `PapagaioCore/Package.resolved:5-10`;
- `Loro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-10`;
- `Loro.xcworkspace/xcshareddata/swiftpm/Package.resolved:5-10`.

Os três `originHash` diferem porque representam grafos de resolução diferentes;
isso não altera o pin da dependência.

Trecho real dos pins de bootstrap:

```bash
# Scripts/bootstrap-runtimes.sh:49-58
LLAMA_TAG="b9222"
LLAMA_SHA="39b5d476d5716249fa9fcb7796b89f1a7dc6bd8828531b825efd936cdd51d4f7"
WHISPER_TAG="v1.9.1"
WHISPER_SHA="8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
ONNX_TAG="1.24.2"
ONNX_SHA="f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
SILERO_SHA="1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
```

O SHA do modelo GGML do app também é fixado no código, nos dois pesos
(`Preflight.swift:22-33`); a validação acontece no download e na revalidação do
arquivo existente (`DownloadDeModelos.swift:82-87,184-194`).

### 1.3 Comandos de build/teste reais declarados

| Etapa | Comando | Evidência |
|---|---|---|
| Bootstrap | `./Scripts/bootstrap-runtimes.sh` | `README.md:79-83,102-104`; `ci.yml:16-17,28-29` |
| Core | `./Scripts/testa-papagaio-core.sh` → `swift test --no-parallel` | `Scripts/testa-papagaio-core.sh:54-60` |
| App test | `xcodebuild test -project Loro.xcodeproj -scheme Loro -destination 'platform=macOS' …` | `ci.yml:31-42`; mode isolado no scheme `Loro.xcscheme:25-48` |
| App build | `xcodebuild build … -destination 'generic/platform=macOS' …` | `ci.yml:44-51`; `README.md:106-112` |
| Xcode Cloud | `"$CI_PRIMARY_REPOSITORY_PATH/Scripts/bootstrap-runtimes.sh"` | `ci_scripts/ci_post_clone.sh:20-22` |
| Release archive | **ausente** | nenhum `xcodebuild archive`, `codesign --verify`, `spctl` ou `notarytool` no workflow |

A CI não cria archive de Release, não verifica assinatura/entitlements do produto
e não publica `xcresult`. Isto é uma lacuna de **gate de distribuição**, não prova
de que a distribuição esteja quebrada.

O suporte de SBOM foi confirmado no help local, sem gerar arquivo:

```text
$ swift package generate-sbom --help
--sbom-spec <sbom-spec> Set the SBOM specification and generate an SBOM.
                  (values: cyclonedx, spdx, cyclonedx1, spdx3)
```

---

## 2. Gargalos, anti-padrões e segurança da cadeia de suprimentos

### 2.1 Controles positivos confirmados

| Controle | Evidência real | Confiança |
|---|---|---|
| Dependência SwiftPM exata e revisão pinada | `Package.swift:15`; três `Package.resolved:9-10` | **CONFIRMADO** |
| SHA-256 de arquivos compactados antes de extrair | `bootstrap-runtimes.sh:122-133,160-171` | **CONFIRMADO** |
| Promoção atômica de arquivos simples | `bootstrap-runtimes.sh:173-181` | **CONFIRMADO** |
| 21 hashes de diarização | `bootstrap-runtimes.sh:242-264`; 21/21 saídas locais conferem | **CONFIRMADO** |
| Pesos GGUF com tamanho + SHA-256 | `Preflight.swift:22-33`; `DownloadDeModelos.swift:184-194` | **CONFIRMADO** |
| Sem pipe de download para shell | busca por `curl … \| (sh\|bash)` = 0 | **CONFIRMADO** |
| Trigger de PR sem privilégio de `pull_request_target` | `ci.yml:3-7` | **CONFIRMADO** |
| App Sandbox e Hardened Runtime configurados | `Papagaio.entitlements:19-22`; `project.pbxproj:447-452,487-492` | **CONFIRMADO** |
| Ambiente de teste sem serviços reais | `Loro.xcscheme:25-48`; `ci.yml:31-34` | **CONFIRMADO** |
| User Script Sandboxing habilitado | `project.pbxproj:400,430` | **CONFIRMADO** |

### 2.2 Achados priorizados

| ID | Prioridade | Classificação | Conclusão |
|---|---:|---|---|
| BCI-01 | P0 condicional | **CONFIRMADO** | client secret de OAuth entrou no histórico; rotação não verificada |
| BCI-02 | P1 | **CONFIRMADO** | action por tag móvel e token sem `permissions:` explícitos |
| BCI-03 | P1 | **CONFIRMADO** | CI não fixa Xcode; local é Swift 6.4/Xcode 27 beta e runner é Xcode 26.6; o patch Swift do runner é **PROVÁVEL** |
| BCI-04 | P1 | **CONFIRMADO** | XCFramework existente é aceito só por `Info.plist`; cópia não é atômica |
| BCI-05 | P1 | **CONFIRMADO** | XCFs locais sem assinatura; library validation desativada; CI sem gate de assinatura |
| BCI-06 | P1 | **CONFIRMADO** | whisper `v1.9.1` não contém 3 correções de segurança de memória presentes em `v1.9.4` |
| BCI-07 | P1 | **CONFIRMADO** | CI pode resolver pacote fora do lockfile; Apple recomenda bloquear resolução automática |
| BCI-08 | P2 | **CONFIRMADO** | URLs `main` degradam disponibilidade/proveniência, embora hashes preservem integridade |
| BCI-09 | P2 | **CONFIRMADO** | sem cache, timeout, retry de download ou artefato `xcresult` |
| BCI-10 | P2 qualidade | **CONFIRMADO** | testes Python dos scripts e warnings-as-errors fora do gate |
| BCI-11 | P2 futuro | **CONFIRMADO** | `-skipPackagePluginValidation` deve sair; **risco atual refutado**, pois há 0 plugins |

#### BCI-01 — segredo no histórico Git

Evidência de proteção do arquivo local:

```text
.gitignore:29-30
# Credenciais OAuth do Google Calendar (locais por dev, nunca versionar).
Config/Secrets.xcconfig
```

```text
Config/Base.xcconfig:3-10
// Secrets.xcconfig é gitignored; o template para copiar é
// Config/Secrets.example.xcconfig.
#include? "Secrets.xcconfig"
```

Busca redigida no histórico por padrão de client secret:

```text
$ git log --all --format='%H %ad %s' --date=short -S'<padrão-redigido>' -- Config/SETUP-GOOGLE.md
e2eceb38199806fd2a9a919db9f4fa1cf95fb64a 2026-08-27 security: remove segredo OAuth do bundle
41c48eb6cb1eb9ec7a035d468840593bb6096228 2026-08-26 Google Calendar funcional

$ git log --all --oneline -- Config/Secrets.xcconfig
# vazio

$ git check-ignore -v Config/Secrets.xcconfig
.gitignore:30:Config/Secrets.xcconfig Config/Secrets.xcconfig
```

**CONFIRMADO:** o valor histórico foi versionado e removido; o arquivo local
atual não foi versionado. **NÃO VERIFICADO:** se o valor de agosto foi revogado,
se o remote já continha os commits e se algum clone/fork o recebeu. A rotação
deve ser verificada no Google Cloud Console; só depois avaliar purga de histórico
e force-push, pois purge quebra clones.

#### BCI-02 — action mutável e permissão implícita

```yaml
# .github/workflows/ci.yml:12-14,24-26
runs-on: macos-26
steps:
  - uses: actions/checkout@v4
...
runs-on: macos-26
steps:
  - uses: actions/checkout@v4
```

Buscas no workflow inteiro:

```text
uses:                 2
actions/checkout@v4  2
permissions:          0
pull_request_target:  0
workflow_run:         0
```

A tag `v4` pode ser movida. O histórico do mantenedor mostra que v5
usa Node 24, v6 move credenciais persistidas para `$RUNNER_TEMP` e v7
endurece defaults para PRs em `pull_request_target`; são motivos de higiene,
não advisories contra `@v4`. O que fazer:

- pinar `actions/checkout` por SHA completo do commit usado, com comentário
  contendo a tag;
- declarar `permissions: contents: read` no workflow;
- usar Dependabot para atualizar a versão comentada e o SHA;
- manter `pull_request`, que é o trigger seguro para conteúdo não confiável.

A ausência de `permissions:` não prova que o token tenha escrita: o default
depende do repositório/organização. Prova apenas que o workflow **não declara**
privilégio mínimo.

#### BCI-03 — toolchain da CI não corresponde à local

Evidência já reproduzida na §1.1. `runs-on: macos-26` seleciona a imagem, não
uma build do Xcode. A imagem pode atualizar o default sem alteração no repositório.
A correção é selecionar uma Xcode instalada explicitamente e imprimir
`xcodebuild -version`/`swift --version` no log, ou fixar a imagem por uma
estratégia suportada. Não presumi um patch Swift que a fonte Apple não publica.

#### BCI-04 — bootstrap aceita XCFramework existente sem rehash

```bash
# Scripts/bootstrap-runtimes.sh:107-116
if [ -d "$DESTINO/$xcf" ]; then
    local info="$DESTINO/$xcf/Info.plist"
    if [ -f "$info" ] && ! head -n 1 "$info" | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
        echo "==> $nome já presente em PapagaioCore/Frameworks/$xcf — pulando"
        return
    fi
```

O teste só exclui ponteiro Git LFS. Não confere tamanho, conjunto de arquivos,
SHA-256 ou assinatura. A cópia também ocorre diretamente no destino:

```bash
# Scripts/bootstrap-runtimes.sh:135-149
unzip -q "$TEMP/$nome.zip" -d "$TEMP/$nome"
...
mkdir -p "$DESTINO"
cp -R "$origem" "$DESTINO/$xcf"
podar_para_macos "$xcf"
```

Interromper `cp -R` ou o podamento pode deixar um `Info.plist` utilizável com
conteúdo incompleto; a próxima execução pode pular. Conclusão de impacto:
**PROVÁVEL** para quebra de build e aceitação de bytes alterados quando o
diretório já foi alterado. O controle é localmente confirmado.

O contraste correto está no download de arquivos simples:

```bash
# Scripts/bootstrap-runtimes.sh:173-181
preparado="$(mktemp "$(dirname "$destino")/.bootstrap.XXXXXX")"
if ! cp "$TEMP/$nome" "$preparado" || ! mv -f "$preparado" "$destino"; then
    rm -f "$preparado"
    return 1
fi
```

Correção recomendada: gerar um manifest determinístico do **XCFramework final**
(após prune e module map), preparar em diretório temporário no mesmo volume,
validar todos os arquivos e só então fazer `mv` atômico para o destino.

#### BCI-05 — binários locais sem assinatura e exceção de library validation

Medição real:

```text
$ for p in PapagaioCore/Frameworks/{llama,whisper,onnxruntime}.xcframework; do
    codesign --verify --deep --strict --verbose=2 "$p" 2>&1 || true
  done
PapagaioCore/Frameworks/llama.xcframework: code object is not signed at all
PapagaioCore/Frameworks/whisper.xcframework: code object is not signed at all
PapagaioCore/Frameworks/onnxruntime.xcframework: code object is not signed at all
```

Configuração do app:

```text
Loro.xcodeproj/project.pbxproj:447-452
CODE_SIGN_ENTITLEMENTS = Config/Papagaio.entitlements;
CODE_SIGN_STYLE = Automatic;
...
ENABLE_HARDENED_RUNTIME = YES;
```

```xml
<!-- Config/Papagaio.entitlements:19-22 -->
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

A Apple define library validation como hardening que impede carregar código sem
assinatura Apple ou do mesmo Team ID; a exceção deve ser a mais estreita
possível. Aqui existe uma exceção ampla para todos os frameworks/plugins.

A CI reduz ainda mais a cobertura:

```yaml
# .github/workflows/ci.yml:39-42,50-51
-skipPackagePluginValidation \
CODE_SIGNING_ALLOWED=NO \
CODE_SIGNING_REQUIRED=NO \
-derivedDataPath /private/tmp/papagaio-ci-app-tests
...
-skipPackagePluginValidation \
CODE_SIGNING_ALLOWED=NO
```

**Não foi afirmado** que o app final esteja sem assinatura. O que está
confirmado é que os XCFs extraídos estão sem assinatura e que a CI não testa a
cadeia assinada/entitlements de um archive Release. A assinatura ad-hoc abaixo
é apenas recuperação do bundle de teste, não distribuição:

```bash
# Scripts/testa-papagaio-core.sh:54-56
limpar_bundle "$bundle"
codesign --force --sign - --timestamp=none "$bundle" 2>/dev/null || return 1
swift test --no-parallel --skip-build "$@"
```

Correção: criar um job de release separado, com Archive/Export, assinatura,
`codesign --verify --deep --strict`, inspeção de entitlements, `spctl` e
notarização. Testar se os XCFs podem ser assinados no copy phase; se possível,
remover `disable-library-validation`.

#### BCI-06 — whisper `v1.9.1` está antes de correções de segurança

O repo whisper.cpp publica **zero advisories**, mas as notas de release oficiais
listam:

- `v1.9.3`: heap OOB read em `log_mel_spectrogram` para áudio muito curto;
- `v1.9.3`: recusa de `n_dins` inválido para impedir stack-buffer-overflow em
  modelo malformado;
- `v1.9.4`: inicialização de `whisper_mel` para evitar leitura não inicializada.

Essas correções não existem em `v1.9.1`, tag fixada no projeto. Não reproduzi
PoC nem determinei reachability no app; a recomendação é avaliar `>= v1.9.4`,
trocando tag e SHA-256 e rodando a suíte.

#### BCI-07 — resolução automática de pacotes na CI

A Apple recomenda commitar `Package.resolved` — o projeto já faz isso — e,
quando usa `xcodebuild` diretamente, passar:

```text
-disableAutomaticPackageResolution
```

O workflow não passa essa flag (`ci.yml:35-51`). Para o job SPM, a flag
equivalente no help local é:

```text
--force-resolved-versions, --disable-automatic-resolution,
--only-use-versions-from-resolved-file
```

Mesmo com `exact:` no manifest, fazer a CI falhar quando o lockfile estiver
inconsistente evita resolução silenciosa diferente da revisada.

#### BCI-08 — URLs mutáveis e proveniência histórica

Bootstrap:

```bash
# Scripts/bootstrap-runtimes.sh:238-241
DIARIZACAO_BASE="https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/main"
...
# caminho|sha256 — gerados em 2026-08-11 a partir do HEAD do repo acima.
```

Pesos:

```swift
// PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:22-33
url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!
...
url: URL(string: "https://huggingface.co/bartowski/Qwen_Qwen3.5-9B-GGUF/resolve/main/Qwen_Qwen3.5-9B-Q4_K_M.gguf")!
```

Os hashes reduzem risco de integridade; `main` reduz determinismo e
disponibilidade. Os 21 hashes locais conferem com o `provenance.json` atual do
Hugging Face. Entretanto, o provenance declara:

```json
"status": "historically-reconstructed",
"source": { "exact_historical_revision_verified": false },
"conversion": { "exact_historical_revision_verified": false }
```

e informa que o commit de conversão público é posterior aos artefatos. Portanto,
há **integridade dos 21 bytes**, mas não há atestado de build histórico
reproduzível. O release `FluidAudio 0.16.0` resolveu um problema equivalente
no upstream, fixando artefatos de diarização em revisão imutável; o bootstrap
local ainda usa `main`, protegido apenas pelos 21 hashes. Recomendação: fixar
revisões HF imutáveis e guardar, junto ao projeto, provenance/attestation
verificável.

#### BCI-09 — cache, timeout, retry e artefatos

Ausências confirmadas no workflow:

```text
actions/cache / cache:       0
upload-artifact:             0
timeout-minutes:             0
xcode-select / setup Xcode:  0
strategy / concurrency:      0
```

Os dois jobs executam o bootstrap (`ci.yml:16-17,28-29`). O script estima os
arquivos compactados upstream completos em ~1,2 GB antes do podamento
(`bootstrap-runtimes.sh:18-26`); não foi medido o tráfego real da CI. As árvores
**após o podamento** ocupam localmente:

```text
llama.xcframework                  9.624 KiB
whisper.xcframework                 5.592 KiB
onnxruntime.xcframework            89.380 KiB
silero_vad.onnx                     2.276 KiB
diarização (21 arquivos)           21.136 KiB
Total                              128.008 KiB = 125,0 MiB
```

Não adicionar cache desses XCFs antes de corrigir BCI-04: o bootstrap atual não
revalida o cache. Para SPM/DerivedData, usar chaves com
`hashFiles('**/Package.resolved')`, sem segredos; o cache não tem assinatura e
pode ser envenenado. O trigger `pull_request` atual tem escopo de ref de merge
e é menos exposto que `pull_request_target`, mas a documentação recomenda que
apenas triggers confiáveis escrevam no escopo padrão.

**Observação sobre o manifest Xcode Cloud (não classificada como bug):**

```json
// Loro.xcodeproj/xcshareddata/xcodecloud/manifest.json:5-10
"id" : "41a37063-538c-4229-8491-14389bbaf017",
"name" : "Loro"
...
"id" : "41a37063-538c-4229-8491-14389bbaf017",
"name" : "Papagaio"
```

A duplicidade textual do ID é **CONFIRMADA**; se ela é esperada pelo schema do
Xcode Cloud ou se representa drift de configuração **NÃO VERIFICADO**, pois o
serviço/console não foi acessado. Validar antes de editar.

#### BCI-10 — qualidade de CI, não vulnerabilidade

- `Scripts/tests/test_scripts.py:1-111` tem 8 testes offline, mas o workflow não
  chama `python`/`unittest`/`pytest`.
- `Scripts/adiciona-target-de-testes.rb:1-4` requer a gem `xcodeproj`, mas não há
  `Gemfile`/lockfile; o teste Python pula quando a gem falta
  (`Scripts/tests/test_scripts.py:89-92`). A versão da ferramenta de build não
  é, portanto, auditável por este repositório.
- Não há manifestos `requirements*.txt`, `pyproject.toml` ou `package.json`;
  `pip-audit`/`npm audit` não têm um alvo local. Isso é limitação de auditoria,
  não vulnerabilidade comprovada.
- Não há `.xctestplan`; o scheme executa apenas `PapagaioTests`
  (`Loro.xcscheme:37-48`).
- Não há `GCC_TREAT_WARNINGS_AS_ERRORS` nem
  `SWIFT_TREAT_WARNINGS_AS_ERRORS` no projeto. A baseline Debug teve 120 linhas
  de warning do umbrella header ONNX, 1 AppIntents e 7 SwiftPM/cache/priors:
  128 linhas de warning (`audit/00-mapa.md:436-446`).
- `xcodebuild test` local não produziu resultado final e foi interrompido após
  300 s (`audit/00-mapa.md:386-434`). Isso torna timeout explícito e artefato de
  diagnóstico necessários; não é classificado como CVE.

#### BCI-11 — `-skipPackagePluginValidation`: risco futuro, não atual

A flag aparece duas vezes:

```text
.github/workflows/ci.yml:39
.github/workflows/ci.yml:50
```

O help local do Xcode 27 diz literalmente:

```text
-skipPackagePluginValidation
Skip validation of package plugins (this can be a security risk if they are not from trusted sources)
```

Entretanto:

- `PapagaioCore/Package.swift` não declara `.plugin(...)`;
- o manifest pinado de FluidAudio tem `dependencies: []` e nenhum target de
  plugin (`PapagaioCore/.build/checkouts/FluidAudio/Package.swift:21-57`);
- busca por `plugin:`/`.plugin(` no grafo retornou 0.

**Refutação de falso positivo:** não há plugin malicioso no grafo exato atual,
logo a flag não cria um vetor executável conhecido neste commit. Ela continua
sendo uma armadilha de manutenção: a próxima dependência pode introduzir plugin
sem prompt. Remover a flag e declarar somente plugins necessários é a postura
correta.

### 2.3 CVEs e advisories

#### Consultas OSV executadas

Endpoint: `POST https://api.osv.dev/v1/querybatch`, em 23/09/2026.

| Package/version consultado | Resultado | Uso como evidência |
|---|---|---|
| FluidAudio `0.15.5` | `{}` — 0 vulnerabilidades | Utils ecosystem para pacote SwiftURL; complementado pela página oficial do repo |
| `actions/checkout` `v4` | `{}` — 0 vulnerabilidades | Utils ecosystem para Actions; complementado pela página do mantenedor |
| `onnxruntime` `1.24.2` (PyPI) | `{}` — 0 vulnerabilidades | proxy de versão; o artefato real é o pod archive C do mesmo upstream |
| `lodash@4.17.11` (sanidade) | 7 GHSAs | confirmou que a API respondia normalmente |

A API OSV não oferece cobertura confiável para XCFramework C/C++ ou para o blob
ONNX; por isso llama/whisper/ONNX C também foram checados nas fontes primárias.
Uma API GitHub REST chegou ao limite de taxa durante a pesquisa; páginas
oficiais ainda cobriram os upstreams.

#### Os 13 advisories de llama.cpp e `b9222`

| GHSA | CVE | Severidade | Faixa upstream | `b9222` |
|---|---|---|---|---|
| [GHSA-3p4r-fq3f-q74v](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v) | CVE-2026-27940 | high | afetadas `<= b8145`; corrigidas `>= b8146` | **Não** |
| [GHSA-j8rj-fmpv-wcxw](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-j8rj-fmpv-wcxw) | CVE-2026-34159 | critical | afetadas `<= b7991`; RPC | **Não** |
| [GHSA-96jg-mvhq-q7q7](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-96jg-mvhq-q7q7) | CVE-2026-33298 | high | afetadas `< b7437` | **Não** |
| [GHSA-8947-pfff-2f3c](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8947-pfff-2f3c) | CVE-2026-21869 | low | até `55d4206c8` | **Não** |
| [GHSA-vgg9-87g3-85w8](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-vgg9-87g3-85w8) | CVE-2025-53630 | high | anterior a `26a48ad` | **Não** |
| [GHSA-7rxv-5jhh-j6xx](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-7rxv-5jhh-j6xx) | CVE-2025-52566 | high | afetadas `< b5721` | **Não** |
| [GHSA-g4cc-763q-h9h6](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-g4cc-763q-h9h6) | — | moderate | `c33fe8b8` | **Não** |
| [GHSA-8wwf-w4qm-gpqr](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-8wwf-w4qm-gpqr) | CVE-2025-49847 | high | corrigidas `>= b5662` | **Não** |
| [GHSA-wcr5-566p-9cwj](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-wcr5-566p-9cwj) | CVE-2024-42479 | critical | afetadas `< b3561` | **Não** |
| [GHSA-5vm9-p64x-gqw9](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-5vm9-p64x-gqw9) | CVE-2024-42478 | moderate | afetadas `< b3561` | **Não** |
| [GHSA-mqp6-7pv6-fqjf](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-mqp6-7pv6-fqjf) | CVE-2024-42477 | moderate | afetadas `< b3561` | **Não** |
| [GHSA-49q7-2jmh-92fp](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-49q7-2jmh-92fp) | CVE-2024-41130 | moderate | afetadas `<= b3426` | **Não** |
| [GHSA-p5mv-gjc5-mwqv](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-p5mv-gjc5-mwqv) | CVE-2024-32878 | high | `b2715` | **Não** |

**Resultado:** **0 de 13 advisories** têm faixa que alcance `b9222`. Isso é uma
avaliação de versão, não uma prova de ausência de bugs. O próprio advisory mais
recente diz que o main model loader usa `no_alloc=true` e não é afetado pelo
seu caminho; o app também não usa o RPC backend listado no outro advisory.

#### Outros runtimes

| Componente | Advisory público em 23/09/2026 | Correções/hardening relevantes |
|---|---|---|
| FluidAudio `0.15.5` | 0 na página do repo; 0 OSV | avaliar `0.16.x` por correções de diarização/cancelamento, sem advisory publicado |
| whisper.cpp `v1.9.1` | 0 publicados | 2 correções em `v1.9.3` + 1 correção de leitura não inicializada em `v1.9.4` |
| ONNX Runtime `1.24.2` | 0 publicados; 0 OSV via PyPI | `1.29`: path traversal TensorRT (não macOS CPU), validação MoE/CPU e `TensorScatter`; `1.30`: hardening de model loading, inputs e CPU index overflow |
| Silero `.onnx` | sem DB aplicável | commit + SHA-256; nenhuma verificação de assinatura upstream |
| Diarização `.mlmodelc` | sem DB aplicável | 21 SHA-256 + provenance histórico parcial; sem attestation de rebuild |

---

## 3. Recomendações oficiais

### 3.1 Ordem sugerida

1. **P0 — verificar rotação do OAuth secret histórico.** Consultar o console do
   provider, revogar o valor de agosto/2026 e emitir um novo client secret. Só
   depois decidir purge de histórico. GitHub recomenda deletar logs/credenciais
   expostos e rotacionar; neste caso o valor está em Git, não em log.
2. **P1 — endurecer Actions:** `permissions: contents: read`; pinar SHA completo
   de `actions/checkout`; Dependabot `github-actions`; manter `pull_request`.
3. **P1 — bloquear resolução automática:** passar
   `-disableAutomaticPackageResolution` ao `xcodebuild` e a opção
   `--only-use-versions-from-resolved-file`/equivalente ao job SPM.
4. **P1 — corrigir integridade do bootstrap:** hash manifest do XCF final,
   staging + validação + rename atômico, validação em toda execução e retries.
5. **P1 — gate de release assinado:** Archive/Export Release, assinatura de
   todos os componentes embutidos, `codesign --verify --deep --strict`, inspeção
   de entitlements, `spctl` e notarização. Manter o job de build sem
   assinatura, mas não usá-lo como prova de release.
6. **P1 — alinhar toolchain:** escolher Xcode 27 GA em CI quando suportado pela
   imagem, imprimir versão no log e testar a toolchain de release explicitamente.
7. **P1 — atualizar runtimes com segurança:** avaliar whisper `>= v1.9.4`; avaliar
   ONNX `>= 1.30` para CPU/model-loading; manter llama `b9222` não é vulnerável
   pelos advisories publicados, mas uma build recente deve ser testada contra
   `qwen35` e ter seu SHA fixado novamente.
8. **P2 — remover `-skipPackagePluginValidation`.** O grafo atual não possui
   plugins; a flag só remove uma barreira futura.
9. **P2 — cache seguro:** só depois de BCI-04. Cache de SPM/DerivedData com
   `Package.resolved`; não cachear segredos; origem de escrita apenas em trigger
   confiável; manter cache de PR no escopo do ref de merge.
10. **P2 — SBOM e provenance:** SwiftPM 6.4 suporta
    `swift package generate-sbom --sbom-spec spdx|cyclonedx`; incluir também
    versões/hashes/transformações dos XCFs e modelos, pois o SBOM SwiftPM não
    inventaria os downloads locais do bootstrap.
11. **P2 — completar gates de qualidade:** testes Python, timeout por job,
    `xcresult`/logs como artefatos, análise estática e warning policy explícita.
12. **P3 — reduzir exceções:** testar o archive sem
    `com.apple.security.cs.disable-library-validation`; manter apenas se uma
    biblioteca terceira realmente exigir e documentar o porquê.

### 3.2 Por que essas recomendações são oficiais

- **GitHub Secure Use:** SHA completo é “the only way” de usar uma action como
  release imutável; token deve ter menor privilégio; segredos devem ser
  rotacionados; `pull_request_target` deve ser evitado para PR não confiável.
- **GitHub Dependency Caching:** cache não é assinado/verificado; não armazenar
  segredos; PRs podem ler cache da base; escrita default é somente leitura para
  gatilhos de baixa confiança, com `push` entre os triggers confiáveis.
- **Apple SwiftPM CI:** commitar `Package.resolved` e passar
  `-disableAutomaticPackageResolution` quando `xcodebuild` é chamado diretamente.
- **Apple Hardened Runtime:** Apple só notariza apps com Hardened Runtime;
  exceções removem barreiras e devem ser as mais estreitas possíveis.
- **Apple Disable Library Validation:** library validation é uma proteção contra
  carregar frameworks/plugins sem assinatura Apple ou do mesmo Team ID.
- **Swift 6.4:** SwiftPM 6.4 usa Swift Build por default e gera SBOM em SPDX ou
  CycloneDX.

---

## 4. Bugs e riscos conhecidos relevantes

| Item | Estado | Confiança | Limite do que foi verificado |
|---|---|---|---|
| whisper OOB/stack/leitura não inicializada | `v1.9.1` não contém correções presentes em `v1.9.3/1.9.4` | **CONFIRMADO** por release notes | nenhum PoC/reachability executado |
| ONNX CPU/model-input validation | `1.24.2` não contém correções/hardening de `1.29/1.30` | **CONFIRMADO** por release notes | parte das correções é CUDA-only; impacto macOS CPU não medido |
| llama parser/RPC advisories | 0/13 faixas publicadas atingem `b9222` | **CONFIRMADO** | não prova ausência de vuln sem advisory |
| File Provider + codesign | recuperação de teste limpa xattrs e assina `.xctest` ad hoc | **CONFIRMADO** por `testa-papagaio-core.sh:27-56,73-94` | workaround local, não assinatura de release |
| CI remote | estado de GitHub Actions/Xcode Cloud desconhecido | **NÃO VERIFICADO** | logs/serviços não acessados |
| OAuth secret rotation | estado da rotação desconhecido | **NÃO VERIFICADO** | serviço real não acessado |
| Package plugins | 0 no grafo atual | **CONFIRMADO** | só o commit/resolution exato foi verificado |
| Archive Release | não existe no workflow | **CONFIRMADO** | nenhum archive/notarização foi executado |

Não há bug de runtime reproduced nesta pesquisa; não foi feita análise dinâmica,
fuzzing ou execução de PoC.

---

## 5. Deprecações e anti-deprecações

| Item | Evidência | Status em 23/09/2026 | Ação |
|---|---|---|---|
| Xcode 27 beta 1 local | build `27A5194q` | superseded por Xcode 27 GA `27A266a`; não é “depreciação” | trocar máquina local para GA quando possível |
| `actions/checkout@v4` | `ci.yml:14,26` | não encontrei depreciação formal; a versão mais recente era `v7.0.1` | atualizar e pinar SHA; sem alegar CVE |
| SwiftPM `--build-system native` | `swift package --help` local marca `native (deprecated)` | deprecado; projeto usa default `swiftbuild` | nenhuma ação; não voltar para `native` |
| `swift-tools-version: 6.0` | `Package.swift:1` | não deprecado; é a versão mínima de tools | manter ou elevar separadamente, sem misturar com update Swift |
| `-undefined dynamic_lookup` | só no target de testes, `project.pbxproj:354-357,377-380` | depreciação latente do linker novo, confirmada apenas por fontes secundárias; não apareceu no build auditado | remover se a suite passar sem ele; não é setting do app Release |
| `COMBINE_HIDPI_IMAGES` | `project.pbxproj:449,489` | depreciação oficial **não confirmada** | não alterar com base em boato |
| `ALWAYS_SEARCH_USER_PATHS = NO` | `project.pbxproj:392,422` | setting legado, mas `NO` é a postura correta | manter |
| `disable-library-validation` | entitlement line 21-22 | não deprecado; é exceção explícita que reduz hardening | remover se assinatura por Team ID funcionar |
| código de warning como erro | 0 settings no `pbxproj` | não é depreciação, é gate de qualidade ausente | política explícita após limpar warnings vendorizados |

---

## 6. Onde procurar no código — buscas e contagens

Escopo: repositório, excluindo `.git`, `.build`, `audit/` e artefatos gerados,
salvo quando explicitamente indicado.

| Padrão/comando | Resultado | Interpretação |
|---|---:|---|
| `rg -n 'uses:' .github/workflows` | 2 | ambos `actions/checkout@v4` |
| `rg -n 'permissions:' .github/workflows` | 0 | privilégio mínimo não declarado |
| `rg -n 'xcode-select|setup-xcode|maxim-locator|get-xcode' .github/workflows` | 0 | toolchain não selecionada |
| `rg -n 'actions/cache|cache:' .github/workflows` | 0 | sem cache |
| `rg -n 'timeout-minutes' .github/workflows` | 0 | sem timeout explícito |
| `rg -n 'upload-artifact' .github/workflows` | 0 | sem artefato xcresult/log |
| `find . -name dependabot.yml -o -name dependabot.yaml` | 0 | sem Dependabot |
| `rg -n 'skipPackagePluginValidation' .github/workflows` | 2 | flag presente; 0 plugins no grafo |
| `rg -n 'plugin:|\.plugin\(' PapagaioCore/Package.swift` | 0 | sem plugin root |
| mesmo padrão no checkout FluidAudio pinado | 0 | sem plugin transitivo no commit resolvido |
| `rg -n 'unsafeFlags' PapagaioCore/Package.swift` | 1 | rpath de teste; SwiftPM pode rejeitar o package como dependency |
| `rg -n 'CODE_SIGNING_ALLOWED|CODE_SIGNING_REQUIRED' .github/workflows` | 3 | CI não assina |
| `rg -n 'disable-library-validation' Config` | 1 | exceção presente |
| `rg -n 'GCC_TREAT_WARNINGS_AS_ERRORS|SWIFT_TREAT_WARNINGS_AS_ERRORS' Loro.xcodeproj` | 0 | warning policy ausente |
| `find . -name '*.xctestplan'` | 0 | sem test plan |
| `rg -n 'python|unittest|pytest' .github/workflows/ci.yml` | 0 | testes Python fora da CI |
| busca por `curl … \| (sh\|bash)` | 0 | sem remote script execution |
| `rg -n 'sudo' Scripts ci_scripts` | 0 | sem sudo nos scripts |
| `find . -name provenance.json` | 0 local | provenance existe no repo HF, não no clone local |
| `git ls-files '*.xcframework'` | 0 | binários ficam fora do Git, como planejado |

Comandos de inspeção de assinatura/medida:

```bash
codesign --verify --deep --strict --verbose=2 <um-dos-três-xcf>
du -sk PapagaioCore/Frameworks/*.xcframework \
  PapagaioCore/Sources/PapagaioCore/Resources/silero_vad.onnx \
  PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao
find PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao -type f -print0 \
  | sort -z | xargs -0 shasum -a 256
```

---

## 7. Fontes

Todas acessadas em **23/09/2026**. URLs completas; o ponto após cada uma é
paráfrase do que foi usado, não citação integral.

### Swift/Apple/toolchain

1. **https://www.swift.org/blog/swift-6.4-released/** — Swift 6.4, 15/09/2026 —
   Swift Build como default no SwiftPM; SBOM SPDX/CycloneDX; lançamento 6.4.
2. **https://docs.swift.org/latest/documentation/packagemanagerdocs/6.4/** —
   notas de release do SwiftPM 6.4 — recursos e compatibilidade do build system.
3. **https://docs.swift.org/latest/documentation/packagemanagerdocs/generatingsboms/**
   — geração de SBOM pelo SwiftPM.
4. **https://developer.apple.com/news/releases/** — Apple Releases — Xcode
   `27A266a` em 14/09/2026 e Xcode 26.6 `17F113` em 25/06/2026.
5. **https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows**
   — Apple Xcode CI — commitar `Package.resolved` e usar
   `-disableAutomaticPackageResolution` com `xcodebuild`.
6. **https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime**
   — Apple — Hardened Runtime; notarization exige a capability; exceções
   removem barreiras e devem ser estreitas.
7. **https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation**
   — Apple — library validation exige Apple/mesmo Team ID; a chave permite
   carregar frameworks/plugins sem essa assinatura.
8. **https://developer.apple.com/library/archive/technotes/tn2339/_index.html**
   — Apple TN2339 — build pela linha de comando e seleção de Xcode via
   `xcode-select`.
9. **https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md**
   — GitHub runner images — imagem consultada `20260824.0517.1`, Xcode 26.6
   como default, SDKs e anúncios.

### GitHub Actions

10. **https://docs.github.com/en/actions/reference/security/secure-use** —
    GitHub Secure Use — pin de SHA completo, privilégio mínimo, rotação de
    segredos, evitar `pull_request_target`, Dependabot e SBOM do runner.
11. **https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching**
    — GitHub Cache — chaves, cache sem assinatura, isolamento por branch,
    cache poisoning, triggers confiáveis e limites.
12. **https://github.com/actions/checkout/releases/tag/v7.0.1** — versão mais
    recente observada `v7.0.1`, 20/07/2026; comparação de major.
13. **https://github.com/actions/checkout/security/advisories** — mantenedor —
    “There aren't any published security advisories”.
14. **https://api.osv.dev/v1/querybatch** — consultas OSV descritas na §2.3.

### Dependências e advisories

15. **https://github.com/FluidInference/FluidAudio/releases/tag/v0.16.1** —
    versão mais recente observada `0.16.1`, 21/09/2026; SemVer/notas de versão.
15a. **https://github.com/FluidInference/FluidAudio/releases/tag/v0.16.0** —
    alteração de pinning dos artefatos de diarização em revisão imutável.
16. **https://github.com/FluidInference/FluidAudio/security/advisories** — página
    oficial do mantenedor; nenhum advisory publicado.
17. **https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.3** — correções de
    OOB read e header de tensor malformado.
18. **https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4** — versão mais
    recente observada e correção de leitura não inicializada.
19. **https://github.com/ggml-org/whisper.cpp/security/advisories** — zero
    advisories publicados.
20. **https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.1** —
    release estável mais recente `v0.4.1`, 14/09/2026; `b10964` é nightly, não a release.
21. **https://github.com/ggml-org/llama.cpp/releases/tag/b11139** — nightly
    observado em 23/09/2026, usado apenas para comparação de atualização.
22. **https://github.com/ggml-org/llama.cpp/security/advisories** e
    **https://github.com/ggml-org/llama.cpp/security/advisories?page=2** —
    13 advisories e respectivas faixas.
23. **https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0** — seção
    Security Fixes e cobertura CPU/CUDA.
24. **https://github.com/microsoft/onnxruntime/releases/tag/v1.30.0** — versão
    mais recente observada, hardening de model loading/input e CPU index overflow.
25. **https://github.com/microsoft/onnxruntime/security/advisories** — zero
    advisories publicados.
26. **https://api.github.com/repos/snakers4/silero-vad/commits/76e3dc408eb2a5c655c34e230d2d5459b4439daa**
    — commit exato do modelo Silero.
27. **https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml**
    — repo HF `df2625ac79a7ac6b65ad868fee6d80f320da4232`, lista de artefatos.
28. **https://huggingface.co/FluidInference/speaker-diarization-coreml/raw/main/provenance.json**
    — hashes dos artefatos, snapshot `1ed7a662…` e status
    `historically-reconstructed`.
29. **https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml/commits/main**
    — histórico do repo; commit de provenance em 19/09/2026.

### Fontes locais

30. `.github/workflows/ci.yml:1-51` — triggers, runner, action, bootstrap,
    testes, flags e assinatura.
31. `Scripts/bootstrap-runtimes.sh:1-314` — versões, hashes, downloads, extração,
    podamento, module map, diarização e atomicidade.
32. `Scripts/testa-papagaio-core.sh:1-95` — SwiftPM, recuperação de xattr/codesign
    e proteção contra testes obsoletos.
32a. `Scripts/adiciona-target-de-testes.rb:1-4` e
    `Scripts/tests/test_scripts.py:89-92` — dependência da gem `xcodeproj` e
    skip condicional.
33. `ci_scripts/ci_post_clone.sh:1-22` — bootstrap pós-clone do Xcode Cloud.
34. `PapagaioCore/Package.swift:1-105` e os três `Package.resolved` — pinagem,
    binary targets e plugin graph.
35. `Loro.xcodeproj/project.pbxproj:342-514` — Swift 6, deployment, sandbox
    inputs, Hardened Runtime e signing.
36. `Config/Papagaio.entitlements:1-38` — App Sandbox, library validation e
    capabilities.
37. `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:1-95` e
    `Loro.xcodeproj/xcshareddata/xcodecloud/manifest.json:1-13` — test action,
    mode isolado e manifest Xcode Cloud.
38. `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:19-36,128-178` e
    `DownloadDeModelos.swift:39-195` — URLs, tamanhos, SHA-256, streaming hash,
    retry/Range e promoção.
39. `audit/00-mapa.md:307-471` — comandos e baseline numérica executada por
    outro agente da mesma auditoria; resultados citados como baseline secundária, não
    como execução desta pesquisa.

---

## 8. Limitações e o que não foi verificado

1. **Não executei `Scripts/bootstrap-runtimes.sh`**, não baixei arquivos
   compactados e não atualizei dependências. Os XCFrameworks e modelos já
   estavam presentes.
2. **Não calculei o SHA-256 dos arquivos compactados originais** de
   whisper/llama/ONNX nem comparei download com o pin; comparei hashes de
   modelos locais e rodei `codesign` nos XCFs extraídos.
3. **Não executei build Release, archive, export, assinatura, `spctl`,
   `codesign --verify` do app final nem notarização.** Portanto o estado de
   assinatura/notarização de uma distribuição real é desconhecido.
4. **Não acessei logs/estado do GitHub Actions nem do Xcode Cloud.** Não sei se
   workflows remotos passaram, falharam ou foram cancelados; também não
   confirmei no console se o ID duplicado do manifest é válido.
5. **Não consultei serviço real para verificar rotação/revogação do OAuth
   secret**, nem fiz purge/force-push.
6. **Não reproduzi PoC, fuzzing ou benchmark de segurança** de whisper, llama ou
   ONNX. A conclusão de llama é por versão/advisory, não por exploração.
7. **Não determinei reachability de domínio** de áudio/modelos maliciosos. Este
   relatório não transforma runtime fix em vulnerabilidade do app.
8. **Não validei attestations/SLSA/SBOM dos arquivos upstream.** O controle
   local é SHA-256; o provenance histórico do modelo de diarização é parcial.
9. **Patch Swift exato do runner macOS-26:** Apple/imagem do runner confirma Xcode
   26.6; a série Swift 6.3 é provável, mas o patch não foi atribído com fonte
   oficial.
10. **Cobertura OSV:** PyPI/SwiftURL são proxies, não a melhor modelagem para
    arquivos C/C++; GitHub REST atingiu rate limit. Páginas oficiais dos
    mantenedores reduziram, mas não eliminam, esse limite.
11. **Desempenho de CI não foi medido.** 48,34 s é apenas o build Debug local da
    baseline; ~1,2 GB é a estimativa do próprio script para downloads upstream,
    não bytes observados no runner.
12. **A árvore já estava suja antes deste relatório** com mudanças não
    relacionadas. Nenhuma delas foi revertida ou atribuída a este P4; somente
    `audit/01-pesquisa/build-ci-seguranca.md` foi criado por esta pesquisa.

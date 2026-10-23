# Verificação V-P4 — Build, CI, SwiftPM, runtimes, assinatura e cadeia de suprimentos

- **Revisor:** V-P4, revisão independente da ficha `audit/01-pesquisa/build-ci-seguranca.md`.
- **Data da verificação:** 23/09/2026.
- **HEAD observado:** `6138e1d1d94c3daf15b5a645930336903ef15b98`.
- **Modo:** somente leitura do repositório e das fontes; nenhuma execução de bootstrap, build, testes, arquivamento, assinatura, publicação, serviço real ou leitura do conteúdo de `Config/Secrets.xcconfig`.
- **Único arquivo escrito:** `audit/03-verificacao/V-P4.md`.
- **Escopo das contagens:** cópia de trabalho principal, excluindo `.git`, `.build`, `.claude/worktrees`, `audit/` e artefatos ignorados, salvo menção explícita.

## 1. Resultado executivo

A ficha P4 é tecnicamente sólida na maior parte: as fixações do SwiftPM, as somas de verificação, o fluxo de reexecução do bootstrap, os intervalos dos 13 avisos de segurança do llama.cpp e as cautelas sobre assinatura e proveniência estão bem sustentados. Porém, há ajustes materiais:

1. o `codesign` de recuperação citado em BCI-05 está em `Scripts/testa-papagaio-core.sh`, arquivo **modificado e não commitado**; portanto, não pertence ao HEAD declarado;
2. os três contêineres/frameworks sem assinatura completa não equivalem a três runtimes “sem assinatura alguma”: os arquivos Mach-O de llama e whisper têm assinatura **ad hoc gerada pelo linker**, embora os bundles não tenham assinatura completa;
3. a estimativa de **~1,2 GB de arquivos compactados** é refutada pelos `Content-Length` e metadados atuais: os três arquivos compactados somam **306.113.690 bytes (~291,9 MiB)**; 1,2 GB pode ser uma estimativa do tamanho extraído, não do tráfego compactado;
4. a URL `FluidAudio/releases/tag/v0.16.0` retorna 404; a mudança para uma fixação imutável aparece na release `v0.15.8`, cujo título é “v0.16.0 — CUA-S1-FORM”;
5. os três valores distintos de `originHash` não representam “grafos de resolução diferentes”: os três arquivos têm exatamente a mesma fixação única;
6. “Recomendações oficiais” mistura orientação normativa oficial com opinião e priorização da autora;
7. as consultas ao OSV para `SwiftURL` e PyPI são representações indiretas, e `v4` não identifica, por si só, o commit efetivamente executado; na reabertura, `v4` apontava para `v4.4.0`/`11d5960…`;
8. `latest` e `nightly` são sensíveis ao tempo: durante a verificação surgiram `FluidAudio v0.17.1` e `llama.cpp b11147` no mesmo dia, depois da janela observada pela P4.

**Conclusão por achado BCI:** 3 `CONFIRMADO`, 8 `CONFIRMADO COM AJUSTE`, 0 `REFUTADO` e 0 `INCONCLUSIVO` no nível do achado; existem alegações individuais refutadas ou inconclusivas dentro desses achados.

## 2. Método e limites da própria verificação

### 2.1 Evidência local reaberta

Foram reabertos e/ou validados:

- manifestos: `PapagaioCore/Package.swift` e os três `Package.resolved` primários;
- workflow: `.github/workflows/ci.yml`;
- scripts citados: `Scripts/bootstrap-runtimes.sh`, `Scripts/testa-papagaio-core.sh`, `Scripts/adiciona-target-de-testes.rb`, `Scripts/tests/test_scripts.py`, `ci_scripts/ci_post_clone.sh`;
- projeto/configuração: `Loro.xcodeproj/project.pbxproj`, `Config/Papagaio.entitlements`, `Config/Base.xcconfig`, `.gitignore`, scheme e manifesto do Xcode Cloud;
- runtimes: `Preflight.swift`, `DownloadDeModelos.swift` e os invólucros Swift dos três XCFrameworks;
- manifestos resolvidos: `PapagaioCore/.build/checkouts/FluidAudio/Package.swift` e HEAD/tag `v0.15.5`.

Comandos somente leitura usados como evidência própria incluíram:

```text
git rev-parse HEAD
git status --short
git log --all --format='%H %ad %s' --date=short -- Config/SETUP-GOOGLE.md
git check-ignore -v Config/Secrets.xcconfig
git diff -- Scripts/testa-papagaio-core.sh
swift --version
swift package --version
swift package --help
swift package generate-sbom --help
xcodebuild -version
xcode-select -p
codesign --verify --deep --strict --verbose=2 <framework/xcf>
codesign -dvvv <framework>
du -sk <artefatos>
shasum -a 256 <artefatos>
rg/find/git ls-files <contagens>
bash -n <scripts>
ruby -c Scripts/adiciona-target-de-testes.rb
python3 -c 'import ast; ast.parse(...)'
plutil -lint <plist>
JSON.parse/YAML.parse <manifests>
```

O teste do segredo histórico foi redigido: um script leu os blobs Git apenas para classificar a atribuição e emitiu `deleted_assignment=True`, `key=GOOGLE_CLIENT_SECRET`, `nonempty=True`; uma busca posterior no instantâneo removido não encontrou a atribuição. **Nenhum valor ou prefixo foi reproduzido**.

### 2.2 URLs

- 31 URLs na lista de fontes + 13 URLs diretas da matriz GHSA = **44 URLs citadas**;
- mais 9 URLs externas distintas presentes nos manifestos, scripts e URLs de modelos citados = **53 URLs distintas reabertas**;
- **52/53** responderam pela operação correta; a única falha foi `FluidAudio .../releases/tag/v0.16.0` (**404**);
- `https://api.osv.dev/v1/querybatch` exige POST; GET retorna 405, mas o POST reproduziu 200;
- as 9 URLs de artefatos locais foram reabertas por **HEAD**, sem baixar o corpo; todas retornaram 200;
- os assets GitHub de llama/whisper tiveram o digest SHA-256 oficial confrontado sem download do arquivo compactado.

### 2.3 O que não foi feito

- nenhum arquivo/binário upstream foi salvo localmente;
- nenhum hash do arquivo compactado do ONNX foi calculado;
- nenhum arquivamento, exportação, notarização ou assinatura foi executado;
- nenhum log remoto do GitHub ou do Xcode Cloud foi acessado;
- OAuth, CloudKit e rotação de segredo não foram consultados;
- builds/testes não foram reexecutados; logs preexistentes foram apenas relidos e são fonte secundária;
- nenhum segredo local foi aberto.

## 3. Contagem de veredictos

A matriz contém **194 alegações** (`C001`–`C194`):

- **146** `CONFIRMADO`;
- **30** `CONFIRMADO COM AJUSTE`;
- **9** `REFUTADO`;
- **9** `INCONCLUSIVO`.

## 4. Divergências principais

### D1 — Evidência do `codesign` não pertence ao HEAD

- `.github/workflows/ci.yml:19-20` executa `Scripts/testa-papagaio-core.sh` em uma cópia de trabalho limpa.
- `git status --short` mostra `M Scripts/testa-papagaio-core.sh`.
- `git diff -- Scripts/testa-papagaio-core.sh` mostra que o `codesign --force --sign -` foi adicionado no WIP.
- No HEAD, o procedimento de recuperação é `xattr -cr "$PRODUTOS"`, seguido de um novo `swift test`, sem assinatura ad hoc.
- Logo, a parte de BCI-05 referente a “File Provider + codesign”, assim como a linha correspondente, vale para a árvore de trabalho, mas é `REFUTADA` como afirmação sobre `6138e1d…`/CI.

### D2 — “~1,2 GB compactados” é incorreto

No HEAD, os assets e os metadados oficiais são:

| Asset | Bytes |
|---|---:|
| llama `b9222` XCFramework ZIP | 203.536.578 |
| whisper `v1.9.1` XCFramework ZIP | 50.438.515 |
| ONNX Runtime C `1.24.2` ZIP | 52.138.597 |
| **Total** | **306.113.690 (~291,9 MiB)** |

A afirmação pode fazer sentido para o tamanho extraído, mas não para “arquivos compactados upstream completos”. A mesma estimativa desatualizada aparece em `Scripts/bootstrap-runtimes.sh:18-26`, `PapagaioCore/Package.swift:18-21` e `ci_scripts/ci_post_clone.sh:11-18`.

### D3 — Release/tag FluidAudio `0.16.0`

- `v0.16.0` não existe entre as releases e tags da API.
- A release `v0.15.8` tem o título **“v0.16.0 — CUA-S1-FORM”** e inclui o commit `a6f1ca8…` (“Pin diarization artifacts to immutable revision”).
- A conclusão sobre a fixação é válida; a URL e a grafia “release/tag `v0.16.0`” não são.

### D4 — `originHash`

Os três valores de `originHash` diferem, mas cada `Package.resolved` contém somente uma fixação, com a mesma identidade, revisão e versão. Logo, a interpretação de “grafos de resolução diferentes” é `REFUTADA`; no máximo representam contextos ou origens de dependências diferentes.

### D5 — A assinatura do XCFramework precisa ser qualificada

- `codesign --verify` no contêiner `.xcframework` e no bundle `.framework` retorna “not signed at all”.
- `codesign -dvvv` no Mach-O de llama/whisper retorna `Signature=adhoc`, com as flags `adhoc,linker-signed`.
- O ONNX é um `static archive` dentro do framework; o bundle não tem assinatura de código, e a assinatura final do app incorporado não foi inspecionada.
- “Unsigned” sem qualificador é impreciso. O relatório deve separar a assinatura do contêiner, a do Mach-O aninhado, a assinatura com Team ID e a assinatura efetiva no app final.

### D6 — “Recomendações oficiais” não é uniformemente oficial

São oficiais: fixação por SHA completo, princípio do menor privilégio, rotação, evitar `pull_request_target`, cache não assinado, cache poisoning, `Package.resolved` + `-disableAutomaticPackageResolution`, Hardened Runtime e exceções estreitas. São decisões da autora ou priorizações: P0/P1/P2, manifesto final do XCF, número de retentativas, momento do cache, atualização de cada runtime, política de avisos e escolha do gate de release.

### D7 — Cobertura do OSV

- `FluidAudio` foi consultado como `SwiftURL`, embora a fixação seja um repositório Git sob controle de código-fonte; uma resposta vazia não demonstra cobertura.
- `onnxruntime` foi consultado como PyPI, não como artefato C; a própria ficha reconhece a representação indireta.
- `actions/checkout@v4` não fixa uma versão; na reabertura, `v4` resolve para `v4.4.0` (`11d5960…`). O OSV para `4.4.0` também retornou vazio, mas a consulta original não era reproduzível sem essa etapa.

### D8 — A configuração de sandbox dos scripts está dormente

`ENABLE_USER_SCRIPT_SANDBOXING=YES` está presente em Debug/Release, porém o `.pbxproj` não contém `PBXShellScriptBuildPhase`. A afirmação “configurado” é verdadeira; hoje, porém, o controle de segurança efetivo para o app é mínimo.

### D9 — As “3 correções de segurança” do whisper

As três correções de segurança de memória e sua ausência em `v1.9.1` foram confirmadas no código-fonte. Porém, o whisper não publica advisories/GHSAs; elas devem ser chamadas **correções de segurança de memória/endurecimento**, não “correções de segurança” no sentido de advisories publicados.

### D10 — Deriva temporal no mesmo dia

Na reabertura, `FluidAudio v0.17.0/v0.17.1` já havia sido publicado e `llama.cpp b11147` substituíra `b11139` como nightly. As afirmações “latest/current” da P4 podem ter sido verdadeiras em sua janela, mas não são estáveis sem data e hora.

### D11 — Escopo literal das contagens

Sem excluir `.claude/worktrees`, há 13 `Package.swift` e 18 `Package.resolved`; na cópia de trabalho principal, há 1 e 3, respectivamente. A P4 deve declarar explicitamente a exclusão de `.claude/worktrees`; “artefatos gerados” pode implicar isso, mas não está escrito.

### D12 — Prioridade de BCI-05

A ausência de assinatura nos componentes extraídos, combinada com uma CI sem assinatura, confirma um **gate ausente**. Isso não demonstra que o app Release falhará, que o arquivo de arquivamento não será assinado nem que a Apple rejeitará a exceção. A ficha majoritariamente admite isso; a prioridade P1 continua sendo uma opinião.

## 5. Matriz completa de achados BCI

| Achado | Veredito | Base independente | Correção mínima |
|---|---|---|---|
| BCI-01 | CONFIRMADO | metadados de dois commits confirmam a adição e a remoção de uma atribuição não vazia `GOOGLE_CLIENT_SECRET`; o arquivo local ignorado nunca foi versionado | manter a rotação como P0 condicional; não afirmar revogação |
| BCI-02 | CONFIRMADO COM AJUSTE | tag móvel, 2 usos, 0 `permissions`; OSV exato de `4.4.0` vazio | usar uma referência exata no OSV; a prioridade é opinião |
| BCI-03 | CONFIRMADO COM AJUSTE | Xcode local 27.0 beta vs. imagem com Xcode 26.6; o rótulo da imagem é móvel | não afirmar a série/patch do Swift do runner sem log |
| BCI-04 | CONFIRMADO | gate baseado em `Info.plist`, `cp -R` e ausência de hash final/renomeação | separar “bytes arbitrados” de “cadeia de suprimentos externa” |
| BCI-05 | CONFIRMADO COM AJUSTE | bundles sem assinatura completa; Mach-O de llama/whisper com assinatura ad hoc do linker; CI sem assinatura; WIP local ≠ HEAD | qualificar as camadas de assinatura e identificar a evidência do WIP |
| BCI-06 | CONFIRMADO COM AJUSTE | três correções de segurança de memória ausentes em v1.9.1; zero advisories | trocar “3 security fixes” por “memory-safety fixes” |
| BCI-07 | CONFIRMADO COM AJUSTE | flags ausentes; Apple recomenda | `exact: 0.15.5` limita a versão; a janela de fixação é um endurecimento condicional |
| BCI-08 | CONFIRMADO COM AJUSTE | URLs `main`, hashes locais e proveniência parcial confirmados | corrigir a fonte `v0.16.0` 404 para a release `v0.15.8` |
| BCI-09 | CONFIRMADO COM AJUSTE | ausências de cache, timeout, artifact e retry confirmadas | refutar 1,2 GB compactado; usar 306.113.690 bytes |
| BCI-10 | CONFIRMADO | 8 testes Python, sem chamada na CI; sem gate de avisos | os resultados são uma baseline/WIP, não uma reexecução V-P4 |
| BCI-11 | CONFIRMADO | flag 2x, grafo exato sem plugin | a prioridade de remoção é um endurecimento futuro |

## 6. Matriz de alegações

### 6.1 Identidade, estado e toolchain

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C001 | Projeto Ōmu/Papagaio, aplicativo macOS | Fato | `README.md:61-70`; `Loro.xcodeproj/project.pbxproj:419-520` | CONFIRMADO | — |
| C002 | Data da pesquisa: 23/09/2026 | Autodeclaração | data do sistema/revisão | CONFIRMADO | — |
| C003 | HEAD `6138e1d…` | Fato | `git rev-parse HEAD` | CONFIRMADO | — |
| C004 | Somente a ficha P4 foi criada | Autodeclaração | `git status --short` mostra vários arquivos não rastreados e WIP; autoria/tempo não são recuperáveis | INCONCLUSIVO | não apresentar como fato verificável |
| C005 | Nenhum segredo/prefixo foi reproduzido | Fato | varredura redigida: 0 ocorrências da atribuição/prefixo do client secret e dos padrões de tokens private/cloud/GitHub | CONFIRMADO | — |
| C006 | Relatório é somente leitura | Autodeclaração | o estado final mostra apenas V-P4 escrito por esta revisão; a execução do autor não é auditável | INCONCLUSIVO | — |
| C007 | Xcode local 27.0 `27A5194q`, em caminho beta | Fato | `xcodebuild -version`; `xcode-select -p` | CONFIRMADO | — |
| C008 | `27A5194q` é “beta 1” | Inferência | o app está em `Xcode-beta.app`; a release oficial reaberta só prova a GA `27A266a`; o `Info.plist` ainda diz `DTXcodeBuild=27A5194o` | CONFIRMADO COM AJUSTE | dizer “build beta local diferente da GA”, sem ordinal se não houver fonte |
| C009 | GA do Xcode 27.0: `27A266a`, em 14/09 | Fato | Apple Releases/feed | CONFIRMADO | — |
| C010 | Xcode 27.1/27.2 eram beta | Fato | Apple Releases: 27.1 `27A9269`, 27.2 `27B5019j` | CONFIRMADO | — |
| C011 | Swift local 6.4, SwiftPM `6.4.0-dev` | Fato | `swift --version`; `swift package --version` | CONFIRMADO | — |
| C012 | Swift 6.4 lançado em 15/09 | Fato | blog de lançamento no swift.org | CONFIRMADO | — |
| C013 | SwiftPM 6.4 usa Swift Build como padrão | Fato | blog oficial + `swift package --help` | CONFIRMADO | — |
| C014 | SBOM SPDX/CycloneDX suportado | Fato | blog + `swift package generate-sbom --help` | CONFIRMADO | o suporte não prova que um SBOM foi gerado ou está completo |
| C015 | `swift-tools-version: 6.0` continua válido no Swift 6.4 | Fato | `PapagaioCore/Package.swift:1`; analisador/help local | CONFIRMADO | — |
| C016 | Projeto criado/atualizado pela última vez para 27.0 | Fato | `project.pbxproj:249-253`; scheme `:2-4` | CONFIRMADO | — |
| C017 | A CI usa `macos-26` sem seleção de Xcode | Fato | `ci.yml:12,24`; buscas por `xcode-select/get-xcode` = 0 | CONFIRMADO | — |
| C018 | Imagem `20260824.0517.1`: Xcode 26.6 como padrão, `17F113` | Fato | README de runner-images macOS-26 reaberto | CONFIRMADO | — |
| C019 | Ambiente local e CI divergem e não têm toolchain reproduzível | Fato | versões locais + `macos-26` móvel | CONFIRMADO | divergência atual confirmada; a reprodutibilidade futura é demonstrável pelo rótulo |
| C020 | Swift 6.3 no runner | Inferência | a fonte oficial consultada não expõe o patch; não há log do runner | INCONCLUSIVO | manter como provável, não como fato |
| C021 | Build Debug local em 48,34 s | Baseline secundária | log existente: `BUILD SUCCEEDED` e `real 48.34`; V-P4 não reexecutou | CONFIRMADO COM AJUSTE | a evidência vem de outro agente/árvore WIP, não da CI |
| C022 | A CI pode mudar quando a imagem ou o Xcode padrão mudam | Fato | `runs-on: macos-26` + versão da imagem/tabela de padrão no README | CONFIRMADO | — |

### 6.2 Manifests, lockfiles e dependências

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C023 | FluidAudio com `exact: 0.15.5` | Fato | `Package.swift:11-16` | CONFIRMADO | — |
| C024 | Três lockfiles fixam o FluidAudio na mesma revisão | Fato | três `Package.resolved:5-10`; checkout HEAD/tag `19600a…` | CONFIRMADO | — |
| C025 | `originHash` distintos = grafos resolvidos distintos | Inferência | cada lockfile contém exatamente uma fixação idêntica | REFUTADO | os hashes refletem o contexto/origem e não demonstram um grafo de pins diferente |
| C026 | Os três XCFs são alvos locais `binaryTarget(path:)` | Fato | `Package.swift:18-27`; imports nos wrappers | CONFIRMADO | — |
| C027 | Todos os targets Swift usam o modo de linguagem v6 | Fato | 7 ocorrências em `Package.swift` | CONFIRMADO | — |
| C028 | Existem três `Package.resolved` primários | Fato | contagem primária = 3; rastreados = 3 | CONFIRMADO | excluir `.claude/worktrees` |
| C029 | FluidAudio 0.16.1 era o `latest` e estava quatro releases atrás | Fato temporal | API no instante da P4: `.15.6`, `.15.7`, `.15.8`, `.16.1`; depois surgiram `.17.0/.17.1` | CONFIRMADO COM AJUSTE | agora são seis releases até `.17.1`; registrar o horário |
| C030 | Release/tag `v0.16.0` adicionou uma fixação imutável | Fato | URL `v0.16.0` = 404; release `v0.15.8` com título `v0.16.0` e commit da fixação `a6f1ca8…` | CONFIRMADO COM AJUSTE | corrigir URL/tag |
| C031 | FluidAudio não publica advisories | Fato | página security/advisories: `none` | CONFIRMADO | — |
| C032 | OSV para FluidAudio `0.15.5` vazio | Fato | POST querybatch 200, `{}` | CONFIRMADO COM AJUSTE | SwiftURL não necessariamente cobre o controle de código-fonte |
| C033 | whisper `v1.9.1`; `latest` `v1.9.4`; três releases atrás | Fato | GitHub releases/API | CONFIRMADO | — |
| C034 | v1.9.1 não contém clamp curto, verificação de `n_dims` nem inicialização de mel | Fato | o código-fonte bruto de v1.9.1 contém padrões antigos e não contém as correções; commits `8631825`, `df1547b`, `eacbd82` | CONFIRMADO | — |
| C035 | São “3 correções de segurança” do whisper | Classificação | release notes + código bruto; zero GHSA/CVE publicado | CONFIRMADO COM AJUSTE | chamar de memory-safety fixes/hardening |
| C036 | llama fixado em `b9222`, nightly de 19/05 | Fato | `bootstrap:49-50`; GitHub release `b9222`, commit `9a532ae…` | CONFIRMADO | — |
| C037 | llama estável `v0.4.1`; `b11139` era o nightly observado | Fato temporal | release `v0.4.1` mais recente; API: `b11139` às 16:11Z e depois `b11147` às 19:03Z | CONFIRMADO COM AJUSTE | “latest” exige atualização imediata; na reabertura, era `b11147` |
| C038 | O SHA do llama no script coincide com o asset oficial | Fato | API do asset `b9222`: digest = pin; HEAD 200, 203.536.578 bytes | CONFIRMADO | hash não é prova de proveniência nem assinatura |
| C039 | O SHA do whisper no script coincide com o asset oficial | Fato | API do asset v1.9.1: digest = pin; HEAD 200, 50.438.515 bytes | CONFIRMADO | — |
| C040 | ONNX fixado em `1.24.2`; `latest` `1.30.0` | Fato | script `:56-57`; release 1.30.0 em 10/09 | CONFIRMADO | o hash upstream continua sem confronto independente |
| C041 | 1.29/1.30 têm endurecimento de path/input/model/CPU | Fato | release notes 1.29 e 1.30 | CONFIRMADO | endurecimento não equivale a advisory |
| C042 | Parte das correções do ONNX é exclusivo de CUDA | Fato | o path traversal da 1.29 é do TensorRT/NvTensorRTRTX; a release lista itens de CPU separadamente | CONFIRMADO | não chamar todo item de irrelevante |
| C043 | Silero está fixado no commit `76e3dc…` de 16/07 | Fato | script `:58,295-297`; API de commits do GitHub; HEAD do blob 200 | CONFIRMADO | — |
| C044 | O SHA local do Silero coincide com o do script | Fato | `shasum -a 256` local = pin | CONFIRMADO | — |
| C045 | 21 arquivos de diarização têm SHA individual | Fato | 21 entradas em `bootstrap:243-263`; 21/21 hashes locais | CONFIRMADO | — |
| C046 | Repositório HF atual `df2625…`; instantâneo dos artefatos `1ed7a662…` | Fato | API do modelo HF + provenance.json | CONFIRMADO | — |
| C047 | Os 21 hashes locais coincidem com a proveniência HF | Fato | comparação local por `shasum` com 21 entradas selecionadas | CONFIRMADO | — |
| C048 | A proveniência é uma reconstrução histórica, sem revisão histórica exata | Fato | `status`, flags `false`, limitations | CONFIRMADO | — |
| C049 | Pesos GGUF usam URL `main`, tamanho e SHA | Fato | `Preflight:22-33`; HEAD das URLs 200 | CONFIRMADO | URL mutável; o hash preserva os bytes |
| C050 | O download existente revalida tamanho e SHA | Fato | `DownloadDeModelos:82-87,168-194` | CONFIRMADO | `Preflight.avaliar` só usa o SHA quando `verificarChecksum=true` |
| C051 | Não há banco de advisories aplicável a blobs Silero/ONNX/CoreML | Limitação | advisories, mantenedores e OSV não cobrem blobs | CONFIRMADO | — |

### 6.3 GitHub Actions, permissões, cache e CI

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C052 | Workflow tem `pull_request` e `push` para main; não `pull_request_target` | Fato | `ci.yml:3-7`; busca = 0 target/workflow_run | CONFIRMADO | — |
| C053 | Dois `actions/checkout@v4` | Fato | `ci.yml:14,26` | CONFIRMADO | — |
| C054 | `v4` resolve atualmente para `v4.4.0`/`11d5960…` | Fato temporal | API de tag/release v4.4.0 | CONFIRMADO COM AJUSTE | em um run futuro pode mudar; workflow não registra commit |
| C055 | `v4` é major tag mutável | Fato | GitHub secure-use; API ref | CONFIRMADO | — |
| C056 | checkout publica zero advisory | Fato | página de advisories do mantenedor | CONFIRMADO | zero advisory não prova ausência de bug |
| C057 | OSV `checkout v4` vazio | Fato | POST original vazio; consulta extra `4.4.0` vazia | CONFIRMADO COM AJUSTE | consulta original não pinava commit |
| C058 | Workflow não declara `permissions:` | Fato | busca = 0 | CONFIRMADO | — |
| C059 | Default do token depende do repo/org | Fato | secure-use documenta mínimo por default, não o estado deste repo | CONFIRMADO | — |
| C060 | `pull_request` é trigger seguro relativo a `pull_request_target` | Recomendação | GitHub secure-use; workflow não usa secrets | CONFIRMADO COM AJUSTE | não chamar “seguro” de forma absoluta; token e caches importam |
| C061 | checkout v5 usa Node 24 | Fato | release v5.0.0 | CONFIRMADO | — |
| C062 | checkout v6 persiste credenciais em `$RUNNER_TEMP` | Fato | release v6 + source `git-auth-helper.ts` | CONFIRMADO | — |
| C063 | v7 endurece default de `pull_request_target`; v4.4 recebeu backport | Fato | releases v7.0.0 e v4.4.0 | CONFIRMADO COM AJUSTE | não vender hardening da v7 como ausente em toda v4 |
| C064 | checkout latest `v7.0.1` em 20/07 | Fato | página/API do release | CONFIRMADO | — |
| C065 | CI não seleciona Xcode | Fato | workflow search = 0 | CONFIRMADO | — |
| C066 | CI não declara cache | Fato | search = 0 | CONFIRMADO | — |
| C067 | CI não declara timeout | Fato | search = 0 | CONFIRMADO | — |
| C068 | CI não faz upload de artifact/xcresult | Fato | busca = 0 | CONFIRMADO | — |
| C069 | CI não declara strategy/concurrency | Fato | busca = 0 | CONFIRMADO | otimização, não requisito |
| C070 | Não há configuração do Dependabot | Fato | tracked/primary find = 0 | CONFIRMADO | — |
| C071 | Dois jobs repetem bootstrap | Fato | `ci.yml:16-17,28-29` | CONFIRMADO | — |
| C072 | Bootstrap não tem retry no curl | Fato | `curl` sem `--retry` | CONFIRMADO | — |
| C073 | Workflow não bloqueia resolução automática | Fato | flags ausentes; documentação Apple recomenda | CONFIRMADO | — |
| C074 | Workflow não contém archive/sign verify/spctl/notarytool | Fato | busca = 0 | CONFIRMADO | — |
| C075 | Workflow não chama testes Python | Fato | busca = 0; 8 testes existem | CONFIRMADO | — |
| C076 | `permissions: contents: read` é hardening oficial | Recomendação oficial | GitHub secure-use | CONFIRMADO | — |
| C077 | Cache unsigned, PR pode ler base, escrita low-trust é read-only | Fato normativo | GitHub dependency caching | CONFIRMADO | — |
| C078 | Cache dos XCFs deve esperar hash final | Recomendação | segue BCI-04 | CONFIRMADO COM AJUSTE | opinião de sequência, não regra upstream |

### 6.4 Bootstrap, XCFrameworks, assinatura, sandbox e Xcode Cloud

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C079 | Quatro downloads base têm SHA-256 | Fato | 3 ZIPs + Silero | CONFIRMADO | “downloads base” não é o mesmo que 21 subdividers |
| C080 | Hash é conferido antes de unzip | Fato | `bootstrap:122-137` | CONFIRMADO | — |
| C081 | ONNX upstream pin não foi conferido independentemente | Limitação | HEAD 200, sem digest oficial; hash local não foi baixado | INCONCLUSIVO | script pin existe, autenticidade upstream não medida |
| C082 | Arquivos simples são promovidos com arquivo temporário + `mv` | Fato | `bootstrap:173-181` | CONFIRMADO | — |
| C083 | XCF existente é aceito por `Info.plist` não-LFS | Fato | `bootstrap:107-116` | CONFIRMADO | — |
| C084 | Cópia de XCF é direta e não atômica | Fato | `bootstrap:135-149` | CONFIRMADO | — |
| C085 | Próxima execução não revalida XCF final | Fato | ramo de skip não chama shasum | CONFIRMADO | — |
| C086 | Diretório parcial/alterado pode ser aceito | Inferência | control-flow + `cp -R` | CONFIRMADO COM AJUSTE | não demonstra comprometimento remoto |
| C087 | ~1,2 GB compactados antes do prune | Fato | HEAD/metadata: 306.113.690 bytes | REFUTADO | 1,2 GB pode ser extraído, não download |
| C088 | Árvore local após prune = 125,0 MiB | Fato | `du -sk`: 9.624+5.592+89.380+2.276+21.136 = 128.008 KiB | CONFIRMADO | — |
| C089 | Bootstrap não tem timeout de rede | Fato | curl sem `--max-time`/opções | CONFIRMADO | — |
| C090 | `codesign` top-level dos 3 XCFs retorna unsigned | Fato | comando reproduzido | CONFIRMADO | comando não se aplica ao código aninhado |
| C091 | llama/whisper Mach-O são ad hoc linker-signed | Fato | `codesign -dvvv`: `Signature=adhoc`, flags | CONFIRMADO | relatório deve qualificar BCI-05 |
| C092 | ONNX nested artifact é static archive sem code signature observável | Fato | `file`: universal ar archive; bundle sem assinatura | CONFIRMADO | assinatura final do app desconhecida |
| C093 | Os três runtimes são realmente importados | Fato | `WhisperRuntime.swift:5`, `LlamaRuntime.swift:5`, `SessaoOnnx.swift:5` | CONFIRMADO | wrapper modules isolam, mas confirmam o import |
| C094 | App declara Hardened Runtime Debug/Release | Fato | `pbxproj:447-452,487-492` | CONFIRMADO | — |
| C095 | App Sandbox e disable-library-validation estão no entitlements | Fato | `Papagaio.entitlements:19-22` | CONFIRMADO | — |
| C096 | Library validation requer Apple/mesmo Team ID; exceção reduz barreira | Fato normativo | artigo de entitlement Apple DocC JSON | CONFIRMADO | — |
| C097 | CI desabilita signing nos dois xcodebuild | Fato | `ci.yml:39-42,50-51` | CONFIRMADO | — |
| C098 | `codesign --sign -` recovery está no script HEAD | Fato | `git diff` mostra apenas WIP; `git show HEAD` não contém | REFUTADO | vale para working tree, não HEAD/CI |
| C099 | Não há archive Release/gate final | Fato | workflow search = 0 | CONFIRMADO | estado do app final desconhecido |
| C100 | User Script Sandboxing está habilitado | Fato | `pbxproj:400,430` | CONFIRMADO | — |
| C101 | Setting tem valor de controle hoje | Inferência | nenhum `PBXShellScriptBuildPhase` no projeto | CONFIRMADO COM AJUSTE | hoje é dormente para o build do app |
| C102 | Xcode Cloud executa bootstrap pós-clone | Fato | `ci_scripts/ci_post_clone.sh:20-22`; modo executable | CONFIRMADO | execução real no serviço não verificada |
| C103 | Xcode Cloud manifest tem IDs target duplicados | Fato | `manifest.json:5,9` | CONFIRMADO | — |
| C104 | Duplicidade é schema-valid/drift de serviço | Limite | não consultou console/schema | INCONCLUSIVO | validar antes de editar |
| C105 | Manifest final deve incluir prune + module map | Fato/recomendação | `bootstrap:65-102,193-223,282-299` | CONFIRMADO | hash após todas transformações |
| C106 | Gate release deve archive/verify/inspect/notarize | Recomendação | Apple TN2339 + signing article | CONFIRMADO | prioridade é opinião |
| C107 | Library-validation exception deve ser removível se archive assinar tudo | Recomendação condicional | Apple guidance | CONFIRMADO | não afirmar que é removível sem archive test |

### 6.5 Modelos, proveniência e disponibilidade

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C108 | URLs de pesos retornam 200 e headers de tamanho batem constantes | Fato | HEAD sem body | CONFIRMADO | `main` pode mudar; HEAD não fixa pin |
| C109 | Hashes de pesos protegem integridade, não provenance | Fato | `Preflight:22-33`; `Download:184-194` | CONFIRMADO | — |
| C110 | Pin mutable do diarization HF pode degradar disponibilidade | Inferência | base `resolve/main`; commit HF de 40 caracteres acessível | CONFIRMADO | hash faz fail closed, não availability |
| C111 | Provenance HF é atestado rebuild reproduzível | Fato | flags/limitation dizem false | REFUTADO | deve dizer que não é |
| C112 | Não há SLSA/attestation validado no repo | Limite | relatório afirma; V-P4 não baixou/verificou | CONFIRMADO | disponibilidade de attestation específica não inventada |
| C113 | Não foi executado bootstrap/download | Autodeclaração | V-P4 também não executou; author execution não auditável | INCONCLUSIVO | limitação é plausível, não prova do autor |
| C114 | URLs mutable reduzem determinismo, hash mantém byte integrity | Recomendação | GitHub/HF URL + validação local | CONFIRMADO | — |
| C115 | Provenance commit `df2625…` é posterior aos artefatos | Fato | HF commits: artifacts `1ed7…` em 14/03; docs `df2625…` em 19/09 | CONFIRMADO | — |
| C116 | Snapshot `1ed7…` pin-up é provenance do build | Inferência | `artifact_snapshot` no JSON | CONFIRMADO COM AJUSTE | identifica artifact tree, não source build exato |
| C117 | ONNX 1.30 CPU index hardening é irrelevante ao app | Inferência | item do release é CPU; app usa CPU EP | REFUTADO | sem reachability; não pode descartar |
| C118 | TensorRT path traversal aplica ao pod macOS CPU | Inferência | item é TensorRT/NvTensorRTRTX | CONFIRMADO | item isolado não é caminho CPU |
| C119 | Modelos de usuário podem ser maliciosos | Hipótese | URLs e paths permitem selectable model; nenhum PoC | INCONCLUSIVO | não medir como bug sem boundary |
| C120 | `DownloadDeModelos` faz resume seguro | Fato | status 200/206 + Content-Range + length/hash | CONFIRMADO | auditoria runtime fora do escopo |

### 6.6 OSV, advisories e reachability

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C121 | OSV FluidAudio 0.15.5 = vazio | Fato | POST 200 `{}` | CONFIRMADO COM AJUSTE | proxy/source-control limitation |
| C122 | OSV checkout v4 = vazio | Fato | POST 200 `{}` | CONFIRMADO COM AJUSTE | query exata pinada extra também vazia |
| C123 | OSV onnxruntime PyPI 1.24.2 = vazio | Fato | POST 200 `{}` | CONFIRMADO COM AJUSTE | não é C archive query |
| C124 | OSV lodash 4.17.11 = 7 GHSAs | Fato | POST retornou 7 IDs | CONFIRMADO | sanity da API |
| C125 | OSV não é cobertura confiável de C/C++/blobs | Limitação | ecosystems usados são proxies | CONFIRMADO | — |
| C126 | GitHub REST atingiu rate limit durante P4 | Autodeclaração histórica | API da revisão respondeu; não há log do autor | INCONCLUSIVO | não generalizar para hoje |
| C127 | GHSA-3p4r: affected <=b8145, patched >=b8146; b9222 posterior | Fato | advisory oficial; b9222 19/05 | CONFIRMADO | — |
| C128 | GHSA-j8rj: affected <=b7991; patched none; b9222 posterior | Fato | advisory oficial | CONFIRMADO | RPC path |
| C129 | GHSA-96jg: affected <b7437, patched b7824; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C130 | GHSA-8947: affected <=55d4206c8, patched >=c78fb90; b9222 posterior | Fato | advisory oficial + chronology | CONFIRMADO | commit-range, not semver |
| C131 | GHSA-vgg9: affected <26a48ad, patched 26a48ad; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C132 | GHSA-7rxv: affected <b5721, patched b5721; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C133 | GHSA-g4cc: affected/fixed c33fe8b8; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C134 | GHSA-8wwf: fixed >=b5662; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C135 | GHSA-wcr5: affected <b3561, fixed >=b3561; b9222 posterior | Fato | advisory oficial | CONFIRMADO | RPC path |
| C136 | GHSA-5vm9: affected <b3561, fixed >=b3561; b9222 posterior | Fato | advisory oficial | CONFIRMADO | RPC path |
| C137 | GHSA-mqp6: affected <b3561, fixed >=b3561; b9222 posterior | Fato | advisory oficial | CONFIRMADO | RPC path |
| C138 | GHSA-49q7: affected <=b3426, fixed b3427; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C139 | GHSA-p5mv: affected b2715, fixed b2740; b9222 posterior | Fato | advisory oficial | CONFIRMADO | — |
| C140 | 0/13 advisories alcançam b9222 | Fato | 13/13 ranges + b9222 date | CONFIRMADO | não prova ausência de bug |
| C141 | Main loader usa `no_alloc=true` e escapa GHSA-3p4r path | Fato | descrição oficial GHSA-3p4r | CONFIRMADO | não é exploit test |
| C142 | App source não usa RPC backend | Fato | search source: sem llama RPC/server; usa model load local | CONFIRMADO | binary may contain code; reachability absent |
| C143 | Zero advisory significa runtime sem vulnerabilidade | Inferência | contradito pelo próprio texto da ficha | REFUTADO | P4 não afirma isso; limiter deve permanecer explícito |
| C144 | whisper publica zero advisory | Fato | maintainer page | CONFIRMADO | memory fixes não viram CVE |
| C145 | ONNX maintainer publica zero advisory | Fato | maintainer page | CONFIRMADO | release hardening still relevant |
| C146 | Tag mobile de Fluid/XCF é comprometimento | Inferência | tag mutability não prova bytes/assinatura | REFUTADO | supply-chain risk != incident |
| C147 | Ausência de `permissions` prova token write | Inferência | default setting unknown | REFUTADO | P4 correctly caveats |
| C148 | Reachability de advisories não foi reproduzido | Limitação | nenhum PoC/fuzzing/archivo release | CONFIRMADO | — |

### 6.7 Testes, qualidade, plugins e deprecações

| ID | Alegação P4 | Tipo | Evidência própria | Veredito | Ajuste/limite |
|---|---|---|---|---|---|
| C149 | `test_scripts.py` tem 8 testes offline | Fato | `test_scripts.py:14-111` | CONFIRMADO | 1 depende da gem |
| C150 | Workflow não chama Python/unittest/pytest | Fato | search = 0 | CONFIRMADO | — |
| C151 | `adiciona-target-de-testes.rb` requer gem xcodeproj sem lock | Fato | `rb:1-4`; no Gemfile/lock | CONFIRMADO | build tool version não reproduzível |
| C152 | Test target sync skip quando gem falta | Fato | `test_scripts.py:89-92` | CONFIRMADO | somente este test |
| C153 | Não há requirements/pyproject/package.json tracked | Fato | `git ls-files` counts = 0/0/0 | CONFIRMADO | — |
| C154 | Não há Gemfile/lock, Podfile, Cartfile | Fato | tracked counts = 0 | CONFIRMADO | — |
| C155 | Não há xctestplan | Fato | primary find = 0 | CONFIRMADO | — |
| C156 | Scheme inclui somente PapagaioTests | Fato | scheme `:37-48` | CONFIRMADO | — |
| C157 | Não há warning-as-errors no pbxproj | Fato | search = 0 | CONFIRMADO | — |
| C158 | Baseline contém 120 umbrella + 1 AppIntents + 7 outras = 128 warning lines | Fato secundário | preexisting log count 128, umbrella 120, AppIntents 1 | CONFIRMADO COM AJUSTE | V-P4 não reproduziu build |
| C159 | App test foi interrompido após 300s | Fato secundário | preexisting `app-test.log` termina `BUILD INTERRUPTED` | CONFIRMADO COM AJUSTE | não é resultado final da CI |
| C160 | Baseline local é fonte secundária, não execução P4 | Limitação | `audit/00-mapa.md:307-446` | CONFIRMADO | — |
| C161 | Dois commits移除/introduzem secret histórico | Fato redigido | commit metadata + redacted blob diff | CONFIRMADO | — |
| C162 | Remote/service rotation não foi verificada | Limite | nenhum serviço real | CONFIRMADO | — |
| C163 | Graph exato tem 0 targets plugin | Fato | root manifest + FluidAudio checkout exact: dependencies=[]; search 0 | CONFIRMADO | `.build` generated, mas HEAD/tag conferido |
| C164 | `-skipPackagePluginValidation` aparece 2x | Fato | `ci.yml:39,50` | CONFIRMADO | — |
| C165 | Help Xcode chama flag de risco | Fato | `xcodebuild -help` local | CONFIRMADO | versão Xcode 27 |
| C166 | Flag cria risco executável no graph atual | Inferência | nenhum plugin | REFUTADO | risco futuro de manutenção, não vetor atual |
| C167 | Remover flag é recomendação válida | Recomendação | reduz bypass futuro | CONFIRMADO | opinião de hardening |
| C168 | `swift-tools-version:6.0` não está deprecated no toolchain atual | Fato | SwiftPM local aceita | CONFIRMADO | — |
| C169 | `native` é deprecated no help local | Fato | `swift package --help` | CONFIRMADO | — |
| C170 | `-undefined dynamic_lookup` deprecation latente | Inferência | P4 não cita source oficial; build não medido | INCONCLUSIVO | não afirmar |
| C171 | `COMBINE_HIDPI_IMAGES` deprecation não confirmado | Limitação | P4 não fez claim positive | CONFIRMADO | — |
| C172 | `ALWAYS_SEARCH_USER_PATHS=NO` é setting legado apropriado | Opinião | pbxproj setting; sem source oficial usada | CONFIRMADO COM AJUSTE | não fazer claim normative sem fonte |
| C173 | `disable-library-validation` não está deprecated | Fato | Apple DocC metadata `deprecated:false` | CONFIRMADO | — |
| C174 | Sem warning-as-errors é quality gate absent, não CVE | Classificação | busca = 0 | CONFIRMADO | — |
| C175 | Build baseline Debug foi bem-sucedido | Fato secundário | log `BUILD SUCCEEDED` | CONFIRMADO COM AJUSTE | não Release/Archive |
| C176 | Testes Python atuais têm 3 falhas | Fato secundário | `script-tests.log`: 8 run, 3 fail | CONFIRMADO COM AJUSTE | teste em WIP, não executado V-P4 |
| C177 | Workflow não produz Release `xcresult` | Fato | sem result/upload archive | CONFIRMADO | — |
| C178 | Ausência de archive não prova distribuição quebrada | Inferência | estado final desconhecido | CONFIRMADO | — |

### 6.8 Recomendações

| ID | Recomendação P4 | Tipo | Veredito | Nota |
|---|---|---|---|---|
| C179 | Verificar rotação/revogação antes de purge de histórico | Recomendação oficial + prioridade | CONFIRMADO |官方 secure-use para rotação; ordem é prudência |
| C180 | `permissions: contents: read` | Recomendação oficial | CONFIRMADO | — |
| C181 | Pin de checkout por SHA + Dependabot | Recomendação oficial | CONFIRMADO | — |
| C182 | Manter `pull_request` | Recomendação oficial condicional | CONFIRMADO | — |
| C183 | `-disableAutomaticPackageResolution` / resolved-only | Recomendação oficial | CONFIRMADO COM AJUSTE | não tratar como CVE; exact pin limita versão |
| C184 | Manifest determinístico + staging + rename de XCF final | Recomendação autora | CONFIRMADO | opinion defensável |
| C185 | Gate separado de archive/export/sign/entitlements/notary | Recomendação autora alinhada Apple | CONFIRMADO | opinion/prioridade |
| C186 | Alinhar Xcode 27 quando runner suportar | Recomendação autora | CONFIRMADO COM AJUSTE | image atual não tem GA 27; “quando suportar” crucial |
| C187 | Avaliar whisper >=1.9.4 | Recomendação autora | CONFIRMADO COM AJUSTE | memory fix real, sem advisory/reachability |
| C188 | Avaliar ONNX >=1.30 | Recomendação autora | CONFIRMADO COM AJUSTE | parte CPU pode ser relevante; testar ABI |
| C189 | Manter llama b9222 sob 版本/advisory review | Recomendação autora | CONFIRMADO COM AJUSTE | 0/13 advisories não é garantia |
| C190 | Remover skip plugin validation | Recomendação autora | CONFIRMADO | — |
| C191 | Cache SPM/DerivedData após BCI-04 | Recomendação autora | CONFIRMADO COM AJUSTE | não cachear XCF final antes de hash |
| C192 | SBOM SwiftPM + manifest XCF/model transformations | Recomendação oficial + extensão | CONFIRMADO COM AJUSTE | SBOM local não é inventário de bytes/provenance |
| C193 | Python tests, timeout, xcresult/log, warnings policy | Recomendação autora | CONFIRMADO | quality, não CVE |
| C194 | Remover disable-library-validation se archive assinar tudo | Recomendação condicional | CONFIRMADO | archive real required |

## 7. “Onde procurar” — contagens reproduzidas

Escopo primário: checkout principal, excluindo `.git`, `.build`, `.claude/worktrees`, `audit/` e artefatos ignorados.

| Padrão/comando | Resultado P4 | Resultado V-P4 | Veredito |
|---|---:|---:|---|
| `rg -n 'uses:' .github/workflows` | 2 | 2 | CONFIRMADO |
| `rg -n 'permissions:' .github/workflows` | 0 | 0 | CONFIRMADO |
| `rg -n 'xcode-select|setup-xcode|maxim-locator|get-xcode' .github/workflows` | 0 | 0 | CONFIRMADO |
| `rg -n 'actions/cache|cache:' .github/workflows` | 0 | 0 | CONFIRMADO |
| `rg -n 'timeout-minutes' .github/workflows` | 0 | 0 | CONFIRMADO |
| `rg -n 'upload-artifact' .github/workflows` | 0 | 0 | CONFIRMADO |
| `find ... dependabot.yml/yaml` | 0 | 0 | CONFIRMADO |
| `rg -n 'skipPackagePluginValidation' .github/workflows` | 2 | 2 | CONFIRMADO |
| `rg -n 'plugin:|\.plugin\(' PapagaioCore/Package.swift` | 0 | 0 | CONFIRMADO |
| mesmo padrão no checkout FluidAudio pinado | 0 | 0 | CONFIRMADO |
| `rg -n 'unsafeFlags' PapagaioCore/Package.swift` | 1 | 1 | CONFIRMADO |
| `rg -n 'CODE_SIGNING_ALLOWED|CODE_SIGNING_REQUIRED' .github/workflows` | 3 | 3 | CONFIRMADO |
| `rg -n 'disable-library-validation' Config` | 1 | 1 | CONFIRMADO |
| `rg -n 'GCC_TREAT_WARNINGS_AS_ERRORS|SWIFT_TREAT_WARNINGS_AS_ERRORS' Loro.xcodeproj` | 0 | 0 | CONFIRMADO |
| `find ... -name '*.xctestplan'` | 0 | 0 | CONFIRMADO |
| `rg -n 'python|unittest|pytest' .github/workflows/ci.yml` | 0 | 0 | CONFIRMADO |
| busca por `curl ... \| (sh\|bash)` | 0 | 0 | CONFIRMADO |
| `rg -n 'sudo' Scripts ci_scripts` | 0 | 0 | CONFIRMADO |
| `find ... -name provenance.json` | 0 local | 0 primário | CONFIRMADO |
| `git ls-files '*.xcframework'` | 0 | 0 | CONFIRMADO |
| `git ls-files '*Package.resolved'` | 3 | 3 | CONFIRMADO |
| `git ls-files '*Package.swift'` | 1 | 1 | CONFIRMADO |
| `find . -name Package.swift` sem exclusões de worktrees | não declarado | 13 | CONFIRMADO COM AJUSTE | scope P4 precisa explicitar worktrees |
| `find . -name Package.resolved` sem exclusões de worktrees | não declarado | 18 | CONFIRMADO COM AJUSTE | scope P4 precisa explicitar worktrees |

## 8. Omissões e limitações adicionais

| ID | Omissão/recomenda-se registrar | Veredito | Observação |
|---|---|---|---|
| O001 | Digest oficial dos assets llama/whisper foi_available e confere | CONFIRMADO | P4 não aproveitou; distinction hash/provenance continua |
| O002 | ONNX archive não tem digest oficial consultado | INCONCLUSIVO | HEAD 200 não autentica bytes |
| O003 | XCF final local não tem manifest; `.DS_Store` presente em `Frameworks/` e `llama.xcframework/` | CONFIRMADO | antes de deterministic manifest, normalizar/prunar metadata |
| O004 | Evidence de signing local é WIP, não HEAD | CONFIRMADO | corrigir BCI-05/§4 |
| O005 | `actions/checkout` exact current ref should be `11d5960…` if pin now | CONFIRMADO | depends on review time; use Dependabot |
| O006 | `aps-environment=development` is same entitlement file for Debug/Release | CONFIRMADO | production signing/profile unresolved |
| O007 | `com.apple.developer.icloud-container-environment` is not explicit | CONFIRMADO | automatic signing behavior not tested |
| O008 | No archive means no final entitlements/Team-ID signature inspection | CONFIRMADO | core P4 limitation |
| O009 | No local `.xctestplan`, test plan remains sole scheme list | CONFIRMADO | quality gap |
| O010 | Xcode Cloud manifest validity/service state not checked | INCONCLUSIVO | preserve P4 limitation |
| O011 | No real `swift package generate-sbom` file generated | CONFIRMADO | V-P4 respected no-write constraint |
| O012 | No remote GitHub/Xcode Cloud logs | CONFIRMADO | cannot assert CI green/red or service behavior |
| O013 | No PoC/reachability/runtime fuzzing | CONFIRMADO | no app vulnerability claim from version alone |
| O014 | `macos-26` currently lacks GA Xcode 27; P4 says when supported | CONFIRMADO | do not make runner switch a current requirement |
| O015 | No release/attestation verification of XCF provenance | CONFIRMADO | tag/hash/signature/provenance are separate |
| O016 | 1.2 GB appears in three source comments as well as report | CONFIRMADO | numeric claim needs correction |
| O017 | CI token/repository default permissions remain unknown | CONFIRMADO | absence declaration is confirmed, actual privilege is not |
| O018 | FluidAudio release “v0.16.0” title/tag mismatch | CONFIRMADO | broken cited URL |
| O019 | `originHash` interpretation should cite SwiftPM format | CONFIRMADO | current explanation refuted |
| O020 | Nested `codesign -dvvv` should be part of signing evidence | CONFIRMADO | avoid “unsigned” overclaim |

## 9. Ledger de URLs reabertas

### Fontes Swift/Apple/toolchain

Reabertas: `swift.org/blog/swift-6.4-released/`, docs SwiftPM 6.4, generating SBOM, Apple Releases, Apple Xcode CI, Hardened Runtime, disable-library-validation, TN2339 e runner-images macOS-26 Readme. Resultado: conteúdo oficial coerente; Apple DocC também foi consultado via JSON oficial para extrair os trechos normativos. Nenhuma URL dessa lista falhou.

### Actions

Reabertas: GitHub Secure Use, Dependency Caching, checkout v7.0.1 e checkout advisories. Resultado: 200; secure-use sustenta SHA completo, least privilege, rotação e trigger advice; cache page sustenta “unsigned/not verified” e scope. Releases adicionais v4.4.0/v5.0.0/v6.0.0/v7.0.0 foram reabertas para testar as assertions de version history.

### Dependências/advisories

Reabertas: FluidAudio 0.16.1, FluidAudio security advisories, whisper 1.9.3/1.9.4/advisories, llama 0.4.1/b11139/advisories page 1/2, ONNX 1.29/1.30/advisories, Silero commit API, HF model API/provenance/commits, FluidAudio 0.15.8/commit pin. `FluidAudio v0.16.0` foi a única URL 404. Todos os 13 GHSAs diretos foram reabertos; seus intervalos foram copiados para a matriz acima.

### OSV

`POST https://api.osv.dev/v1/querybatch` retornou 200 para as quatro queries P4 e para as queries adicionais `actions/checkout 4.4.0`/`7.0.1`. A ausência de resposta em proxies não foi elevada a cobertura de C/C++/source-control.

### URLs dos arquivos locais

HEAD 200 para: GitHub FluidAudio, llama b9222 XCF, whisper v1.9.1 XCF, ONNX 1.24.2 pod, Silero raw, uma amostra do path HF diarization e os dois pesos GGUF. O content-length dos três archives foi usado sem baixar corpo.

## 10. Conclusão

A ficha P4 pode ser mantida como base, mas deve ser revisada nos pontos D1–D12 antes de ser tratada como evidação de P0/P1. A maior correção é de ** provenance e evidência**: separar HEAD de WIP, hash de assinatura, assinatura de provenance, e release/tag de URL. As хорошо-definidas claims de SwiftPM, advisories, Apple entitlements e CI hardening survived independent verification.

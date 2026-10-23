# A9 — Build, CI e entrega

> **Base:** `audit/00-mapa.md` e `audit/01-pesquisa/build-ci-seguranca.md`, relidos integralmente e revistos contra as fontes primárias em 23/09/2026.
> **HEAD:** `6138e1d1d94c3daf15b5a645930336903ef15b98`.
> **Modo:** relatório. Nenhum código, configuração, lockfile, dependência, assinatura, serviço ou banco foi alterado. Testes que poderiam escrever no checkout foram executados em cópias sob `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a9`; o bootstrap não foi executado e nenhum runtime/peso foi baixado.
> **Confiança:** CONFIRMADO = execução/prova direta; PROVÁVEL = inferência forte ainda não reproduzida; HIPÓTESE = não usada como achado.

## Resumo executivo

A CI do HEAD exato já está vermelha: o job do core falhou em **122 s**, enquanto o job do app ficou **21.599 s (5 h 59 min 59 s)** no step de testes, foi cancelado e pulou o build. A reprodução local do mesmo `xcodebuild test` ficou 240,015 s sem linha final; cada um dos dois testes OAuth isolados também excedeu 60 s. Em paralelo, o core tem uma regressão determinística de UUID e a suíte do app tem seis testes cujo resultado depende do locale. Não há job de archive/Release assinado/notarizado, os XCFrameworks locais não têm assinatura, o bootstrap aceita um XCFramework parcial e a toolchain/action não são imutavelmente selecionadas.

### A9-001: Gate do app não termina e o job consome seis horas
- Severidade: ALTO
- Confiança: CONFIRMADO
- Local: `.github/workflows/ci.yml:31-51`; `PapagaioTests/OAuthGoogleTests.swift:47-83`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:423-451,484-502`; `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:25-49`
- Evidência:
  ```swift
  // .github/workflows/ci.yml:35-42 — não há timeout nem result bundle
  xcodebuild test -project Loro.xcodeproj -scheme Loro \
    -destination 'platform=macOS' -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    -derivedDataPath /private/tmp/papagaio-ci-app-tests
  ```
  ```swift
  // SessaoOAuthGoogle.swift:438-451,491-502
  Darwin.shutdown(listener.fileDescriptor, SHUT_RDWR)
  let cliente = Darwin.accept(socket, $0, &tamanho)
  guard cliente >= 0 else { throw CancellationError() }
  ```
  A API pública do run `35649758900`, cujo `head_sha` é o HEAD auditado, retornou em duas consultas `curl -sSL --fail` (exit 0; **1,29 s** e **1,44 s**): o step `Testes isolados do app` começou em `2026-09-21T20:14:32Z`, terminou em `2026-09-22T02:14:31Z`, com conclusão `cancelled`; `xcodebuild build` ficou `skipped` (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a9/remote-summary.txt:1-8`).
  Reprodução local do step, sem bootstrap e com DerivedData temporário: exit **124**, duração **240,015 s**. O log iniciou **107** testes, terminou **99** (`passed`), **6** (`failed`) e deixou **2** sem resultado; não houve `Test run with ...`, apenas `** BUILD INTERRUPTED **` (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a9/app-test-current.log:4334,4363,4548`). Os dois pendentes são exatamente `Cancelar a espera...` e `Timeout do OAuth...`.
  Isolados: `-only-testing:PapagaioTests/servidorOAuthGooglePodeSerCancelado()` → exit **124**, **60,013 s**, só linha final `BUILD INTERRUPTED` (`oauth-isolated.log:121-125`); `timeoutDoOAuthGoogleEncerraEspera()` → exit **124**, **60,011 s** (`oauth-timeout-isolated.log:95-99`).
- Cenário de falha: qualquer push/PR deixa o job do app preso até o limite padrão do Actions; o build Debug é pulado e não há `xcresult`/log arquivado para diagnóstico. No produto, o mesmo mecanismo pode prender o fluxo de cancelamento/timeout OAuth, conforme prova de socket em `audit/02-achados/A2.md:36-80`.
- Como reproduzir: no clone, após o bootstrap, executar o comando de `.github/workflows/ci.yml:35-42`; para isolar sem esperar seis horas, usar os dois `-only-testing` acima e um wrapper com timeout de 60 s.
- O que procurei para refutar: o terceiro teste de socket (`OAuthGoogleTests.swift:169-194`) passa porque já existe cliente conectado; procurei timeout por teste/job, `resultBundlePath`, cliente de dequeue ou `close()` do listener — não há; a execução local completa chegou aos dois testes de cancelamento e timeout sem abortar antes deles.
- Causa raiz: `accept()` bloqueia em um worker e `shutdown()` no socket de escuta não o desperta; a CI não limita o tempo nem preserva o resultado parcial.
- Correção sugerida: corrigir o despertar de `accept()` e, em paralelo, definir `timeout-minutes` curto para o job, timeout individual via `xcodebuild -test-timeouts-enabled YES -maximum-test-execution-time-allowance ...`, `-resultBundlePath` e upload `if: always()`; separar build e teste em jobs para o gate de compilação não ser pulado. Não aplicar nesta auditoria. Impacto: baixo no workflow; a correção do socket deve ser validada pelos dois testes.
- Referência: P4 BCI-09/BCI-10 (`audit/01-pesquisa/build-ci-seguranca.md:524-591`); mapa §5.2 (`audit/00-mapa.md:386-434`).

### A9-002: Job do core está vermelho por perda determinística de `Trecho.id`
- Severidade: ALTO
- Confiança: CONFIRMADO
- Local: `PapagaioCore/Tests/PapagaioCoreTests/PipelineTests.swift:521-579`; `PapagaioCore/Sources/PapagaioCore/Transcricao/Segmentacao.swift:25-49`; `PapagaioCore/Sources/PapagaioCore/Dominio.swift:136-145`; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:252-260`; `.github/workflows/ci.yml:19-20`
- Evidência:
  ```swift
  // Segmentacao.swift:39-48 — id não é repassado
  trechos.append(Trecho(
      start: primeiro.start,
      end: ultimo.end,
      texto: acumulados.map(\.texto).joined(separator: " "),
      speaker: primeiro.speaker,
      palavras: palavras,
      noSpeechProb: noSpeech
  ))
  ```
  `Trecho.init` gera `UUID()` por padrão (`Dominio.swift:136-145`). A execução em cópia do pacote, `./Scripts/testa-papagaio-core.sh --scratch-path <temp>`, saiu **1** em **33,33 s**: 6 XCTest passaram; Swift Testing reportou 216 testes, 211 passaram, 1 falhou com 2 issues e 4 foram pulados (`core-current.log:503-512,693-737`; `core-current.time:1-3`).
  Isolamento: `swift test --no-parallel --scratch-path <temp> --filter pipelineTraduzAntesDeSalvarEResumir` → exit **1**, **2,10 s**, com IDs de entrada e saída diferentes em `PipelineTests.swift:554` e `:579` (`core-failing-only.log:1-25`).
  O run remoto do HEAD confirma o job `swift test` como `failure` após **122 s** (`remote-summary.txt:2-4`), embora o log remoto completo não fosse acessível sem autenticação.
- Cenário de falha: o job obrigatório `test-papagaio-core` falha em todo push/PR; mesmo que o app seja corrigido, a CI continua impedindo entrega. Além do gate, o UUID trocado quebra a identidade de âncora entre tradução/sumarização e persistência.
- Como reproduzir: executar o script do core; para uma prova mínima, usar o `--filter` acima. Não depende dos modelos grandes nem do locale.
- O que procurei para refutar: comparei o log com o mapa e com o job remoto do HEAD; rodei a suíte inteira e o teste isolado; as mudanças WIP locais são em VAD/CLI e no script de recuperação, não em `Segmentacao`, `PipelineDeArquivo` ou no teste. O caminho importado/canal único chega explicitamente a `Segmentacao.agrupar` (`PipelineDeArquivo.swift:252-260`).
- Causa raiz: a normalização reconstrói `Trecho` sem preservar o `id` do segmento original.
- Correção sugerida: passar `id: primeiro.id` ao construir o trecho agrupado e repetir a suíte em clone limpo. Não aplicar. Impacto de produto: baixo; preserva a âncora esperada e deve tornar as duas issues verdes.
- Referência: mapa §5.1 (`audit/00-mapa.md:349-375`); P4 BCI-10 (`audit/01-pesquisa/build-ci-seguranca.md:572-591`).

### A9-003: Seis testes do app mudam de resultado conforme o locale
- Severidade: MÉDIO
- Confiança: CONFIRMADO
- Local: `Papagaio/Suporte/Localizacao.swift:6-23`; `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:92-112`; `Papagaio/ViewModels/MidiasDaConversaViewModel.swift:216-227`; `PapagaioTests/EquipesCloudKitTests.swift:202-236`; `PapagaioTests/InterfaceTests.swift:41-50`; `PapagaioTests/MidiasDaConversaViewModelTests.swift:9-32`; `.github/workflows/ci.yml:31-42`
- Evidência: produção usa `.autoupdatingCurrent` e a tabela em inglês (`Localizacao.swift:6-23`), enquanto os testes comparam literais portugueses, por exemplo `#expect(equipe.resumoDeMembros == "participantes ainda não carregados")` (`EquipesCloudKitTests.swift:211`).
  Com os mesmos seis testes e o locale herdado (`en-BR`), `xcodebuild test ... -parallel-testing-enabled NO` → exit **65**, **8,19 s**, 6 testes/10 issues; a saída real foi `participants not loaded yet`, `This team's shared zone...` e `Unlock your iPhone...` (`locale-six-default.log:95-137`; `locale-six-default.time:7-20`).
  Adicionando apenas `-testLanguage pt -testRegion BR` → exit **0**, **2,21 s**, `Test run with 6 tests ... passed` (`locale-six-pt.log:121-138`; `locale-six-pt.time:1-9`).
  A suíte completa reproduziu as mesmas seis falhas antes dos dois travamentos (`app-test-current.log:4390-4512`).
- Cenário de falha: runner/desenvolvedor com locale em inglês executa a mesma revisão como vermelha; locale em português a executa como verde. A CI não declara `LANG`, `-testLanguage` ou `-testRegion`, portanto seu resultado depende do padrão do runner.
- Como reproduzir: executar os seis testes sem flags de idioma e depois com `-testLanguage pt -testRegion BR`; o conteúdo do código não muda.
- O que procurei para refutar: as asserções também existem em um teste de lógica sem interface (`falhaSemAPalavraErro`), mas a produção o traduz pelo mesmo helper; testar explicitamente PT/BR tornou os seis testes verdes; procurei locale no scheme/workflow — nenhum está definido.
- Causa raiz: o contrato de teste fixa a representação em português, mas a produção escolhe a representação com base no locale atual.
- Correção sugerida: para desbloqueio mínimo, fixar `pt`/`BR` na CI e documentar; melhor, injetar locale no helper e manter uma matriz PT/EN, comparando a tradução esperada em vez de assumir um único idioma do sistema. Não aplicar. Risco: fixar apenas PT temporariamente oculta regressões em inglês, então testes EN devem ser adicionados.
- Referência: P4 BCI-10 (`audit/01-pesquisa/build-ci-seguranca.md:572-591`); mapa §5.2/§10 (`audit/00-mapa.md:386-434,716-731`).

### A9-004: Quatro testes dos motores de IA são sempre pulados em uma CI limpa
- Severidade: MÉDIO
- Confiança: CONFIRMADO
- Local: `PapagaioCore/Tests/PapagaioCoreTests/TranscricaoTests.swift:7-20,149-160,205-239`; `PapagaioCore/Tests/PapagaioCoreTests/SumarizacaoTests.swift:6-10,148-170`; `Scripts/bootstrap-runtimes.sh:282-299`; `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:19-36`; `.github/workflows/ci.yml:16-20`
- Evidência: os testes só ficam habilitados se os pesos estiverem em `~/Documents/InterviewLab/Models`; o áudio real também está em `~/Documents/InterviewLab/Audio`. O bootstrap da CI baixa XCFrameworks, Silero e diarização, mas não baixa `ggml-large-v3.bin` nem `Qwen_Qwen3.5-9B-Q4_K_M.gguf`. Os pesos são externos e totalizam **9.264.375.467 bytes** (`Preflight.swift:22-33`).
  A suíte local registrou 1 Qwen + 3 Whisper `skipped` (`core-current.log:693-716`). Numa CI GitHub limpa esses caminhos de desenvolvimento não existem, então esses quatro testes não exercitam o runtime real nem podem falhar.
- Cenário de falha: uma alteração no wrapper Whisper/Qwen, ABI, tokenizer ou saída real passa nos testes sintéticos porque os motores reais estão desabilitados; a falha aparece apenas no app ou no uso com modelo.
- Como reproduzir: `swift test` em um clone sem `~/Documents/InterviewLab`; observar os quatro `skipped` sem timing de modelo.
- O que procurei para refutar: `.timeLimit(.minutes(5/10))` existe, mas só atua quando habilitado; procurei download dos pesos no bootstrap, cache de modelo, fixture versionada e `--filter` obrigatório — nenhum está na CI. O fixture `fala_ola_mundo.wav` versionado não é usado por `audioDeTeste`.
- Causa raiz: disponibilidade dos testes depende de caminhos absolutos e artefatos de 9,26 GB não fornecidos pelo job.
- Correção sugerida: tornar diretório de modelos/audio variáveis explícitas, usar fixture versionada e criar um job noturno/manual de integração real em que `skipped` seja erro; armazenar pesos por hash somente depois de A9-006. Não aplicar em todo PR devido ao custo. Impacto: horas/armazenamento no job pesado, mas fecha a principal lacuna.
- Referência: mapa §5.1/§10 (`audit/00-mapa.md:376-381,722`); P4 BCI-08/BCI-09 (`audit/01-pesquisa/build-ci-seguranca.md:486-523,524-556`).

### A9-005: Não existe gate de Release assinado, validado ou notarizado
- Severidade: ALTO
- Confiança: CONFIRMADO
- Local: `.github/workflows/ci.yml:44-51`; `Loro.xcodeproj/project.pbxproj:441-452,481-492`; `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:71-94`; `Config/Papagaio.entitlements:19-22`; `Scripts/bootstrap-runtimes.sh:107-149`
- Evidência: o único build da CI é Debug, sem assinatura:
  ```yaml
  # .github/workflows/ci.yml:46-51
  xcodebuild build -project Loro.xcodeproj -scheme Loro \
    -destination 'generic/platform=macOS' \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
  ```
  `xcodebuild -showBuildSettings` sem `-configuration` retornou `CONFIGURATION = Debug` (exit 0, **11,67 s**, `show-settings-default.log:72-89`). A varredura nos arquivos de CI/script/documentação retornou **0** ocorrências de `xcodebuild archive`, `-exportArchive` e `notarytool` (script estático, exit 0, **0,03 s**, `static-gates.log:7-9`).
  Para refutar que a configuração Release não compila, fiz build Release temporário com `CODE_SIGNING_ALLOWED=NO`: exit **0**, **101,16 s**, `BUILD SUCCEEDED` (`release-build.log:3058-3089`). O produto resultante é propositalmente não distribuível: `codesign --verify --deep --strict` → exit **1** em **0,01 s**, `code object is not signed at all`; `spctl --assess` → exit **3** em **0,61 s**, `rejected / no usable signature`. Os três XCFs fonte também falharam `codesign` em **0,01 s** cada (`codesign-{llama,whisper,onnx}.time:1-4`).
  A entitlement ainda desativa a validação de bibliotecas (`Papagaio.entitlements:19-22`).
- Cenário de falha: depois de corrigir os testes, uma CI pode ficar verde por compilar um Debug sem assinatura enquanto um archive real falha ao assinar componentes aninhados, diverge de entitlements/profile, é rejeitado por `spctl` ou não é notarizado. O gate atual não detectaria isso até a entrega.
- Como reproduzir: executar o build Release acima; para avaliar a distribuição real seria necessário um archive/export em clone limpo com credenciais, não executado por este modo.
- O que procurei para refutar: o scheme tem `ArchiveAction = Release`, o target tem Hardened Runtime e assinatura automática; o build Release sem assinatura também passou. Portanto **não** afirmo que a distribuição atual está quebrada — a ausência é do gate que comprovaria a cadeia.
- Causa raiz: a CI trata “compilar” como “entregar”, desabilita assinatura e não valida o artefato final.
- Correção sugerida: job separado em ambiente protegido, `archive` + `exportArchive`, assinatura dos frameworks aninhados, `codesign --verify --deep --strict`, inspeção de entitlements, `spctl`, `notarytool` submit/staple; testar remoção de `disable-library-validation`. Não aplicar. Impacto: exige credenciais e runner compatível; não deve usar `CODE_SIGNING_ALLOWED=NO` no job de release.
- Referência: P4 BCI-05/BCI-09 (`audit/01-pesquisa/build-ci-seguranca.md:387-450,524-556`).

### A9-006: Bootstrap aceita e reutiliza um XCFramework parcial sem revalidar seu conteúdo
- Severidade: MÉDIO
- Confiança: CONFIRMADO
- Local: `Scripts/bootstrap-runtimes.sh:65-102,104-150,152-190`; `PapagaioCore/Package.swift:18-27`; `.gitignore:1-9`
- Evidência: a condição de skip só exige `Info.plist` e exclui um ponteiro Git LFS:
  ```bash
  # bootstrap-runtimes.sh:107-115
  if [ -d "$DESTINO/$xcf" ]; then
    if [ -f "$info" ] && ! head -n 1 "$info" | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
      echo "==> $nome já presente ... — pulando"
      return
  ```
  Experimento sem rede, em fixture temporária: criei `fake.xcframework/Info.plist` contendo apenas texto, carreguei o script com `source` e chamei `baixar` com URL/hash inválidos. Exit **0**, **0,01 s**, saída `fake já presente ... — pulando` (`bootstrap-accept-partial.log:1`); o diretório continha somente o `Info.plist`.
  A instalação copia diretamente com `cp -R` e só depois poda (`bootstrap-runtimes.sh:146-149`), sem manifest final/rename atômico. Em contraste, os 21 arquivos de diarização e o Silero são revalidados: 22/22 conferiram em **0,27 s**.
- Cenário de falha: uma cópia interrompida, workspace/cache reutilizado ou XCF alterado com `Info.plist` presente faz o próximo bootstrap retornar sucesso; a resolução/build do pacote falha por artefato incompleta ou carrega bytes não revisados. O resumo final imprime `SEM slice de macOS`, mas não retorna erro (`bootstrap-runtimes.sh:301-309`).
- Como reproduzir: fixture acima; para caso real, interromper `cp -R`/pod e executar o script novamente.
- O que procurei para refutar: os XCFs estão gitignored e uma CI GitHub nova normalmente nasce sem eles; os downloads novos verificam o SHA do ZIP, os modelos simples verificam SHA e atualmente não há cache. Ainda assim, o experimento confirma o ramo de aceitação de diretório existente.
- Causa raiz: validação ocorre no ZIP apenas quando ele é baixado; não há verificação do XCF final já presente nem promoção atômica.
- Correção sugerida: gerar manifest determinístico do XCF final após prune/module-map, validar todos os arquivos/assinatura/layout em staging e fazer `mv` atômico; só então habilitar cache. Não aplicar. Impacto: manutenção do manifest e espaço temporário, sem alterar a API.
- Referência: P4 BCI-04/BCI-09 (`audit/01-pesquisa/build-ci-seguranca.md:343-385,524-556`).

### A9-007: CI não fixa Xcode nem força uso exclusivo dos lockfiles
- Severidade: MÉDIO
- Confiança: PROVÁVEL
- Local: `.github/workflows/ci.yml:10-12,22-24,35-51`; `Loro.xcodeproj/project.pbxproj:245-253`; `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:2-4`; `PapagaioCore/Package.swift:11-16`; três `Package.resolved:1-15`
- Evidência: a CI escolhe apenas a imagem móvel `macos-26`; não há `xcode-select`, setup de Xcode nem impressão de `xcodebuild -version`/`swift --version`. O projeto foi criado/marcado para Xcode 27. A máquina selecionada usa Xcode `27A5194q` (exit 0, **0,08 s**) e Swift `6.4 (6.4.0.20.104)` (exit 0, **0,09 s**); a GA instalada usa `27A266a` (exit 0, **0,04 s**). A imagem oficial `macos-26` consultada (`20260824.0517.1`) documenta Xcode **26.6 `17F113`** como default.
  A Apple recomenda `-disableAutomaticPackageResolution` com `xcodebuild` direto. A varredura estática encontrou 0 usos da flag/equivalentes (exit 0, **0,03 s**, `static-gates.log:17`). Os três lockfiles têm `originHash` diferentes, mas **o mesmo pin FluidAudio 0.15.5 / revisão `19600a...`**; a comparação sem `originHash` retornou `true`. `xcodebuild -list` resolveu 0.15.5 sem drift (exit 0, **11,38 s**).
- Cenário de falha: atualização/padrão da imagem muda compiler/SDK sem alteração no repo; um lockfile inconsistente pode ser resolvido automaticamente em vez de fazer a CI falhar, executando bytes não pretendidos. O risco é de reprodutibilidade, não uma divergência já observada.
- Como reproduzir: comparar `xcodebuild -version` local com a versão padrão da imagem; para o lock, executar os comandos atuais em uma cópia com lockfile deliberadamente inconsistente (não foi feito para respeitar “sem download”).
- O que procurei para refutar: `exact: "0.15.5"`, três pins idênticos e Xcode GA 27 abriram o projeto (`xcodebuild -list` exit 0, **8,89 s**); o run remoto chegou aos testes. Portanto não há pin de FluidAudio divergente hoje.
- Causa raiz: padrões mutáveis de runner/build system são usados como entrada de reprodutibilidade.
- Correção sugerida: selecionar explicitamente uma Xcode suportada (preferir 27 GA para release), imprimir versões e falhar se não for a esperada; adicionar `-disableAutomaticPackageResolution` e `--only-use-versions-from-resolved-file`/equivalente. Não aplicar. Risco: a imagem pode remover uma versão instalada; o guard deve falhar explicitamente.
- Referência: P4 BCI-03/BCI-07 (`audit/01-pesquisa/build-ci-seguranca.md:335-341,466-484`).

### A9-008: Action de checkout usa tag móvel e token sem privilégio mínimo declarado
- Severidade: MÉDIO
- Confiança: CONFIRMADO
- Local: `.github/workflows/ci.yml:3-7,12-17,22-29`
- Evidência:
  ```yaml
  # linhas 14 e 26
  - uses: actions/checkout@v4
  ```
  A varredura do workflow encontrou 2 `uses`, 2 `actions/checkout@v4`, 0 `permissions:`, 0 `pull_request_target` e 0 `workflow_run` (script estático, exit 0, **0,03 s**; `static-gates.log:1-6`). A documentação oficial do GitHub afirma que SHA completo é a única forma imutável e que tags podem ser movidas/excluídas. Em 23/09/2026, a release mais recente consultada era v7.0.1; a página do mantenedor continuava sem advisories publicados.
- Cenário de falha: quem controla a tag upstream pode mudar o código executado sem alteração no repositório; a action roda com os privilégios efetivos do `GITHUB_TOKEN`, cujo default não é declarado no arquivo.
- Como reproduzir: `rg -n 'uses:|permissions:|pull_request_target|workflow_run' .github/workflows/ci.yml`.
- O que procurei para refutar: o workflow não passa secrets, usa trigger `pull_request`, e a página do mantenedor reportou zero advisories; portanto não há CVE alegada nem comprometimento demonstrado. O achado trata somente da entrada mutável e do privilégio desconhecido do token.
- Causa raiz: a action de supply chain e a autorização do token não são especificadas por identificador/permissão imutável.
- Correção sugerida: pinar um SHA auditado de `checkout` com comentário da tag, declarar `permissions: contents: read` e usar Dependabot para atualizar SHA. Não aplicar. Risco: manutenção manual/atualizações de actions.
- Referência: P4 BCI-02 (`audit/01-pesquisa/build-ci-seguranca.md:297-333`); GitHub Secure Use e advisories revalidados.

### A9-009: O script WIP do core e seus testes offline divergem, e a CI não executa esses testes
- Severidade: BAIXO
- Confiança: CONFIRMADO
- Local: `Scripts/testa-papagaio-core.sh:44-56,73-95`; `Scripts/tests/test_scripts.py:53-87`; `.github/workflows/ci.yml:16-20,28-51`; `.gitignore:23-24`
- Evidência: a versão WIP usa `codesign` + `swift test --skip-build`; os testes ainda exigem uma segunda compilação e `xattr -cr` (`test_scripts.py:61-82`). `python3 -m unittest Scripts.tests.test_scripts` → exit **1**, **2,52 s**, **3/8 falhas** (`script-tests.time:1-32`). Em fixture temporária, substituindo somente o script pelo arquivo de `HEAD` e mantendo o mesmo arquivo de teste/projeto, o mesmo comando → exit **0**, **3,30 s**, **8/8 passam** (`script-tests-head.time:1-8`).
  A CI não contém `python`, `unittest` ou `pytest`; portanto não detectaria a divergência.
- Cenário de falha: o WIP do script é commitado sem reconciliar os testes; a recuperação de FinderInfo pode regredir e o workflow normal, em runner sem FinderInfo, continua verde sem exercitar esse ramo.
- Como reproduzir: rodar o unittest no working tree; comparar com `git show HEAD:Scripts/testa-papagaio-core.sh` em cópia.
- O que procurei para refutar: `git diff` mostra que a alteração ainda é WIP; o job remoto do HEAD executou o script versionado, não este arquivo WIP; o script de HEAD passa nos oito testes, então não é uma falha do harness de teste.
- Causa raiz: implementação e contrato de teste foram alterados em separado, sem gate Python.
- Correção sugerida: decidir entre voltar ao contrato de reconstrução ou adaptar os testes à assinatura/skip-build, e adicionar `python3 -m unittest Scripts.tests.test_scripts` à CI. Não aplicar. Risco: baixo; o teste da recuperação pode depender de filesystem/sandbox e deve continuar offline.
- Referência: P4 BCI-10 (`audit/01-pesquisa/build-ci-seguranca.md:572-591`); mapa §5.4 (`audit/00-mapa.md:448-463`).

### A9-010: README e PR template não reproduzem o gate que a Actions executa
- Severidade: MÉDIO
- Confiança: CONFIRMADO
- Local: `README.md:100-117`; `.github/pull_request_template.md:5-9`; `.github/workflows/ci.yml:19-20,31-51`; `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:25-49`
- Evidência: README manda executar bootstrap, core e `xcodebuild build`, mas não contém o `xcodebuild test` do app que a CI executa; o PR template só lista core e “Build do scheme Loro”. A única definição executável do teste do app está no YAML. A varredura dos comandos locais (exit 0, **0,03 s**) encontrou 0 `python3 -m unittest`, 0 timeout de teste, 0 `-resultBundlePath` e 0 `-testLanguage` (`static-gates.log:9-18`).
- Cenário de falha: uma alteração que passa exatamente pelos três comandos/checklists documentados pode falhar no job do app, falhar por locale ou pendurar por OAuth; o documento dá falsa sensação de reprodução local.
- Como reproduzir: comparar README/template com os steps do workflow; seguir o checklist em uma branch sem executar o step omitido.
- O que procurei para refutar: README afirma que Actions testa o app e o scheme injeta `PAPAGAIO_TEST_MODE=1`, mas não dá comando; não há wrapper único, teste de documentação ou script que reproduza o workflow.
- Causa raiz: comandos de validação duplicados em YAML, README e template, sem fonte única.
- Correção sugerida: criar um comando único de validação usado por CI, README e template, incluindo app tests, script tests e timeouts; ou incluir o comando exato do app nos três. Não aplicar. Risco: wrapper deve ser executável em CI e local sem segredo.
- Referência: P4 BCI-10 (`audit/01-pesquisa/build-ci-seguranca.md:572-591`); mapa §4.1 (`audit/00-mapa.md:307-324`).

### A9-011: whisper.cpp `v1.9.1` não contém correções upstream de memória presentes em `v1.9.3`/`v1.9.4`
- Severidade: MÉDIO
- Confiança: PROVÁVEL
- Local: `Scripts/bootstrap-runtimes.sh:47-58,282-292`; `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:98-105,116-145,167-178`; `Papagaio/App/ContentView.swift:1072-1087`; `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:99-118,128-140`
- Evidência: o pin exato é `WHISPER_TAG="v1.9.1"` com SHA-256. As release notes oficiais revalidadas de `v1.9.3` listam heap OOB read em `log_mel_spectrogram` para áudio muito curto e rejeição de header de modelo malformado para stack-buffer-overflow; `v1.9.4` lista inicialização de `whisper_mel` para evitar leitura não inicializada. O repositório whisper.cpp não publica GHSA/CVE para esses itens, portanto não há alegação de CVE.
  O wrapper local só rejeita `amostras.isEmpty` e passa qualquer buffer não vazio a `whisper_full` (`ContextoWhisper.swift:142-178`); a pasta de modelos é selecionável pelo usuário (`ContentView.swift:1072-1087`). Preflight normalmente verifica tamanho, mas `verificarChecksum` default é `false` (`Preflight.swift:99-118`).
- Cenário de falha: áudio muito curto ou modelo malformado em uma pasta escolhida pode alcançar um caminho que versões posteriores corrigiram; impacto e alcançabilidade não foram reproduzidos nesta auditoria.
- Como reproduzir: comparar os commits de correção upstream com a tag fixada; um PoC de fuzzing/arquivo malformado exigiria uma execução de segurança separada e não foi feito.
- O que procurei para refutar: o projeto tem guard de array vazio, hash/tamanho para downloads e testes sintéticos; não há advisory/CVE oficial nem prova de que o app passa uma amostra mínima. Por isso o achado é hardening de versão, não “CVE confirmada”.
- Causa raiz: runtime pinado antes de correções de segurança de memória upstream, com validação de entrada/modelo incompleta no wrapper.
- Correção sugerida: avaliar `>= v1.9.4`, trocar tag e SHA, compilar o bootstrap e executar testes de integração/modelos antes de promover. Não aplicar. Impacto: novo binário, possível regressão de performance/API; testar `qwen35`/Whisper e hardened runtime.
- Referência: P4 BCI-06 (`audit/01-pesquisa/build-ci-seguranca.md:452-464`); releases oficiais `whisper.cpp` `v1.9.3` e `v1.9.4` revalidadas.

### A9-012: Gate não mede cobertura, não executa Analyze e não tem política de warnings
- Severidade: BAIXO
- Confiança: CONFIRMADO
- Local: `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:25-49,88-90`; `.github/workflows/ci.yml:31-51`; `Loro.xcodeproj/project.pbxproj:389-439`
- Evidência: `rg -n 'codeCoverageEnabled|coverage|-enableCodeCoverage|GCC_TREAT_WARNINGS_AS_ERRORS|SWIFT_TREAT_WARNINGS_AS_ERRORS' Loro.xcodeproj .github Scripts ci_scripts` retornou exit **1**, **0,00 s**, sem ocorrências. O scheme tem AnalyzeAction Debug, mas a CI não executa `xcodebuild analyze`. O build Release local registrou **121 ocorrências de warning em 11 mensagens únicas**: 120 linhas de umbrella header do XCFramework ONNX gerado pelo module map patcheado e 1 metadata AppIntents; não houve warning de primeiro-party observado.
- Cenário de falha: regressões de cobertura, análise estática ou novos warnings podem passar sem bloquear o gate; o volume vendorizado também torna difícil avaliar somente o exit code sem baseline.
- Como reproduzir: `xcodebuild build ... -configuration Release` e comparar `rg 'warning:'`; a CI atual não tem comando de cobertura/analyze.
- O que procurei para refutar: não há linter/formatador nem threshold configurado; as warnings atuais são majoritariamente artefatos do framework e não provam bug de produto. Reporto apenas a lacuna de gate, não um bug de código-fonte.
- Causa raiz: política de qualidade não é executada nem definida no repositório.
- Correção sugerida: primeiro gerar relatório de cobertura sem threshold e `analyze` em job separado; depois limpar/baselinear warnings vendorizados e aplicar warning-as-errors por target. Não aplicar. Impacto: aumento de tempo/armazenamento e possível falha por código vendorizado.
- Referência: P4 BCI-10 (`audit/01-pesquisa/build-ci-seguranca.md:572-591`); mapa §5.5 (`audit/00-mapa.md:465-479`).

## Matriz job/comando/resultado

| Origem | Job/comando | Exit/conclusão | Duração | Resultado observado |
|---|---|---:|---:|---|
| GitHub run `35649758900`, HEAD exato | `test-papagaio-core / bootstrap` | success | 28 s | Runtimes baixados; sem erro de bootstrap |
| GitHub run `35649758900` | `test-papagaio-core / swift test` | **failure** | **122 s** | Step terminou; job reprovou |
| GitHub run `35649758900` | `build-app / bootstrap` | success | 28 s | Runtimes baixados |
| GitHub run `35649758900` | `build-app / Testes isolados do app` | **cancelled** | **21.599 s (5:59:59)** | Sem resultado final; runner cancelou |
| GitHub run `35649758900` | `build-app / xcodebuild build` | skipped | 0 s | Não executou porque o teste anterior não terminou |
| Local, cópia do pacote | `./Scripts/testa-papagaio-core.sh --scratch-path <temp>` | **1** | **33,33 s** | 6 XCTest passam; 216 Swift: 211 passam, 1 falha/2 issues, 4 skips |
| Local, filtro do teste | `swift test --no-parallel --filter pipelineTraduzAntesDeSalvarEResumir` | **1** | **2,10 s** | UUID de entrada/saída diferente |
| Local, cópia do app | comando de `ci.yml:35-42` + timeout de 240 s | **124** | **240,015 s** | 107 iniciados; 99 passes, 6 falhas, 2 pendurados; sem resumo final |
| Local, OAuth cancel isolado | `-only-testing:PapagaioTests/servidorOAuthGooglePodeSerCancelado()` | **124** | **60,013 s** | Teste iniciou e não emitiu resultado |
| Local, OAuth timeout isolado | `-only-testing:PapagaioTests/timeoutDoOAuthGoogleEncerraEspera()` | **124** | **60,011 s** | Teste iniciou e não emitiu resultado |
| Local, locale default | 6 testes sem `-testLanguage` | **65** | **8,19 s** | 6 testes, 10 issues; textos em inglês |
| Local, locale PT/BR | mesmos 6 + `-testLanguage pt -testRegion BR` | **0** | **2,21 s** | 6 testes passaram |
| Local, script WIP | `python3 -m unittest Scripts.tests.test_scripts` | **1** | **2,52 s** | 3 falhas de 8 |
| Local, script de `HEAD` em fixture | mesmo unittest, script `HEAD` | **0** | **3,30 s** | 8 passes de 8 |
| Local, release sem assinatura | `xcodebuild build -configuration Release CODE_SIGNING_ALLOWED=NO` | **0** | **101,16 s** | `BUILD SUCCEEDED`; 121 warnings |
| Local, release sem assinatura | `codesign --verify --deep --strict <app>` | **1** | **0,01 s** | `code object is not signed at all` |
| Local, release sem assinatura | `spctl --assess --type execute <app>` | **3** | **0,61 s** | `rejected; no usable signature` |
| Local, fixture sem rede | `baixar` com XCF contendo só `Info.plist` | **0** | **0,01 s** | Bootstrap aceitou e pulou download |
| Local, hashes já staged | 21 diarização + Silero | **0** | **0,27 s** | 22/22 hashes conferiram |

## Versões, pins e divergências

| Item | Valor observado/fixado | Divergência ou decisão |
|---|---|---|
| Xcode selecionado local | `27.0 / 27A5194q` | Beta; GA instalada `27A266a` também abriu o projeto |
| Xcode default da imagem oficial `macos-26` consultada | `26.6 / 17F113` | CI não seleciona Xcode; runner pode mudar |
| Swift local | `6.4`, build `swiftlang-6.4.0.20.104` | Não é o patch exato do runner; não foi alegado |
| Deployment target | macOS `26.0` | Projeto, package e workspace estão alinhados |
| FluidAudio | `0.15.5`, rev `19600a485baa4998812e4654b70d2bab8f2c9949` | Mesmo pin nos 3 `Package.resolved`; só `originHash` difere |
| FluidAudio upstream revalidado | `v0.17.1` | A “latest 0.16.1” da P4 foi superada no mesmo dia; não foi usada para alegar CVE |
| whisper.cpp | `v1.9.1`, SHA `8c3ecbe7…` | Runtime antes de correções de memória `v1.9.3`/`v1.9.4` |
| llama.cpp | `b9222`, SHA `39b5d476…` | P4 revisou 13 advisories; nenhuma faixa alcançava `b9222`; nenhum CVE novo alegado |
| ONNX Runtime C | `1.24.2`, SHA `f7100a99…` | Release `1.30.0` revalidada; parte do hardening é CUDA-only; sem CVE alegado |
| Silero | commit `76e3dc408e…`, SHA `1a153a22…` | 1 arquivo staged revalidado |
| Diarização CoreML | 21 arquivos + SHA por arquivo | 21/21 conferiram; provenance upstream é histórica, não atestado rebuild |
| `actions/checkout` | `@v4` (tag móvel) | Release mais recente consultada: `v7.0.1`; sem advisory publicado |
| Cache | 0 ações/0 chaves | Não foi encontrado cache inseguro; a ausência reduz risco de poisoning, mas também não reaproveita SPM/DerivedData |
| Plugins SwiftPM | 0 no manifest raiz e no checkout FluidAudio pinado | `-skipPackagePluginValidation` não tem exploit atual comprovado; permanece armadilha futura |

## Cobertura e quality gates

- **Cobertura configurada:** 0 (`codeCoverageEnabled`/`-enableCodeCoverage` ausentes). **Percentual real:** desconhecido; não foi inventado.
- Testes app enumerados: **107**, todos habilitados, 0 erro de enumeração. Na execução completa, 2 não terminaram.
- Testes core: **222** casos (216 Swift Testing + 6 XCTest); 4 testes com modelo real foram pulados; a regressão de ID produziu 1 teste falhado com 2 issues.
- Testes de script: 8 no working tree (3 falham); os mesmos 8 passam com o script de `HEAD` em fixture.
- Build Release sem assinatura: 121 ocorrências de warning, 11 mensagens únicas, sem warning first-party observado; nenhum gate de warning-as-errors.
- Análise estática: há AnalyzeAction no scheme, mas nenhum comando de analyze na CI.
- Artefatos: a CI não faz upload de `xcresult`, logs ou coverage; a única retenção remota observável é o texto/log do Actions.

## Refutações e itens não promovidos a achado

1. **Falso positivo de segredo histórico:** a revalidação dos commits `41c48eb...` e `e2eceb3...` encontrou somente uma linha de exemplo dentro de um bloco de setup; o valor era um placeholder ASCII curto em formato de duas partes, não foi demonstrado como credencial real. Nenhum valor/prefixo foi transcrito. `Config/Secrets.xcconfig` está ignorado em `.gitignore:29-30`; portanto o P4 BCI-01 **não foi confirmado** e nenhuma rotação foi solicitada.
2. **Package.resolved:** os três arquivos têm hashes de arquivo diferentes porque `originHash` difere, mas `pins`, versão e revisão são idênticos. Não é uma divergência de dependência; apenas falta lock-only no comando.
3. **`-skipPackagePluginValidation`:** procurado no manifest raiz e no checkout FluidAudio `19600a...`; zero plugins. Não há risco de execução conhecido neste commit.
4. **Cache inseguro:** não existe cache no workflow. Não foi reportado “cache envenenado”; a recomendação de cache só vale depois de validar o XCF final (A9-006).
5. **Action/CVEs:** a página de advisories de `actions/checkout` foi revalidada sem advisories; a tag móvel é risco de supply chain, não CVE. llama/FluidAudio/ONNX também não têm alegação nova de CVE neste relatório.
6. **APNs:** `Config/Papagaio.entitlements:9-10` contém `development`, mas a documentação Apple diz que Xcode define esse valor conforme o provisioning profile. Sem archive assinado, isso não foi promovido a bug de Release.
7. **Xcode Cloud:** `manifest.json:5-10` repete o mesmo target ID em duas entradas. O serviço/schema não foi acessado; é limitação, não achado confirmado.
8. **Build Release:** a configuração Release compila; a falha é a ausência de gate de assinatura/distribuição, não uma falha de compilação comprovada.
9. **Cleanup:** `bootstrap-runtimes.sh:41-42` remove seu temporário por `trap`; `testa-papagaio-core.sh:7-8` remove o log temporário; runners GitHub são efêmeros e não há cache persistente no workflow. Não foi encontrado leak de cleanup no gate atual.
10. **Targets/configs/workspace:** projeto e `Loro.xcworkspace` listam os mesmos targets `Loro` e `PapagaioTests`; há apenas um scheme compartilhado, `Loro`. Debug/Release mantêm bundle, versão, Swift, deployment e assinatura esperados; as diferenças Debug/Release não foram classificadas como drift. A única divergência de gate é o Debug padrão sem Release gate (A9-005).

## Fontes primárias revalidadas

- GitHub runner `macos-26`: `https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md` — imagem `20260824.0517.1`, Xcode 26.6 `17F113` default.
- GitHub Secure Use e sintaxe/timeout: `https://docs.github.com/en/actions/reference/security/secure-use` e `https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax`.
- `actions/checkout`: `https://github.com/actions/checkout/security/advisories` e `https://api.github.com/repos/actions/checkout/releases/latest` — zero advisory publicado; latest observado v7.0.1.
- Apple SwiftPM/Xcode CI: `https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows`.
- Apple APNs entitlement: `https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.aps-environment.json` — Xcode define o valor conforme o profile.
- FluidAudio: `https://api.github.com/repos/FluidInference/FluidAudio/releases/latest` — v0.17.1 no momento da revalidação.
- whisper.cpp: releases `v1.9.3` e `v1.9.4` em `https://github.com/ggml-org/whisper.cpp/releases`; advisories em `https://github.com/ggml-org/whisper.cpp/security/advisories`.
- llama.cpp e ONNX Runtime: páginas oficiais de advisories/releases `https://github.com/ggml-org/llama.cpp/security/advisories` e `https://github.com/microsoft/onnxruntime/releases/tag/v1.30.0`.

## Limitações

- Não executei `Scripts/bootstrap-runtimes.sh`, não baixei zips/pesos e não alterei dependências; reusei os runtimes locais já staged.
- Não executei archive, export, assinatura com credenciais, `spctl` sobre produto assinado, notarização, Apple Cloud Console ou Xcode Cloud. Logo, não afirmo que o app Release real está recusado.
- Logs remotos completos exigiram autenticação; a API pública forneceu run/jobs/timestamps, e a reprodução local cobriu a sintaxe e os testes do step.
- Não fiz fuzzing/PoC de whisper, llama ou ONNX; A9-011 é avaliação de hardening por release notes, não CVE confirmada.
- O XCFramework local é ignorado e não versionado; hashes de ZIP não puderam ser comparados sem download.
- A árvore de trabalho já estava suja; este relatório não alterou nem limpou WIP de outros agentes.
- Locale da máquina era inglês (`en-BR`); a matriz registra a comparação explícita PT/BR.

## Contagens

| Métrica | Quantidade |
|---|---:|
| Achados | **12** |
| Severidade | CRÍTICO **0** · ALTO **3** · MÉDIO **7** · BAIXO **2** · INFO **0** |
| Confiança | CONFIRMADO **10** · PROVÁVEL **2** · HIPÓTESE **0** |
| Jobs remotos no run do HEAD | **2**; core failure, app cancelled |
| Testes app | 107 iniciados; 99 passaram; 6 falharam; 2 pendurados |
| Testes core | 222 casos; 217 passaram; 1 falhou; 4 pulados |
| Testes de script no working tree | 8; 3 falharam |
| Cobertura | 0 configurada; percentual desconhecido |
| Release build warning | 121 ocorrências; 11 mensagens únicas |
| Comandos/consultas medidos relevantes | mais de 20, com exit e duração registrados acima |

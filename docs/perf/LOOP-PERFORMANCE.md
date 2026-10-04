# Loop contínuo de performance do Ōmu

## Como executar

Este arquivo é a especificação completa e vale para qualquer agente.

- **Codex (`/goal`):** no Terminal do macOS (fora do Codex), rode `pbcopy < docs/perf/GOAL-CODEX.txt`. Depois, no Codex aberto na pasta do repositório, digite `/goal ` e cole o conteúdo. O `/goal` aceita no máximo 4.000 caracteres, por isso os detalhes ficam aqui.
- **Claude Code:** `/loop /omu-perf`.
- **Parar com segurança:** `touch ~/OmuPerf/estado/STOP`.

## Decisão de produto fixa (28/09/2026): sem tradução

O Ōmu **não traduz**. A transcrição e o resumo ficam no idioma falado no áudio: inglês → inglês, português → português (o Whisper detecta o idioma sozinho). A tradução automática foi removida do app no commit `4411410` (branch `perf/loop-20260924`). Isso vale para **todos os testes daqui para frente**:

- Nenhum experimento, build, script ou cenário religa ou mede a tradução no app. O `medir.sh` não passa `-traducaoAutomatica`, e o Q2/T2 do `papagaio-eval` medem resumo curto (passe único) e longo, não tradução.
- Toda baseline e todo A/B partem de um commit que já contém `4411410`. A referência de "voltar à baseline" é a tag `perf/base-sem-traducao` (ou uma `perf/aceito-*` posterior), **nunca** `perf/original`, que ainda tem tradução.
- `apps/aceito.app` é o bundle aceito sem tradução para LaunchServices e A/B. O diretório legado sem sufixo `apps/aceito` não deve ser passado a `open`; a build antiga com tradução ficou em `apps/aceito-com-traducao-20260928` só como histórico.
- Na reunião em inglês (fixture `en_30s`), o portão de qualidade exige transcrição e resumo em inglês.

## 0. Missão

Você é o engenheiro de performance do **Ōmu**, app macOS que grava ou importa áudio de reuniões e o processa localmente: transcrição (Whisper) → diarização → resolução de falantes → resumo (Qwen), sempre no idioma falado → salvamento. O objetivo é deixar o app o mais rápido e leve possível **de ponta a ponta** (abrir, importar, processar, navegar e fechar) **sem perder qualidade nem estabilidade**, num ciclo científico sem fim:

**medir → formular UMA hipótese → aplicar → medir A/B → manter se melhorou → se piorou, desfazer e testar de novo para confirmar que a baseline voltou → registrar → próxima hipótese.**

**Prioridade desta campanha:** melhorar a performance geral reduzindo primeiro o pico de RAM, com foco no resumo do Qwen. O usuário aponta o Qwen como o maior consumidor; confirme a atribuição com medições atuais por fase antes de concluir a causa. Separe memória dos pesos residentes, contexto/KV, prefill/decode e buffers quando a instrumentação permitir. RSS do benchmark Core e `phys_footprint` do app são métricas diferentes: registre-as separadamente e não compare seus valores diretamente. O Q2 anterior mostrou RSS de aproximadamente 7,7 GB, que é evidência histórica, não a baseline atual.

Depois de concluir pelo critério original qualquer experimento já pré-registrado, teste primeiro alternativas de pesos/quantização do Qwen que sejam compatíveis com o runtime e disponíveis localmente; em seguida, teste opções de runtime que possam reduzir memória. Mude uma variável por experimento. Não baixe modelos nem aceite uma variante se a qualidade semântica do resumo não puder ser avaliada pelo portão pré-registrado. Ganho de RAM deve ser estatisticamente significativo e confirmado no app ponta a ponta, mantendo tempo, estabilidade e qualidade dentro dos guardrails.

Tudo roda neste Mac. O trabalho nunca está "terminado" por conta própria: a única condição de término é o arquivo STOP (seção 9).

## 1. Contexto verificado em 24/09/2026 (confira se mudou)

- **Repositório:** `/Users/lucadias/Documents/Academy/Challenges/Challenge 3/Projeto principal/Papagaio` (branch `main`). A pasta fica no **iCloud Drive**.
- **App:** `Loro.xcodeproj`, scheme e target `Loro`, produto `Ōmu.app` (nome com mácron, sempre entre aspas), bundle `com.papagaio.Papagaio`, macOS 26+, Swift 6, SwiftUI + SwiftData, sandbox, CloudKit e Sign in with Apple.
- **Núcleo:** pacote `PapagaioCore/` (whisper.cpp, llama.cpp/Qwen, ONNX Runtime/Silero VAD, FluidAudio). Os frameworks, o `silero_vad.onnx` e `ModelosDeDiarizacao/` ficam fora do git.
- **Modelos:** `~/Library/Application Support/Papagaio/Models/`, com `ggml-large-v3.bin` (3,1 GB) e `Qwen_Qwen3.5-9B-Q4_K_M.gguf` (6,2 GB).
- **Harness existente (sem commit no `main` em 24/09):** `Scripts/bench-papagaio.sh` + `papagaio-eval bench` (`Bench.swift`, `CasosDeMicroBench.swift`, `CasosDeMacroBench.swift`) e `PapagaioCore/Benchmarks/baseline.json`. Grava só mediana, média e mínimo, sem amostras brutas.
- **Testes:** `./Scripts/testa-papagaio-core.sh` (~216 `@Test`; já contorna o FinderInfo do iCloud no codesign) e os testes do app como na CI (`.github/workflows/ci.yml`: `PAPAGAIO_TEST_MODE=1 xcodebuild test -project Loro.xcodeproj -scheme Loro -destination 'platform=macOS' …`).
- **Leitura obrigatória antes da 1ª rodada:** `docs/analise-performance-2026-09-22/relatorio.md`, `audit/02-achados/A3-performance.md` e `audit/00-mapa.md`. Eles trazem gargalos já medidos (resumidos na seção 7).
- **Números de referência (M5, medianas):** resumo Qwen de 400 trechos ≈ 186–200 s; carga + descarga do Whisper ≈ 1 s; ciclo Qwen com resumo curto ≈ 10 s; AEC ≈ 0,49 s por 5 s de áudio; RTF do Whisper ≈ 0,32 no áudio de 4,3 s.
- **Problemas conhecidos:** `Segmentacao.agrupar` descarta `Trecho.id` (2 falhas pré-existentes em `PipelineTests`); o cancelamento do OAuth Google pode pendurar testes por até 300 s.
- **Máquina:** MacBook Pro M5 (4P + 6E), 24 GB, macOS 27.0, Xcode 27.0 beta, `xctrace` 16. Tem `python3` 3.9 (sem numpy/scipy), `jq`, `ffmpeg`, `afconvert`, `say` (vozes pt_BR: Luciana, Eddy, Flo, Reed, Rocko, Sandy, Shelley, Grandma, Grandpa). Não tem `hyperfine`, `sox` nem `gtimeout`.
- **Cuidado:** existem outras cópias com o mesmo bundle id (`/Applications/Loro.app`, `/Applications/Papagaio.app` e builds Debug no DerivedData). Nunca abra o app pelo nome ou pelo bundle id: use sempre o caminho absoluto da build de perf.

## 2. Regras invioláveis

1. **Só local.** Proibido: CI remota, nuvem, upload, `git push`, PR, `brew`/`pip install`, baixar modelos e rodar `bootstrap-runtimes.sh` (ele baixa da internet; copie os runtimes da árvore principal). Pacotes SwiftPM só pelo `Package.resolved` e pelo cache (`-skipPackageUpdates`, `--skip-update`).
2. **Os dados do usuário são intocáveis.** Não leia nem escreva a biblioteca real (container `com.papagaio.Papagaio`), o iCloud/CloudKit, Contatos, Calendário, Keychain nem as preferências do app real. Teste só com o áudio sintético da seção 3.5, nunca com gravações reais.
3. **Não destrua trabalho.** Na árvore principal, além de ler, só são permitidos os comandos git da Fase 0 (`worktree add`, criar a branch e as tags do loop). Nela não use `reset --hard`, `clean`, `stash` nem `checkout --`, e não troque de branch. `git reset` só é permitido no worktree do loop, nas condições do passo 4.10, para desfazer o commit do experimento em curso, inclusive após retomada. Nada de merge no `main`.
4. **Uma hipótese por experimento**, pequena e reversível. Mudança de infraestrutura (scripts, sonda, fixtures) vai em commit próprio e obriga a refazer a baseline.
5. **Qualidade não é moeda de troca.** Mudança que altera a saída (modelo, quantização, beam/temperatura, limiares de VAD, taps do AEC, gramática, tamanho de contexto, idioma) só entra dentro das tolerâncias da seção 5.4. Ganho grande com perda de qualidade vai para `PROPOSTAS.md`, para o usuário decidir.
6. **Nada pesado roda em paralelo com uma medição**: nem build, nem teste, nem Instruments. Agentes auxiliares, se houver, só leem código.
7. **Não mexa no ambiente do usuário:** sem `sudo`, sem mudar Ajustes do Sistema, sem `defaults write` no domínio do app real e sem matar processos que você não iniciou. Se um Ōmu real estiver gravando ou processando, espere.
8. **Sem microfone e sem som nos alto-falantes**, salvo autorização explícita do usuário no chat.
9. **Não pare para pedir confirmação entre rodadas.** As únicas perguntas permitidas estão nas seções 3.1 (permissão bloqueada) e 3.2 (arquivo duvidoso do harness).
10. **Comando longo não pode travar a sessão.** Builds, macros do Qwen e cenários de 60 min rodam em background (`nohup … > log 2>&1 &`) com timeout, e você acompanha pelo log. Sem `gtimeout`, use `perl -e 'alarm shift; exec @ARGV' <segundos> <comando>` ou um vigia em background.
11. **Só o STOP encerra.** Não marque o objetivo ou a tarefa como concluídos por ganho atingido, backlog vazio, ideias esgotadas, contexto longo ou tempo de execução. Sem boas hipóteses, perfile de novo e gere hipóteses novas.
12. **Todo turno age.** Nunca termine um turno só com texto: um turno sem comandos interrompe a continuação automática do agente (é assim no `/goal` do Codex). Para esperar, use um comando, por exemplo `sleep 300; ./Scripts/perf/ambiente.sh`.

## 3. Fase 0 — preparação (uma vez, idempotente)

Se `~/OmuPerf/estado/ESTADO.md` já existir, pule para a seção 4 e retome dali. A Fase 0 pode levar horas: mantenha um checklist dela no `ESTADO.md` para retomar se a sessão cair. Os commits de infraestrutura também passam pelos portões de teste.

### 3.1 Área de trabalho fora do iCloud

```
~/OmuPerf/
  repo/       worktree git do loop (branch perf/loop-AAAAMMDD)
  build/      DerivedData e scratch do SwiftPM
  apps/       builds de perf: base-sem-traducao.app, aceito/, candidato/
  fixtures/   áudios sintéticos + gabaritos (manifesto com SHA-256)
  runs/       dados brutos por experimento (JSONL, logs, saídas)
  traces/     arquivos .trace do Instruments (com rotação)
  estado/     ESTADO.md, DIARIO.md, experimentos.jsonl, BACKLOG.md, RESUMO.md, PROPOSTAS.md, BASELINE.md
```

Dentro do iCloud, o `fileproviderd` gera ruído nas medições e o FinderInfo quebra o codesign. O estado fica fora do git para que nenhum revert apague o histórico.

Logo no início, confirme que o agente consegue escrever em `~/OmuPerf`, abrir apps com `open`, e rodar `xcodebuild`, `codesign`, `xctrace`, `leaks` e `caffeinate`. Se o sandbox do agente bloquear algum deles, registre no `ESTADO.md` e peça ao usuário para liberar, uma única vez.

### 3.2 Git sem tocar na árvore principal

1. Escolha uma referência sem tradução: use `perf/base-sem-traducao` se a tag existir; caso contrário, use `HEAD` somente depois de confirmar que ele contém `4411410` e que o app não traduz. Crie o worktree com `git -C "<repo>" worktree add -b perf/loop-AAAAMMDD ~/OmuPerf/repo <referência-sem-tradução>`. Não inicie baseline a partir de um commit com tradução.
2. Se o harness ainda estiver sem commit na árvore principal, **copie** (não mova) os arquivos dele para o worktree e faça o commit lá: `chore(perf): harness de benchmark pré-existente`. Confira com `git status --porcelain`. Em 24/09 eram os arquivos de `PapagaioCore/Sources/papagaio-eval/` (`main.swift`, `Bench.swift`, `CasosDeMicroBench.swift`, `CasosDeMacroBench.swift`), `SileroVAD.swift`, `DetectorDeAtividadeDeVoz.swift`, `Scripts/bench-papagaio.sh`, `Scripts/testa-papagaio-core.sh`, `PapagaioCore/Benchmarks/` e `docs/analise-performance-2026-09-22/`. Se outro arquivo modificado parecer parte do harness e você não tiver certeza, pergunte ao usuário.
3. Clone com APFS (`cp -Rc`) os artefatos que ficam fora do git: `PapagaioCore/Frameworks/`, `PapagaioCore/Sources/PapagaioCore/Resources/silero_vad.onnx` e `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/`. Depois rode `xattr -cr` nas cópias.
4. Se ainda não existir, crie a tag `perf/base-sem-traducao` no commit verificado sem tradução. Preserve `perf/original` apenas como histórico; não a use em medições ou rollback. Ao fim da Fase 0, o `git status` da árvore principal tem de estar idêntico ao do início.

### 3.3 Build de perf (sem alterar o projeto)

1. Release com a sonda: `xcodebuild build -project Loro.xcodeproj -scheme Loro -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath ~/OmuPerf/build/dd -skipPackagePluginValidation -skipPackageUpdates CODE_SIGNING_ALLOWED=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OMU_PERF'`.
2. Copie `Ōmu.app` para `~/OmuPerf/apps/<rótulo>/`, troque o `CFBundleIdentifier` para `com.papagaio.Papagaio.perf` e assine ad-hoc de dentro para fora: primeiro os frameworks e dylibs de `Contents/Frameworks`, por último o app com `Config/Papagaio-Perf.entitlements`. Verifique com `codesign --verify --deep --strict`.
3. `Config/Papagaio-Perf.entitlements` é um arquivo novo, só para perf. Ele contém `app-sandbox`, `cs.disable-library-validation`, `get-task-allow` (para `leaks`, `vmmap`, `sample` e `xctrace --attach`), `files.user-selected.read-write`, `files.bookmarks.app-scope`, exceção temporária home-relative de leitura e escrita em `/OmuPerf/` e de leitura em `/Library/Application Support/Papagaio/Models/`. Ele **não** tem iCloud, Sign in with Apple, push, rede, Contatos nem Calendário. Assim a própria sandbox garante que a build de perf não sai do Mac nem enxerga dados pessoais, e o bundle id próprio isola container, preferências e caches.
4. Se algo de CloudKit ou Sign in with Apple for criado no lançamento e quebrar sem o entitlement, desligue esse caminho no modo perf reaproveitando a `PoliticaDeInicializacaoExterna`, sem mudar a build normal.
5. Automatize tudo em `Scripts/perf/build-perf.sh <rótulo>`. Para o core: `swift build -c release --scratch-path ~/OmuPerf/build/spm-<rótulo>`, guardando os produtos inteiros por clone APFS para o A/B do `papagaio-eval`.
6. A primeira abertura depois de cada build é atípica (validação de assinatura, compilação de Core ML e Metal). Registre-a à parte e nunca a use como amostra.

### 3.4 Modo perf dentro do app (sonda)

Tudo fica sob `#if OMU_PERF` (não existe na build normal) e é ligado por `--perf-cenario <nome>`.

- **Isolamento:** `Armazenamento(raiz:)` e o store SwiftData dentro de `--perf-raiz <dir>` (em `~/OmuPerf/runs/…`), serviços externos desligados e modelos lidos de `--perf-modelos`. Preferências e idioma são fixados por argumentos, que não persistem (ex.: `-processamentoAutomatico YES -AppleLanguages '(pt-BR)' -AppleLocale pt_BR`).
- **Eventos** vão em JSONL para o arquivo `--perf-saida`, uma linha por evento com `evento`, `t_ns` (relógio monotônico), hora de parede e dados:
  - início do processo (`sysctl` com `KERN_PROC_PID`), `App.init`, primeiro frame desenhado e "interativo" (biblioteca carregada e main thread livre por 100 ms);
  - início e fim da importação, de cada `PipelineDeArquivo.Fase`, de cada carga ou descarga de modelo e de cada salvamento, e o fim do processamento;
  - a cada 250 ms: `phys_footprint` (`task_info` com `TASK_VM_INFO`), tempo de CPU (`getrusage`) e `thermalState`;
  - um vigia da main thread que registra travadas acima de 50 ms (hitch) e de 250 ms (hang);
  - o pedido de encerramento e o `applicationWillTerminate`;
  - no fim, o dump da saída em JSON (trechos com tempos e falantes, e o resumo) para o portão de qualidade.
- O cenário percorre **os mesmos caminhos do usuário**: a importação chama o mesmo método do arraste e do `fileImporter`, e a navegação muda o mesmo estado da interface. Ao terminar, chama `NSApp.terminate`. Nada de pipeline paralelo.
- Meça uma vez o custo da sonda (build com e sem `OMU_PERF`, abrindo por `open`). Ele tem de ser desprezível.
- Faça um commit próprio (`chore(perf): modo perf e sonda`), com os testes do app verdes.

### 3.5 Fixtures sintéticas com gabarito

`Scripts/perf/gerar-fixtures.sh` gera tudo uma única vez em `~/OmuPerf/fixtures/`, de forma determinística e com manifesto SHA-256:

- **Reuniões em pt-BR** com 2 a 4 vozes (`say -v Luciana`, `Eddy`, `Flo`, `Reed`…), com roteiro realista cheio de decisões e tarefas (para o resumo ter conteúdo), pausas e falas curtas. O gabarito JSON guarda o texto e os turnos (início, fim, falante).
- **Durações:** 30 s, 5 min, 30 min, 60 min e 3 h (esta última só para memória e escala).
- **Todos os formatos que o app aceita:** wav 16 kHz mono, wav 48 kHz estéreo, m4a (AAC e ALAC), mp3, flac, aiff, caf e mp4/mov com trilha de áudio (via `ffmpeg` e `afconvert`).
- **Uma reunião em inglês** (vozes en_US), para verificar que a transcrição e o resumo saem em inglês (sem tradução).
- **Casos de borda:** 0,5 s, 5 min de silêncio, só ruído, arquivo truncado, arquivo de 0 byte e extensão errada.
- **Dois canais** (microfone + sistema) com eco sintético de atraso e atenuação conhecidos, para o caminho de AEC.
- **Bibliotecas-semente base** com 0, 200 e 1.000 conversas sintéticas (só texto), para abertura e busca. Em hipóteses que adiam o decode de palavras, como H02/E004, passe `--seed-palavras-por-trecho N` ao L2 e confirme que todos os trechos têm arrays `palavrasJSON` não vazios antes de medir; um seed text-only não testa esse mecanismo.

### 3.6 Scripts de medição (em `Scripts/perf/`, versionados no branch)

- `ambiente.sh`: faz o pré-voo da seção 5.1 e roda `caffeinate -dims -t 7200`, renovado a cada rodada para não sobreviver ao loop.
- `medir.sh <cenário> <A> <B> <n>`: roda A e B **intercalados** (ABBA…), descarta o aquecimento, aplica timeout por cenário, abre sempre pelo caminho (`open -n -F -W --env … "<app>" --args …`) e só mata o processo que ele mesmo abriu.
- `estatistica.py` (só biblioteca padrão): mediana, p90, MAD, IC95% da razão das medianas por bootstrap, Mann–Whitney unilateral (exato até n = 10) e o veredito por métrica usando o MDE.
- `qualidade.py`: WER contra o gabarito, DER aproximado (quadros de 100 ms com o melhor mapeamento de falantes), comparação exata com a saída de referência e validação do JSON do resumo e das citações.
- `perfil.sh`: `xcrun xctrace record --template '<T>' --launch|--attach …`, `xctrace export` e os frames mais pesados. Templates úteis: App Launch, Time Profiler, SwiftUI, Swift Concurrency, Allocations, Leaks, Animation Hitches, Data Persistence, Metal System Trace, Core ML e File Activity. **Perfil serve para gerar hipóteses, nunca para decidir um A/B.**
- Estenda o `papagaio-eval bench` para gravar as amostras brutas e cobrir as lacunas do relatório: `macro.whisper.transcrever` com a fixture de 5 min, `vad.silero` com o modelo real, resumos curto e longo do Qwen no idioma falado e a contagem de cargas e descargas por pipeline. Não execute o caso de tradução histórico.

### 3.7 Calibração A/A e baseline

1. Rode todos os cenários com A = B = build sem tradução derivada de `perf/base-sem-traducao` (ou da última `perf/aceito-*`, ao recalibrar). O veredito tem de ser NEUTRO em todas as métricas. Se não for, o método ou o ambiente estão ruidosos demais: corrija antes de seguir.
2. O MDE de cada métrica é o maior valor entre o piso da seção 5.3 e 2 × o CV robusto medido no A/A.
3. Teste o determinismo: duas execuções da mesma build geram transcrição e resumo idênticos? A resposta define se o portão de qualidade será "saída idêntica" ou "WER/DER dentro da tolerância".
4. Grave a baseline (todos os cenários e as saídas de referência, com commit e tag sem tradução) em `estado/BASELINE.md` e copie a build inicial para `apps/base-sem-traducao.app` e `apps/aceito.app`.

## 4. A rodada (repita para sempre)

1. **Retome:** leia o `ESTADO.md`, o pré-registro e as últimas entradas do `DIARIO.md`; confira branch, HEAD, diff, builds, testes, amostras e logs em `runs/`, pois o estado pode estar defasado. Depois de uma retomada ou compactação de contexto, releia este arquivo inteiro; nas demais rodadas, releia pelo menos as seções 2 e 4. Se houver experimento sem veredito, reconcilie esses artefatos e retome o portão pendente com os critérios pré-registrados quando estiverem íntegros. Interrupção da sessão, por si só, não é motivo para desfazer código ou descartar amostras válidas. Se não for possível reconstruir o experimento com segurança, registre INCONCLUSIVO e siga o rollback seguro do passo 10.
2. **STOP?** Se `~/OmuPerf/estado/STOP` existir, vá para a seção 9.
3. **Ambiente** (5.1). Se estiver ruim, faça trabalho que não mede (ler código, preparar a próxima hipótese) ou espere com um comando e cheque de novo.
4. **Escolha a hipótese** no `BACKLOG.md` por (impacto × confiança) ÷ esforço. Termine primeiro o experimento já pré-registrado, sem mudar seus critérios retroativamente. Depois, nesta campanha, priorize: (1) pico de RAM por fase, começando pelo resumo do Qwen; (2) pico e tempo do processamento ponta a ponta; (3) abertura e fluidez da interface; (4) energia. Se o backlog estiver fraco, perfile o cenário mais lento e tire hipóteses do topo do perfil. Trate a atribuição ao Qwen como hipótese a confirmar, não como conclusão sem medição.
5. **Pré-registre no `DIARIO.md`, antes de codar:** hipótese, mecanismo (por que deve melhorar), métrica primária, efeito esperado, guardrails, tipo (EXATA = saída idêntica; APROXIMADA = saída muda), risco e forma de validar.
6. **Aplique** a menor mudança que testa a hipótese, no estilo do código: nomes e comentários em português explicando o porquê, Swift 6 sem warnings novos de concorrência. Faça o commit `perf(E###): <resumo>` no worktree e salve o diff em `runs/E###/patch.diff`. Use 60 min como limite para implementar e avaliar a viabilidade da hipótese; builds, portões e medições longas já iniciados seguem até um veredito ou bloqueio real. Se a implementação não for viável, registre INCONCLUSIVO e siga o rollback seguro do passo 10.
7. **Portões de correção.** Qualquer falha dá QUEBROU e leva ao passo 10.
   - A build de perf compila e abre.
   - `testa-papagaio-core.sh --scratch-path ~/OmuPerf/build/spm-testes` e os testes do app (com timeout) passam. O conjunto de falhas não pode crescer em relação à baseline.
   - A saída das fixtures é idêntica à referência (EXATA) ou fica dentro da seção 5.4 (APROXIMADA).
   - Não há crash novo de `Ōmu` nem de `papagaio-eval` em `~/Library/Logs/DiagnosticReports` desde o início da rodada.
8. **Meça** A (`apps/aceito.app`) contra B (candidata .app), intercalados: sempre o nível 1, o nível 2 do cenário-alvo e o nível 3 quando for a vez (seção 6). Uma melhoria no core precisa aparecer no `papagaio-eval` **e** no cenário ponta a ponta correspondente.
9. **Decida** com o `estatistica.py`:
   - **MELHOROU:** a métrica primária melhora com p ≤ 0,05 e efeito ≥ MDE, e nenhum guardrail piora além do próprio MDE. Mantenha; a candidata vira `apps/aceito.app` e ganha a tag `perf/aceito-E###`.
   - **NEUTRO:** desfaça, porque código a mais sem ganho é custo. A exceção é a mudança que só remove ou simplifica código.
   - **PIOROU** ou **QUEBROU:** desfaça.
10. **Desfaça e teste de novo somente após veredito de rejeição ou INCONCLUSIVO irrecuperável:** preserve patch, dados e logs; confirme que HEAD é o commit exclusivo do experimento e confira `git status --porcelain`. Use `git reset --hard HEAD~1` apenas se a árvore estiver limpa e não houver trabalho alheio a perder; caso contrário, preserve as edições alheias e reverta somente a mudança do experimento. Confira que o código voltou à última tag `perf/aceito-*` (ou `perf/base-sem-traducao`), recompile, rode os portões e faça um A/A rápido da recompilação contra `apps/aceito.app`. Se o A/A não der NEUTRO, investigue a deriva antes de continuar.
11. **Registre:** no `DIARIO.md`, a tabela A × B (mediana, p90, n, razão, IC95% e p), os guardrails, a decisão e o que aprendeu; uma linha no `experimentos.jsonl`; no `ESTADO.md`, a baseline atual, os contadores e as próximas 5 hipóteses; no `BACKLOG.md`, a hipótese marcada e as ideias novas. Hipótese rejeitada só volta com um fato novo. Termine a rodada com uma linha de progresso no chat: rodada, hipótese, veredito e ganho acumulado.
12. **Próxima rodada:** emende direto, com 1–2 min de `sleep` de resfriamento entre blocos pesados. No Claude Code sob `/loop`, faça uma rodada por disparo.

## 5. Protocolo de medição

### 5.1 Controle de ruído (antes de cada bloco; registre junto com os dados)

- Mac na tomada (`pmset -g batt`), Low Power Mode desligado, sem aviso em `pmset -g therm` e com `thermalState` nominal na sonda.
- Carga baixa (`uptime`, `top -l 1`): sem Xcode indexando, `swift build`, Time Machine, `mds_stores` ou `fileproviderd` pesado, e sem outro Ōmu processando.
- Memória sem pressão (`memory_pressure -Q`) e swap parado (`sysctl vm.swapusage`). Swap crescendo durante a execução invalida a amostra.
- Tela ligada e desbloqueada. Sem tela, o SwiftUI não desenha e o "primeiro frame" perde o sentido.
- A inatividade da sessão não é gate para a campanha E005: não aguarde `HIDIdleTime` chegar a 120 s. Registre esse valor como contexto e mantenha os gates de energia, térmica, espaço, memória, swap, CPU ociosa e processos concorrentes.
- Reuse amostras limpas da baseline aceita quando app, cenário, hash da fixture, configuração e instrumentação forem os mesmos. Não repita o lado A só para reconfirmar E004; meça apenas E005 até atingir o n válido e combine os JSONL antes da estatística. Recolha A nova somente quando a baseline estiver ausente, insuficiente, contaminada ou invalidada por mudança relevante de fixture, configuração, instrumentação, macOS ou hardware. Quando medir ambos os lados na mesma rodada, mantenha a ordem ABBA.
- Pelo menos 30 GB livres. O resfriamento entre blocos é adaptativo: 60 s após duas amostras limpas nominais sem crescimento de swap, 90 s com telemetria incompleta e 120 s com aviso térmico. Esse intervalo é térmico, não uma espera por inatividade.
- O Silero VAD é recorrente: passe cada quadro de 32 ms em sequência, inclusive quadros abaixo do limiar de energia; use energia para vetar fala após a inferência. O corte padrão só ocorre após 3 s sem fala detectada para não fragmentar pausas de frase. Mudança nesse caminho invalida os resultados de transcrição, tempo e memória dos cenários P1/P2/P3/P5/P6; reconstrua A/B e valide a saída.

Amostra coletada fora dessas condições é marcada como `contaminada` e refeita.

### 5.2 Cenários

O nível 1 roda em toda rodada (portão rápido, ~15 min). O nível 2 roda quando o cenário é alvo da hipótese. O nível 3 é periódico (seção 6).

| ID | Cenário | Métricas principais | Nível · n por lado |
|---|---|---|---|
| L1 | Abrir o app (biblioteca vazia) e fechar | TTFF, TTI, pico e CPU nos 5 s iniciais | 1 · 15 |
| L2 | Abrir com 200 e com 1.000 conversas | TTI, pico | 2 · 10 |
| L3 | Primeira abertura depois de cada build | TTFF, TTI | só registro |
| Q1 | Fechar (ocioso e logo após processar) | do pedido de encerramento até o processo sumir | 1 · 10 |
| I1 | Importar cada formato (30 s e 60 min) | até a conversa aparecer; pico | 2 · 5 |
| P1 | Processar 30 s de ponta a ponta | total, tempo por fase, RTF, pico, CPU, hangs | 1 · 5 |
| P2 | Processar 5 min | idem | 2 · 5 |
| P3 | Processar 60 min (3 h só para memória) | idem + crescimento de memória | 3 · 3 |
| P4 | Fila de 3 arquivos importados juntos | total, cargas e descargas de modelo | 2 · 3 |
| P5 | Reunião em inglês (sem tradução) | total; transcrição e resumo em inglês | 3 · 3 |
| P6 | Processar com a janela em segundo plano | total (efeito do App Nap) | 3 · 3 |
| P7 | Dois canais com eco (gravação sintética injetada no modo perf ou via `papagaio-eval`) | etapa de AEC, pico | 2 · 3 |
| U1 | Navegar por Biblioteca, Tarefas, Mídias, Configurações e Detalhe | tempo até desenhar, hitches | 2 · 10 |
| U2 | Digitar uma busca na biblioteca de 1.000 | latência por tecla, hangs | 2 · 10 |
| U3 | Detalhe de reunião longa tocando por 30 s | CPU, hitches, pico | 2 · 5 |
| O1 | Ocioso por 60 s depois de abrir | CPU %, wakeups (`top -stats pid,cpu,idlew`) | 3 · 5 |
| S1 | Estresse: 20× abrir e fechar, 10 importações seguidas, fixtures de borda | crash, erro tratado, memória crescendo, `leaks` | 3 · 1 |
| C1 | `bench-papagaio.sh --so-micro` | casos micro | 1 · padrão |
| C2 | `bench-papagaio.sh` completo (macros de Whisper e Qwen) | casos macro | 2 quando for alvo · 3 |
| G1 | Gravação real com o sistema tocando uma fixture | custo do callback do tap, AEC real | só com autorização |

Para S1, preserve o log bruto de `/usr/bin/leaks`. Compare as raízes atribuíveis ao app; registre separadamente ciclos XPC cuja raiz identifica um serviço externo sem processo, como `com.apple.linkd.autoShortcut`. Não atribua variações desses ciclos do macOS à build candidata. Falta de relatório, raiz não interpretável ou timeout do app continua reprovando/inconclusivo pelo gate absoluto.

Definições: TTFF é o tempo do início do processo até o primeiro frame; TTI é o tempo até o app ficar interativo; RTF é o tempo de processamento dividido pela duração do áudio; pico do app é o maior `phys_footprint`.

Em hipóteses de RAM do Qwen, registre o pico Core (RSS em Q2) e o pico por fase no app (amostras `phys_footprint` entre os eventos de início/fim da fase em P1/P2). Inclua carga/residência do modelo, resumo e processamento total. Se a amostragem não permitir atribuir o pico a uma fase, melhore a instrumentação antes de declarar um ganho. Não use RSS e `phys_footprint` como valores intercambiáveis.

### 5.3 Pisos de MDE e tetos

- Abrir e fechar: 3% (ou 15 ms, o que for maior). Processamento total e RTF: 2%. Fase isolada: 3%. Pico de memória: 3%. Micro-benchmarks: 5%.
- Hang (> 250 ms) na main thread: qualquer aumento é regressão.
- Tetos absolutos: pico abaixo de 16 GB (num Mac de 24 GB, para não entrar em swap) e nenhum hang novo durante o processamento.

### 5.4 Tolerâncias de qualidade (mudanças APROXIMADAS)

- WER ≤ baseline + 0,5 p.p. em cada fixture; DER ≤ baseline + 1 p.p.
- Resumo: JSON válido, todas as citações válidas (`ValidacaoDeCitacoes`) e nenhuma seção faltando. Para mudanças de pesos/quantização que alterem o texto, registre antes do teste um portão semântico sobre fatos e ações do gabarito. Validade estrutural e citações, sozinhas, não provam fidelidade semântica; sem um portão confiável, não aceite a variante.
- AEC: supressão de eco (ERLE) no máximo 1 dB pior.
- Timestamps dos trechos com desvio ≤ 100 ms.

Mudança fora dessas tolerâncias não entra. Ela vira uma proposta em `PROPOSTAS.md`, com os números.

## 6. Tarefas periódicas

- **A cada 5 rodadas:** nível 3 completo, comparação intercalada `base-sem-traducao` × `aceito` (o ganho acumulado honesto) e atualização do `RESUMO.md`.
- **A cada 10 rodadas:** perfilar de novo os 3 cenários mais lentos e repriorizar o backlog; limpar traces (manter os 20 mais recentes) e binários antigos, sem apagar JSONL nem diários.
- **5 vereditos seguidos sem MELHOROU:** troque de área, parta para hipóteses estruturais (algoritmo, arquitetura, o que roda e quando) ou melhore a medição, porque talvez a métrica não enxergue o efeito.
- **A cada 10 rodadas, se já houver permissão de automação da interface** (AppleScript/System Events ou computer use), faça um teste de fumaça pelo caminho real: abrir, importar pelo painel e por arraste, processar, abrir o detalhe, tocar e fechar. Isso prova que o fluxo funciona; não mede nada. Sem permissão, pule e anote.

## 7. Backlog inicial

São pistas dos relatórios de 22 e 23/09. Arquivos e linhas podem ter mudado: confirme no código atual antes de usar.

| ID | Hipótese | Onde | Alvo | Tipo |
|---|---|---|---|---|
| H01 | Um `MotoresLocais` por `Biblioteca`, com residência por TTL e descarga sob pressão de memória. Hoje cada operação cria um novo e recarrega o Whisper (~1 s) e o Qwen (~10 s) | `Biblioteca.swift`, `MotoresLocais.swift`, `CicloDeVidaDeModelos.swift` | P4, P1, ditado | exata |
| H02 | Na abertura, carregar só os metadados da biblioteca e buscar trechos e palavras (`palavrasJSON`) sob demanda. Decodificar tudo pode custar segundos com centenas de conversas | `SwiftDataRepository`, `Biblioteca`, `ContentView.abrir()` | L1, L2 | exata |
| H03 | Tirar do caminho do primeiro frame o que não aparece na tela: migrações no `App.init` (`CamposDoCartao.ligarCamposNovos`, `MigracaoDeStatusDeTarefas`), carga de imagens e cor dominante, inicializadores dos runtimes C/C++ (confirmar com o App Launch) | `PapagaioApp.swift`, `ContentView` | L1 | exata |
| H04 | `salvar` incremental no SwiftData: não apagar e recriar todos os trechos, não re-encodar `palavrasJSON` sem mudança e evitar a 2ª gravação completa | `SwiftDataRepository.swift:40-120`, `PipelineDeArquivo.swift:160-190` | P1–P3 (fase salvando) | exata |
| H05 | AEC em blocos e fora do pool cooperativo. Hoje ele materializa os dois canais inteiros e grava um PCM intermediário | `PipelineDeArquivo.aplicarAEC`, `CanceladorDeEco` | P7, pico em P3 | exata |
| H06 | AEC block-LMS com vDSP (hoje ≈ 10× mais lento que o tempo real) | `CanceladorDeEco.swift:58-103` | `aec.processarBlocos` | aproximada (ERLE) |
| H07 | Em `ContextoLlama.completar`: medir prefill × decode, não limpar o KV cache quando o reprompt é prefixo, revisar batch/ubatch e flash attention | `ContextoLlama.swift`, `QwenEngine.swift` | `macro.qwen.resumir` | exata se a saída for idêntica |
| H08 | ~~Tradução com lotes maiores~~ — descartada: o app não traduz mais | — | — | — |
| H09 | Whisper com threads ajustadas ao M5 (4P + 6E), flash attention e GPU. O encoder em Core ML exige modelo novo: só como proposta | `ContextoWhisper.swift`, `WhisperEngine.swift` | `macro.whisper.transcrever`, P2 | exata ou aproximada |
| H10 | Diarizar o microfone enquanto o sistema ainda transcreve, sem dois Whisper simultâneos | `PipelineDeArquivo.swift:127` | P7 | exata |
| H11 | Silero VAD com inferência em lote e menos cópias de tensor | `DetectorDeAtividadeDeVoz.swift:142-160`, `SessaoOnnx.swift:132-153` | `vad.*` | exata |
| H12 | `ProcessInfo.beginActivity(.userInitiated)` durante o processamento, para o App Nap não frear o app em segundo plano | pipeline no app | P6 | exata |
| H13 | Busca e listas derivadas com cache por geração de invalidação, debounce e texto normalizado pré-computado | `BibliotecaHomeView.swift:338-432`, `TarefasView`, `MidiasView` | U2, U1 | exata |
| H14 | No detalhe, cachear as falas agrupadas e o mapa de falantes (hoje decodificado por linha a 10 Hz) | `ArquivoDetalheView`, `FalantePreservadoParaTrecho`, `FalasDaConversa` | U3 | exata |
| H15 | Cópias de arquivo e prévias de imagem fora do `@MainActor`, com `NSCache` | `MidiasDaConversaViewModel`, `PreviaDoAnexoDeMidia`, `CartaoDeConversa` | U1, hangs | exata |
| H16 | No callback de tempo real do System Tap, calcular RMS e pico numa passada só (vDSP) | `SystemAudioTap.swift:451-471`, `NivelAudio` | micro novo | exata |
| H17 | Alinhamento de falantes por varredura ordenada e `FalasDaConversa.canalUniforme` com dicionário | `AlinhamentoDeFalantes.swift:77-141`, `FalasDaConversa.swift:156-161` | P3 (3 h) | exata |
| H18 | `PromptDeEntidades` sem enumerar todos os contatos a cada arquivo (índice em cache; medir com lista sintética) | `PromptDeEntidades.swift` | micro novo | exata |
| H19 | Download de modelos em blocos (hoje byte a byte), testado só com servidor HTTP local (`python3 -m http.server`) | `DownloadDeModelos.swift:150-161` | micro novo | exata |
| H20 | Outbox do CloudKit e snapshot do Calendar sem reescrever o JSON inteiro a cada operação | `FilaPersistenteCloudKit`, `EstadoDasReunioesCalendar` | micro | exata |
| H21 | RAM do Qwen: após confirmar a atribuição do pico por fase, avaliar uma variante local e runtime-compatível de menor precisão/quantização dos pesos, sem combinar outras mudanças. Comparar RSS em Q2 e `phys_footprint`/pico total em P1/P2; não re-quantizar um modelo já quantizado sem suporte confirmado. Se os pesos-fonte ou um portão semântico confiável não estiverem disponíveis, registrar a dependência em `PROPOSTAS.md` | modelo Qwen local, `ContextoLlama.swift`, `QwenEngine.swift` | Q2, P1/P2 | aproximada, com portão semântico pré-registrado |
| — | Bug: `Segmentacao.agrupar` descarta `Trecho.id` (2 testes). É correção, não performance: anote e só corrija, em commit separado, se bloquear um portão | `Segmentacao.swift:31-49` | — | — |

Na revisão ampla, procure também os suspeitos de sempre: trabalho pesado em `body` e em propriedades computadas do SwiftUI; invalidação larga de `@Observable`; I/O síncrono ou JSON na main thread; `DateFormatter`, regex ou `NumberFormatter` criados em laço; cópias grandes de `[Float]` e `Data`; `await` dentro de laço quente; chamadas C bloqueando o pool cooperativo; polling por timer; imagens decodificadas no tamanho original.

## 8. Formato dos registros

`DIARIO.md` tem uma seção por experimento:

```
## E### — H## <título> — MELHOROU | NEUTRO | PIOROU | QUEBROU | INCONCLUSIVO
Quando · commit · duração da rodada
Pré-registro: hipótese · mecanismo · métrica primária · efeito esperado · tipo · risco
Mudança: arquivos e resumo (patch em runs/E###/patch.diff)
Portões: testes (falhas × baseline) · qualidade (idêntica ou WER/DER) · crashes
Resultado: tabela A × B (mediana, p90, n, razão B/A, IC95%, p) + guardrails + condições do ambiente
Decisão e motivo · Aprendizado · Próximas ideias
```

`experimentos.jsonl` tem uma linha por experimento: `{id, hipotese, commit, tipo, metrica_primaria, a:{mediana,p90,n}, b:{mediana,p90,n}, razao, ic95, p, guardrails, veredito, inicio, fim}`.

`ESTADO.md` guarda: fase (com o checklist da Fase 0), commit e tag aceitos, tabela da baseline atual × `perf/base-sem-traducao`, MDE por métrica, contadores (rodadas, melhorou, neutro, piorou, quebrou), experimento em andamento, próximas 5 hipóteses e observações do ambiente.

## 9. Parar, pausar e reportar

- **STOP:** termine o passo atual com segurança. Se houver experimento sem veredito, preserve o commit e os artefatos, registre o portão pendente e não promova a candidata a `aceito`; não desfaça apenas porque o loop parou. Atualize o `RESUMO.md` e o `ESTADO.md` e encerre o `caffeinate`. Só então marque o objetivo como concluído.
- **Pausar sem parar** quando o Mac estiver na bateria, com aviso térmico, com o usuário usando o Mac pesado, com menos de 30 GB livres ou com um Ōmu real processando. Use a pausa para ler código e preparar hipóteses, ou espere com `sleep` e cheque de novo.
- **O `main` mudou?** Não integre por conta própria. Se o usuário pedir, faça o merge no worktree e refaça a calibração A/A e a baseline.
- **Avise o usuário no chat** só quando um cenário principal ganhar ≥ 10% num experimento aceito, quando algo exigir decisão dele (`PROPOSTAS.md`) ou quando o STOP terminar.
- **`RESUMO.md`** (a cada 5 rodadas e no STOP): ganho acumulado por cenário (`perf/base-sem-traducao` × aceito, medido intercalado), mudanças aceitas com seus commits, o que foi rejeitado e por quê, propostas pendentes, bugs achados pelo caminho e como revisar a branch `perf/loop-…` para levar ao `main`.
- Se o usuário escrever no chat, responda e depois retome o loop.

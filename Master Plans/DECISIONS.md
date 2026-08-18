# DECISIONS.md — Papagaio

Registro de decisões de arquitetura e escopo. Uma entrada por decisão: o que foi
decidido, o que foi descartado, e por quê.

Formato: `D-<passo>.<n>`. Decisões tomadas antes de escrever código ficam em `D-0.x`.

---

## Ambiente auditado — 2026-07-30

Levantado antes de decidir qualquer coisa. São fatos medidos, não premissas.

| Item | Valor | Consequência |
|---|---|---|
| macOS | 27.0 (build 26A5388g) | Acima do mínimo de 26+. OK. |
| Chip | Apple M5 | Apple Silicon. OK. |
| RAM | 24 GB (25.769.803.776 B) | Passa o portão de 18 GB do modo IA Local. |
| Swift | 6.4 (swiftlang-6.4.0.27.1), target `arm64-apple-macosx27.0.0` | Suporta strict concurrency `complete`. |
| `FoundationModels.framework` | Presente em `/System/Library/Frameworks` | API de sumarização disponível no SO. |
| `Speech.framework` | Presente em `/System/Library/Frameworks` | API de transcrição disponível no SO. |
| **Xcode** | **Ausente** | **Bloqueio do Passo 1.** Ver R-1 abaixo. |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` | Só CLT. `xcodebuild` não existe. |

Saída real:

```
$ sw_vers
ProductName:		macOS
ProductVersion:		27.0
BuildVersion:		26A5388g

$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory '/Library/Developer/CommandLineTools' is a command line tools instance

$ ls -d /Applications/Xcode*.app
(nenhum resultado)

$ swift --version
swift-driver version: 1.168.5 Apple Swift version 6.4 (swiftlang-6.4.0.27.1 clang-2100.3.27.1)
Target: arm64-apple-macosx27.0.0

$ system_profiler SPHardwareDataType | grep -E "Chip|Memory"
      Chip: Apple M5
      Memory: 24 GB

$ ls -d /System/Library/Frameworks/FoundationModels.framework
/System/Library/Frameworks/FoundationModels.framework
```

---

## D-0.1 — Posicionamento da v1: call online é o caso principal

**Decidido:** a v1 se posiciona para **reunião online**, e portanto **Core Audio
Process Taps entra na v1**. Gravar só o microfone não atende o caso de uso escolhido.

**Descartado:**

- *Presencial + importação como caminho principal* — risco de cronograma zero, mas
  exclui o caso de uso que o produto quer atender. Rejeitado por posicionamento.
- *Só importação, sem gravar* — o app deixaria de ser gravador e viraria processador
  de arquivo.

**Por quê:** com fone de ouvido e só microfone, o interlocutor não é gravado — o
resultado é um monólogo. Com alto-falante, ele entra com eco e WER alto. Nenhum dos
dois é um app de reunião online defensável.

**Isto sobrepõe uma restrição do prompt mestre.** A seção CONTEXTO diz literalmente
"Na v1 o app grava apenas o microfone. Sem Core Audio Process Taps." A decisão 0.1
revoga essa linha. Consequências que passam a valer:

1. `AVAudioEngine` **não funciona** apontado para aggregate device com tap. Setar
   `kAudioOutputUnitProperty_CurrentDevice` retorna `noErr` e o engine segue lendo o
   input default **em silêncio** — falha silenciosa, o pior tipo. O caminho é
   `AudioHardwareCreateProcessTap` (`CATapDescription`) →
   `AudioHardwareCreateAggregateDevice` → `AudioDeviceCreateIOProcIDWithBlock` direto.
2. O PID do próprio Papagaio precisa ser **excluído** do tap, senão o playback do app
   volta para dentro da gravação.
3. TCC separado: `NSAudioCaptureUsageDescription`.
4. A API aplica um filtro de reconstrução na ingestão que nenhum app desliga.
   Irrelevante para ASR; impede prometer "qualidade de estúdio".
5. O Passo 2 deixa de ser "tap no `inputNode`" e passa a ter **dois caminhos de
   captura** (microfone + processo), com mixagem das duas fontes antes do
   arquivamento. Isso é trabalho novo, não descrito no Passo 2 original.

**Aberto (R-2):** distribuição de Process Taps pela Mac App Store precisa ser
confirmada antes de investir no caminho. Não tenho essa confirmação e não vou afirmar
nem que passa nem que é barrado.

---

## D-0.2 — Escopo da v1: pipeline completo, com equipe e com IA Local

**Decidido:** a v1 entrega gravação, transcrição, segmentação, resumo, persistência,
busca, player com navegação por trecho, exportação Markdown, login de perfil,
**espaços de equipe** e **modo IA Local** (WhisperKit + Qwen2.5-14B). Ou seja, os
Passos 1 a 13 inteiros, sem corte.

**Descartado:**

- *Passos 1–11, individual completo* — deixaria equipe e IA Local para depois.
- *Passos 1–10, sem Sign in with Apple.*
- *Núcleo mínimo (1–4, 9, 10)* — sem o Passo 5 não há número nenhum sobre qualidade.

**Por quê:** decisão do usuário, tomada com as três alternativas e seus custos à vista.

**Consequência declarada:** a ordem de corte que o prompt mestre define
(equipe → IA Local → FTS5 → waveform) fica **vazia**. Não há folga planejada. O prompt
também diz, sobre puxar Process Taps para a v1: *"corte outra coisa no lugar — não
some escopo."* D-0.1 mais D-0.2 somam escopo nos dois eixos ao mesmo tempo. Registrado
como risco R-3, não como impedimento.

### D-0.2.a — Qwen2.5-14B: formato do modelo

O escopo pedido nomeia `Qwen2.5-14B-Q5_K_M`. **`Q5_K_M` é quantização GGUF**, formato
do llama.cpp — e llama.cpp cru, Ollama e invocação de binário externo estão
descartados da stack, além de subprocesso não rodar sob App Sandbox. O `QwenSummarizer`
do InterviewLab chamava `llama-cli` exatamente assim, e é por isso que aquela camada
não sobrevive à premissa de Mac App Store.

**Assunção adotada até você confirmar:** o modelo é **Qwen2.5-14B-Instruct em formato
MLX**, carregado via MLX Swift (SPM, sem bridging C++), não o GGUF Q5_K_M. A escolha
entre quantização 4-bit (~8 GB) e 8-bit (~15 GB) fica para o Passo 13, decidida com
medição, não com estimativa.

Se a intenção era mesmo manter o `.gguf` Q5_K_M já em disco, isso **muda a stack** e
precisa ser dito antes do Passo 13 — não é um detalhe de configuração.

### D-0.2.b — Whisper: WhisperKit, não whisper.cpp

"Whisper" no escopo é **WhisperKit** (Swift/SPM, Core ML na ANE), não whisper.cpp cru,
que está explicitamente descartado. O portão de disco do preflight será calibrado com
o tamanho **real dos artefatos Core ML do WhisperKit**, não com os 3,09 GB do
`ggml-large-v3.bin`.

---

## D-0.3 — Espaços de equipe entram na v1

**Decidido:** sim. O Passo 12 executa. CloudKit puro — `CKSyncEngine` + `CKShare` em
custom zone.

**Descartado:**

- *Cortar* — era a recomendação da skill `papagaio-persistence-sync`, que classifica
  esta feature como a de **pior relação valor/risco do projeto**.
- *Arquitetar agora, implementar depois* (stub de `CloudKitRepository`).
- *SwiftData + CloudKit* — **não é uma opção**, e não foi descartada por preferência:
  SwiftData com CloudKit suporta exclusivamente a private database. Sem `CKShare`,
  sem colaboração. A API não existe. Registros na zona default também não são
  compartilháveis — sharing exige custom zone.

**Por quê:** decisão do usuário.

**Consequências:**

1. Dois stores por trás de `ArquivoRepository`: `SwiftDataRepository` (individual) e
   `CloudKitRepository` (equipe).
2. Identidade de sync é `CKContainer.default().userRecordID()`, **não** o
   `userIdentifier` do Sign in with Apple. O usuário pode estar logado no app com um
   Apple ID e no iCloud do sistema com outro — isso precisa ser detectado e avisado.
3. `accountStatus() == .available` checado **antes** de oferecer o espaço de equipe.
4. Modelagem do SwiftData já dentro das restrições do CloudKit: tudo opcional ou com
   default, sem `@Attribute(.unique)`, relações opcionais com `inverse`. Migração de
   schema com dados já sincronizados é o pior lugar possível para estar.
5. `QuotaExceeded` tratado sem perda de dado local — sync é conveniência, não
   pré-requisito.
6. O teste de aceite exige **duas contas iCloud reais em duas máquinas**. Precisa ser
   providenciado antes do Passo 12; não dá para simular.

---

## D-0.4 — Base de código: projeto novo, InterviewLab intacto

**Decidido:** o workspace `Papagaio` nasce do zero. O `InterviewLab` continua no
repositório, funcionando, sem alteração.

**Descartado:**

- *Converter o InterviewLab no lugar* — herdaria o `.xcodeproj` já configurado, mas
  arrastaria `CommandRunner.swift`, `WhisperCppRunner.swift` e `QwenSummarizer.swift`,
  que precisam ser apagados de qualquer forma.
- *Arquivar o InterviewLab* — perderia a referência viva.

**Por quê:** o InterviewLab roda `whisper-cli` e `llama-cli` como subprocesso via
`CommandRunner.swift`. Isso não é apenas "stack antiga" — **processo externo não roda
sob App Sandbox**, então nenhuma linha dessa camada sobrevive à premissa da Mac App
Store. Mantê-lo intacto custa zero e preserva duas coisas úteis: uma referência de
comparação e uma fonte de áudios reais em PT-BR para o corpus do Passo 5.

**Consequência:** o repositório passa a ter dois projetos. `InterviewLab/` é código
legado de referência, **não é o código vivo**. Nada do Papagaio deve importar dele.

---

## Ambiente auditado — 2026-07-30 (sessão 2) — decisão de modelos e distribuição

Esta rodada resolve R-4 e o conflito entre D-0.2.a/D-0.2.b (que assumiam
WhisperKit/MLX pendentes de confirmação) e o pedido explícito do usuário:
**manter os modelos que já estão em uso no código** (`WhisperCppRunner.swift`,
`QwenSummarizer.swift`), com Mac App Store permanecendo obrigatória.

## D-0.5 — Modelos confirmados: Whisper large-v3 + Qwen2.5-14B-Q5_K_M

**Decidido:** os modelos do Papagaio são os mesmos já usados no `InterviewLab`:
**Whisper large-v3** (GGUF, `whisper.cpp`) para transcrição e
**Qwen2.5-14B-Instruct-Q5_K_M** (GGUF, `llama.cpp`) para sumarização. Isto
revoga a assunção D-0.2.a/D-0.2.b (formato MLX / WhisperKit).

**Descartado:**

- *WhisperKit + MLX Swift* — eram uma assunção pendente de confirmação (R-4),
  não uma decisão. Trocariam os pesos GGUF já escolhidos por conversões Core ML
  diferentes, sem necessidade — o usuário já validou estes modelos.
- *`SpeechAnalyzer` + `FoundationModels` como v1* — só faziam sentido como
  caminho "zero download" com qualidade inferior. `Private Cloud Compute`, que
  elevaria o teto de qualidade do modelo on-device da Apple, não lança a tempo
  do prazo. Sem PCC, o `FoundationModels` fica preso a ~3B/4k tokens — pior que
  os modelos já escolhidos, sem nenhuma vantagem de prazo real (o download dos
  pesos GGUF já era exigido de qualquer forma pelo modo IA Local).

**Por quê:** decisão do usuário, resolvendo R-4.

**Consequência:** não existe mais "modo Apple vs. modo Local". Existe uma
engine só. O conceito inteiro de toggle "IA Local" desaparece — ver D-0.7.

## D-0.6 — Resolução do conflito sandbox vs. subprocess: linkagem, não CLI

**Decidido:** `whisper.cpp` e `llama.cpp` são **linkados como biblioteca**
(`Package.swift` oficial de cada projeto, ou XCFramework) dentro dos targets
`Papagaio`/`PapagaioCore`. Chamada in-process via `whisper_context`/
`llama_context`, cada um protegido por um `actor` (não são thread-safe).

**Descartado:**

- *Manter `CommandRunner.swift` + `Process()` apontando para `whisper-cli`/
  `llama-cli` do Homebrew* — é o que o `InterviewLab` faz, e é exatamente por
  isso que essa camada não sobrevive à Mac App Store (D-0.4). App Sandbox não
  permite invocar um binário arbitrário fora do container; não existe
  entitlement que libere isso. Não é uma questão de interpretação de revisor —
  é limite técnico do sandbox.
- *Abrir mão da Mac App Store para manter subprocess* — o usuário confirmou que
  a Mac App Store continua obrigatória.

**Por quê:** dá para manter exatamente os mesmos pesos GGUF sem manter o padrão
de subprocess. O que muda é só a forma de execução, não o modelo.

**Consequência:**

1. `CommandRunner.swift` não é portado para o Papagaio. Nenhuma linha dele
   sobrevive — nem como referência de implementação, só como prova de que os
   modelos escolhidos produzem boa qualidade (o que já foi demonstrado no
   arquivo de teste `entrevista-2026-07-27T20-16-57Z.md`).
2. Build do Papagaio passa a depender de compilar `whisper.cpp`/`llama.cpp` a
   partir do fonte (CMake + Metal) ou de um XCFramework pré-compilado — isso
   entra no Passo 0/1 como pré-requisito de toolchain.
3. Guideline 2.5.2 (R-6) continua se aplicando do mesmo jeito que antes: os
   pesos `.gguf` são dados baixados após a instalação, não código executável
   embarcado. A biblioteca (código) vai dentro do bundle, compilada — isso é
   normal e não é o que a guideline restringe.

## D-0.7 — Fim do modo dual (Apple vs. Local); RAM é piso, não degradação

**Decidido:** com D-0.5 e D-0.6, não há mais segunda engine. O preflight de
hardware (RAM ≥ 18 GB, disco ≥ 20 GB) deixa de ser gate de um "modo avançado
opcional" e passa a ser **requisito mínimo do app**. Um Mac abaixo do piso não
degrada para outra engine — bloqueia a funcionalidade com mensagem clara.

**Descartado:**

- *Cadeia de fallback para `FoundationModels` sob OOM/térmico/RAM insuficiente*
  — não existe mais engine Apple para a qual cair. As skills antigas
  (`papagaio-engine-selection`, `papagaio-summarization`) descreviam esse
  fallback; foi removido na reescrita.

**Por quê:** consequência direta de D-0.5. Registrado como risco novo, R-7.

## D-0.8 — Sem v1/v2: todo o escopo é uma entrega única

**Decidido:** reforça D-0.2. O prompt mestre reescrito (`PROMPT-MESTRE.md`,
v4) remove a seção "Ordem de corte" e qualquer framing de "fase 2". Os Passos
0–13 são sequenciais por dependência técnica (não dá para sumarizar antes de
transcrever), não por prioridade de produto a ser cortada.

**Descartado:**

- *Manter a ordem de corte (equipe → IA Local → FTS5 → waveform) como guia de
  escopo* — contradiz "aplicar tudo de uma vez". O risco de cronograma
  (R-3) continua registrado, mas como risco aceito, não como lista de features
  a adiar.

**Por quê:** decisão explícita do usuário.

---

## Passo 0 — Reauditoria de ambiente (sessão 3, 2026-07-30)

Reconfirmação exigida pelo Passo 0 antes de qualquer commit. Fatos medidos nesta
sessão, não copiados da auditoria anterior.

| Item | Valor | Portão | Estado |
|---|---|---|---|
| macOS | 27.0 (26A5388g) | ≥ 26 | ✅ |
| Chip | Apple M5 (MacBook Pro) | Apple Silicon | ✅ |
| RAM | 24 GB (25.769.803.776 B) | ≥ 18 GB (Passo 3) | ✅ |
| Disco livre | 401 GB | ≥ 20 GB (Passo 3) | ✅ |
| Swift | 6.4, target `arm64-apple-macosx27.0.0` | strict concurrency `complete` | ✅ |
| SDKs (CLT) | `MacOSX27.0.sdk`, `MacOSX26.sdk` | SDK de macOS presente | ✅ |
| `ggml-large-v3.bin` | 3.095.033.483 B | peso de transcrição | ✅ em disco |
| `Qwen2.5-14B-Instruct-Q5_K_M.gguf` | 10.508.873.856 B | peso de resumo | ✅ em disco |
| **CMake** | **4.4.1** | build de `whisper.cpp`/`llama.cpp` | ✅ **instalado nesta sessão** |
| **Xcode** | **27.0 beta (27A5194q)**, em `~/Downloads/Xcode-beta.app` | `xcodebuild`, target de app, entitlements | ✅ **R-1 resolvido** |
| **Metal Toolchain** | **27A5194o** | backend Metal dos dois runtimes | ✅ **baixada nesta sessão** |
| `xcode-select -p` | `/Library/Developer/CommandLineTools` | — | ⚠️ ver D-0.9 |

Saída real:

```
$ sysctl -n hw.memsize
25769803776

$ df -g /System/Volumes/Data | tail -1 | awk '{print $4" GB livres"}'
401 GB livres

$ cmake --version | head -1
cmake version 4.4.1

$ mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"
/Applications/Xcode-beta.app

$ DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer xcodebuild -version
Xcode 27.0
Build version 27A5194q

$ xcodebuild -downloadComponent MetalToolchain
Done downloading: Metal Toolchain 27A5194o.

$ xcrun metal -c t.metal -o t.air
OK: shader compilou -> 3360 bytes

$ xcrun swift build          # pacote SwiftPM com swiftLanguageMode(.v6)
Build complete! (3,82 seg)

$ ls -la ~/Documents/InterviewLab/Models
-rw-r--r--  10508873856 Jul 24 11:37 Qwen2.5-14B-Instruct-Q5_K_M.gguf
-rw-r--r--   3095033483 Jul 27 15:04 ggml-large-v3.bin
```

**Achado desta reauditoria:** o compilador `metal` não vem com as Command Line
Tools, e no Xcode 27 **também não vem dentro do app** — é um componente baixado à
parte (805 MB) via `xcodebuild -downloadComponent MetalToolchain`. Sem ele,
`xcrun metal` falha com *"missing Metal Toolchain"*. Como `whisper.cpp` e
`llama.cpp` só atingem no Apple Silicon a performance que sustenta os números do
`InterviewLab` (~4 s para 14 s de áudio) com o backend Metal, isso era pré-requisito
tanto do Passo 1 quanto do Passo 3. Baixado e verificado nesta sessão com um shader
real.

**Também confirmado:** `brew list` mostra `whisper-cpp` e `llama.cpp` instalados.
São os binários que o `InterviewLab` chama via `Process()`. Não serão usados pelo
Papagaio (D-0.6) — ficam apenas como referência de comparação.

**Conclusão do Passo 0: aprovado.** Hardware, pesos e toolchain verificados com
execução real, não com inspeção de versão. O Passo 1 está liberado.

## D-0.9 — Xcode beta fora de `/Applications`, acionado por `DEVELOPER_DIR`

**Decidido:** a toolchain do projeto é o **Xcode 27.0 beta**, e todo comando de
build passa a exportar

```
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

**Descartado:** *`sudo xcode-select -s`* como forma de ativação — funciona, mas
exige senha de admin a cada troca e muda a toolchain de **todo** o sistema,
inclusive de outros projetos na máquina. `DEVELOPER_DIR` é por processo, não pede
senha e não tem efeito colateral fora do build do Papagaio.

**Por quê:** o app está em `~/Downloads/Xcode-beta.app`, não em `/Applications`, e
`xcode-select -p` segue apontando para as Command Line Tools. Sem uma das duas
formas de ativação, `xcodebuild` não existe no PATH.

**Consequências:**

1. Todo comando de build documentado neste repositório precisa carregar
   `DEVELOPER_DIR`. Um comando sem ele falha de um jeito confuso ("requires Xcode").
2. ~~`~/Downloads` é um local frágil para uma dependência de build de 3,5 GB.~~
   **Resolvido durante o Passo 1:** o usuário moveu o app para `/Applications`.
   O caminho registrado acima já é o definitivo.
3. Sendo **beta**, a toolchain pode mudar de comportamento entre releases. O
   build de `whisper.cpp`/`llama.cpp` (R-8) precisa ser revalidado a cada
   atualização do Xcode beta.
4. Swift sob esta toolchain é 6.4 (`swiftlang-6.4.0.20.104`), levemente diferente
   do Swift das CLT (`6.4.0.27.1`). Vale o do Xcode.

---

## Passo 1 — Esqueleto e contratos (2026-07-30)

Estrutura criada em `Papagaio/`, ao lado do `InterviewLab/`, que segue intacto
(D-0.4):

```
Papagaio/
  Papagaio.xcworkspace          workspace com o projeto e o pacote
  Papagaio.xcodeproj            target de app
  Papagaio/                     fontes do app (grupo sincronizado)
  Config/Papagaio.entitlements  os quatro entitlements do Passo 1
  PapagaioCore/                 pacote SwiftPM: biblioteca + CLI + testes
```

Três targets, como pedido: `Papagaio` (app), `PapagaioCore` (biblioteca) e
`papagaio-eval` (CLI).

## D-1.1 — `project.pbxproj` escrito à mão, com grupos sincronizados

**Decidido:** o `.xcodeproj` é versionado como fonte, escrito à mão em
`objectVersion = 77`, usando `PBXFileSystemSynchronizedRootGroup` para as fontes
do app.

**Descartado:**

- *Gerar o projeto pela UI do Xcode* — produz um `pbxproj` cheio de ruído e não
  é reproduzível a partir do repositório.
- *XcodeGen/Tuist* — resolveria bem, mas adiciona uma dependência de build de
  terceiro a um projeto que já tem `whisper.cpp` e `llama.cpp` para compilar
  (R-8). Custo maior que o benefício com um único target de app.

**Por quê:** com grupo sincronizado, o `pbxproj` **não lista arquivo por
arquivo** — arquivo novo em `Papagaio/` entra no target sozinho. Isso remove a
principal fonte de conflito e de erro de um projeto escrito à mão.

## D-1.2 — `Arquivo` é struct de domínio; `@Model` fica no repositório

**Decidido:** `Arquivo` e `Trecho` em `PapagaioCore` são **structs `Sendable`**.
A entidade `@Model` do SwiftData entra no Passo 8 **dentro** do
`SwiftDataRepository`, mapeada de e para o struct.

**Descartado:** *`Arquivo` já nascer `@Model`* — a skill
`papagaio-persistence-sync` mostra o `@Model` direto, e seria menos código.

**Por quê:** `@Model` é classe de referência e **não é `Sendable`**. Se ele
atravessasse `ArquivoRepository`, a conformidade `Sendable` do protocolo seria
mentira e o Swift 6 em modo `complete` reclamaria na primeira travessia de
ator. Além disso `CloudKitRepository` (Passo 13) não usa SwiftData — um tipo de
domínio neutro é o que permite os dois stores atrás do mesmo protocolo.

**Consequência:** o Passo 8 precisa escrever um mapeamento struct ↔ `@Model`.
Trabalho a mais, previsto aqui e não descoberto lá.

## D-1.3 — `ArquivoRepository` ganha `apagar`

**Decidido:** o protocolo tem quatro métodos: `salvar`, `buscar`, `listar` e
**`apagar(_ id: ArquivoID)`**.

**Por quê:** o prompt mestre (Passo 1) lista só três, mas a skill
`papagaio-persistence-sync` inclui `apagar`, e o critério de aceite do Passo 8 é
*"apagar um arquivo apaga também o `.m4a` do disco"* — inexecutável sem o método.
Divergência do contrato literal, aditiva e declarada aqui conforme a regra 6.

## D-1.4 — Assinatura ad-hoc e bundle ID provisório

**Decidido:** `CODE_SIGN_IDENTITY = "-"`, `CODE_SIGN_STYLE = Manual`,
`DEVELOPMENT_TEAM` vazio, `PRODUCT_BUNDLE_IDENTIFIER = com.papagaio.Papagaio`.

**Por quê:** não há Apple Developer Team configurado nesta máquina (o
`InterviewLab` usa `devplaceholder.…` pelo mesmo motivo). Assinatura ad-hoc é
suficiente para o App Sandbox prender localmente — verificado neste passo.

**Consequência — vira bloqueio no Passo 13:** CloudKit **exige** um team real e
um container provisionado. Sign in with Apple (Passo 12) também. Registrado como
**R-10**.

**Nota:** o build de Debug injeta `com.apple.security.get-task-allow` (é o que
permite anexar o depurador). Não está no arquivo de entitlements e não vai para
Release — não é entitlement extra do app.

---

## Passo 2 — Captura e arquivamento (2026-07-30)

Arquivos novos em `PapagaioCore/Sources/PapagaioCore/`:
`Captura/` (`FormatoAudio`, `RingBufferAudio`, `NivelAudio`, `ErroCaptura`,
`CapturaMicrofone`, `CapturaSistema`, `ConversorCanonico`, `Armazenamento`,
`SessaoGravacao`) e `Importacao/ImportadorAudio`. No app:
`GravadorViewModel` e a `ContentView` com botão de gravar, waveform e
importador. `Config/Info.plist` novo.

## D-2.1 — API Swift do CoreAudio, não a sequência C

**Decidido:** o tap do sistema usa `AudioHardwareSystem.shared` com
`process(for:)`, `makeProcessTap(description:)` e
`makeAggregateDevice(description:)` — a API Swift do `CoreAudio` disponível
desde o macOS 15.

**Descartado:** *a sequência C* (`AudioHardwareCreateProcessTap` +
`AudioHardwareCreateAggregateDevice` + `AudioObjectGetPropertyData` na mão), que
é o que a skill e o prompt mestre descrevem. Custou um arquivo inteiro de
açúcar sobre ponteiro (`CoreAudioPropriedades.swift`), escrito e depois apagado.

**Por quê:** a API Swift devolve objetos tipados (`AudioHardwareTap` já expõe
`.uid` e `.format`), lança `AudioHardwareError` em vez de `OSStatus` solto, e
elimina toda a aritmética de ponteiro de propriedade. Mesma sequência por baixo,
muito menos superfície para errar.

**Continua em C:** a entrega de quadros. `AudioDeviceCreateIOProcIDWithBlock`
não tem equivalente Swift, e **não** dá para apontar `AVAudioEngine` para o
aggregate device — setar `kAudioOutputUnitProperty_CurrentDevice` retorna
`noErr` e o engine segue lendo o input default em silêncio.

### D-2.1.a — Três erros de API corrigidos na skill

A skill `papagaio-audio-capture` prescrevia código que **não compila**. Corrigido
lá, registrado aqui:

| Prescrito | Realidade no SDK |
|---|---|
| `descricao.excludeProcesses = [...]` | não existe — a exclusão vai no inicializador |
| `descricao.exclusiveProcesses` | não existe — a propriedade é `isExclusive` |
| `CATapDescription(stereoMixdownOfProcesses: [])` como tap global | mixdown de lista vazia não captura nada |

E as listas do `CATapDescription` são de **`AudioObjectID` de processo**, não de
`pid_t` — passar o PID cru não excluiria o próprio app, em silêncio.

## D-2.2 — Blocos de tap só fazem `memcpy`; conversão e escrita saem para fora

**Decidido:** os blocos de áudio (tap do `AVAudioEngine` e `IOProc`) fazem
apenas downmix aritmético e cópia para um `RingBufferAudio` lock-free. Um
consumidor a cada 100 ms converte para 16 kHz, mixa e escreve os arquivos.

**Descartado:** *escrever `AVAudioFile` dentro do bloco do tap*, que é o que a
skill mostra e explicitamente permite.

**Por quê:** codificar AAC aloca memória. Alocação em thread de áudio não
crasha — produz glitch intermitente que só aparece na máquina do usuário sob
carga, o pior tipo de bug para diagnosticar depois. O ring buffer usa
`Atomic` com ordering acquire/release e contabiliza amostras descartadas, que
viram aviso no fim da gravação.

## D-2.3 — Arquivamento a 48 kbps, não 64

**Decidido:** AAC mono 16 kHz a **48 kbps**.

**Por quê:** os 64 kbps do prompt mestre e da skill **são impossíveis** nesta
taxa. O encoder da Apple rejeita, e `AVAudioFile(forWriting:)` falha em
`AudioConverterSetProperty(kAudioConverterEncodeBitRate)`. Medido:

| Taxa | Bitrates aceitos (kbps) |
|---|---|
| 16 kHz | 24, 32, **48** |
| 22,05 kHz | 24, 32, 48, 64 |
| 44,1 kHz | 32, 48, 64, 96 |

**Descartado:** *subir a taxa para 22,05 kHz só para caber 64 kbps* — 16 kHz é
o que o `whisper.cpp` consome; reamostrar para cima não adiciona informação.

**Consequência no critério de aceite:** 10 min de gravação ficam em **~3,6 MB**,
não os ~5 MB previstos no Passo 2. Menor que o esperado, não maior.

## D-2.4 — `Info.plist` base, porque `INFOPLIST_KEY_…` descarta a chave de TCC

**Decidido:** o target usa `INFOPLIST_FILE = Config/Info.plist` **junto com**
`GENERATE_INFOPLIST_FILE = YES` (o Xcode mescla os dois).

**Por quê:** `INFOPLIST_KEY_NSAudioCaptureUsageDescription` é **silenciosamente
descartada** — o mecanismo `INFOPLIST_KEY_*` só entrega chaves de uma lista
conhecida do Xcode, e essa não está nela. O build passava, o `Info.plist` saía
sem a chave, e o app crasharia ao criar o process tap. Verificado com `plutil`
no bundle construído, antes e depois.

A chave em si está certa: `NSAudioCaptureUsageDescription` e
`kTCCServiceAudioCapture` aparecem nas strings do `tccd` do sistema.

## D-2.5 — Falha do tap do sistema degrada para só microfone

**Decidido:** se o tap não subir, `SessaoGravacao` continua gravando só o
microfone e devolve o motivo em `Resultado.avisos`. Sem crash, sem silêncio.

**Por quê:** critério explícito do Passo 2. E é a única degradação aceita no
projeto — não contradiz D-0.7, que fala de *engine de IA*, não de canal de
captura.

## D-2.6 — R-11 investigado: o tap entrega silêncio, e a causa não é o aggregate

**Fato medido.** Primeira gravação real do usuário (2026-07-31, 2 min, com
áudio tocando e as duas permissões concedidas):

| Canal | Duração | RMS | Pico | Amostras com sinal |
|---|---|---|---|---|
| `microfone.pcm` | 128,7 s | 0,02223 (−33,1 dBFS) | 0,1978 | **59,2%** |
| `sistema.pcm` | 126,6 s | **0,00000** (−∞) | **0,0000** | **0,0%** |

O microfone está correto. O canal do sistema tem 126,6 s de **zeros exatos**.

**Matriz executada dentro do bundle do Papagaio** (o único com a permissão
concedida — um bundle de diagnóstico separado recebe zero callbacks e não
distingue "sem permissão" de "config errada"), com tom de 440 Hz tocando de
outro processo:

| # | Configuração | Callbacks | Pico |
|---|---|---|---|
| A | aggregate sem subdevice | 0 | — |
| B | subdevice + `MainSubDevice` | 0 | — |
| C | `ClockDevice` | 0 | — |
| D | **sem `tapAutoStart`** | **375** | **0,0** |
| E | sem excluir o próprio processo | 0 | — |
| F | tap por device, mono | 375 | 0,0 |
| G | tap global, estéreo | 375 | 0,0 |
| H | `mutedWhenTapped` | 375 | 0,0 |
| I | tap por device, estéreo | 375 | 0,0 |

**O que isso descarta:**

- *Configuração do aggregate* — nenhuma variante muda o resultado. B e C, as
  hipóteses de clock, nem callback produzem.
- *Descrição do tap* — global, por device, mono, estéreo, mute: todas iguais.
- *Exclusão do próprio processo* — E se comporta igual.
- *Ausência de áudio* — havia tom tocando; e o estéreo dobra os quadros
  (384.000 vs 192.000), provando que o formato é respeitado.
- *TCC obsoleto* — `tccutil reset` + app rodando de `/Applications` (caminho
  estável) deu o mesmo resultado.

**Achado colateral:** `kAudioAggregateDeviceTapAutoStartKey = true` **impede**
os callbacks nesta versão do macOS. Só com ele `false` o `IOProc` roda. Isso
contradiz o uso comum da chave e está no código de produção hoje como `true` —
provavelmente por isso a gravação escreveu zeros em vez de nada.

**Assinatura real testada e descartada como causa.** O usuário configurou a
conta no Xcode (assinatura automática, Team `8CTC75M93B`, certificado
`Apple Development: lucadiasferreira@gmail.com`). Com o app devidamente
assinado — `Authority=Apple Development…`, cadeia até a Apple Root CA — a
matriz inteira foi reexecutada e deu **exatamente o mesmo resultado**. R-10
não é a causa de R-11.

Efeito colateral da assinatura real: o container passou a ser inacessível de
fora do app, e o diagnóstico ganhou saída por `stdout` para continuar legível.

**O que sobra, em ordem de probabilidade:**

1. **Regressão do macOS 27.0 beta.** Ver R-9. Reforçado pelo achado de R-12
   (`tapAutoStart = true` impedindo callbacks), que também contradiz o
   comportamento documentado.
2. **Saída em device Bluetooth** (`34-0E-22-74-86-D4:output`) não ser tapável.
   Não testado: exigiria trocar a saída padrão para o alto-falante interno.
3. Permissão de TCC nunca efetivamente concedida — o teste mais recente rodou o
   binário direto, sem apresentar o prompt.

**Nenhuma linha de produção foi alterada com base em hipótese não testada.** O
`DiagnosticoTap.swift` (modo `--diagnostico-tap`) fica no app até o R-11 fechar.

---

## Passo 3 — Runtime dos modelos locais (2026-07-31)

## D-3.1 — XCFramework oficial, não compilar do fonte

**Decidido:** `whisper.cpp` e `llama.cpp` entram como **XCFramework
pré-compilados**, baixados por `Scripts/bootstrap-runtimes.sh` com tag e SHA-256
fixados, e declarados como `binaryTarget` local no `Package.swift`.

Versões fixadas: `llama.cpp b10205`, `whisper.cpp v1.9.1`.

**Descartado:**

- *`Package.swift` oficial de cada projeto via SPM remoto* — é o que o prompt
  mestre sugere como primeira opção, mas **não existe mais**: `Package.swift`
  dá 404 em `master` nos dois repositórios (verificado em 2026-07-31).
- *Compilar do fonte com CMake + Metal* — funcionaria (CMake e Metal Toolchain
  instalados no Passo 0), mas os binários oficiais já vêm com
  `MTL : EMBED_LIBRARY = 1`, e compilar ~1 GB de C++ a cada build limpo não
  paga.
- *`binaryTarget(url:checksum:)` remoto do SPM* — os dois zips publicam o
  `.xcframework` dentro de `build-apple/`, e o SPM exige o artefato na **raiz**
  do arquivo.
- *Commitar os frameworks* — ~1 GB. Ficam em `.gitignore`; o script é a fonte
  reproduzível.

**Consequência:** clone novo exige rodar `Scripts/bootstrap-runtimes.sh` antes
do primeiro build. **R-8 resolvido.**

## D-3.2 — Um target Swift por runtime, por causa de dois ggml

**Decidido:** `WhisperRuntime` e `LlamaRuntime` são targets Swift separados,
cada um dependendo de exatamente um `binaryTarget`. `PapagaioCore` fala só com
eles e **nunca importa `whisper` ou `llama` direto**.

**Por quê:** não é organização, é obrigatório. Os dois frameworks embutem cópias
**de versões diferentes** do ggml e exportam os mesmos símbolos. Importar os
dois no mesmo target quebra o build:

```
ggml.h:389:10: error: 'ggml_type' has different definitions in different
modules; definition in module 'llama' first difference is enum with 36 elements
```

**Separar os targets não bastou.** O erro voltou no Xcode mesmo com os targets
separados: `import WhisperRuntime` + `import LlamaRuntime` dentro de
`PapagaioCore` carrega os **dois** módulos clang no mesmo contexto de
compilação, porque um `import` público expõe o módulo C subjacente a quem
importa. O `swift build` de linha de comando passava; o Xcode, não.

A correção é declarar os módulos C como **`internal import`** (SE-0409) dentro
de cada wrapper:

```swift
internal import whisper   // em WhisperRuntime
internal import llama     // em LlamaRuntime
```

Assim o módulo C fica restrito ao target que o usa e não vaza para `PapagaioCore`.
Isso só é possível porque os wrappers expõem apenas tipos Swift nativos
(`String`, `Bool`) na sua API pública — nenhum tipo do ggml atravessa a fronteira.

Verificado com `DerivedData` apagado: app Debug e Release compilam sem nenhum
diagnóstico de ggml, e os dois runtimes carregam juntos, cada um com o seu Metal.

**Saída real:**

```
$ papagaio-eval runtime
whisper.cpp: WHISPER : COREML = 1 | OPENVINO = 0 | MTL : EMBED_LIBRARY = 1 | CPU : NEON = 1 | …
llama.cpp:   MTL : EMBED_LIBRARY = 1 | CPU : NEON = 1 | … | LLAMAFILE = 1 | ACCELERATE = 1 |
Metal:       sim
```

**Risco que fica:** os dois exportam `ggml_*` no mesmo espaço de símbolos do
processo. O `dlopen` resolve por framework, e o teste de fumaça passa, mas uma
carga real de modelo nos dois ao mesmo tempo ainda não foi exercitada — os
Passos 4 e 7 é que fecham isso. Registrado como **R-13**.

## D-3.3 — Checksums medidos dos pesos reais

SHA-256 calculado sobre os arquivos já em disco:

| Peso | Bytes | SHA-256 |
|---|---|---|
| `ggml-large-v3.bin` | 3.095.033.483 | `64d182b4…94d1e2` |
| `Qwen2.5-14B-Instruct-Q5_K_M.gguf` | 10.508.873.856 | `48ad2daf…0b8cb2` |

O hash do Whisper confere com o publicado pelo repositório oficial do
`whisper.cpp`, o que valida o arquivo que já estava na máquina.

O hash roda em **streaming** com `CryptoKit`, em blocos de 4 MB. Um
`Data(contentsOf:)` de 10,7 GB estouraria a memória exatamente na máquina que já
está no limite dos 18 GB.

## D-3.4 — Retomada por `Range:` HTTP, não por `resumeData`

**Decidido:** o download escreve num arquivo `.parcial` e retoma com cabeçalho
`Range: bytes=N-`, promovendo para o nome final só **depois** de o SHA-256
bater.

**Descartado:** *`URLSessionDownloadTask.cancel(byProducingResumeData:)`* — o
resume data da Apple não sobrevive ao encerramento do app, e 10,7 GB é grande
demais para recomeçar do zero por causa disso.

**Por que verificar antes de promover:** um peso corrompido que vira "ativo" é
pior que um download perdido — o modelo carrega e produz lixo silenciosamente.

## D-3.5 — Pressão de memória descarrega tudo, sem meio termo

`CicloDeVidaDeModelos` trata `.warning` e `.critical` igual: descarrega todos os
residentes. Com um modelo de 10,7 GB não existe descarte parcial útil — ou ele
está na memória, ou não está. Sem isso, o app é o candidato óbvio do jetsam num
Mac de 18 GB.

## D-3.6 — `rpath` explícito no target de teste

O bundle `.xctest` falhava em `dlopen` com
`Library not loaded: @rpath/whisper.framework/…`, e `DYLD_FRAMEWORK_PATH` não
resolve: o SIP remove variáveis `DYLD_*` do `swiftpm-testing-helper`, que é
binário assinado pelo sistema. Solução: `-rpath @loader_path/../../..` via
`linkerSettings` no `testTarget`.

---

## Passos 4, 5 e 7 — executados sem review, a pedido (2026-07-31)

O usuário autorizou explicitamente seguir sem parar para review a cada passo,
sobrepondo a regra 2 do prompt mestre. **Passo 6 pulado**: o corpus exige
transcrição manual (R-5), que não dá para produzir sem ele. Nada foi commitado.

## D-4.1 — Ponteiro C numa caixa, por causa do `deinit` do ator

`ContextoWhisper` e `ContextoLlama` guardam os ponteiros C numa classe interna
(`Caixa`) em vez de propriedade direta do ator.

**Por quê:** o Swift 6 recusa `deinit` não isolado tocando propriedade isolada
(`cannot access property 'contexto' with a non-Sendable type from nonisolated
deinit`). Com a caixa, quem libera o contexto é o `deinit` dela, que roda quando
o ator morre.

## D-4.2 — Um processo só, confirmado por contagem

Critério de aceite do Passo 4 verificado com `ps --ppid` antes e depois da
transcrição: **0 processos filhos** nos dois momentos. O `InterviewLab` criava
um `whisper-cli`; o Papagaio não cria nada.

**Medido** (`entrevista-2026-07-27T20-12-00Z.wav`, 193,1 s, M5):

| | |
|---|---|
| Tempo | 23,7–25,2 s |
| Fator de tempo real | **7,7–8,2×** |
| Segmentos | 46 |
| Entidades | R$4.850, R$1.730, 9h30, Fernanda, Felipe, Antônio — todas corretas |

## D-4.3 — `AVAudioConverter` não consome tudo numa chamada

`convert(to:error:withInputFrom:)` preenche o buffer de saída e **volta**, sem
consumir o resto da entrada. Passar um arquivo inteiro e ler o resultado de uma
única chamada devolve só o primeiro pedaço — **sem erro nenhum**. O
`DecodificadorDeAudio` faz laço até `endOfStream`/`inputRanDry`.

Achado com um teste que esperava 2 s e recebeu menos. Vale para qualquer uso de
`AVAudioConverter` no projeto.

## D-5.1 — Agrupamento, não re-segmentação

`Segmentacao.agrupar` junta segmentos nativos do Whisper até ~40 s e **nunca
divide um segmento** — cortar no meio de um é cortar no meio de uma frase.
Fecha o trecho quando: cruza o alvo, passaria de 60 s, o falante muda, ou há
pausa ≥ 2 s depois de metade do alvo.

**Medido** no mesmo áudio: 46 segmentos → **5 trechos**, min 17,0 s (o último),
média 38,3 s, máx 45,8 s, **zero trechos fora de 20–60 s** ignorando o último.

Troca de falante sempre fecha o trecho: misturar as duas vozes num trecho só
destruiria a atribuição por canal, que é a única diarização que o projeto tem.

## D-7.1 — Três bugs de API do `llama.cpp`, todos fatais e silenciosos

Os três derrubam o processo em vez de devolver erro. Ficam registrados porque
nenhum é óbvio a partir da assinatura:

1. **Quebra de linha termina a regra no GBNF.** Uma gramática com regras
   quebradas em várias linhas dá `failed to parse grammar`. Todas as regras
   agora ficam em **uma linha cada**, e há teste travando isso.
2. **`llama_decode` aborta se o lote passar de `n_batch`** —
   `GGML_ASSERT(n_tokens_all <= cparams.n_batch)`. Como o passe único vai até
   28k tokens, o prefill é **fatiado** em lotes de 2.048.
3. **`llama_sampler_sample` já aceita o token** ("Sample **and** accept" no
   header). Chamar `llama_sampler_accept` depois avança a pilha da gramática
   duas vezes e mata o processo com *"Unexpected empty grammar stack after
   accepting piece"*.

## D-7.2 — Resultado real do passe único

Pipeline completo (transcrever → segmentar → resumir) no mesmo processo:

```
transcrição: 46 segmentos → 5 trechos
entrada: 947 tokens (teto de passe único: 28000)
modo: passe único
tempo de resumo: 99,6 s
engine: qwen2.5-14b-instruct-q5_k_m
```

Saída: `Resumo` tipado válido, com 5 temas, 9 citações e 5 próximos passos. Os
números batem com o resumo que o pipeline antigo (subprocess) produziu para o
mesmo áudio: R$1.730, R$9.600, prazo de 3 → 7 dias, sexta 24/07 às 12h.

**R-13 exercitado e aprovado:** os dois modelos carregados no mesmo processo,
sem colisão de ggml.

**Duas ressalvas medidas, não resolvidas:**

- O modelo **inventa `start`** em algumas citações (uma aponta 256 s num áudio
  de 193 s). A gramática garante que o campo é um número; não garante que o
  número é verdadeiro.
- O modelo preenche `speaker` das citações com **nomes próprios** tirados do
  conteúdo ("Fernanda", "Luca"), não com `"eu"`/`"interlocutor"`. Contradiz a
  atribuição por canal. Registrado como **R-14**.

## D-7.3 — Testes com modelo rodam serializados

Whisper (3 GB) e Qwen (10,7 GB) carregando em paralelo estouram a GPU com
`kIOGPUCommandBufferCallbackErrorOutOfMemory` numa máquina de 24 GB. Os testes
pesados ficam em `@Suite(.serialized)` e a suíte roda com `--no-parallel`.

Não é defeito do código — é a confirmação empírica de por que
`CicloDeVidaDeModelos` existe.

---

## Correções no Passo 2 (2026-07-31)

## D-2.7 — `capturouAudioDoSistema` passa a significar sinal, não API

O app mostrava **"mic + sistema"** em gravações cujo canal do interlocutor era
silêncio puro: a flag vinha de "o tap subiu", não de "chegou áudio". Com R-11
aberto, isso é o app afirmando algo falso ao usuário.

Agora a flag só é `true` se alguma amostra passou de −80 dBFS, e um aviso
explícito aparece quando o tap sobe mudo. **Descartado:** deixar como estava e
só documentar — o rótulo estava errado na tela, não no papel.

## D-2.8 — Gravação abaixo de 1 s é descartada do disco

Um clique de gravar/parar produzia arquivo de 26 KB e 0:00 na biblioteca. Agora
a pasta é apagada e a gravação não entra na lista.

## D-2.9 — Tap de saída por stream do dispositivo padrão

**Decidido:** `SystemAudioTap` passa a criar um `CATapDescription` exclusivo
no stream de saída do dispositivo padrão e um aggregate privado contendo apenas
o sub-tap. A configuração foi portada do `AudioRecorder`, projeto de referência
que grava simultaneamente microfone e saída do sistema nesta máquina.

**Descartado:** o tap global com aggregate contendo também o dispositivo físico
de saída. Apesar de criar callbacks, esta rota já foi medida no Papagaio como
um canal de zeros (D-2.6).

**Validação pendente:** o build cobre a integração estática; a confirmação de
sinal exige uma gravação real, com áudio de outro processo, no app assinado e
aberto pelo Finder/Dock. Ela permanece fora do alcance de testes unitários e do
simulador de dispositivo de áudio.

## D-2.10 — Stream de saída é descoberto, não presumido

**Decidido:** antes de criar o Process Tap, o Papagaio enumera os streams da
saída padrão e usa o primeiro que anuncia PCM, taxa válida e ao menos um canal.

**Descartado:** fixar `stream = 0`. O índice zero corresponde aos AirPods
estéreo usados nesta máquina hoje, mas não é contrato de Core Audio para
interfaces multicanal ou rotas que o usuário venha a selecionar depois.

## D-2.11 — Captura grava PCM/CAF assíncrono; AAC não roda no callback

**Decidido:** o canal de sistema é gravado como `sistema.caf` PCM pelo
`ExtAudioFileWriteAsync`, como no AudioRecorder. A transcrição e reprodução
aceitam CAF; `sistema.m4a` continua como leitura legada.

**Descartado:** criar `AVAudioPCMBuffer` e escrever AAC/M4A pelo `AVAudioFile`
dentro do bloco do `IOProc`. Essa rota codifica e pode alocar na thread de
áudio, além de não ser a arquitetura que se mostrou funcional no projeto de
referência.

## D-2.12 — Resultado da captura exige sinal, não apenas tap iniciado

**Decidido:** no fim da gravação, o Papagaio mede callbacks, quadros e pico
Float32 do tap. Ele remove o canal do sistema e mostra um aviso específico se
não houve callbacks ou se os buffers recebidos foram silêncio.

**Por quê:** o estado anterior considerava sucesso tão logo `AudioDeviceStart`
retornava sem erro, escondendo a diferença operacional entre TCC negado,
callback ausente e stream que entrega zeros.

## D-2.13 — Medidores separados para microfone e áudio do sistema

**Decidido:** a tela de gravação desenha uma waveform por canal. O medidor do
sistema lê o RMS do próprio Process Tap e não reutiliza o nível do microfone.

**Por quê:** uma única waveform tornava impossível distinguir na interface um
microfone silencioso de um tap do sistema silencioso durante a gravação.

---

## Passos 8 e 9 — Persistência e busca (2026-07-31)

## D-8.1 — `@ModelActor`, com o mapeamento struct ↔ `@Model` prometido em D-1.2

`SwiftDataRepository` é um `@ModelActor`: `ModelContext` não é `Sendable`, e o
ator garante que todo acesso acontece numa fila só. O custo previsto em D-1.2
(escrever o mapeamento) foi pago aqui, em `paraDominio`.

Modelagem já dentro das restrições do CloudKit, mesmo com
`cloudKitDatabase: .none` hoje: tudo opcional ou com default, nenhum
`@Attribute(.unique)`, relações opcionais com `inverse`. Migrar schema depois de
já haver dado sincronizado é o pior lugar possível para estar (D-0.3).

## D-8.2 — `Insight` é entidade, não blob

O prompt mestre lista `Insight` entre os `@Model`. Cada tema, citação e próximo
passo do `Resumo` vira um `InsightPersistido` com `tipo`, `texto`, `start` e
`ordem`.

**Descartado:** *guardar o `Resumo` como JSON num `Data`* — seria menos código,
mas a busca do Passo 9 não acharia um próximo passo pelo texto dele, e o player
do Passo 10 não teria âncora de tempo por citação.

## D-8.3 — Trechos e insights são reescritos por inteiro

`salvar` apaga e regrava as duas coleções em vez de reconciliar item a item.
São **derivados** da transcrição e do resumo; reconciliar custaria mais código
para o mesmo resultado. Salvar duas vezes atualiza, não duplica — há teste.

## D-9.1 — Busca em quatro consultas, não numa

Título (bucket A) primeiro; depois visão geral, trechos e insights (bucket B),
excluindo o que já veio em A.

**Por que quatro e não uma:** um `#Predicate` único com as condições em `||`,
duas delas sobre relação, **não compila** — *"the compiler is unable to
type-check this expression in reasonable time"*. Separar compila rápido e lê
melhor.

**Por que dois buckets e não ordenação por relevância:** quem procura
"orçamento" e tem um arquivo chamado "Orçamento Q3" quer *aquele* primeiro. Um
score calculado daria o mesmo resultado com muito mais código.

`localizedStandardContains` é o que faz "orcamento" achar "Orçamento" — ignora
caixa **e** diacrítico. `contains` simples não acha.

## D-9.2 — Campos do resumo não são opcionais

`resumoTitulo` e `resumoVisaoGeral` são `String` com default `""`, mais um
`temResumo: Bool`.

**Por quê:** com `String?`, o predicado de busca precisa de `?? ""`, que o
CoreData traduz para `TERNARY` e recusa em runtime com *"unimplemented SQL
generation for predicate … (bad RHS)"* — o teste morre com signal 6. Ter
default também é exigência do CloudKit.

---

## Passo 10 — Player e navegação por trecho (2026-07-31)

`ReprodutorDeArquivo` + `NavegacaoPorTrecho` em `PapagaioCore/Reproducao/`, e
`ArquivoDetalheView` no app. A lista da tela principal virou `NavigationStack`:
cada gravação abre o detalhe.

## D-10.1 — `AVPlayer`, não `AVAudioPlayer`

**Decidido:** o player é `AVPlayer`, com `addPeriodicTimeObserver` a 0,1 s e
`seek(to:toleranceBefore: .zero, toleranceAfter: .zero)`.

**Por quê:** o passo pede as duas coisas — *"`AVAudioPlayer`, `currentTime =
trecho.start`, `addPeriodicTimeObserver`"* — e elas são de classes diferentes.
`addPeriodicTimeObserver` não existe em `AVAudioPlayer`; para acompanhar o tempo
com ele seria preciso um `Timer`, e o critério de aceite *"sair da view não deixa
observer vivo"* só faz sentido no caminho do `AVPlayer`.

**Descartado:** *`AVAudioPlayer` + `Timer`* — além do critério acima, o setter de
`currentTime` em AAC pousa na fronteira de pacote mais próxima. Clicar num trecho
tem que pousar **no trecho**, e é o `seek` com tolerância zero que garante isso.
Medido: os três saltos do teste pousam a menos de 0,15 s do `start` pedido.

**Consequência:** `encerrar()` é obrigatório no `onDisappear`. Há
`isolated deinit` (SE-0371) como rede de segurança, mas ele só roda quando o
objeto morre — a view é quem sabe que saiu de cena.

## D-10.2 — O destaque não some no silêncio entre trechos

`NavegacaoPorTrecho.indiceAtivo` devolve o **último trecho que já começou**, não
só o trecho que contém o instante. Num buraco entre dois trechos o destaque fica
onde estava.

**Descartado:** *conter estritamente (`start <= t < end`, senão `nil`)* — é o mais
literal, mas faz o destaque piscar a cada pausa da fala, e o critério do passo é
"o highlight acompanha **sem parecer travado**". O texto que o usuário está lendo
durante uma pausa continua sendo o que acabou de tocar.

Antes do primeiro `start` o retorno é `nil`: silêncio inicial não tem texto para
destacar (é o mesmo `start` deslocado que o Passo 5 preserva).

## D-10.3 — Build de teste fora do iCloud Drive

`swift test` passou a falhar em `CodeSign … resource fork, Finder information, or
similar detritus not allowed`: `~/Documents` está sincronizado pelo iCloud Drive,
e o file provider põe `com.apple.FinderInfo` no bundle `.xctest` dentro de
`.build/`. Apagar o atributo não resolve — ele volta no build seguinte.

**Decidido:** rodar os testes com `--scratch-path` fora de `~/Documents`. O
`-rpath` relativo do target de teste (D-3.6) continua válido, porque é
`@loader_path`.

**Não decidido:** mover o repositório inteiro para fora do iCloud. Resolveria de
vez e é o que se faria num projeto de equipe — fica como sugestão, não como
mudança feita sem review.

## D-10.4 — Trecho inicia reprodução e player Liquid Glass contextual (2026-07-31)

**Decidido:** selecionar um trecho da aba Transcrição chama
`tocar(aPartirDe:)`: executa o `seek` com tolerância zero e só então inicia o
áudio. A tela revela uma barra flutuante centralizada na base, disponível também
nas abas Resumo e Próximos passos.

**Escopo da barra:** é um transporte compacto, não uma tela de música completa:
play/pause, título, posição atual, duração e slider. A implementação atual usa
o Liquid Glass nativo do macOS 26 — `.glassEffect(.regular, in: Capsule())` —
e botão de play/pause com `.glassProminent`. O slider só confirma o seek ao fim
do arraste, evitando uma sequência concorrente de seeks enquanto a pessoa o move.
Cada trecho é um `Button` com estilo visual neutro, em vez de um gesto solto,
para preservar foco de teclado e semântica do VoiceOver; a apresentação e a
rolagem respeitam a preferência de reduzir movimento.

**Descartado visualmente:** `regularMaterial`, borda e sombra manuais. Eles só
imitariam uma superfície translúcida e impediriam o sistema de aplicar o efeito
Liquid Glass apropriado ao contexto.

**Descartado:** letras sincronizadas ou controles de letra, faixa anterior ou
próxima, avançar/voltar, fila, arte de álbum e envio para TV. Nenhum desses
controles ajuda a revisar a gravação a partir da transcrição.

**Por quê:** o clique no texto passou a ser uma ação de escuta, não somente de
navegação. Manter o transporte fora das abas evita obrigar a pessoa a voltar para
Áudio para pausar ou ajustar a posição, sem tapar o fim do conteúdo rolável.

---

## D-10.5 — A interface opera o pipeline individual local (2026-07-31)

**Decidido:** `ContentView` mantém `Biblioteca` e `ModelosViewModel`; gravação,
importação e o comando de reprocessar registram o `Arquivo` no
`SwiftDataRepository` e disparam `PipelineDeArquivo`. A interface mostra as
fases de transcrição/resumo, usa a pasta de modelos ativa e atualiza a biblioteca
com o resultado persistido.

**Por quê:** transcrição, segmentação e resumo não podem permanecer somente na
CLI: a gravação feita pelo app precisa chegar ao mesmo pipeline local e voltar
como trechos navegáveis. Os modelos são criados por execução e descarregados ao
fim, respeitando o orçamento de memória já definido.

**Limite preservado:** isto integra somente o espaço individual local. O
`CloudKitRepository` existe no Core, mas ainda não há interface para criar,
entrar ou gerenciar um espaço de equipe.

---

## D-10.6 — Estados vazios ocupam o centro da área de conteúdo (2026-07-31)

**Decidido:** título e abas ficam no topo da tela de detalhe. A área abaixo das
abas ocupa o espaço restante: quando não houver resumo, transcrição ou próximos
passos, o respectivo `ContentUnavailableView` fica centralizado nela. Quando há
conteúdo, ele continua alinhado ao topo e rolável. A aba Áudio também usa essa
área central para uma orientação ampliada, com ícone de waveform, título e
instrução para usar a barra fixa ou iniciar por um trecho da transcrição.

**Por quê:** mostrar a ausência no canto superior parecia conteúdo truncado ou
falha de layout. O centro comunica claramente que a seção está aguardando o
processamento, sem deslocar a barra de áudio flutuante.

---

## D-10.7 — Fila serial para transcrição e resumo (2026-07-31)

**Decidido:** todo áudio novo e todo comando de reprocessar entra numa fila FIFO
em memória. Apenas o primeiro item da fila cria `MotoresLocais` e executa
`PipelineDeArquivo`; o próximo só começa depois que a execução atual termina e
`descarregarTudo()` libera os modelos. Assim, Whisper e Qwen nunca são
carregados simultaneamente por dois arquivos.

**Feedback:** a biblioteca mostra a fase real para o item ativo e “na fila
(posição N)” para os demais, com um ícone de relógio. O mesmo arquivo não pode
ser enfileirado duas vezes; reprocessar e apagar ficam indisponíveis enquanto ele
está ativo. Um arquivo ainda na fila pode ser apagado, o que também o remove da
fila.

**Limite assumido:** a fila existe somente durante a sessão. Ao encerrar o app,
itens ainda não processados continuam salvos como “aguardando processamento” e
podem ser reenviados manualmente. Não iniciamos trabalhos automaticamente ao
abrir o app, pois isso poderia surpreender a pessoa e carregar os modelos sem
uma ação explícita.

**Por quê:** os dois modelos podem usar cerca de 13,7 GB; iniciar duas
transcrições/resumos em paralelo em um Mac com a margem mínima de memória do
app arrisca encerramento pelo sistema.

---

## D-10.8 — Sistema visual modular da Alta Fidelidade (2026-08-01)

**Decidido:** a aparência de referência da página **Alta Fidelidade** é aplicada
às superfícies que já existem no Papagaio: biblioteca, gravação, modelos locais,
cartões de conversa e detalhe de uma conversa. O sistema visual fica em
`Papagaio/UI/DesignSystem`, com tokens de cor, espaçamento, raios, selos de
status e estilos de botão; os componentes reutilizáveis ficam separados por
responsabilidade em `UI/Components`, `UI/Biblioteca` e `UI/Detalhe`.

**Componentização:** `ContentView` continua sendo apenas o coordenador que cria
e conecta `GravadorViewModel`, `Biblioteca`, `ModelosViewModel` e
`PerfilViewModel`. As subviews recebem estado e closures, sem recriar view
models. No detalhe, a barra de abas, a linha de transcrição, a orientação de
áudio e a barra de áudio inferior são componentes visuais independentes. O
container conserva preparação, seek, reprodução por trecho, atualização tardia
dos trechos, exportação e o encerramento do observador de `AVPlayer`.

**Comportamento preservado:** o player inferior permanece centralizado e usa
Liquid Glass conforme D-10.4; ele contém somente tocar/pausar e posição. Clicar
num trecho continua fazendo seek e iniciando a reprodução. Estados sem resumo,
transcrição ou próximos passos ficam centralizados na área disponível. A grade
continua expondo somente ações funcionais (gravar, importar, reprocessar e
mover para a lixeira), sem inventar telas, controles de música ou dados
decorativos do Figma.

**Correção de integração:** escolher uma pasta externa **ou** voltar a usar a
pasta do app sincroniza `Biblioteca.pastaDeModelos`. Assim, o próximo item da
fila usa a mesma pasta que a interface mostra, eliminando a divergência anterior
entre o seletor visual e o pipeline local.

**Acessibilidade e validação:** botões, menus, `NavigationLink`, dicas de
acessibilidade e `accessibilityReduceMotion` permanecem semânticos; não foram
substituídos por áreas de toque decorativas. O app completo compilou com
`xcodebuild` em 2026-08-01, usando `CODE_SIGNING_ALLOWED=NO` e Derived Data em
`/private/tmp/papagaio-design-derived`.

---

## D-10.9 — Lixeira persistente, restauração e exclusão definitiva (2026-08-01)

**Decidido:** excluir um arquivo da biblioteca agora significa movê-lo para uma
lixeira persistente local. `Arquivo.apagadoEm` registra a remoção no SwiftData;
as consultas normais não retornam esses itens e a nova seção **Lixeira** os
exibe separadamente. Os dados processados e a pasta de áudio continuam no
dispositivo até a exclusão definitiva.

**Recuperação e remoção:** selecionar um cartão da lixeira abre ações explícitas
para recuperar ou apagar definitivamente. Recuperar zera `apagadoEm` e devolve
o arquivo para **Todos os arquivos**, preservando o áudio, a transcrição e o
resumo. Apagar definitivamente requer confirmação e só então remove o registro
e a pasta `Gravacoes/<UUID>`, validada antes de qualquer remoção física.

**Fila e concorrência:** um item ativo não pode ser movido para a lixeira. Para
um item aguardando processamento, ele é retirado da fila antes do primeiro
`await`, evitando que se torne ativo durante a operação. A restauração não
reinicia automaticamente o pipeline: o usuário pode escolher reprocessar,
evitando uso inesperado de memória e dos modelos locais.

**Resiliência:** uma atualização tardia do pipeline não pode ressuscitar um
arquivo já na lixeira. A persistência preserva a marca de remoção e os testes
cobrem mover, restaurar, apagar definitivamente, impedir remoção fora da
lixeira, filtrar buscas e esse caso de concorrência. O build completo e os
quatro testes da lixeira passaram em
2026-08-01.

---

## D-10.10 — Notas temporizadas capturadas durante a gravação (2026-08-01)

**Decidido:** uma gravação ativa oferece um painel de **Notas da conversa**
com editor, marcador e sinalização de criticidade. O texto digitado pode ser
salvo por botão ou `⌘↩`; o rascunho também é convertido em nota ao finalizar a
gravação. Marcadores não exigem texto e servem para assinalar pontos relevantes
da conversa.

**Sincronização:** o carimbo de tempo não vem de `Date` nem de um cronômetro de
interface. `SessaoGravacao` expõe a duração das amostras que já chegaram à
mixagem; assim a nota aponta para o mesmo ponto do áudio que será reproduzido,
mesmo quando buffers de captura atrasam a atualização visual. Uma gravação
descartada por ser curta demais também descarta suas notas e comunica isso ao
usuário.

**Modelo e persistência:** `NotaDaConversa` é uma entidade própria — texto,
instante, tipo (`nota` ou `marcador`) e criticidade — e não um insight gerado
pelo resumo. Ela acompanha o `Arquivo` antes de entrar na fila serial, é
persistida como relação em SwiftData e indexada na busca local. O pipeline
preserva essas notas quando atualiza transcrição e resumo.

**Consulta:** o detalhe agora inclui a seção **Notas**, ao lado de Resumo,
Transcrição, Áudio e Próximos passos. Cada nota mostra o tempo, tipo e estado
crítico; selecioná-la abre a barra flutuante e inicia o áudio naquele instante.
As notas também entram na exportação Markdown para que o contexto manual viaje
com a transcrição e o resumo.

**Qualidade:** o painel usa controles semânticos, rótulos para VoiceOver,
tipografia dinâmica e feedback visível de notas registradas. A mudança foi
validada por build do app e testes focados de duração por amostras,
persistência/atualização, busca e exportação.

---

## D-10.11 — Configurações e lixeira em telas próprias (2026-08-03)

**Decidido:** a engrenagem da barra superior abre uma tela própria de
**Configurações**. No momento ela contém somente **Pausar transcrições e
resumos automáticos**. A preferência é persistente e vem desligada por padrão,
preservando o fluxo anterior: áudios gravados ou importados entram na fila FIFO
assim que são salvos. Ao pausar, o áudio é salvo normalmente, mas fica com o
estado **Pronto para transcrever**; a aba Transcrição exibe um botão centralizado
**Transcrever**.

**Fluxo manual:** tocar em **Transcrever** usa exatamente
`Biblioteca.enfileirarProcessamento(_:)`, sem caminho paralelo. Após o Whisper,
o `PipelineDeArquivo` executa o Qwen para o resumo como já fazia antes. Assim,
o controle muda apenas o gatilho de entrada da fila — nunca sua serialização,
que continua garantindo um único arquivo e um único conjunto de modelos em
memória por vez.

**Lixeira:** o seletor exposto na biblioteca continua removido, mas a Lixeira
não pertence às Configurações. Ela é um botão `trash` vermelho separado, ao lado
da engrenagem, e abre a área Lixeira com título próprio. Recuperação, exclusão
definitiva, confirmação e as proteções de concorrência de D-10.9 não mudam.

**Navegação e composição:** Configurações e Lixeira não exibem mais o botão
textual “Voltar à biblioteca” dentro do cabeçalho. Ambas mostram um único
`chevron.backward` no canto esquerdo da barra superior, que retorna à biblioteca.
A coluna de Configurações fica centralizada e limitada a 760 pt; o formulário
ganha altura compacta para não criar uma área vazia em torno do único toggle.
A busca e a identificação **Biblioteca** formam um bloco centralizado na barra
superior, independente dos controles ancorados em suas extremidades. Esse bloco
usa a `Toolbar` nativa do macOS — não uma faixa dentro do conteúdo — para
permanecer alinhado aos controles de janela e à tela de detalhe.
Ele contém apenas a busca: não há ícone de pasta ou moldura customizada ao seu
redor. O menu de perfil oculta o indicador de submenu, e a Lixeira e as
Configurações compartilham o botão de voltar padrão da toolbar.
O avatar genérico usa uma área circular de 36 pt e símbolo de 26 pt, compatíveis
com a presença visual dos outros controles. Ele abre um popover com as mesmas
ações de perfil em vez de um `Menu` nativo, pois o controle nativo impõe uma
cápsula vertical que não representa o avatar como um botão redondo.
Configurações e Lixeira compartilham um único `ToolbarItemGroup`; o perfil é
um `ToolbarItem` separado, preservando sua ação sem misturá-la às utilidades da
biblioteca. Um `ToolbarSpacer(.fixed)` entre eles impede que o macOS os una no
mesmo grupo visual.

**Deliberadamente não feito:** ativar a preferência não envia
retroativamente itens que estavam pausados para a fila, nem reinicia trabalhos
ao abrir o app. Isso preserva a expectativa de que os modelos pesados só sejam
carregados depois de uma ação que a pessoa escolheu.

---

## D-10.12 — Proteções de qualidade para áudio e transcrição (2026-08-03)

**Decidido:** as novas gravações guardam os canais de microfone e sistema como
WAV mono Float32 a 16 kHz, o mesmo formato canônico entregue ao Whisper. A
mixagem AAC continua sendo o arquivo compacto de reprodução/exportação. A
transcrição prefere os WAVs; gravações antigas em PCM continuam funcionando
como fallback, sem migração destrutiva.

**Confiabilidade:** antes de carregar o Whisper, um detector de atividade por
energia recusa canais sem fala sustentada. O runtime usa `no_context = true`
para que uma hipótese ruim não contamine as janelas posteriores. Ao mesclar os
dois canais, trechos quase idênticos e simultâneos do microfone são removidos
quando correspondem ao áudio do sistema, evitando duplicação por eco.

**Nomes próprios:** o app pede acesso opcional a Contatos e Calendário e usa no
máximo 40 termos como `initial_prompt` curto do Whisper. Negar qualquer uma das
permissões não bloqueia a transcrição; apenas deixa de fornecer esse contexto.
O prompt é uma pista de reconhecimento, nunca uma correção automática.

**Importação:** anexos já são normalizados com `AVAssetReader` antes de serem
arquivados, mantendo o caminho tolerante a contêineres AAC/M4A/MP3 adotado no
Passo 2. Não foi criada uma segunda conversão para evitar alterar o áudio duas
vezes.

**Validação:** build Debug do app e cinco testes focados passaram. A eficácia
contra a repetição precisa de validação manual com os áudios reais reportados e
deve virar corpus de regressão quando houver autorização para guardar amostras.

---

## Passo 11 — Exportação Markdown (2026-07-31)

## D-11.1 — `fileExporter` salva o Markdown; o áudio é copiado depois

**Decidido:** o Markdown é entregue por `FileDocument` ao painel nativo
`fileExporter`. Quando o usuário confirma o local, o app copia o `.m4a` para a
mesma pasta, com o mesmo nome-base do `.md`.

**Por quê:** `FileDocument` representa um único documento; o áudio é um anexo
separado e não deve virar blob dentro de um pacote opaco. O destino vem do
painel do sistema, portanto a gravação respeita o App Sandbox.

**Consequência:** uma exportação de `decisoes.md` também produz
`decisoes.m4a`. Caso a cópia do anexo falhe, o Markdown já salvo é preservado e
o app mostra o erro em vez de apagar a exportação válida.

## D-11.2 — Tipo Markdown compatível com macOS 26

`UTType.markdown` é anotado pelo SDK como disponível apenas em macOS 27, mas o
deployment target do app é macOS 26. O documento usa `UTType(filenameExtension:
"md")` — mesmo formato e extensão, sem elevar o mínimo de sistema.

---

## Passo 12 — Sign in with Apple (2026-07-31)

## D-12.1 — Perfil opcional no Keychain; nunca identidade de sync

**Decidido:** `PerfilViewModel` inicia `ASAuthorizationAppleIDProvider`, guarda
apenas o `user` da credencial no Keychain e, em toda abertura, chama
`getCredentialState(forUserID:)`. A notificação
`credentialRevokedNotification` remove a sessão local imediatamente.

**Descartado:** usar `UserDefaults` para o identificador — não é local adequado
para uma credencial de sessão. Também foi descartado bloquear qualquer fluxo do
app até o login: o perfil é opcional e o Papagaio continua funcionando sem ele.

**Limite importante:** Sign in with Apple é perfil opcional do app. Ele não
identifica nem sincroniza arquivos, que permanecem locais nesta versão.

**Provisionamento verificado:** o Mac foi registrado no Team `8CTC75M93B` e o
Xcode gerou `Mac Team Provisioning Profile: com.papagaio.Papagaio`. O bundle
assinado contém `com.apple.developer.applesignin = [Default]`; `codesign
--verify --deep --strict` passou.

**Aceite manual:** o usuário concluiu o fluxo real de Sign in with Apple na
build assinada depois de configurar o App ID como Primary no portal Apple. O
erro `ASAuthorizationError 1000` anterior desapareceu.

---

## Passo 13 — Espaços de equipe (início, 2026-07-31)

## D-13.1 — Container CloudKit explícito

**Decidido:** o container do Papagaio é `iCloud.com.papagaio.Papagaio`. O
profile de desenvolvimento foi regenerado com esse container e com o serviço
`CloudKit`; o entitlement assinado foi conferido no bundle.

**Atualização:** Push Notifications foi habilitado no App ID. O profile regenerado
passou a conter `com.apple.developer.aps-environment = development`, além de
`CloudKit`; ambos foram conferidos no bundle assinado.

---

## D-13.2 — Repositório de equipe usa custom zone e CKSyncEngine

**Decidido:** cada `EspacoID` é uma custom zone privada `espaco-<UUID>`. O
`CloudKitRepository` serializa o arquivo, envia áudio e Markdown como `CKAsset`,
persiste a serialização de estado do `CKSyncEngine` e cria um `CKShare` para a
zone inteira. A identidade de CloudKit continua sendo `userRecordID`, sem relação
com Sign in with Apple.

**Aceite adiado por decisão do usuário (2026-07-31):** não há um segundo
dispositivo disponível. Portanto não foram executados o convite/aceite entre duas
contas iCloud, a propagação de alteração em menos de um minuto, a resolução de
conflito, a remoção de participante nem a apresentação de `QuotaExceeded`.
Também permanece pendente a interface para criar/entrar em espaços. Build assinado
e teste unitário do contrato passaram, mas não substituem o ensaio em duas
máquinas; este passo deve ser reaberto antes de distribuir o recurso de equipe.

---

## D-13.3 — CloudKit e espaços de equipe removidos antes da distribuição (2026-08-01)

**Decidido:** esta versão do Papagaio é exclusivamente local. O
`CloudKitRepository`, o container `iCloud.com.papagaio.Papagaio`, o compartilhamento
por `CKShare` e a capacidade de Push Notifications associada ao sync deixam de
fazer parte do target distribuído.

**Por quê:** o recurso de equipe não ganhou interface nem validação entre duas
contas iCloud. Em contrapartida, o container pertence a um Apple Developer Team
específico e bloqueia a assinatura automática quando outra pessoa precisa gerar
um archive/TestFlight. Manter essa dependência sem entregar colaboração ao
usuário cria risco de distribuição, sem benefício na versão atual.

**Consequência:** biblioteca, lixeira, fila serial, gravações, transcrição,
resumo e notas continuam no SwiftData local. Não há envio de áudio, Markdown ou
metadados a iCloud. A configuração de assinatura não fixa Developer Team nem
certificado: quem publicar escolhe o próprio time no Xcode, registra o bundle
identifier correspondente e deixa a assinatura automática selecionar a
identidade de distribuição correta para o archive.

**Futuro:** uma versão com colaboração deve voltar como projeto próprio, com
organização responsável pelo container, migração explícita dos dados locais,
interface de convites e teste real entre duas contas. O código removido não deve
ser reativado apenas adicionando de volta o entitlement.

---

## D-13.4 — Correções de empacotamento para a Mac App Store (2026-08-13)

**Decidido:** o ícone distribuído é `Papagaio/PapagaioAppIcon.icns`, declarado
por `CFBundleIconFile` e contendo todas as representações de 16 a 1024 pixels.
O catálogo anterior continha um `Contents.json` inválido e o `actool` não gerava
um `.icns` completo; a fonte PNG foi preservada em `Config/AppIconSource` para
regenerar o arquivo quando necessário.

**Entitlements:** a chave inválida
`com.apple.security.personal-information.contacts` foi substituída por
`com.apple.security.personal-information.addressbook`, necessária para o uso
real de `CNContactStore`. As capacidades `usernotifications.communication` e
`usernotifications.time-sensitive` foram removidas: o app só agenda
notificações locais padrão e não implementa intents de mensagem ou chamada.

**Validação local:** build `Release` sem assinatura passou e o bundle resultante
declara `CFBundleIconFile = PapagaioAppIcon`; a representação
`icon_512x512@2x.png` extraída do `.icns` mede 1024 x 1024. A assinatura de
distribuição e a validação final continuam sendo responsabilidade do archive do
Xcode Cloud/App Store Connect.

---

## D-3.7 — Candidato Qwen3.5 9B Q4_K_M em janela de 32k (2026-08-14)

**Em avaliação na branch `codex/qwen35-9b-memory-evaluation`:** substituir o
Qwen2.5-14B-Instruct-Q5_K_M pelo
`Qwen_Qwen3.5-9B-Q4_K_M.gguf`, de 6.169.341.984 bytes, mantendo a janela
operacional de 32.768 tokens e a saída JSON estruturada.

**Por quê:** o peso atual tem 10,5 GB e o seu KV cache em FP16 cresce cerca de
6 GB a 32k. O candidato reduz o peso para cerca de 6,2 GB e, pela arquitetura
híbrida com menos camadas de atenção, o cache estimado para a mesma janela é
cerca de 1 GB. A estimativa não substitui o `phys_footprint` real do processo.

**Compatibilidade:** o peso requer `llama.cpp b9222` ou posterior. O template
do Qwen3.5 entra em modo de raciocínio por padrão; o Papagaio fecha
explicitamente `<think></think>` antes da gramática GBNF para gerar JSON direto.

**Não decidido:** não reduzir o piso de 18 GB, não promover o candidato para
`main` e não apagar o peso anterior antes de medir no Mac real: checksum,
carregamento Metal, `phys_footprint`, velocidade e fidelidade das decisões,
números e próximos passos num áudio já conhecido.

**Atualização (2026-08-18):** o candidato **já está em uso no código** — este
registro ficou para trás. `QwenEngine.identificador` é `qwen3.5-9b-q4_k_m`,
`Pesos.qwen35_9B` (6.169.341.984 bytes) é o único peso de resumo em
`Preflight.todos`, e `MotoresLocais` carrega esse arquivo. O piso de RAM segue
em 18 GB (`Preflight.ramMinima`), como esta decisão pedia. O que continua **não
feito** é a medição que a decisão exigia: `phys_footprint` real, velocidade e
fidelidade num áudio conhecido, comparados contra o Qwen2.5-14B. Sem o harness
do Passo 6 (R-15, bloqueado em R-5), a troca de modelo está validada só por
inspeção.

---

## Riscos abertos

| # | Risco | Estado |
|---|---|---|
| **R-1** | ~~**Xcode não está instalado.**~~ Estava em `~/Downloads/Xcode-beta.app`, fora do caminho procurado. O compilador `metal` faltava de fato e foi baixado à parte (Metal Toolchain 27A5194o, 805 MB). | **Resolvido na sessão 3.** Ativação por `DEVELOPER_DIR` — ver D-0.9. Verificado com shader Metal e build SwiftPM Swift 6 reais. |
| **R-2** | Distribuição de Core Audio Process Taps pela Mac App Store não confirmada. D-0.1 depende disso. | **Continua aberto.** O Passo 2 foi implementado por decisão do usuário sem essa confirmação. Tecnicamente a API funciona nesta máquina; o risco é de revisão da App Store, não de viabilidade. |
| **R-11** | **O tap do sistema entrega silêncio.** Confirmado em gravação real: 126,6 s de zeros exatos no canal do sistema, com o microfone correto na mesma sessão. 9 configurações testadas, todas iguais. Sem esse canal **não há áudio do interlocutor**, e o posicionamento "app de reunião online" (D-0.1) não se sustenta. | **Aberto e bloqueante para o Passo 2.** Próximo teste depende de R-10 (assinatura real). Ver D-2.6. |
| **R-12** | `kAudioAggregateDeviceTapAutoStartKey = true` **impede** os callbacks do `IOProc` no macOS 27.0 beta — só com `false` o áudio flui. | **Configuração corrigida em D-2.9:** o tap por stream usa `false`. Requer validação real de sinal junto com R-11. |
| **R-3** | Escopo somado nos dois eixos (Process Taps + modelos locais) ainda exige bastante validação de hardware. | **Reduzido em 2026-08-01:** o eixo de equipes/CloudKit foi removido por D-13.3. |
| **R-4** | ~~`Qwen2.5-14B-Q5_K_M` é GGUF/llama.cpp, incompatível com a stack e com o sandbox.~~ | **Resolvido por D-0.5/D-0.6.** Modelo confirmado como GGUF; sandbox resolvido via linkagem de biblioteca, não subprocess. |
| **R-5** | Corpus do Passo 6 exige 5 gravações reais em PT-BR com ground truth **transcrito à mão**. Sem isso, todas as métricas são ficção. Não há decisão sobre quem produz nem quando. | A decidir antes do Passo 6. |
| **R-6** | Guideline 2.5.2 da App Store proíbe baixar código executável. Pesos de modelo são dados e o precedente favorece, mas é interpretação do revisor. Aplica desde o Passo 3, não mais como risco de "fase 2". | Aceito. |
| **R-7** | **RAM < 18 GB bloqueia o app inteiramente** (transcrição e resumo), sem engine alternativa para cair — consequência de D-0.7. Reduz o público endereçável em troca de manter os modelos já escolhidos e evitar depender do Private Cloud Compute (indisponível no prazo). | Aceito conscientemente pelo usuário. |
| **R-8** | ~~Build de `whisper.cpp`/`llama.cpp` dentro do pipeline da Mac App Store não testado.~~ | **Resolvido por D-3.1.** XCFramework oficial com Metal embutido; os dois linkam e carregam juntos. Compilar do fonte deixou de ser necessário. |
| **R-13** | ~~Colisão de símbolos `ggml_*` entre os dois frameworks.~~ | **Resolvido em 2026-07-31.** Pipeline completo executado no mesmo processo: Whisper transcreveu e Qwen resumiu o mesmo áudio, sem colisão. A separação por target + `internal import` (D-3.2) segura. |
| **R-14** | O Qwen preenche `Citacao.speaker` com **nomes próprios** tirados do conteúdo, não com `"eu"`/`"interlocutor"`, e **inventa `start`** (uma citação apontou 256 s num áudio de 193 s). A gramática garante o tipo, não a veracidade. | Aberto. Mitigação provável: validar `start` contra o intervalo dos trechos e mapear o falante pelo trecho mais próximo, em vez de confiar no modelo. |
| **R-15** | **Passo 6 (harness de medição) não executado** — depende do corpus com transcrição manual (R-5). Sem ele não há WER nem acurácia de entidades: a qualidade está avaliada só por inspeção de um áudio. | Aberto. Bloqueado em R-5. |
| **R-9** | Toolchain é um **Xcode beta**, e beta muda de comportamento entre releases. Ver D-0.9. | Parte do local frágil (`~/Downloads`) **resolvida** — movido para `/Applications` durante o Passo 1. Continua aceito quanto ao beta: revalidar R-8 a cada atualização. |
| **R-10** | ~~Sem Apple Developer Team utilizável.~~ | **Resolvido em 2026-07-31.** Uma equipe com assinatura automática foi validada. Desde D-13.3 o projeto não fixa Team: cada publicador seleciona o seu no Xcode. |
| **R-16** | ~~A interface não tem caminho para produzir transcrição nem resumo.~~ `ContentView` passou a ligar captura/importação à `Biblioteca`, ao download ou seleção dos pesos, ao `PipelineDeArquivo` e ao `SwiftDataRepository`; o resultado volta para a lista e para a tela de detalhe. | **Resolvido no código em 2026-07-31** por D-10.5. A validação manual completa com pesos reais e uma gravação continua necessária, mas não há mais lacuna arquitetural entre a interface e o pipeline. |
| **R-17** | ~~O fluxo CloudKit de equipe não foi validado entre duas contas iCloud porque não há segundo dispositivo.~~ | **Fechado em 2026-08-01:** CloudKit e espaços de equipe foram removidos antes da distribuição (D-13.3). |

---

## D-13.5 — Identidade única, assinatura destravada e target de teste (2026-08-18)

**Decidido:** o produto se chama **Papagaio** e o bundle identifier é
`com.papagaio.Papagaio`.

**Por quê:** o app tinha duas identidades ao mesmo tempo. Projeto, workspace,
esquema, ícone e `CFBundleDisplayName` diziam `Loro`; as cinco
`INFOPLIST_KEY_NS*UsageDescription` diziam `Papagaio`. O usuário via os dois
nomes nas mesmas caixas de diálogo de permissão do macOS. O bundle identifier
estava `com.papagaio.Papagaioooo`, com quatro letras "o" — as pendências de
10/08 já apontaram o erro quando eram duas, e ele define o caminho do container
do sandbox e a identidade permanente na App Store.

**Consequência:** renomeados `Loro.xcodeproj`, `Loro.xcworkspace`,
`Loro.xcscheme` e `LoroAppIcon.icns`. `CFBundleIconFile` passa a ser
`PapagaioAppIcon`, o que torna verdadeira pela primeira vez a afirmação de
D-13.4. O manifest do Xcode Cloud tinha duas entradas com o mesmo target id,
resíduo de uma renomeação feita pela metade; ficou uma. Bundle identifier novo
significa **container novo**: bibliotecas e pesos GGUF já baixados em máquinas
de teste ficam órfãos no container antigo. Renomear o target costuma exigir
reapontar o workflow do Xcode Cloud no App Store Connect.

**Assinatura:** `DEVELOPMENT_TEAM` sai do `project.pbxproj`, cumprindo o que
D-13.3 já havia decidido. Fixá-lo era o que obrigava um integrante a manter
`project.pbxproj` e os entitlements alterados só no disco dele — arquivos que,
por isso, "não podiam entrar em commit". `com.apple.developer.aps-environment`
sai dos entitlements: D-13.4 já removera as capacidades de notificação remota, o
app só agenda notificações locais, e a chave em `development` só produziria
divergência de perfil no archive de distribuição.

**Target de teste:** os 17 testes em `PapagaioTests/` eram código morto. O
`.xcodeproj` tinha um único `PBXNativeTarget`, `<Testables>` estava vazio, e o
módulo se chamava `Loro` enquanto os testes faziam `@testable import Papagaio`.
Agora existe o target `PapagaioTests`, com grupo sincronizado por filesystem,
dependência no alvo hospedeiro e `TEST_HOST`/`BUNDLE_LOADER`. Sem fase de
Frameworks de propósito: religar o `PapagaioCore` arrastaria whisper e llama uma
segunda vez para dentro do processo de teste.

**Dois defeitos que os testes acharam ao compilar pela primeira vez:**

1. `Biblioteca.carregar()` gravava a falha de abrir a biblioteca em
   `erros[UUID()]` — dicionário chaveado por arquivo, sob um UUID que não
   pertence a arquivo nenhum. Nenhuma view procura essa chave, então o erro era
   invisível, e cada tentativa acumulava uma entrada. Virou `erroDeCarregamento`,
   com alerta na `BibliotecaHomeView`.
2. `apagarDefinitivamente` removia o registro no SwiftData e a pasta do disco,
   mas deixava as quatro chaves visuais do arquivo em `UserDefaults` órfãs para
   sempre. Fechado por `PreferenciasVisuaisDoArquivo.esquecer(_:)`.

**CI:** `xcodebuild build` virou `xcodebuild test`, com destino concreto
(`platform=macOS,arch=arm64`). Entrou um job de formatação com `.swift-format`,
**bloqueante**, porque a base já passa limpa em `swift format lint --strict`
(zero achados). A previsão de que o primeiro passe acusaria a base inteira era
palpite e foi desmentida pela medição.

**Não decidido:** a limpeza das outras chaves por conversa
(`tarefasDaConversa.<uuid>`, `midiasDaConversa.<uuid>`, aparência de cartão) na
exclusão e em `excluirDadosDaConta` continua aberta, junto da migração dessas
lojas de `UserDefaults` para SwiftData.

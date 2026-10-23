# 00 — Mapa da auditoria técnica Ōmu (Papagaio/Loro)

> **Documento autocontido.** Os demais agentes da auditoria não têm o contexto do
> prompt original: tudo que precisam está aqui. O arquivo já existente foi lido
> integralmente antes desta consolidação; seu conteúdo útil foi preservado.
> Gerado e consolidado pelo Agente de Reconhecimento em **2026-09-23** (horário
> de Brasília, `-0300`).
>
> **Legenda de confiança:**
> - **CONFIRMADO** — executei/medi na máquina (inclusive por agente paralelo), com comando e saída registrados nesta auditoria.
> - **PROVÁVEL** — inferência forte a partir de evidência lida, sem execução direta.
> - **HIPÓTESE** — plausível, não verificada.
>
> **Modo:** relatório (somente leitura + escrita no arquivo indicado abaixo).
> Nenhum código de produção, manifesto, configuração, dependência, serviço ou
> banco foi alterado.
> O único arquivo que **este agente** pode escrever é `audit/00-mapa.md`; os
> comandos abaixo foram executados com as restrições registradas na §10.
>
> **Como ler a evidência:** **fato** é uma leitura de arquivo ou uma saída de
> comando; **comando** é a invocação literal, sem ser tratado como resultado;
> **inferência** é a interpretação, marcada como provável/hipótese. Referências
> `arquivo:linha` apontam para evidência local; logs temporários são citados com
> o caminho e a linha. Segredos nunca são transcritos: apenas a existência de uma
> configuração local é registrada.

---

## 1. Stack e versões exatas

### 1.1 Ferramentas desta máquina (medido, CONFIRMADO)

| Item | Valor | Como medi |
|---|---|---|
| Swift | 6.4 (swiftlang-6.4.0.20.104, clang-2100.3.20.102) | `swift --version` |
| Xcode | 27.0 (27A5194q), `/Applications/Xcode-beta.app` | `xcodebuild -version`, `xcode-select -p` |
| SDK | MacOSX27.0.sdk | saída do `xcodebuild build` (log `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-build.log:79-103`) |
| macOS | 27.0 (26A428) | `sw_vers` |
| Hardware | Apple M5, arm64, 24 GiB RAM (25769803776 bytes) | `sysctl -n machdep.cpu.brand_string`, `hw.memsize`, `uname -m` |

### 1.2 Configuração declarada do projeto (lido em `Loro.xcodeproj/project.pbxproj`)

| Setting | Valor | Linha (grep) |
|---|---|---|
| `SWIFT_VERSION` | 6.0 | `Loro.xcodeproj/project.pbxproj:361`, `:384`, `:415`, `:437` |
| `MACOSX_DEPLOYMENT_TARGET` | 26.0 | `Loro.xcodeproj/project.pbxproj:353`, `:376`, `:407`, `:431` |
| `SDKROOT` | macosx | `Loro.xcodeproj/project.pbxproj:360`, `:383`, `:411`, `:434` |
| `SWIFT_STRICT_CONCURRENCY` | complete (nível projeto) | `Loro.xcodeproj/project.pbxproj:414`, `:436` |
| `PRODUCT_NAME` (target Loro) | `"Ōmu"` → gera `Ōmu.app` | `Loro.xcodeproj/project.pbxproj:474`, `:514` |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | 1.3 / 31 | `Loro.xcodeproj/project.pbxproj:470`, `:450` |
| `PRODUCT_BUNDLE_IDENTIFIER` | com.papagaio.Papagaio | `Loro.xcodeproj/project.pbxproj:472`, `:512` |
| `OTHER_LDFLAGS` | `-Wl,-export_dynamic` | `Loro.xcodeproj/project.pbxproj:471` |
| Config base do target | `Base.xcconfig` (injeta secrets) | `Loro.xcodeproj/project.pbxproj:443` |
| Targets Xcode | `Loro` (app) + `PapagaioTests` | `Loro.xcodeproj/project.pbxproj:195-213`, `:217-240` |
| Pacote local | `XCLocalSwiftPackageReference "PapagaioCore"` | `Loro.xcodeproj/project.pbxproj:554-556` |

`PapagaioCore/Package.swift`: `swift-tools-version: 6.0` (linha 1),
`platforms: [.macOS("26.0")]` (linha 6), e todos os targets com
`swiftLanguageMode(.v6)` (linhas 42, 47, 52, 64, 82, 87, 92).

### 1.3 Dependências SwiftPM — versões exatas e qual `Package.resolved` manda

Os **três** `Package.resolved` do repo pinsam a **mesma única dependência remota**,
com a mesma revisão — só o `originHash` (hash do grafo de resolução) difere:

| Arquivo | pin | originHash |
|---|---|---|
| `Loro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | FluidAudio **0.15.5** (rev `19600a485baa4998812e4654b70d2bab8f2c9949`) | `679f14cb069e…` |
| `Loro.xcworkspace/xcshareddata/swiftpm/Package.resolved` | FluidAudio **0.15.5** (mesma rev) | `def56519cd42…` |
| `PapagaioCore/Package.resolved` | FluidAudio **0.15.5** (mesma rev) | `7deab3280146…` |

(linha da versão em cada arquivo: `:10`; identidade: `:5` — conteúdo idêntico nos três.)

**Fonte autoritativa (PROVÁVEL, consistente com o que executei):**
- **App:** `Loro.xcodeproj/project.xcworkspace/…/Package.resolved` — CI e README
  constroem com `xcodebuild -project Loro.xcodeproj` (`.github/workflows/ci.yml:36`, `:46`;
  `README.md:106-112`), e o build executado logou `Checking out 0.15.5 of
  package 'FluidAudio'` (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-build.log:7-19`).
- **Core (SPM puro):** `PapagaioCore/Package.resolved` — usado por
  `swift test` rodando dentro de `PapagaioCore/` (`Scripts/testa-papagaio-core.sh` faz `cd` no pacote).
- O `Loro.xcworkspace/…/Package.resolved` só manda se alguém abrir o **workspace**;
  nenhum comando desta auditoria o usou.

Declaração fixa no manifest:
`PapagaioCore/Package.swift:15` → `.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")`.

### 1.4 Dependências não-SwiftPM (binários e modelos, via bootstrap)

XCFrameworks baixados por `Scripts/bootstrap-runtimes.sh` (não versionados; presentes nesta máquina — **CONFIRMADO** por `ls PapagaioCore/Frameworks/`):

| Artefato | Versão/commit fixado | SHA-256 fixado | Linha no script |
|---|---|---|---|
| whisper.cpp xcframework | tag `v1.9.1` | `8c3ecbe73f48…` | `Scripts/bootstrap-runtimes.sh:51-52` |
| llama.cpp xcframework | tag `b9222` | `39b5d476d571…` | `Scripts/bootstrap-runtimes.sh:49-50` |
| ONNX Runtime | `1.24.2` | `f7100a992d2a…` | `Scripts/bootstrap-runtimes.sh:56-57` |
| Silero VAD (`silero_vad.onnx`, em `Sources/PapagaioCore/Resources/`) | commit fixado snakers4/silero-vad | `1a153a22f450…` | `Scripts/bootstrap-runtimes.sh:58`, `:297` |

Peso dos binários declarados em `PapagaioCore/Package.swift:22-27` (`binaryTarget` whisper/llama/onnxruntime em `Frameworks/`).
Modelos de IA para resumo/transcrição (fora do git; **presentes nesta máquina**, CONFIRMADO por `ls`):
- `~/Library/Application Support/Papagaio/Models/ggml-large-v3.bin` (3.095.033.483 B — bate com `Preflight.swift:24`)
- `~/Library/Application Support/Papagaio/Models/Qwen_Qwen3.5-9B-Q4_K_M.gguf` (6.169.341.984 B — bate com `Preflight.swift:31`)
- Modelos de diarização CoreML versionados no repo: `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/` (21 MB, CONFIRMADO por `du`).

**Não executei** `bootstrap-runtimes.sh` (baixa ~1 GB; restrição da auditoria: sem atualizar dependências). Os artefatos já estavam presentes.

### 1.5 Segredos/config local

- `Config/Base.xcconfig:7-8` faz `#include? "Secrets.xcconfig"` (opcional — sem ele o build não quebra).
- `Config/Secrets.example.xcconfig:10` define `GOOGLE_CLIENT_ID` (template).
- `Config/Secrets.xcconfig` **existe nesta máquina** (gitignored, 273 B, com chaves de credenciais — existência CONFIRMADA por `ls`; os valores foram mascarados e não são necessários para a auditoria).

---

## 2. Arquitetura

### 2.1 Módulos e papéis

```
Papagaio/            171 arquivos .swift / 34.232 linhas — app SwiftUI (target Xcode "Loro", módulo Papagaio, binário Ōmu.app)
  App/               entry point + navegação           (5 arquivos)
  CloudKit/          sync de equipes                   (4)
  DesignSystem/      tema + 18 componentes             (22)
  Diagnostico/       diag do System Audio Tap          (2)
  Funcionalidades/   telas (Biblioteca, Detalhe, Gravacao, Equipes, Tarefas, Midias, Perfil, Configuracoes) (64)
  Integracao/        OAuth Google/Granola, MCP, Calendar (9)
  Modelos/           structs de produto                (18)
  Persistencia/      stores UserDefaults/arquivos      (23)
  Suporte/           busca, localização, export, share (14)
  ViewModels/        Biblioteca, GravadorViewModel…    (10)
PapagaioCore/        pacote SwiftPM local (Package.swift:105 linhas)
  Sources/           61 arquivos / 11.370 linhas
    PapagaioCore/    domínio puro (49 arquivos): Captura, Transcricao, Sumarizacao,
                     Diarizacao, Processamento, Persistencia, Reproducao, Runtime,
                     Integracao, Exportacao, Importacao + Contratos/Dominio
    WhisperRuntime/  wrapper clang do whisper.cpp (isolado p/ ggml — Package.swift:30-40 comenta o porquê)
    LlamaRuntime/    wrapper do llama.cpp
    OnnxApi/         wrapper do ONNX Runtime (Silero VAD)
    DiarizationRuntime/ wrapper Sendable do FluidAudio (CoreML)
    papagaio-eval/   CLI de diagnóstico/bench (6 arquivos)
  Tests/             20 arquivos / 4.837 linhas (Swift Testing + 1 XCTest)
  Frameworks/        XCFrameworks baixados (não versionados)
PapagaioTests/       13 arquivos / 2.893 linhas — testes do app (Swift Testing, 107 @Test)
Scripts/             bootstrap, testes core, bench, geração de traduções (5 .sh/.rb/.py principais + tests/)
ci_scripts/          ci_post_clone.sh (Xcode Cloud → bootstrap)
.github/workflows/   ci.yml (51 linhas)
Config/              xcconfig, Info.plist, entitlements
docs/                analise-performance-2026-09-22/relatorio.md (NÃO rastreado pelo git)
```

Contagens por subpasta de `Papagaio/` (linhas, medida): App 1.296 · CloudKit 1.301 ·
DesignSystem 2.623 · Diagnostico 265 · Funcionalidades 17.400 · Integracao 2.550 ·
Modelos 846 · Persistencia 2.604 · Suporte 2.015 · ViewModels 3.332. Soma = 34.232 ✓.

### 2.2 Pontos de entrada

- **`Papagaio/App/PapagaioApp.swift:9-17`** — `@main enum InicializacaoDoPapagaio`
  escolhe o host **antes** de qualquer estado: se
  `PoliticaDeInicializacaoExterna().permiteServicosExternos` → `PapagaioApp.main()`,
  senão `HostDeTestesDoPapagaio.main()` (janela vazia `Color.clear`).
- **`Papagaio/App/PoliticaDeInicializacaoExterna.swift:13-16`** — modo teste =
  env `PAPAGAIO_TEST_MODE=1` **ou** `XCTestConfigurationFilePath` presente.
- **`Papagaio/App/PapagaioApp.swift:28`** — `@NSApplicationDelegateAdaptor(DelegadoDeConvitesCloudKit.self)`
  (aceite de convites `CKShare` chega via delegate).
- **`Papagaio/App/PapagaioApp.swift:33`** — `GravadorViewModel` nasce na Scene (compartilhado com menu bar).
- **`Papagaio/App/PapagaioApp.swift:41-58`** — `init()` roda `DiagnosticoTap` (R-11, sai em seguida),
  `CamposDoCartao.ligarCamposNovos()` e `MigracaoDeStatusDeTarefas.executarUmaVez()` (migrações).
- **`Papagaio/App/PapagaioApp.swift:59+`** — `WindowGroup` → `ContentView(gravador:)`,
  painel flutuante de gravação e `MenuBarExtra` (só enquanto grava).
- **`Papagaio/App/ContentView.swift:34`** — `struct ContentView` (1.092 linhas): orquestra
  biblioteca, importação, equipes, Calendar, Granola, navegação.
- **Navegação:** `NavigationStack` com `navigationDestination(for: UUID.self)` (`ContentView.swift:154`);
  telas raiz enumeradas em `Papagaio/App/Navegacao/TelaPrincipal.swift:3-11`
  (biblioteca/tarefas/midias/configuracoes/perfil/equipe);
  contexto de conta (pessoal × equipe) em `Papagaio/App/Navegacao/ContextoDaConta.swift:3`.

### 2.3 Camadas e fluxo de dados (síntese)

```
[Captura] SessaoGravacao (microfone AVAudioRecorder) + SystemAudioTap (Process Taps, Core Audio)
          PapagaioCore/…/Captura/SessaoGravacao.swift:17, SystemAudioTap.swift:3-8
[Importação] ImportadorAudio.importar(de:) — PapagaioCore/…/Importacao/ImportadorAudio.swift:42
     │  GravadorViewModel.iniciar()/importar() — Papagaio/ViewModels/GravadorViewModel.swift:427/373
     ▼
[Fila + Pipeline] Biblioteca (filaDeProcessamento, Biblioteca.swift:42-45) monta
     PipelineDeArquivo com closures reais — Papagaio/ViewModels/Biblioteca.swift:905-931
     PipelineDeArquivo.processar — PapagaioCore/…/Processamento/PipelineDeArquivo.swift:101
       transcrever(Whisper) → diarizar(FluidAudio) → resolverFalantes(Qwen) →
       [traduzir] → salvar(SwiftData) → resumir(Qwen) → salvar        (:116-189)
     │  MotoresLocais (carga/descarga dos modelos; exclusividade por instância, ver A2-003) — PapagaioCore/…/Runtime/MotoresLocais.swift:138-208
     ▼
[Persistência] SwiftDataRepository (@ModelActor) — PapagaioCore/…/Persistencia/SwiftDataRepository.swift:12
     containerLocal(cloudKitDatabase: .none) — :18-36  →  ModelContainer local "Papagaio"
     @Model: EspacoPersistido/ArquivoPersistido/TrechoPersistido/InsightPersistido/NotaPersistida
     — PapagaioCore/…/Persistencia/ModelosSwiftData.swift:12/27/91/119/142
     Dados não-SwiftData (favoritos, pastas, tarefas, lixeira, anexos, perfil…) em
     UserDefaults/arquivos via Papagaio/Persistencia/* (23 arquivos)
     ▼
[UI] Biblioteca (@MainActor @Observable, Biblioteca.swift:19-20) → views de
     Funcionalidades/*  ·  EstadoDoArquivo.fase (Papagaio/Modelos/EstadoDoArquivo.swift:15-30)
     ▼
[CloudKit — equipes] ao trocar de espaço (Biblioteca.usarEspaco, :211) →
     FilaPersistenteCloudKit (fila-pendente.json, :159-163) →
     SincronizadorDaBibliotecaCloudKit (TransporteDeConversasCloudKit, :127) →
     zona custom por equipe + CKShare + registro público CodigoDeEquipe
     (Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift)
```

### 2.4 Dependências externas

| Sistema | Onde |
|---|---|
| **CloudKit** (iCloud.com.papagaio.Papagaio, CloudKit only) | `Config/Papagaio.entitlements:11-16`; 4 arquivos em `Papagaio/CloudKit/` |
| **Sign in with Apple** | `Papagaio/ViewModels/PerfilViewModel.swift:2`, `:60-63`, `:206-241`; entitlement `Config/Papagaio.entitlements:5` |
| **Google Calendar OAuth 2.0 (loopback + PKCE)** | `Papagaio/Integracao/SessaoOAuthGoogle.swift:68`, `:124`, `:187`, `:329`; Client ID via `Config/Base.xcconfig:8` |
| **EventKit** (calendário local p/ prompt de entidades) | `Papagaio/Suporte/PromptDeEntidades.swift:2`, `:28`, `:61-62`; entitlement `Config/Papagaio.entitlements:35` |
| **Granola via OAuth DCR+PKCE + MCP (JSON-RPC over Streamable HTTP)** | app: `Papagaio/Integracao/SessaoOAuth.swift:58`, `GranolaViewModel.swift:27`, `ClienteMCP.swift:32`; core: `PapagaioCore/…/Integracao/ClienteMCP.swift:141`, `AutenticacaoOAuth.swift:106-251`, `CofreDeTokens.swift:7` (Keychain) |
| **Sandbox/rede** | `Config/Papagaio.entitlements:19-33` (app sandbox, network client/server, audio-input, disable-library-validation) |
| **UserNotifications** | `Papagaio/ViewModels/NotificacoesViewModel.swift:3`, `:54` |
| **Localização** | `Localizable.xcstrings` (12.361 linhas; **1.131 chaves, idiomas `en` e `pt-BR`** — medido com script Python) + tabela fallback `Papagaio/Suporte/TabelaDeStrings.swift:6` (1.124 linhas) + helper `Papagaio/Suporte/Localizacao.swift:27-40` (`.localized`) |

---

## 3. Fluxos críticos (cada passo mapeado até o arquivo que o implementa)

### 3.a Gravação/importação → transcrição → resumo/notas/tarefas

| Passo | Arquivo:linha |
|---|---|
| UI de gravação, notas durante gravação | `Papagaio/Funcionalidades/Gravacao/PainelDeGravacao.swift:3`, `NotasDuranteGravacao.swift:7`, `Waveform.swift:6`, `JanelaFlutuanteDeGravacao.swift:21/39/173` |
| ViewModel (iniciar/pausar/importar/concluir ditado) | `Papagaio/ViewModels/GravadorViewModel.swift:11`, `:427`, `:509`, `:373`, `:551` (ditado → `concluir(transcrever:)`) |
| Captura microfone + sistema + pausa/continua | `PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift:17`, `:92`, `:183`, `:196`, `:217`; tap do sistema `SystemAudioTap.swift:3-16` (Process Taps, macOS 14.4+); erros `ErroCaptura.swift:6`; nível `NivelAudio.swift:16` |
| Armazenamento em pastas por gravação | `PapagaioCore/Sources/PapagaioCore/Captura/Armazenamento.swift:11`, `:43`, `:70`, `:83`, `:101` |
| Importação (cópia sem re-encode) | `PapagaioCore/Sources/PapagaioCore/Importacao/ImportadorAudio.swift:42`; entrada UI `ContentView.swift:261`, `:661` (drag&drop), extensões em `ContentView.swift:673-680` |
| Enfileirar + processar (fila de 1 em 1) | `Papagaio/ViewModels/Biblioteca.swift:42-45`, `:315` (processamento automático), montagem do pipeline `:905-931`, `pipeline.processar` `:937` |
| Pipeline (fases) | `PapagaioCore/…/Processamento/PipelineDeArquivo.swift:15-21` (enum Fase), `:101-189` (processar), diarização decorativa `:119-131`, tradução `:143-157`, resumo no idioma `:165-185` |
| Engines locais | Whisper `Transcricao/WhisperEngine.swift:43`; Qwen `Sumarizacao/QwenEngine.swift:10` (summarize `:33`, traduzir `:69`); VAD Silero `Transcricao/SileroVAD.swift:21` + `DetectorDeAtividadeDeVoz`; diarização `Diarizacao/GerenciadorDeModelosDeDiarizacao.swift:12/32/60`; alinhamento palavra×segmento `AlinhamentoDeFalantes.swift:68`; resolução de falantes `ResolvedorDeFalantes.swift:85/169` |
| Ciclo de vida de modelos (memória) | `Runtime/CicloDeVidaDeModelos.swift:14`, `:53`, `:68`; download+sha `DownloadDeModelos.swift:62`, `:184-189`; preflight `Preflight.swift:86/100/166` |
| Persistência (duas chamadas de salvar por pipeline) | `SwiftDataRepository.swift:40`; observado em `PipelineDeArquivo.swift:159`, `:187` |
| Notas da conversa | `Papagaio/Funcionalidades/Detalhe/NotasDaConversa.swift:15`; VM `Papagaio/ViewModels/NotasDaConversaViewModel.swift:29`, `:104`, `:158` (marcador no instante) |
| Tarefas da conversa + sugestões | `Papagaio/Funcionalidades/Detalhe/Tarefas/*` (6 arquivos); store `Papagaio/Persistencia/TarefasDaConversa.swift:5/33`; VM `Papagaio/ViewModels/TarefasDaConversaViewModel.swift:12` |
| Resumo/notas viram UI | seções do detalhe `Papagaio/Funcionalidades/Detalhe/BarraDeSecoesDaConversa.swift:8-13` (Resumo/Transcrição/Notas/Mídia/Tarefas) |
| Testes deste fluxo | Core: `PipelineTests.swift` (16 @Test — **1 está falhando, ver §5.1**), `TranscricaoTests`, `SumarizacaoTests`, `CapturaTests`, `PersistenciaTests`; App: `BibliotecaTests.swift` (26 @Test: fila, duplicar, processamento) |

### 3.b Biblioteca (busca, pastas, favoritos, lixeira)

| Passo | Arquivo:linha |
|---|---|
| Tela principal + cartões | `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:8` (1.365 l.), `CartaoDeConversa.swift` (1.867 l., `alternarFavorito` `:1404`) |
| Busca | Backend: `SwiftDataRepository.buscar(termo:espaco:)` `PapagaioCore/…/Persistencia/SwiftDataRepository.swift:135` — bucket A título (`:144-156`), bucket B corpo: visão geral `:175`, trechos `:184`, insights `:193`, notas (seqüente); `localizedStandardContains` ignora acento/caixa (`:130`). Filtro local na UI: `BibliotecaHomeView.swift:401-417` (título, pasta, metadados, data, duração, participantes, resumo) + `Papagaio/Suporte/BuscaSemAcento.swift:10` |
| Favoritos | estado `PreferenciasVisuaisDoArquivo.swift:33/37`; atalho de filtro `AtalhosDaBiblioteca.swift:4-5` (`.favoritos`); botão `CartaoDeConversa.swift:1119/1129` |
| Pastas | criar/renomear/apagar `PreferenciasVisuaisDoArquivo.swift:46-138`; grade/capa/cor `Papagaio/Funcionalidades/Biblioteca/GradeDePastas.swift:13/81/534`; lixeira de pastas `Papagaio/Persistencia/LixeiraDePastas.swift:9/36/43/54`; restauração com conversas `PastasDaBiblioteca.swift:28/55/72/89`; filtro `FiltroDeConversas.swift:4-5` |
| Lixeira (arquivos) | mover/restaurar/esvaziar `Biblioteca.swift:390/443/507`; seção `Papagaio/Modelos/SecaoDaBiblioteca.swift:8-10` |
| Lixeira de mídia/tarefas | `Papagaio/Persistencia/LixeiraDeMidia.swift:33/100/154/176`; `Papagaio/Funcionalidades/Biblioteca/Lixeira/LixeiraDeTarefas.swift:5/12/19/29` |
| Duplicar/renomear/exportar | `Biblioteca.swift:599` (renomear), `:696` (duplicar); export Markdown `Papagaio/Suporte/DossieDaConversa.swift:6/28/56` → `PapagaioCore/…/Exportacao/ExportacaoMarkdown.swift:9`; compartilhamento `Papagaio/Suporte/OpcoesDeCompartilhamento.swift:19-92` |
| Testes | `PapagaioTests/BibliotecaTests.swift` (26), `PastasDaBibliotecaTests.swift` (4), `LixeiraDeMidiaTests.swift` (8) |

### 3.c Player + navegação pela transcrição

| Passo | Arquivo:linha |
|---|---|
| Reprodutor (tocar/pausar/velocidade/saltar) | `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:111` (preparar), `:136` (tocar), `:147` (pausar), `:159` (velocidade), `:174` (saltar p/ trecho), `:179` (tocar a partir de trecho), `:191` (saltar p/ segundo), `:229` (tick), `:242` (palavra ativa) |
| Navegação trecho/palavra | `Reproducao/NavegacaoPorTrecho.swift:22/41`; `NavegacaoPorPalavra.swift:17` |
| Integração na tela de detalhe | `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:41` (estado), `:495` (cria reprodutor), `:1194-1215` (tocar trecho/editar posição), `:1554` (transcrição por trechos), `:1539` (palavra ativa), `:1763` (tocar palavra); MARKs `:605` navegação, `:1331` transcrição |
| Barra de áudio (velocidade, mudo, seek) | `Papagaio/Funcionalidades/Detalhe/Player/BarraDeAudioDaConversa.swift:7`, `:254`, `:285` |
| Linhas da transcrição / edição inline / nomes de voz | `Detalhe/Transcricao/LinhaDeTranscricao.swift`, `LinhaDeFala.swift`, `EditorInlineDaTranscricao.swift`, `EditorDeNomesDeVoz.swift`, `RotuloDeVoz.swift`; nome preservado por trecho `Papagaio/Persistencia/FalantePreservadoParaTrecho.swift:9/20` |
| Falas agrupadas (turnos) | `PapagaioCore/…/Diarizacao/FalasDaConversa.swift:75/156` |
| Testes | Core: `ReproducaoTests.swift` (9 @Test); App: `InterfaceTests.swift` (15, incl. “Space do player…”) |

### 3.d Equipes CloudKit (criação, CKShare, código de 6 chars, sync)

| Passo | Arquivo:linha |
|---|---|
| Criar workspace: zona custom + `CKShare` + publicar código | `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:48-89` (`criarWorkspace`), `CKShare` `:59-60`, publicar código `:73`, registro público `CodigoDeEquipe` tipo `:27` campo `codigoDeEntrada` `:16` |
| Código de 6 caracteres (alfabeto sem 0/O/1/I) | `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:135-136` |
| Entrar com código (query no registro público) | `ServicoDeEquipesCloudKit.swift:91-104` (`entrarNaEquipe`), normalização `:377-378` |
| Aceite de convite (CKShare via app delegate) | `Papagaio/CloudKit/DelegadoDeConvitesCloudKit.swift:12-24` (`userDidAcceptCloudKitShareWith` → `aceitar`); `aceitar(_:)` `ServicoDeEquipesCloudKit.swift:339-374` |
| Rotação de código (troca o CKShare) | `ServicoDeEquipesCloudKit.swift:242-270`; UI `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:106-111/309` |
| Exclusão global (marcador `EquipeExcluida`) | `ServicoDeEquipesCloudKit.swift:280-293`; reconciliação `ContentView.swift:761-782`; limpeza local `ContentView.swift:784-796` |
| Sync de conversas textuais (paginação, mesclagem, conflitos) | `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:45` (preparar envio), `:51` (mesclar), `:71` (decidir), `:127` (protocolo transportável), `:156-295` (transporte CKRecord), `:351-396` (enviar/baixar/remover) |
| Fila persistente com backoff | `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:55` (agendarEnvio), `:103` (processar), `:199` (atraso); arquivo `fila-pendente.json` `Biblioteca.swift:159-163` |
| Custo de busca da zona (estático, não medido) | `SincronizadorDaBibliotecaCloudKit.swift:246-270` usa `fetchAllChanges = true` sem token; a pesquisa P3 registra leitura integral da zona em `audit/01-pesquisa/cloudkit.md:93-117` |
| Estado observável + retomada | `Biblioteca.swift:6-11` (enum), `:52`, `:1075-1118` (sincronizar), `:1088` (retomar), `:491` falha |
| Troca de espaço pessoal×equipe | `Biblioteca.usarEspaco` `:211-223`; criação de espaço `ContentView.swift:839-850`; add/entrar `ContentView.swift:797-838` |
| UI de gestão (membros, permissões, código) | `GestaoDeEquipeView.swift:3-28` (572 l.), `TabelaDaEquipe.swift:3/98/120`, `SeletorDeEquipeView.swift:3`, `Papagaio/Funcionalidades/Perfil/EquipesDoPerfil.swift:3` |
| Persistência de equipes/membros | `Papagaio/Persistencia/EquipesDoUsuario.swift:7-32`, `MembrosDasEquipes.swift:10-35`; migração `MigracaoDeRemocaoDeEquipes.swift:6-34` |
| Schema esperado no CloudKit Dashboard | documentado `README.md:85-98` |
| Testes | `PapagaioTests/EquipesCloudKitTests.swift` (16 @Test — **3 falhando por localização, ver §5.2**) |

### 3.e Integrações OAuth Google Calendar / MCP

| Passo | Arquivo:linha |
|---|---|
| OAuth Google: fluxo loopback + PKCE S256 (96 chars) | `Papagaio/Integracao/SessaoOAuthGoogle.swift:124` (fluxo), `:160` (aguardar código c/ timeout), `:187-413` (servidor local em 127.0.0.1:0), `:221` (troca código), `:329-337` (PKCE), `:340` (info da conta) |
| Timeout/cancelamento da espera | `SessaoOAuthGoogle.swift:160-185` (task group), `:423-441` (`withTaskCancellationHandler` + `shutdown`), `:444-452` (`parar`) — **2 testes TRAVAM aqui (§5.2)** |
| ViewModel Calendar (conectar, sync periódica, importar áudio p/ reunião) | `Papagaio/Integracao/GoogleCalendarViewModel.swift:20`, `:60`, `:152` (timer), `:188` (importarAudioParaReuniao) |
| Fonte da API + pendências de reunião | `FonteGoogleCalendarAPI.swift:5/48/101/156`; `Papagaio/Modelos/ReuniaoPendenteCalendar.swift`; estado `Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:22-66` |
| Apresentação/auth session + callback | `ApresentadorDeSessaoDeAutorizacao.swift:13-17`, `GerenciadorDeCallbackDeAutorizacao.swift:13-50` |
| Granola (OAuth DCR + PKCE) | `SessaoOAuth.swift:58`; `GranolaViewModel.swift:27`; core `PapagaioCore/…/Integracao/AutenticacaoOAuth.swift:106` (registro `:134`, autorização `:199`, PKCE `:241`), cofre Keychain `CofreDeTokens.swift:7-67` |
| MCP (JSON-RPC 2.0 / Streamable HTTP) | app `Papagaio/Integracao/ClienteMCP.swift:5-30` (erros) e `:32` (cliente); core `PapagaioCore/…/Integracao/ClienteMCP.swift:141` (`chamar`), `:148` (initialize), `:185` (retry) |
| Contratos de reunião externa (Granola/Calendar) | `PapagaioCore/…/Integracao/ReuniaoExterna.swift:5/40/120/172`, `ParticipanteDaReuniao.swift:9` |
| Ponto de entrada no app (conexão/abertura) | `ContentView.swift:449` (cria `GoogleCalendarViewModel`), `:518` (`conectarGoogleCalendarSeAutorizado`), `:387` e `:479` (importar para reunião pendente); card `Papagaio/Funcionalidades/Biblioteca/CartaoReuniaoPendente.swift:3` |
| Segredos | `Config/Base.xcconfig:8` + `Config/Secrets.xcconfig` (local) |
| Testes | App: `OAuthGoogleTests.swift` (9 — **2 TRAVAM**), `GoogleCalendarTests.swift` (5); Core: `IntegracaoTests.swift` (14 — PKCE/URLs/mensagens) |

---

## 4. Comandos de build, teste, lint e execução

### 4.1 Comandos documentados

| Fonte | Comando |
|---|---|
| `README.md:82` | `./Scripts/bootstrap-runtimes.sh` (primeira config) |
| `README.md:103` | `./Scripts/bootstrap-runtimes.sh` (validação local) |
| `README.md:104` | `./Scripts/testa-papagaio-core.sh` |
| `README.md:106-112` | `xcodebuild build -project Loro.xcodeproj -scheme Loro -destination 'generic/platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` |
| `.github/workflows/ci.yml:10-20` | job `test-papagaio-core` (macos-26): bootstrap + `./Scripts/testa-papagaio-core.sh` |
| `.github/workflows/ci.yml:22-42` | job `build-app`: bootstrap + `xcodebuild test … PAPAGAIO_TEST_MODE=1 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -derivedDataPath /private/tmp/papagaio-ci-app-tests` |
| `.github/workflows/ci.yml:44-51` | job `build-app`: `xcodebuild build …` |
| Scheme do app | `Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:32` injeta `PAPAGAIO_TEST_MODE=1` no TestAction; alvo `PapagaioTests.xctest` (`:39-47`) |
| `ci_scripts/ci_post_clone.sh:22` | Xcode Cloud: roda o bootstrap a cada build |
| `Scripts/bench-papagaio.sh:1-24` | micro/macro benchmarks (`bench` da CLI `papagaio-eval`, versão `0.2.0-bench` — **arquivo NÃO rastreado, WIP**) |
| `Scripts/adiciona-target-de-testes.rb`, `Scripts/build_complete_catalog.py`, `Scripts/generate_translations.py` | utilitários (ruby p/ scheme, geração de catálogo/traduções) — **não referenciados pela CI** |

### 4.2 O que EXECUTEI nesta sessão (resultados reais em §5)

| Comando | Executou? | Resultado resumido |
|---|---|---|
| `./Scripts/testa-papagaio-core.sh` (via `cd PapagaioCore && /usr/bin/time -p …`) | ✅ | exit **1** — 6 XCTest + 216 testes Swift; **1 teste com 2 issues**, 4 skips; **24,95 s** wall (detalhe §5.1) |
| `xcodebuild build -project Loro.xcodeproj -scheme Loro -destination 'generic/platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` | ✅ | exit 0, **48,34 s**, `** BUILD SUCCEEDED **`; logs de build em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-build.log:6000-6023` |
| `PAPAGAIO_TEST_MODE=1 xcodebuild test … -derivedDataPath /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-derived` | ⚠️ **TRAVOU → interrompido** | 107 testes iniciaram; 105 finalizaram (**99 pass / 6 fail / 2 pendurados**); sem linha final, `** BUILD INTERRUPTED **` — ver §5.2 |
| `python3 -m unittest Scripts.tests.test_scripts` | ✅ | 8 testes, **3 falhas**, **2,80 s** — ver §5.4 |
| `./Scripts/bench-papagaio.sh --so-micro --iteracoes 5 …` | ✅ | build release do core **45,04 s**; execução total **48,58 s**; 11 resultados micro — ver §11 |
| Linter (SwiftLint/SwiftFormat/etc.) | ❌ **não existe** | ver §5.5 |
| Cobertura de testes | ❌ **não configurada** | ver §5.5 |
| `Scripts/bootstrap-runtimes.sh` | ❌ não executei | artefatos já estavam presentes; não atualizei dependências |
| Teste de sync CloudKit real, OAuth Google real | ❌ não executei | restrição: sem escrita em serviços reais |

---

## 5. Baseline executada (números medidos, não estimados)

**Condições comuns:** Apple M5, 24 GiB, macOS 27.0 (26A428), Xcode-beta 27.0
(27A5194q), Swift 6.4, 2026-09-23 `-0300`. Os tempos são de execução local e
incluem o estado não commitado descrito na §6.3. A máquina estava sob carga e
houve outro processo de auditoria concorrente; por isso os tempos são
observações desta máquina, não SLAs.

### 5.1 Testes do PapagaioCore — `./Scripts/testa-papagaio-core.sh` (CONFIRMADO)

- **Comando:** `cd PapagaioCore && /usr/bin/time -p ../Scripts/testa-papagaio-core.sh`.
- **Resultado medido:** exit **1**; `real 24.95 s` (user 25.15, sys 6.89).
  A saída está em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/core-test.log:568-573`.
- **Evento de ambiente recuperado:** a primeira tentativa de codesign do
  `.xctest` falhou com `resource fork, Finder information, or similar
  detritus not allowed`; o script WIP limpou o FinderInfo e assinou o bundle,
  depois registrou a mensagem em `core-test.log:39-47`. Isso é condição de
  ambiente, não uma falha do teste de domínio.
- **Contagem observada:**

  | Suíte | Casos | Resultado observado |
  |---|---:|---|
  | XCTest `CanceladorDeEcoTests` | 6 | 6 passaram (`core-test.log:48-68`) |
  | Swift Testing (8 suítes) | 216 | 211 passaram, 1 falhou, 4 pulados (`core-test.log:568`) |
  | **Total** | **222** | **217 passaram · 1 teste falhou · 4 pulados** |

- **Falha de produto (2 issues em 1 teste):** o teste *“Pipeline traduz antes
  de salvar e resume no idioma de destino”* falhou em
  `PapagaioCore/Tests/PapagaioCoreTests/PipelineTests.swift:554` e `:579`,
  comparando o `Trecho.id` antes/depois (`core-test.log:334-343`). A
  investigação estática aponta `Segmentacao.agrupar` recriando o UUID ao
  fechar um grupo em `PapagaioCore/Sources/PapagaioCore/Processamento/Segmentacao.swift:31-49`,
  acionado pelo caminho de mixagem em `PipelineDeArquivo.swift:259`. A causa
  funcional é **CONFIRMADA pelo teste**; a intenção de corrigir é PROVÁVEL, não
  implementada nesta onda.
- **Skips:** quatro testes de Whisper/Qwen pulados (`core-test.log:524-547`).
  Fato: os testes procuram `~/Documents/InterviewLab/Models`
  (`TranscricaoTests.swift:9-13`, `SumarizacaoTests.swift:6-10`), enquanto os
  pesos usados pelo app existem em `~/Library/Application Support/Papagaio/Models`
  (confirmado na §1.4). Inferência: há drift de caminho; não se mediu aqui a
  qualidade de transcrição/resumo.
- **Compilação:** houve quatro linhas de warning do CLI em
  `PapagaioCore/Sources/papagaio-eval/main.swift:70` (repetidas no log), não
  zero warnings; elas são do alvo de diagnóstico, não do Swift do domínio.

### 5.2 Testes do app — `xcodebuild test` com `PAPAGAIO_TEST_MODE=1` (CONFIRMADO parcial; RUN NÃO CONCLUIU)

- **Comando:** `PAPAGAIO_TEST_MODE=1 xcodebuild test -project Loro.xcodeproj -scheme Loro -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -derivedDataPath /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-derived`
  (mesma forma do job CI em `.github/workflows/ci.yml:31-42`).
- **Comando de isolamento:** `xcodebuild test -project Loro.xcodeproj -scheme Loro -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -parallel-testing-enabled NO -only-testing:PapagaioTests -derivedDataPath /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-derived-app-only` (log `app-test-only.log:1-2`).
- **Estado final observável:** 107 testes Swift Testing iniciaram; 105
  finalizaram (**99 passaram e 6 falharam, com 10 issues**). O log não contém a
  linha final `Test run with …`; termina em `** BUILD INTERRUPTED **`
  (`app-test.log:4300-4552`). Portanto **não há verde/vermelho final confiável**
  para a suíte do app.
- **Dois testes pendurados (CONFIRMADO):**
  `PapagaioTests/OAuthGoogleTests.swift:47` (“Cancelar a espera fecha o servidor
  local e desbloqueia o callback”) e `:67` (“Timeout do OAuth encerra o servidor
  sem bloquear o actor”) iniciaram e não emitiram resultado
  (`app-test.log:4322`, `:4399-4552`). A execução somente
  `-only-testing:PapagaioTests` também foi interrompida pelo limite de 300 s,
  ficando no primeiro teste de cancelamento
  (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-test-only.log:4500-4504`).
- **Mecanismo do travamento (A2-001, agente paralelo):** comando do
  experimento `swiftc /tmp/a2_shutdown_accept.swift && /tmp/a2_shutdown_accept`;
  o achado `audit/02-achados/A2.md:36-80` registra a saída reproduzida
  nesta máquina: `shutdown()` no socket de escuta retornou `-1`, `errno=57`, e
  `accept()` não despertou em 2 s. A evidência local combina com
  `SessaoOAuthGoogle.swift:438-447,491-495`; portanto a causa mecânica está
  **CONFIRMADA pelo A2**, enquanto a linha de base deste mapa confirma o
  sintoma nos dois testes. A correção proposta pelo A2 (despertar o `accept`
  com uma conexão local ou `DispatchSource`) fica para a Onda 1.
- **Seis falhas observadas (CONFIRMADO):** todas são asserções de strings com
  português literal contra a saída inglesa do locale `en-BR`/`en_BR` da máquina:

  | Teste/linha | Evidência resumida |
  |---|---|
  | `PapagaioTests/EquipesCloudKitTests.swift:211` | resumo de membros esperado em PT |
  | `PapagaioTests/EquipesCloudKitTests.swift:223-225` | mensagens de esquema/zona em PT |
  | `PapagaioTests/EquipesCloudKitTests.swift:235-236` | orientação de atualização em PT |
  | `PapagaioTests/InterfaceTests.swift:50` | descrição de estado sem fala |
  | `PapagaioTests/MidiasDaConversaViewModelTests.swift:19` | orientação de iPhone bloqueado |
  | `PapagaioTests/MidiasDaConversaViewModelTests.swift:31` (3 issues) | orientação de acesso a arquivo |
  A resolução de strings passa por `.localized` em
  `Papagaio/Suporte/Localizacao.swift:27-40`; a máquina está em `en-BR`/`en_BR`.
  As saídas inglesas estão em `app-test.log:4496-4505` e `:4524-4527`.
  **Classificação:** contrato/localização da baseline local, não prova de
  defeito na lógica de CloudKit ou mídia. O badge externo do Actions foi visto
  como *failing*, mas o log remoto não foi lido; atribuir a causa à CI é
  apenas PROVÁVEL.
- **Limite do resultado:** `xcodebuild test` não pode ser usado como gate sem
  timeout explícito até o travamento do OAuth ser resolvido.
  (o comando foi encerrado sem contagem final; o `143` registrado pertence ao
  wrapper/timeout, não a uma falha funcional do app).

### 5.3 Build Debug do app (CONFIRMADO)

- **Comando:** `xcodebuild build -project Loro.xcodeproj -scheme Loro -destination 'generic/platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO`
- **Resultado:** exit 0, `real 48.34 s` (user 208.71, sys 18.10), `** BUILD SUCCEEDED **`; log em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-build.log:6000-6023`.
- O log contém 120 ocorrências do warning de umbrella header do ONNX Runtime
  (`app-build.log:4174-4274`), uma ocorrência de metadata AppIntents ignorada
  (`:6005`) e sete avisos de cache/priors do SwiftPM (`:346-4022`). **Esses
  números são warnings de linhas do log, não uma contagem de arquivos ou de
  defeitos de produto**; não há contagem oficial de warnings no projeto.
- A build é Debug e sem assinatura; não foi feita build Release do app. O único
  release executado foi a compilação interna do CLI no benchmark micro (§11).

### 5.4 Testes dos scripts (Python) — `python3 -m unittest Scripts.tests.test_scripts` (CONFIRMADO)

- **8 testes, 3 falhas, `real 2.80 s`.** Saída em
  `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/script-tests.log:1-40`.
  Falharam: `test_attribute_recovery_rebuilds`,
  `test_scratch_path_equals`, `test_scratch_path_with_spaces` (todas do caminho de
  recuperação de FinderInfo).
- **Causa (CONFIRMADO por `git diff`):** `Scripts/testa-papagaio-core.sh` está
  **modificado sem commit** (+61/−16): a recuperação antiga era
  `xattr -cr "$PRODUTOS"` + `swift test` de novo (o que os testes Python mockam e
  esperam — `Scripts/tests/test_scripts.py:62-81`, incl. `assertNotIn("--skip-build", …)`).
  A versão nova usa `codesign` + `swift test --skip-build` e exige o bundle
  `PapagaioCoreTests.xctest` real, que o sandbox dos testes Python não cria → exit 1.
  Os testes Python **não rodam na CI** (grep no `ci.yml`: nenhuma menção).
- Classificação: **WIP do usuário** (script mudou, testes do script não acompanharam).
  HIPÓTESE: com o script de `HEAD` os 8 passariam (a recuperação antiga não depende do bundle).

### 5.5 Lint, análise estática e cobertura (CONFIRMADO ausentes)

- **Linter: nenhuma ferramenta configurada.** Busca em todo o repo (incluindo
  ocultos, excluindo `.claude/` e binários): nenhum `.swiftlint.yml`,
  `.swiftformat`, `periphery.yml`, Makefile, Fastfile; nenhum plugin SwiftPM de build
  (`PapagaioCore/Package.swift` não declara `plugin`); nenhum script de lint no
  `pbxproj` nem no `ci.yml`. Único YAML do repo: `.github/workflows/ci.yml`.
- **Análise estática:** o scheme define `AnalyzeAction` Debug
  (`Loro.xcodeproj/xcshareddata/xcschemes/Loro.xcscheme:88-90`), mas não
  executei `xcodebuild analyze`; portanto não há resultado de análise estática
  para reportar.
- **Cobertura: nenhuma configuração.** `grep -rn "codeCoverageEnabled\|coverage"` em
  `Loro.xcodeproj/`, `.github/` e `Scripts/` → **zero ocorrências**; o `TestAction`
  do scheme (`Loro.xcscheme:25-49`) não define `codeCoverageEnabled` (default do
  Xcode = desligado). CI não usa `-enableCodeCoverage`.

---

## 6. Hotspots

### 6.1 Arquivos maiores (top 20 por `wc -l`, medido)

| # | Linhas | Arquivo | `func`s (grep) |
|---:|---:|---|---:|
| 1 | 1.867 | `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift` | 20 |
| 2 | 1.785 | `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift` | 41 |
| 3 | 1.455 | `Papagaio/ViewModels/Biblioteca.swift` | 49 |
| 4 | 1.365 | `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift` | 21 |
| 5 | 1.124 | `Papagaio/Suporte/TabelaDeStrings.swift` | dados (dicionário EN) |
| 6 | 1.092 | `Papagaio/App/ContentView.swift` | 38 |
| 7 | 837 | `PapagaioTests/BibliotecaTests.swift` | (testes) |
| 8 | 815 | `Papagaio/Funcionalidades/Tarefas/TarefasView.swift` | 15 |
| 9 | 721 | `Papagaio/Funcionalidades/Biblioteca/GradeDePastas.swift` | — |
| 10 | 715 | `Papagaio/Funcionalidades/Configuracoes/ConfiguracoesView.swift` | 6 |
| 11 | 686 | `PapagaioCore/Tests/PapagaioCoreTests/PipelineTests.swift` | (testes) |
| 12 | 622 | `Papagaio/Integracao/SessaoOAuthGoogle.swift` | 27 |
| 13 | 605 | `Papagaio/ViewModels/GravadorViewModel.swift` | 28 |
| 14 | 604 | `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift` | 31 |
| 15 | 580 | `Papagaio/DesignSystem/PapagaioTheme.swift` | — |
| 16 | 572 | `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift` | — |
| 17 | 559 | `PapagaioCore/Sources/papagaio-eval/main.swift` | — |
| 18 | 549 | `Papagaio/Funcionalidades/Configuracoes/PersonalizacaoDosCartoes.swift` | — |
| 19 | 541 | `PapagaioCore/Sources/PapagaioCore/Dominio.swift` | 7 |
| 20 | 529 | `PapagaioCore/Tests/PapagaioCoreTests/PersistenciaTests.swift` | (testes) |

Complexidade aproximada (contagem de `func`, proxy grosseiro — **não** é cyclomatic):
`Biblioteca.swift` 49 · `ArquivoDetalheView.swift` 41 · `ContentView.swift` 38 ·
`ServicoDeEquipesCloudKit.swift` 31 · `GravadorViewModel.swift` 28 ·
`SessaoOAuthGoogle.swift` 27 · `SincronizadorDaBibliotecaCloudKit.swift` 25 ·
`SwiftDataRepository.swift` 20.

### 6.2 Alterações — `git log --since="6 months ago" --format= --name-only | sort | uniq -c | sort -rn` (medido; 320 commits, 2026-07-31 → 2026-09-21)

Top 30 (repo inteiro; `.claude/worktrees` é gitignored e não aparece):

```
 54 Papagaio/App/ContentView.swift
 51 Papagaio/ViewModels/Biblioteca.swift
 45 Loro.xcodeproj/project.pbxproj
 36 Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift
 35 Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift
 29 Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift
 28 Config/Info.plist
 24 PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift
 20 PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift
 20 Papagaio.xcodeproj/project.pbxproj            (histórico — diretório não existe mais)
 18 PapagaioTests/BibliotecaTests.swift
 18 Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift
 17 PapagaioTests/EquipesCloudKitTests.swift
 17 Papagaio/DesignSystem/Componentes/BarraSuperiorPapagaio.swift
 17 Papagaio/App/PapagaioApp.swift
 17 Config/Papagaio.entitlements
 16 PapagaioCore/Tests/PapagaioCoreTests/PersistenciaTests.swift
 16 PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift
 16 Papagaio/Modelos/Equipes/EquipeDisponivel.swift
 16 Papagaio/Funcionalidades/Tarefas/TarefasView.swift
 16 Papagaio/Funcionalidades/Configuracoes/ConfiguracoesView.swift
 15 PapagaioCore/Sources/PapagaioCore/Dominio.swift
 15 Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift
 13 Papagaio/DesignSystem/PapagaioTheme.swift
 13 Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift
 13 Papagaio/Biblioteca.swift                      (histórico — caminho movido p/ ViewModels/)
 12 PapagaioCore/Sources/papagaio-eval/main.swift
 12 Papagaio/Persistencia/LixeiraDeMidia.swift
 12 Papagaio/Funcionalidades/Biblioteca/EditorDeInformacoesDoCard.swift
 12 Master Plans/DECISIONS.md                      (histórico — arquivo não existe mais)
```

Leitura: `ContentView.swift`, `Biblioteca.swift` e `BibliotecaHomeView/ArquivoDetalheView`
são os centros de gravidade simultâneos de tamanho **e** churn → maior risco de regressão.

### 6.3 Estado do working tree NESTA execução (git status, CONFIRMADO)

Branch `main`, HEAD `6138e1d` (`feat: melhoria do localization`) no início e
na finalização; não houve commit, push ou limpeza.

**Janela medida da baseline:** havia 4 arquivos modificados e 6 grupos
não rastreados; os testes/build rodaram sobre esse estado WIP:
- Modificados: `PapagaioCore/Sources/…/DetectorDeAtividadeDeVoz.swift` (usa novo
  `SileroVAD.urlDoModeloPadrao`), `…/Transcricao/SileroVAD.swift` (+7: expõe
  `urlDoModeloPadrao`), `PapagaioCore/Sources/papagaio-eval/main.swift` (+75: comando
  `bench`, versão `0.2.0-bench`), `Scripts/testa-papagaio-core.sh` (+61/−16: recuperação
  por codesign).
- Não rastreados: `PapagaioCore/Benchmarks/` (contém `baseline.json` de 2026-09-22,
  Apple M5), `PapagaioCore/Sources/papagaio-eval/Bench.swift`,
  `CasosDeMacroBench.swift`, `CasosDeMicroBench.swift`, `Scripts/bench-papagaio.sh` e
  `docs/`.
- **Durante a finalização**, outros agentes criaram `audit/01-pesquisa/`,
  `audit/02-achados/A2.md` e `audit/04-medicoes/` (visíveis no
  `git status --short --untracked-files=all`). Eles não foram editados nem
  removidos por este mapa; a consolidação apenas os referencia quando indicado.

### 6.4 TODO / FIXME / HACK / XCODE (grep no repo de produto — exclui `Frameworks/` vendados)

| Marcador | Ocorrências no código do projeto |
|---|---|
| TODO | **1**: `Papagaio/Funcionalidades/Perfil/InformacoesPessoaisDoPerfil.swift:14` — `TODO(validacao-produto): o nome aparece 2x…` |
| FIXME | **0** |
| HACK | **0** |
| XCODE | **0** |
| (falsos positivos “TODOS” pt-BR) | `PapagaioCore/…/Sumarizacao/GramaticaDoResumo.swift:50`; `PapagaioCore/Tests/…/ResolvedorDeFalantesTests.swift:147` |

(TODOs adicionais só em headers C de `PapagaioCore/Frameworks/*.xcframework` — código de terceiros, fora de escopo.)

### 6.5 Achados recebidos dos agentes paralelos (não executados por este mapa)

> `A2-001` etc. são IDs do agente de concorrência; não confundem com a
> partição de biblioteca A2 da §8.

| ID | Severidade / confiança | Fato ou hipótese | Encaminhamento |
|---|---|---|---|
| **A2-001** | ALTO / **CONFIRMADO** | `shutdown()` no listener não acorda `accept()`; experimento mínimo e código em `audit/02-achados/A2.md:36-80` | Onda 1: corrigir cancelamento antes de confiar no gate do app |
| **A2-002** | ALTO / **PROVÁVEL** | Ditado de nota não tem cancelamento no ciclo de vida da tela; `audit/02-achados/A2.md:82-137` | Onda 2/3: amarrar cancelamento à tela/ditado e testar |
| **A2-003** | ALTO / **PROVÁVEL** | A exclusividade Whisper/Qwen é por instância de `MotoresLocais`, enquanto a app cria instâncias por operação; `audit/02-achados/A2.md:142-207` | Onda 2: compartilhar/coordenar o ciclo de modelos e medir memória |
| **A2-004** | MÉDIO / **PROVÁVEL** | Callbacks do CloudKit compartilham `Array`/`Error` mutáveis fora de um actor; `audit/02-achados/A2.md:213-266` | Onda 4: testar TSan com transporte real e proteger a continuação |

Esses quatro itens são referências de outro agente, não alterações de produção
nesta onda. A incorporação da A2-001 explica o travamento observado na §5.2; as
demais hipóteses continuam pendentes de teste no domínio indicado.

---

## 7. Contagem de código

| Módulo | Arquivos `.swift` | Linhas |
|---|---:|---:|
| `Papagaio/` (app) | 171 | 34.232 |
| `PapagaioCore/Sources/` | 61 | 11.370 |
| `PapagaioCore/Tests/` | 20 | 4.837 |
| `PapagaioCore/Package.swift` | 1 | 105 |
| `PapagaioTests/` | 13 | 2.893 |
| **Total Swift (exclui `.claude/`, `.build/`, `Frameworks/`)** | **266** | **53.437** |
| Não-Swift (`Scripts/`+`ci_scripts/` sh/py/rb) | 9 arquivos | 1.967 |
| CI (`.github/workflows/ci.yml`) | — | 51 |
| Strings (`Papagaio/Localizable.xcstrings`) | — | 12.361 (1.131 chaves, `en`+`pt-BR`) |

Subpasta → linhas (app): App 1.296 · CloudKit 1.301 · DesignSystem 2.623 ·
Diagnostico 265 · Funcionalidades 17.400 (Biblioteca 6.458 / Detalhe 5.292 /
Tarefas+Mídias+Config 3.367 / Equipes+Perfil 1.399 / Gravacao 884) · Integracao 2.550 ·
Modelos 846 · Persistencia 2.604 · Suporte 2.015 · ViewModels 3.332.

### Testes

| Conjunto | Arquivos | Casos |
|---|---:|---:|
| PapagaioCore (Swift Testing `@Test`) | 19 | 216 (4 pulados; 1 falhou com 2 issues) |
| PapagaioCore (XCTest, só `CanceladorDeEcoTests`) | 1 | 6 |
| PapagaioTests (Swift Testing `@Test`) | 13 | 107 (2 travam, 6 falham nesta máquina) |
| Scripts (unittest Python) | 1 | 8 (3 falham com WIP) |

### Arquivos SEM teste associado (estimativa honesta)

- Heurística executada: nome do arquivo de produto aparece em algum arquivo de
  `PapagaioTests/`. Resultado: **48/171 arquivos do app têm “par de nome”** →
  **≈123 arquivos (72%) sem teste de nome correspondente.**
- Limitações (diga-se honestamente): a heurística erra para os dois lados —
  `BibliotecaTests.swift` cobre `Biblioteca.swift` (existe par) mas testa também
  coisas sem par exato; e um arquivo pode ser coberto indiretamente (ex.:
  `DesignSystem/` quase todo aparece como “sem teste”, mas `InterfaceTests.swift:139-201`
  testa tokens de cor/formatação de tempo). **Não há ferramenta de cobertura
  configurada (§5.5), então % real de linhas cobertas é DESCONHECIDO.**
- Sem nenhum teste nome-similar (exemplos lidos): `GravadorViewModel.swift`,
  `PerfilViewModel.swift`, `ModelosViewModel.swift`, `NotasDaConversaViewModel.swift`,
  `NotificacoesViewModel.swift`, `PapagaioApp.swift`, `DelegadoDeConvitesCloudKit.swift`,
  a pasta `DesignSystem/Componentes/` (18 arquivos) e a maioria de `Modelos/Tarefas/`.
- Core: 49 arquivos de domínio vs 20 arquivos de teste — cobertura **por feature**
  (pipeline, VAD, diarização, persistência), não 1:1; arquivos órfãos evidentes:
  `ImplementacoesVazias.swift` (só comentário, verificado), `CanceladorDeEco` tem
  teste XCTest dedicado, `FormatoAudio`/`ErroCaptura` cobertos via `CapturaTests`.

---

## 8. Plano de particionamento sugerido (A1..A12)

O pedido base sugeria A1..A9; o repo só cobre **sem órfãos** com **12 partições**
(§7 soma: 171 app + 82 core + 13 testes = 266 arquivos, todos com dono).
Cada partição declara **arquivos | linhas** (medidas) e o dono dos testes relacionados.

| ID | Partição | Pastas/arquivos | Arquivos | Linhas | Testes relacionados (dono coadjuvante) |
|---|---|---|---:|---:|---|
| **A1** | App + Navegação + Entry | `Papagaio/App/**` (PapagaioApp, ContentView, Politica, TelaPrincipal, ContextoDaConta) | 5 | 1.296 | `PapagaioTests/InterfaceTests.swift` (15), `InicializacaoExternaTests.swift` (2) |
| **A2** | Funcionalidades/Biblioteca | `Papagaio/Funcionalidades/Biblioteca/**` | 19 | 6.458 | `BibliotecaTests` (26), `PastasDaBibliotecaTests` (4), `LixeiraDeMidiaTests` (8) |
| **A3** | Funcionalidades/Detalhe (player, transcrição, resumo, notas, tarefas-da-conversa, mídias-da-conversa) | `Papagaio/Funcionalidades/Detalhe/**` | 20 | 5.292 | `TarefasDaConversaViewModelTests` (7), `MidiasDaConversaViewModelTests` (4); Core `ReproducaoTests` (9) |
| **A4** | Funcionalidades/Gravacao | `Papagaio/Funcionalidades/Gravacao/**` | 5 | 884 | Core `CapturaTests` (10); (app: nenhum — lacuna) |
| **A5** | Funcionalidades/Equipes + Perfil | `Papagaio/Funcionalidades/Equipes/**`, `…/Perfil/**` | 9 | 1.399 | `EquipesCloudKitTests` (16) |
| **A6** | Funcionalidades/Tarefas + Mídias + Configurações | `…/Tarefas/**`, `…/Midias/**`, `…/Configuracoes/**` | 11 | 3.367 | `OrdenacaoDeTarefasTests` (5), `TarefasDoPainelViewModelTests` (5) |
| **A7** | ViewModels + Persistência do app | `Papagaio/ViewModels/**`, `Papagaio/Persistencia/**` | 33 | 5.936 | `InvalidacaoVisualTests` (1) — lacuna enorme: 10 VMs × 1 teste |
| **A8** | CloudKit (sync de equipes) | `Papagaio/CloudKit/**` | 4 | 1.301 | parte de `EquipesCloudKitTests` (sync/fila/mesclagem: linhas 44-131, 252+) |
| **A9** | Integração (OAuth Google/Granola, Calendar, MCP) | `Papagaio/Integracao/**` | 9 | 2.550 | `OAuthGoogleTests` (9 — **2 travam**), `GoogleCalendarTests` (5); Core `IntegracaoTests` (14) |
| **A10** | DesignSystem + Suporte + Modelos + Diagnóstico | `Papagaio/DesignSystem/**`, `Suporte/**`, `Modelos/**`, `Diagnostico/**` | 56 | 5.749 | `InterfaceTests` (parte de tokens/formatação) |
| **A11** | PapagaioCore (captura/VAD/transcrição/diarização/sumarização/persistência/reprodução/runtime/CLI) | `PapagaioCore/**` (Sources 61 + Tests 20 + Package.swift) | 82 | 16.312 | seus próprios 20 arquivos de teste (216 Swift Testing + 6 XCTest; baseline com 1 teste/2 issues) |
| **A12** | Testes do app (orquestração, infra de teste) | `PapagaioTests/**` | 13 | 2.893 | é o próprio — cada arquivo aponta a partição de domínio acima |

**Regras de vizinhança (para nada ficar sem dono):**
- Cada A revisa **todos** os `.swift` das suas pastas (somatório = 266, conferido por comando).
- Arquivos de teste são dono do A de domínio correspondente (tabela acima) com A12
  respondendo pela infra (`@testable import`, host de teste, fixtures).
- Recomendação de prioridade pelos hotspots (§6): A1 (ContentView, churn 54),
  A7 (Biblioteca.swift, churn 51), A2/A3 (2 arquivos >1.700 linhas),
  A8/A9 (serviços com falhas conhecidas na baseline), A11 (bug `Segmentacao.agrupar`).

---

## 9. Suposições feitas (config vazia → inferência)

1. **Autoridade dos `Package.resolved`** — o repo não documenta qual vale; inferi
   pelo comando que a CI/README usam (`-project Loro.xcodeproj`) e pelo log do meu
   build (§1.3). Marcado PROVÁVEL.
2. **Idioma esperado dos testes de localização** — os testes comparam strings PT-BR
   literais; assumi que a intenção é rodar em PT-BR (commits recentes “versao app
   em ingles”/“melhoria do localization” mudaram o comportamento em máquina EN).
   Não há config de idioma de teste no scheme/CI — **é suposição minha** que
   existia um locale PT no ambiente de origem.
3. **Causa do badge “failing”** — assumi (PROVÁVEL) que é o mesmo problema de
   localização/travamento que reproduzi; **não li os logs da Actions**.
4. **Classificação ambiente × produto** do codesign FinderInfo: tratei como
   ambiente (File Provider do macOS), pois o próprio script existe para isso e o
   repo comenta o fenômeno (`Scripts/testa-papagaio-core.sh:26-31`).
5. **Escopo de “arquivos maiores/complexidade”** — usei `wc -l` + contagem de `func`
   como proxy; **não** calculei ciclomática real (não há ferramenta no repo).
6. **`docs/`, `Benchmarks/` e os demais artefatos `audit/01-*`–`audit/04-*` pertencem a outras ondas/auditorias** (não rastreados; alguns datados de 2026-09-22); tratei-os como material de referência, não como código do produto. `docs/refatoracao-2026-09-09/` está **vazio**.
7. **Referências quebradas no README** (inconsistência registrada, não suposição):
   `README.md:121` aponta `PLANO-APLICACAO-INTELIGENCIA-PRODUTO-PAPAGAIO.md`
   (inexistente) e `README.md:122` aponta `docs/REVISAO-PLANO-E-FLUXOS-2026-08-28.md`
   (inexistente) — confirmado com `ls` (ambos `No such file or directory`).
   Também `PapagaioCore/Package.swift` e o comentário de `README.md:127-131` citam
   `DECISIONS.md`/histórico que não existe mais no repo (`Master Plans/DECISIONS.md`
   só aparece no histórico do git).

---

## 10. Avisos ambientais (o que não rodou e o que isso invalida)

| # | Limite | Evidência | O que fica INVÁLIDO/parcial para as ondas seguintes |
|---|---|---|---|
| 1 | **`xcodebuild test` do app não concluiu** (2 testes OAuth pendurados; `** BUILD INTERRUPTED **`; wrapper registrou timeout) | §5.2; `app-test.log:4300-4552`; A2-001: `audit/02-achados/A2.md:36-80` | Não há resultado final da suíte; a causa do `accept` está confirmada pelo experimento A2, mas o gate ainda precisa ser corrigido e repetido. |
| 2 | **Locale do sistema em `en-BR`** | `defaults read -g AppleLanguages` → `("en-BR","pt-BR")`; `Localizacao.swift:27-40` | Os 6 testes de localização falharam nesta execução; qualquer onda deve controlar o locale antes de comparar regressões |
| 3 | **Modelos de teste em caminho diferente** | `TranscricaoTests.swift:9-13` vs pesos em `~/Library/Application Support/Papagaio/Models` | 4 testes core de Whisper/Qwen foram pulados nesta execução; qualidade real de transcrição/resumo **não medida** |
| 4 | **FinderInfo/File Provider** | falha de codesign na 1ª tentativa, recuperada pelo script | Builds/testes podem falhar na 1ª execução em qualquer onda; usar sempre `./Scripts/testa-papagaio-core.sh` (não `swift test` cru) |
| 5 | **Máquina carregada + paralelismo** | snapshots de execução registraram outro processo/DerivedData de auditoria concorrente | Todos os tempos da §5 e §11 são **superestimáveis**; não use-os como SLA |
| 6 | **Working tree suja (WIP de bench e artefatos paralelos)** | baseline tinha 4 modificados + 6 grupos não rastreados; `git status --short --untracked-files=all` ganhou também `audit/01-pesquisa/`, `audit/02-achados/A2.md` e `audit/04-medicoes/` durante a finalização (§6.3) | Baselines refletem WIP; os arquivos paralelos não foram limpos nem alterados por este mapa |
| 7 | **Sem escrita em serviços reais (restrição)** | regras do prompt | **CloudKit sync real (2 contas iCloud), convite/CKShare, OAuth Google de verdade, MCP/Granola não foram exercitados** — validação desses fluxos continua pendente (README:126-129 também marca isso como pendência de produto) |
| 8 | **Não executei `bootstrap-runtimes.sh`** | restrição de dependências | Funcionamento do bootstrap (URLs vivas, checksums) **não verificado nesta sessão**; assumi integridade dos artefatos já presentes |
| 9 | **Sem lint e sem cobertura no repo; AnalyzeAction não executado** | §5.5; `Loro.xcscheme:88-90` | Ondas de qualidade **não têm baseline de cobertura nem análise estática executada**; qualquer afirmação de “cobertura X%” seria inventada |
| 10 | **CI remota não inspecionada em detalhe** | só badge “failing” (fetch) | Não sei qual job falha na Actions; reprodução local difere (runner macos-26 + locale EN) |
| 11 | **Xcode-beta 27.0 / macOS 27 vs target 26 / runner macos-26** | §1.1 | Diferença de toolchain possível entre minha medição e a CI — comparações de warnings/tempo são “nesta toolchain” |
| 12 | **Testes Python dos scripts fora da CI** | grep `ci.yml` sem menção | As 3 falhas da §5.4 não quebram a CI atualmente — mas mostram WIP incoerente |

---

### Checklist de execução desta sessão (resumo para auditoria de processo)

| Item do prompt | Status |
|---|---|
| Stack/versões exatas + 3 Package.resolved + Package.swift | ✅ §1 |
| Arquitetura + pontos de entrada + fluxo de dados | ✅ §2 |
| 5 fluxos críticos mapeados até arquivo:linha | ✅ §3 |
| Comandos README/Scripts/CI extraídos + executados | ✅ §4 |
| Baseline `testa-papagaio-core.sh` medida | ✅ §5.1 (**24,95 s**; 217 pass / 1 teste com 2 issues / 4 skip) |
| Build Debug do app medido | ✅ §5.3 (**48,34 s**, `BUILD SUCCEEDED`; warnings vendorizados/infra) |
| Testes do app `PAPAGAIO_TEST_MODE=1` | ⚠️ §5.2 — executado, **não concluiu** (99 pass/6 fail/2 pendurados de 107) |
| Warnings contados | ✅ §5.3 |
| Linter/estático | ✅ §5.5 — **nenhuma ferramenta configurada; AnalyzeAction não executado** |
| Cobertura | ✅ §5.5 — **nenhuma configuração** |
| Hotspots (wc -l, git log 6m, TODO/FIXME) | ✅ §6 |
| Contagem de código + sem-teste | ✅ §7 |
| Plano A1..A9 (partições A1..A12) | ✅ §8 |
| Suposições | ✅ §9 |
| Avisos ambientais | ✅ §10 |
| Performance medida (micro release) | ✅ §11 (**11 resultados**, sem macro/p95 inventado) |
| Plano das Ondas 1–4 | ✅ §12 |
| Testes Python dos scripts (extra) | ✅ §5.4 (3/8 falham por WIP) |

---

## 11. Performance — somente números medidos nesta onda

### 11.1 Método e limites da medição

- **Fato:** o harness mede uma execução de warm-up, depois `n` execuções e
  calcula mínimo, média e mediana; a implementação está em
  `PapagaioCore/Sources/papagaio-eval/Bench.swift:41-116`. Os casos e suas
  entradas sintéticas estão em
  `PapagaioCore/Sources/papagaio-eval/CasosDeMicroBench.swift:6-198`.
- **Comando executado:** `./Scripts/bench-papagaio.sh --so-micro --iteracoes 5 --audio PapagaioCore/Tests/PapagaioCoreTests/Fixtures/fala_ola_mundo.wav --modelos "$HOME/Library/Application Support/Papagaio/Models" --saida /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/micro.json`.
  A invocação literal, o build e a saída estão em
  `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/bench-micro.log:1-81`.
- **Condições:** Apple M5, 10 cores ativas, macOS 27.0, 24 GiB, Metal sim,
  build **Release do PapagaioCore**; o binário reportou Whisper/LLama com Metal
  (`bench-micro.log:15-56`). O build release do core levou **45,04 s** e o
  processo total **48,58 s** (`bench-micro.log:6-13`, `:79-81`).
- Foram produzidas **11 linhas de resultado** (o JSON tem 11 entradas em
  `micro.json:6-98`). O rótulo `--so-micro` não impediu os dois casos Silero
  porque o modelo está disponível no bundle; os detalhes `silero: sim` e os
  números estão em `micro.json:71-89`.
- O `PapagaioCore/Benchmarks/baseline.json` presente localmente é um artefato
  não rastreado, datado de 2026-09-22; **não foi usado como medição desta
  onda**. O único baseline aceito aqui é o `micro.json` temporário produzido
  pelo comando acima.

### 11.2 Resultados medidos

Valores em segundos; `n` é o número de execuções medidas após o aquecimento.

| Caso | Mediana | n | Entrada |
|---|---:|---:|---|
| `segmentacao.agrupar` | **0,000127542** | 5 | 500 segmentos |
| `segmentacao.mesclarCanais` | **0,002351334** | 5 | 250 + 250 segmentos |
| `alinhamento.atribuir` | **0,003740583** | 5 | 200 trechos × 400 segmentos |
| `filtroRepeticao.remover` | **0,004563167** | 5 | 300 trechos |
| `falas.agrupar` | **0,000352333** | 5 | 200 trechos |
| `navegacao.indiceAtivo` | **0,000119125** | 50 | 200 trechos, 10 mil buscas |
| `exportacao.markdown` | **0,000171709** | 5 | 200 trechos |
| `aec.processarBlocos` | **0,489002250** | 3 | 5 s de áudio |
| `vad.janelasDeFala` | **0,056728500** | 3 | 30 s de áudio |
| `vad.silero.lote` | **0,031454584** | 3 | 600 quadros de 512 amostras |
| `idioma.detectar` | **0,003119917** | 5 | ~60 mil caracteres |

Fonte primária: `micro.json:6-98`; arredondamento em
`bench-micro.log:64-76`. O caso AEC monta um `CanceladorDeEco` com bloco 512 e
filtro 4096 (`CasosDeMicroBench.swift:122-144`); portanto o número é uma
medição sintética desse harness, **não RTF de uma reunião real**.

### 11.3 Leitura permitida e lacunas

- **Fato medido:** entre os casos desta execução, AEC e VAD/Silero foram os
  maiores valores de mediana; segmentação, navegação, exportação e detecção de
  idioma ficaram abaixo de 0,005 s. Isso descreve somente esta máquina, este
  harness e estas iterações.
- **Inferência de investigação, não SLA:** o AEC merece instrumentação de
  blocos porque o laço medido está em
  `PapagaioCore/Sources/PapagaioCore/Processamento/CanceladorDeEco.swift:58-103`;
  o caminho VAD por lotes está em
  `PapagaioCore/Sources/PapagaioCore/Transcricao/DetectorDeAtividadeDeVoz.swift:142-160`.
- **Não medido:** macro-benchmark com Qwen/Whisper, RTF de áudio real, p95,
  número de cargas/descargas, custo de CloudKit, tempo de UI, pico de memória,
  cobertura ou regressão de builds. Não se deve importar números do relatório
  de performance anterior como se fossem desta auditoria.

---

## 12. Plano recomendado para as Ondas 1–4

> **Natureza:** proposta de sequenciamento para agentes seguintes, não
> implementação realizada nesta onda. A1–A9 são as partições de domínio da §8;
> A10–A12 são camadas transversais de suporte. Nenhuma onda deve declarar
> cobertura, p95 ou desempenho que não tenha medido.

**Mapa resumido A1–A9 → ondas:** A1 (1/3), A2 (3), A3 (3), A4 (2),
A5 (3), A6 (3), A7 (1/2/3), A8 (4), A9 (1/4). A10–A12 acompanham todas as
frentes como suporte transversal.

### Onda 1 — Gate de correção e reprodutibilidade

**Domínios:** A11 (core), A9 (OAuth/MCP) e A1 (host/test mode), com A12.

**Prioridades:**
1. Preservar `Trecho.id` em `Segmentacao.agrupar`
   (`PapagaioCore/Sources/PapagaioCore/Processamento/Segmentacao.swift:31-49`)
   e fechar as duas issues de `PipelineTests.swift:554,579`.
2. Reproduzir e isolar os dois testes pendurados de
   `PapagaioTests/OAuthGoogleTests.swift:47,67`; cobrir sucesso, timeout,
   cancelamento e fechamento do socket em `SessaoOAuthGoogle.swift:160-185,416-493`.
   O experimento de A2-001 (`audit/02-achados/A2.md:59-80`) é a reprodução
   mínima do mecanismo; corrigir o desbloqueio do `accept` antes de usar a suíte como gate.
3. Tornar o resultado do app testável sem depender do locale da máquina,
   mantendo uma expectativa explícita para PT-BR e EN; o modo de host já é
   definido em `Papagaio/App/PoliticaDeInicializacaoExterna.swift:13-16`.
4. Reconciliar `Scripts/testa-papagaio-core.sh` com
   `Scripts/tests/test_scripts.py:62-81` e registrar FinderInfo como condição
   de ambiente, não como sucesso silencioso.

**Critério de saída:** o core termina com a falha de ID resolvida ou
justificativa; o app termina (com timeout explícito) e produz uma linha final;
não há segredos nos logs; os três testes Python passam ou a incompatibilidade
do script fica bloqueada e documentada. Não exigir percentual de cobertura.

### Onda 2 — Pipeline local, captura e persistência

**Domínios:** A11, A4 e A7.

**Prioridades:**
1. Validar o caminho de captura/importação até
   `PipelineDeArquivo.swift:101-189`, incluindo dois canais, AEC, VAD,
   diarização, tradução e os dois salvamentos; no ditado, cobrir o
   cancelamento apontado por A2-002 (`audit/02-achados/A2.md:82-137`).
2. Unificar o caminho de modelos entre testes, app e CLI, preservando a
   distinção entre `~/Documents/InterviewLab/Models` e
   `~/Library/Application Support/Papagaio/Models`; executar os quatro testes
   Whisper/Qwen que foram pulados.
3. Medir, com fixture versionada, tempo e memória de carga/descarga de
   Whisper/Qwen e a fila serial de `MotoresLocais.swift:39-119,138-208`;
   investigar A2-003 (`audit/02-achados/A2.md:142-207`) antes de tratar a
   exclusividade de modelos como global.
4. Criar testes de persistência para IDs de trechos, traduções e falha de salvar,
   incluindo `SwiftDataRepository.swift:40-103` e `PipelineDeArquivo.swift:159-187`.

**Critério de saída:** testes com modelos reais deixam de pular por drift de
caminho; há medição antes/depois para qualquer mudança; a fila nunca duplica
processamento e os testes de app não inventam um estado de sucesso.

### Onda 3 — Biblioteca, detalhe e hotspots de UI

**Domínios:** A1, A2, A3, A5, A6 e A7, com A10/A12 como suporte.

**Prioridades:**
1. Dividir ou extrair responsabilidades de `CartaoDeConversa.swift` (1.867
   linhas), `ArquivoDetalheView.swift` (1.785), `Biblioteca.swift` (1.455) e
   `ContentView.swift` (1.092), começando pelos centros de churn da §6.2.
2. Consolidar contratos de biblioteca, pastas, favoritos, lixeira, busca e
   player; cobrir o fluxo em `BibliotecaHomeView.swift:401-417` e
   `SwiftDataRepository.swift:135-215`.
3. Tornar a localização uma propriedade testável do ViewModel, não uma
   comparação incidental com o locale do processo; cobrir as seis asserções
   observadas nesta execução em `EquipesCloudKitTests`, `InterfaceTests` e
   `MidiasDaConversaViewModelTests`.
4. Manter A10 para tokens/acessibilidade e A12 para a infraestrutura de testes,
   sem contar a heurística de “par de nome” como cobertura.

**Critério de saída:** os testes de biblioteca/detalhe passam em locale
controlado; o churn deixa de aumentar sem um responsável claro; não há regressão de
busca, navegação, lixeira ou acessibilidade. Qualquer melhoria de UI deve ser
medida com uma métrica declarada, não estimada.

### Onda 4 — Equipes, integrações e preparação de entrega

**Domínios:** A8 e A9, com A10/A11/A12.

**Prioridades:**
1. Validar criação de zona, `CKShare`, código de entrada, convite, exclusão e
   fila de sincronização em `ServicoDeEquipesCloudKit.swift:48-104,242-293` e
   `SincronizadorDaBibliotecaCloudKit.swift:127-396`, com duas contas iCloud
   reais em ambiente de teste controlado; investigar A2-004
   (`audit/02-achados/A2.md:213-266`) com TSan e avaliar cache de token antes
   de afirmar que a leitura integral da zona é custo aceitável.
2. Validar OAuth Google Calendar, Granola/MCP e Keychain sem imprimir tokens;
   adicionar testes de timeout/cancelamento e de callback duplicado.
3. Repetir o benchmark micro em commit limpo e, somente se necessário, criar
   casos macro com fixtures e modelos reais; reportar p95 apenas se o harness
   coleta e documenta essa estatística.
4. Fazer build Debug/Release assinada em um clone limpo, executar bootstrap,
   testes, análise estática disponível e checklist de segredos/entitlements.

**Critério de saída:** os fluxos externos têm evidência de integração ou uma
limitação explícita; a suíte termina; o baseline de performance é
reprodutível em commit limpo; nenhum arquivo fora do escopo da onda foi
alterado.

### Dependências e ordem de ataque

1. **Onda 1 é bloqueante:** sem gate confiável, uma alteração de domínio pode
   parecer verde apenas porque o runner foi interrompido.
2. **Onda 2 vem antes de otimização estrutural:** o caminho local e a
   persistência são a fonte de IDs, idiomas e estados consumidos pelas telas.
3. **Onda 3 pode ser paralelizada por A2/A3**, depois integrada com A1/A7.
4. **Onda 4 fecha o produto** depois que contratos de core, app e integrações
   estiverem estáveis; A8 exige contas/serviços que a Onda 0 não tocou.

### Estado final da Onda 0

A Onda 0 **não altera código**. O único artefato de auditoria produzido/
consolidado **por este agente** é `audit/00-mapa.md`; build Debug e microbenchmark foram medidos,
mas o benchmark macro, os serviços reais e a suíte completa do app continuam
limitados pelos motivos registrados na §10.

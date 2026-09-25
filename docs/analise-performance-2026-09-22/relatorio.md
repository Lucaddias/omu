# Análise de performance — Papagaio / Ōmu

**Data:** 2026-09-22  
**Máquina baseline:** Apple M5 (10 cores)  
**Baseline:** `PapagaioCore/Benchmarks/baseline.json` (micro + macro, Whisper large-v3 + Qwen3.5-9B Q4_K_M reais)  
**Escopo:** backtesting e análise; **sem implementação** de melhorias (apenas harness da Fase 0).

---

## 1. Resumo executivo

| Prioridade | Cluster | Impacto estimado | Esforço |
|---|---|---|---|
| **P0** | Pipeline IA — sumarização Qwen | **186 s** por reunião sintética (400 trechos); domina o pós-processamento | Alto |
| **P0** | Ciclo de vida dos modelos (load/unload thrash) | ~1 s+ Whisper + carga Qwen a cada execução/ditado; risco de serializar a fila | Médio |
| **P1** | Chamadas C bloqueando o pool cooperativo | AEC ~0,49 s / 5 s de áudio (~12× slower-than-realtime single-thread); Whisper/Qwen longos no ator | Médio |
| **P1** | Pipeline serial mic→sistema + AEC em memória | 2× tempo de transcrição de canal; pico de RAM com arquivos longos | Médio |
| **P2** | VAD Silero — inferência por quadro | Overhead de ator/ONNX por lote de 128 quadros; path degradado de energia já barato | Baixo |
| **P2** | Download byte-a-byte | 3–6 GB com `for await byte` — lentidão clara na primeira instalação | Baixo |
| **P3** | Alinhamento O(palavras×segmentos) | 3,7 ms no baseline; degrada em reuniões de 3 h | Baixo |
| **P3** | UI/persistência (SwiftData rewrite, busca 5×) | Salvva 2×/pipeline regrava todos os trechos; busca multi-fetch | Baixo |
| **Bug** | `Segmentacao.agrupar` descarta `Trecho.id` | 2 testes falham; âncoras de navegação podem quebrar | Baixo |

**Números-chave do baseline (mediana):**

| Caso | segundos | unidade |
|---|---:|---|
| `macro.qwen.resumir` | **186,28** | 400 trechos sintéticos (1 iteração) |
| `macro.whisper.cicloCargaDescarga` | **0,979** | carga+unload large-v3 |
| `aec.processarBlocos` | **0,488** | 5 s de áudio |
| `vad.janelasDeFala` | 0,0497 | 30 s (path energia; Silero não no CLI) |
| `alinhamento.atribuir` | 0,00373 | 200 trechos × 400 segmentos |
| demais micro | < 0,005 | — |

Micro-benches puros (segmentação, filtro, falas, navegação, export, idioma) são **irrelevantes** frente ao Qwen e ao AEC — não priorizar.

---

## 2. Pipeline IA (prioridade máxima)

### 2.1 Sumarização Qwen — P0

**Evidência:** `macro.qwen.resumir = 186,3 s` para 400 trechos sintéticos (~55k caracteres de prompt similar ao formato real).

**Código:**
- `QwenEngine.summarize` → `passeUnico` se ≤ 28k tokens, senão `mapReduce` (`QwenEngine.swift:45-50`).
- `ContextoLlama.completar` (`ContextoLlama.swift:136-219`):
  - `llama_memory_clear` no início e no `defer` de **cada** chamada — sem continuidade de KV-cache entre tentativas;
  - prefill em fatias de 2048 (`tokensPorLote`);
  - decode **1 token por `llama_decode`** com `llama_batch_get_one` de tamanho 1;
  - greedy + gramática GBNF; `maxTokens` 4096 no resumo.
- Reprompt em JSON inválido → **segunda geração completa** (`gerarComReprompt`, `QwenEngine.swift:151-168`).

**Propostas (validar com macro-bench antes/depois):**
1. **Medir breakdown** prefill vs decode vs gramática (instrumentar `completar` com contadores no harness — sem mudar o runtime).
2. Evitar `llama_memory_clear` quando o prompt for prefixo da tentativa anterior (reprompt corretivo); hoje custa re-prefill inteiro.
3. Avaliar `n_ubatch`/batch de decode maior no greedy (llama.cpp suporta amostrar em lote interno — confirmar versão linkada).
4. Reduzir `maxTokens` de 4096 para o teto real do JSON da gramática (medir p95 de tokens gerados).
5. Map-reduce: prompts parciais rodam **em série** no mesmo ator (`mapReduce` loop) — se houver folga de memória, avaliar 2 contextos… **conflita com invariante** “nunca dois modelos grandes juntos”; só faria sentido se Qwen fosse o único residente (hoje já é, durante resumo) — então paralelizar chunks **dentro** do mesmo modelo não é possível sem 2× RAM. Manter série; otimizar só o passe único (caso comum ≤ 28k).

**Risco:** mudança de amostragem/gramática quebra validação de citações (`ValidacaoDeCitacoes`) — manter golden tests.

### 2.2 Ciclo de vida / thrash de modelos — P0

**Evidência:** carga+unload Whisper ≈ 0,98 s no baseline (2 iterações); Qwen comenta-se 10–30 s em documentos do próprio código (`ContextoLlama.swift:34-35`).

**Comportamento atual:**
- `MotoresLocais` **descarrega o modelo oposto antes de cada operação** (`MotoresLocais.swift:45,61,75,100`) — invariante correta de memória, mas com custo de ping-pong.
- `Biblioteca.executarProcessamento` cria `MotoresLocais` **novo por execução** e `descarregarTudo` no `limpar` (`Biblioteca.swift:894-977`).
- `transcreverDitado` idem (`Biblioteca.swift:852-860`) — ditado sempre paga carga fria do Whisper.
- Pipeline real: transcrever (Whisper) → diarizar → resolverFalantes (pode carregar Qwen) → traduzir (Qwen) → salvar → resumir (Qwen). Whisper é descarregado ao entrar no Qwen e **não volta** — ok se não houver 2º arquivo; a fila serializa arquivos.

**Propostas:**
1. **Sessão de motores com TTL** (ex.: permanece residente N minutos após o último uso; `CicloDeVidaDeModelos` já monitora pressão) em vez de unload obrigatório no fim de cada `executarProcessamento`.
2. Reaproveitar um `MotoresLocais` singleton por `Biblioteca` (o ator já serializa) em vez de instanciar por execução.
3. Ditado: reusar o mesmo contexto residente se a pressão de memória permitir (`Preflight` + `CicloDeVidaDeModelos.descarregarTudo` sob warning continua como fallback).
4. **Overlap opcional:** iniciar `contarTokens`/formatação do resumo enquanto o Whisper ainda está saindo — hoje é estritamente serial na `FilaEstrita` (`MotoresLocais.comExclusividade`). Só vale se a etapa for CPU leve fora do ator (formatação de string já é barata — ganho marginal).

**Validação:** micro `macro.whisper.cicloCargaDescarga` + novo caso `macro.qwen.cicloCargaDescarga` (falta no baseline) + contagem de loads por pipeline no harness.

### 2.3 Sequenciamento do pipeline — P1

**Evidência/código:** `PipelineDeArquivo.transcrever` (`PipelineDeArquivo.swift:222-260`):
1. AEC opcional carrega **arquivos inteiros** em `[Float]` (`aplicarAEC` → `DecodificadorDeAudio.amostras`).
2. Transcreve mic **depois** sistema, em série (mesmo com contexts separados, a fila do ator serializa).
3. `Segmentacao.mesclarCanais` no fim.

**Propostas:**
1. Manter série (invariante de memória + um `ContextoWhisper`) — **não** paralelizar dois `whisper_full`.
2. **AEC em blocos** usando o mesmo padrão de `processarEmBlocos` (hoje `amostras(de:)` materializa tudo) — reduz pico de RAM em reuniões longas.
3. Pipeline pode **iniciar diarização do canal A enquanto B ainda transcreve**? Diarizador é ator separado (~40 MB) — **sim**, `aplicarDiarizacao` espera o fim das duas transcrições (`PipelineDeArquivo.swift:127`); poderia diarizar o mic assim que ele fechar, em paralelo com a transcrição do sistema. Ganho: some parte da latência da fase `.diarizando`.

### 2.4 Tradução local — P1 (depende do idioma)

- Lotes de 2000 tokens em série (`tokensPorLoteDeTraducao`); cada lote = `completar` com clear de memória.
- Só roda se `deveTraduzir` — **desligada por padrão** no app? (`traducaoAutomatica` vem da UI). Se habilitada, custo ≈ N× (prefill+decode) comparável a fração do resumo.
- Proposta: medir `macro.qwen.traduzir` com 400 trechos (falta no baseline); se significativo, reduzir clear e aumentar lote.

### 2.5 Resolução de falantes — P2

- Bons recortes já: costura grátis, lotes de 12, só elegíveis.
- Se houver muitos casos, N chamadas curtas com clear each — medir `macro.qwen.resolverFalantes`.

---

## 3. Chamadas C bloqueando o pool cooperativo — P1

| Local | Chamada longa | Sintoma |
|---|---|---|
| `ContextoWhisper.transcrever` | `whisper_full` | Segundos~minutos no ator; outros awaits do app no mesmo cooperative pool podem atrasar UI se o pool encher |
| `ContextoLlama.completar` | prefill+decode | Idem, pior (minutos) |
| `CanceladorDeEco.processar` | NLMS síncrono puro CPU | 0,49 s / 5 s de áudio **no thread do chamador** |
| `SileroVAD` / `SessaoOnnx.rodar` | ONNX Run | Pequeno mas por quadro |

**Propostas:**
1. **AEC:** mover o laço NLMS para `Task.detached(priority: .utility)` ou fila GCD dedicated; ou acelerar com `vDSP` em janelas maiores / reduzir `comprimentoFiltro` com validação de qualidade.
2. Whisper/Qwen: considerar rodar o C em thread dedicada e bridgear com `withCheckedThrowingContinuation` para não ocupar o cooperative pool global (whisper.cpp já usa `n_threads` internamente — o custo principal é a thread do ator esperando).
3. Medir com `swift test` + Instruments (Time Profiler) num Mac real com pressão de UI.

---

## 4. AEC — P1 (algoritmo)

**Código:** `CanceladorDeEco.swift:58-103` — NLMS sample-by-sample, `vDSP_dotpr` + update escalar por amostra, filtro 4096 taps.

**Baseline:** 0,488 s para 5 s → **~10,2× slower than realtime** single-thread (uma hora de conversa sem fones ≈ 8–10 min só de AEC, ainda antes do Whisper).

**Propostas:**
1. Block-LMS (update por bloco de 512 com vDSP) — mesmo comportamento aproximado, muito menos overhead de amostra.
2. Reduzir taps se a qualidade permitir (2048) — validar com fixture de eco.
3. Pular AEC quando SNR do sistema for baixo (já há corte por `usavaFones == false`).

---

## 5. VAD — P2

- Path de energia (baseline CLI): 50 ms / 30 s — **ok**.
- Silero: `probabilidadesDeFala` itera quadros com `await` por lote de 128 (`DetectorDeAtividadeDeVoz.swift:142-160`); cada `SessaoOnnx.rodar` aloca/copias tensores (`SessaoOnnx.swift:132-153`).
- **Proposta:** inferência batch real (128×576 em um Run se o modelo aceitar batch) ou reduzir cópias; adicionar micro `vad.silero` ao harness com o `.onnx` do bundle.

---

## 6. Download de pesos — P2

`DownloadDeModelos.swift:150-161`: `for try await byte in bytes` — **um byte de cada vez** até 4 MiB de buffer.

**Proposta:** consumir em fatias (`bytes.lines` não serve; usar `AsyncBytes` em blocos de 256 KiB–4 MiB via `Unsafe` ou acumular com `reduce`/chunking). Ganho típico: ordens de magnitude de overhead de Swift concurrency no primeiro download (3+6 GB).

---

## 7. Alinhamento / diarização — P3

- `AlinhamentoDeFalantes.atribuir` — O(palavras × segmentos) com `map/filter/sort` por palavra (`AlinhamentoDeFalantes.swift:77-141`). Baseline 3,7 ms (200×400). Para 3 h: ~10k palavras × ~2k segmentos pode ir a dezenas–centenas de ms — ainda ok; se medir pior, usar sweep ordenado por tempo (dois ponteiros).
- `FalasDaConversa.canalUniforme` faz `first { $0.id == id }` **O(n²)** em trechos da fala (`FalasDaConversa.swift:156-161`) — micro; baseline `falas.agrupar` 0,34 ms.
- `ResolvedorDeFalantes.aplicar` remapeia palavras por trecho — ok.

---

## 8. Persistência e UI — P3

- `SwiftDataRepository.salvar` regrava **todos** os trechos e re-encoda `palavrasJSON` a cada save (`SwiftDataRepository.swift:70-103`); pipeline salva **duas vezes** (`PipelineDeArquivo` 161 e 189). Em reunião com milhares de palavras, JSON encode ×2 é medível mas menor que o Qwen.
- `buscar` faz **5 fetches** + filtros em memória (`SwiftDataRepository.swift:135-215`) — ok para catálogo local; FTS5 já é considerado no comentário.
- `BibliotecaHomeView.arquivosFiltrados` recomputa sort+filter a cada render (`BibliotecaHomeView.swift:338-366`) — com centenas de arquivos ok; com milhares, memoizar por geração de `invalidacaoVisual`.
- `ExportacaoMarkdown` e `navegacao.indiceAtivo` — irrelevantes.

---

## 9. Bug de correção encontrado (bloqueia 2 testes)

**`Segmentacao.agrupar` descarta o `id` do trecho** ao fechar um grupo (`Segmentacao.swift:31-49`): `Trecho(...)` sem parâmetro `id` → `UUID()` novo (`Dominio.swift:137`).

- Efeito: pipeline de mixagem (`Segmentacao.agrupar(try await transcrever(...))`, `PipelineDeArquivo.swift:259`) troca o id que o motor/devolveu.
- Testes falhos: `PipelineTests.swift:554` e `:579` (`pipelineTraduzAntesDeSalvarEResumir`) — `trechos[0].id != idDoTrecho`.
- **Pré-existente** (último commit que tocou o arquivo: `622561a`); diff atual do harness não altera `Segmentacao` nem `PipelineTests`.
- **Correção proposta (fora do escopo de implementação desta análise):** preservar `id` do primeiro segmento (ou do agrupador) em `fechar()` — mesmo padrão de `marcar` (`Segmentacao.swift:124`).

---

## 10. Ordem de ataque recomendada

1. **Corrigir `Segmentacao.agrupar` id** — destrava suíte; risco quase zero.  
2. **Instrumentar `completar` + ciclo de carga Qwen** no harness (Fase 2 dos benches) para baseline de prefill/decode/loads.  
3. **AEC em background + block-LMS** — ganho linear no caminho dual-channel.  
4. **Motores residentes com TTL** — remove ~1 s+ (Whisper) e carga Qwen do caminho crítico de UI.  
5. **Download em blocos** — UX de instalação.  
6. **Otimizações Qwen (clear seletivo, maxTokens, medir reprompt rate)** — maior alvo absoluto (186 s).  
7. VAD batch / alinhamento sweep / UI memo — só se os macros indicarem.

---

## 11. Harness e reprodução

```bash
# baseline micro+macro (modelos em Application Support)
./Scripts/bench-papagaio.sh

# suíte (recupera codesign do .xctest se preciso)
./Scripts/testa-papagaio-core.sh
```

Artefatos: `PapagaioCore/Benchmarks/baseline.json`  
Código: `papagaio-eval` (`bench`), `Bench.swift`, `CasosDeMicroBench.swift`, `CasosDeMacroBench.swift`.

**Lacunas do baseline atual (próximos casos a adicionar):**
- `macro.whisper.transcrever` com áudio real (RTF) — pulou sem `--audio`;
- `macro.qwen.cicloCargaDescarga`;
- `macro.qwen.traduzir`;
- `vad.silero` com modelo ONNX;
- contagem de loads/unloads por pipeline.

**Testes:** 216 `@Test`; **2 falhas pré-existentes** em `PipelineTests` (seção 9), não relacionadas ao harness.

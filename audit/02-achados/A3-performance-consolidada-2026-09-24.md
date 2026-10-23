# A3 — Auditoria consolidada de performance

> **Data:** 24/09/2026  
> **Escopo principal:** todo o código Swift de produção de primeira parte do app e do `PapagaioCore`, além dos testes, do harness de benchmarks e da integração com a dependência FluidAudio.  
> **Escopo da análise:** 232 arquivos de produção (171 do app e 61 do `PapagaioCore`), aproximadamente 45.602 linhas, 33 arquivos de teste e o fluxo de build/CI.  
> **Método:** leitura integral por áreas paralelas, busca transversal, inspeção das configurações, build pelo Xcode e revisão das medições locais já registradas em `audit/02-achados/A3-performance.md`. Nenhum arquivo de produção foi alterado.

## Como interpretar

- **CONFIRMADO:** o mecanismo e o custo potencial estão diretamente demonstrados no código; alguns itens também possuem medição sintética local.
- **PROVÁVEL:** o mecanismo está confirmado estaticamente, mas a magnitude real depende do acervo, hardware, rede ou duração do áudio.
- **CONDICIONAL:** o problema só se manifesta em condições específicas, como concorrência, payloads grandes ou uso intenso.

Severidade:

- **Alta:** congelamento, consumo desproporcional de CPU/RAM/disco, crescimento quadrático ou trabalho de rede indevido em cenários plausíveis.
- **Média:** repetição evitável, invalidação ampla ou degradação relevante com volume/tempo.
- **Baixa:** custo constante ou de impacto limitado, mas ainda evitável.

## Resumo executivo

Foram consolidados **32 problemas de performance**:

| Severidade | Quantidade |
|---|---:|
| Crítica | 0 |
| Alta | 16 |
| Média | 13 |
| Baixa | 3 |
| **Total** | **32** |

Os riscos mais importantes são:

1. **I/O no caminho de áudio em tempo real e no `MainActor`.**
2. **Ciclo de vida inefficientemente fragmentado dos modelos locais**, com recarga frequente e ausência de um coordenador global.
3. **Carga eager da biblioteca completa**, seguida de busca linear por tecla sobre todo o conteúdo.
4. **Persistência excessiva:** o SwiftData regrava o grafo inteiro; Calendar, lixeiras e outbox repetem encodes/decodes completos.
5. **Sincronização CloudKit que baixa a zona inteira e materializa tudo antes de “paginar”.**
6. **Complexidade quadrática no AEC, mesclagem de canais, alinhamento de palavras, limpeza de conta e alguns joins da UI.**
7. **Falta de observabilidade e gate de performance**, impedindo detectar regressões de cauda, memória e interface.

## Validação realizada nesta consolidação

- `BuildProject`: **sucesso em 23,409 s**, sem erros.
- Build Debug: apenas um aviso de extração de metadata do AppIntents sem dependência declarada; não é um problema de runtime do app.
- Testes do app pelo Xcode: **107 testes, 99 passaram e 8 falharam**.
- Entre as falhas, os dois testes de cancelamento/timeout do OAuth Google terminaram com o runner encerrado antes de concluir, reproduzindo o travamento de cancelamento já documentado.
- Esses números de build/teste são verificações de sanidade, não medições de desempenho de produção.

## Evidências quantitativas já disponíveis

As medições abaixo vieram da auditoria anterior neste mesmo checkout e foram reutilizadas; não são SLAs nem resultados Release do app completo.

| Cenário sintético | Resultado anterior | Leitura correta |
|---|---:|---|
| Busca: 100 arquivos × 300 trechos, sem match | `0,512702 s` no núcleo de busca | O corpo da UI pode avaliar o resultado mais de uma vez por tecla. |
| Duas avaliações do mesmo núcleo de busca | `≈1,0254 s` projetados | Projeção aritmética, não p95 observado no app. |
| Reescrita de snapshot Calendar com 1.000 eventos | `0,017338 s` por reescrita | O custo é repetido por evento, não uma vez por sincronização. |
| Atualização SwiftData: 20 arquivos × 800 palavras | `0,222033 s` por arquivo | Container em memória; disco real pode ser diferente. |
| AEC com 5 s sintéticos | `0,573178 s` | Confirma custo alto do algoritmo; não representa RTF de uma reunião real. |
| Ciclo de carga/descarga do Whisper em nova instância | mediana `1,006931 s`, n=3 | Medida isolada, incluindo uma primeira amostra fria. |
| Codificação de outbox com 500 operações | `0,014581 s` por gravação | Conteúdo sintético menor que uma transcrição real. |
| AEC de uma hora, dois canais e saída | aproximadamente `879 MiB` só nos arrays principais | Aritmética de buffers, não RSS medido. |

Fonte primária: `audit/02-achados/A3-performance.md:21-82,184-233`.

---

# Achados de severidade alta

## PERF-001 — Escrita síncrona no callback de áudio do ditado

- **Confiança:** CONFIRMADO
- **Evidência:** `Loro/Papagaio/ViewModels/GravadorViewModel.swift:452-456`.
- O `installTap` de `AVAudioEngine` chama `arquivo.write(from: buffer)` diretamente no callback de renderização e descarta o erro com `try?`.
- **Impacto:** disco lento, buffer cheio ou I/O concorrente pode bloquear o thread de áudio, gerar underrun/dropout e fazer a captura atrasar ou falhar.
- **Correção:** usar escrita assíncrona/ring buffer com writer dedicado; propagar erro de escrita e marcar a captura como degradada. Não é seguro despachar o `AVAudioPCMBuffer` original para outra fila sem antes manter/copiar seus bytes.
- **Validação:** captura real de 1 h em disco normal e volume artificialmente lento; p99 do callback abaixo do prazo do buffer e zero erro ignorado.

## PERF-002 — Modelos são recriados e recarregados por operação

- **Confiança:** CONFIRMADO; impacto medido em ciclo isolado
- **Evidências:**
  - `Loro/Papagaio/ViewModels/Biblioteca.swift:846-860` — nova instância para ditado.
  - `Loro/Papagaio/ViewModels/Biblioteca.swift:894-975` — nova instância por arquivo e descarga no fim.
  - `Loro/Papagaio/ViewModels/Biblioteca.swift:994-1040` — nova instância na diarização avulsa.
  - `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:21-80,122-193`.
- **Impacto:** cada operação paga carga/descarga de Whisper/Qwen e perde provedores de aceleração. A medição anterior medianou `1,006931 s` para um ciclo Whisper em nova instância.
- **Correção:** compartilhar um gerente de motores por `Biblioteca`, com política explícita de residência, reutilização enquanto RAM/temperatura permitir e descarga por pressão. Registrar carga fria, quente e descarga.
- **Validação:** processar 10 arquivos consecutivos; comparar tempo total, número de cargas, pico de `phys_footprint` e trocas térmicas.

## PERF-003 — Operações pesadas de modelos não têm exclusão mútua global

- **Confiança:** CONDICIONAL à concorrência
- **Evidências:** `Loro/Papagaio/ViewModels/Biblioteca.swift:846-975,994-1040`.
- Pipeline, ditado e diarização criam instâncias diferentes de `MotoresLocais`; a fila de exclusão pertence à instância, não ao app.
- **Impacto:** ditado durante resumo, duas diarizações ou outra sobreposição podem deixar Whisper e Qwen residentes ou duas cópias do mesmo modelo, causando pico de RAM/Metal, contenção e aquecimento.
- **Correção:** criar um ator/coordenador único de jobs de modelo. A política deve primeiro serializar operações pesadas e só depois decidir por reutilização; o coordenador deve aplicar prioridade, cancelamento e descarga por pressão.
- **Validação:** barreiras em testes devem provar que apenas um job de modelo entra por vez e que jobs de I/O/UI podem continuar sem violar o limite de memória.

## PERF-004 — A biblioteca carrega eager transcrições, palavras, notas e lixeira

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/ViewModels/Biblioteca.swift:245-257` carrega ativos e excluídos na abertura.
  - `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:218-240` usa prefetch de `trechos`, `insights` e `notas`.
  - `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:424-510` reconstrói cada palavra ao mapear para o domínio.
- **Impacto:** a grade recebe modelos completos, mesmo quando precisa apenas de título, preview, duração, estado e contagens. Abrir a biblioteca pode materializar horas de transcrição e decodificar todas as palavras.
- **Correção:** criar `ArquivoCard`/`CabecalhoArquivo`, paginar a query, carregar transcrição apenas no detalhe e carregar a lixeira apenas quando acessada.
- **Validação:** 10/100/500/1.000 conversas; tempo até primeiro conteúdo, número de entidades carregadas e footprint.

## PERF-005 — Busca da biblioteca percorre todo o acervo a cada tecla

- **Confiança:** CONFIRMADO e medido sinteticamente
- **Evidências:** `Loro/Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:338-432` e `Loro/Papagaio/Suporte/BuscaSemAcento.swift:3-12`.
- `arquivosFiltrados` ordena a fonte e `conversaCasaTermo` relê metadados, normaliza datas/durações e percorre resumo, trechos e notas. A lista é consultada mais de uma vez no mesmo `body`.
- **Impacto:** o pior caso é busca sem correspondência. A medição anterior mediu `0,512702 s` no núcleo para 100 × 300 trechos, e o `body` pode avaliar o derivado novamente.
- **Correção:** debounce de 200–300 ms, tarefa cancelável, índice normalizado/FTS por conversa e cache do resultado por `(revisão, consulta, filtros)`.
- **Validação:** digitação real com 10/100/500/1.000 conversas; p50/p95 de tecla→resultado e stalls do main actor.

## PERF-006 — SwiftData regrava o grafo inteiro e carrega relações completas

- **Confiança:** CONFIRMADO e medido sinteticamente
- **Evidências:**
  - `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:40-120` apaga e recria `trechos`, `insights` e `notas`.
  - `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:135-225` busca e lista com prefetch completo.
  - `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:159-189` salva antes e depois do resumo.
- **Impacto:** editar título/metadados custa o mesmo que reescrever a transcrição inteira; o pipeline repete deletes/inserts e JSON quando apenas o resumo mudou. A atualização sintética medianou `0,222033 s` por arquivo de 800 palavras em container em memória.
- **Correção:** APIs `salvarTranscricao`, `atualizarDiarizacao`, `atualizarTraducao`, `atualizarResumo` e `atualizarCamposEscalares`; reconciliar filhos por revisão/ID e não destruir relações imutáveis.
- **Validação:** 10–100 mil palavras; exigir zero delete/insert de filhos ao editar título ou resumo.

## PERF-007 — AEC é O(N × 4096), materializa canais inteiros e deixa PCM temporário

- **Confiança:** CONFIRMADO e parcialmente medido
- **Evidências:**
  - `PapagaioCore/Sources/PapagaioCore/CanceladorDeEco.swift:70-97` monta o vetor de 4.096 taps e atualiza 4.096 pesos por amostra.
  - `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:398-418` decodifica microfone e sistema completos, produz um terceiro array e grava `microfone_aec.pcm`.
  - `PapagaioCore/Sources/PapagaioCore/Transcricao/DecodificadorDeAudio.swift:37-41,66-82` retorna a gravação inteira.
- **Impacto:** para uma hora a 16 kHz são cerca de 57,6 milhões de amostras × 4.096 taps. Somente inputs/saída/Data chegam perto de 900 MB. O arquivo intermediário adiciona outra cópia em disco e não é removido após a transcrição.
- **Correção:** AEC incremental por blocos, atualização NLMS por passo `L/4` ou `L/8`, Accelerate/vDSP, escrita em `FileHandle` e cleanup em `defer`; avaliar AudioToolbox/WebRTC/RNNoise conforme qualidade.
- **Validação:** 1 s, 60 s, 10 min e 1 h; RTF, pico de memória independente da duração e ausência do `.pcm` após sucesso/erro.

## PERF-008 — A “paginação” CloudKit baixa e materializa a zona inteira

- **Confiança:** CONFIRMADO no código; impacto real depende do workspace
- **Evidências:** `Loro/Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:178-197,212-270`.
- `CKFetchRecordZoneChangesOperation` usa `fetchAllChanges = true`, não persiste `CKServerChangeToken`, acumula todos os `CKRecord`, converte assets em `Data` e só depois divide o array em páginas de 200.
- **Impacto:** rede, memória e decode escalam com a zona inteira a cada sincronização; o cursor atual não reduz a carga do servidor.
- **Correção:** persistir token por zona, configurar limite real de resultados, processar cada página ao chegar e só salvar o token depois de aplicar a página correspondente.
- **Validação:** ambiente CloudKit de desenvolvimento com 100/1.000/5.000 registros; segunda sincronização sem mudança deve trazer apenas delta.

## PERF-009 — Outbox CloudKit regrava o JSON inteiro e envia uma operação por vez

- **Confiança:** CONFIRMADO e medido no formato
- **Evidências:** `Loro/Papagaio/CloudKit/FilaPersistenteCloudKit.swift:103-170,204-219`.
- Cada conclusão ou backoff busca linearmente a operação, filtra a fila inteira e grava atomicamente todo o JSON. A fila também serializa envios e mantém payloads completos.
- **Impacto:** busca linear pode chegar a O(n²), gravação completa O(n²) em bytes e há até duas requests sequenciais por item. A medição anterior chegou a `0,014581 s` por encode/gravação com 500 operações sintéticas.
- **Correção:** drain single-flight, lotes limitados, log append-only ou armazenamento transacional, payload por hash/referência e confirmação/backoff persistido em lote.
- **Validação:** 10/100/500/1.000 operações; contar requests, bytes escritos, encodes e número de drains efetivos.

## PERF-010 — Reconciliação do Calendar reescreve o snapshot por evento

- **Confiança:** CONFIRMADO e medido no mecanismo
- **Evidências:**
  - `Loro/Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:31-83`.
  - `Loro/Papagaio/Integracao/GoogleCalendarViewModel.swift:260-296`.
- Para cada evento, o estado relê e regrava o dicionário completo. Eventos convertidos podem disparar outra escrita e outra consulta/decoder.
- **Impacto:** custo agregado O(M²) no main actor. A auditoria anterior medianou `0,017338 s` por reescrita com um snapshot de 1.000 eventos.
- **Correção:** carregar uma vez, reconciliar a página em lote, manter índices ignorados/convertidos, expirar estados antigos e persistir no máximo uma vez quando algo mudou.
- **Validação:** 10/100/500/1.000 eventos; uma carga inicial e no máximo uma escrita por reconciliação.

## PERF-011 — Limpeza de conta e lixeiras é O(F × R) no `MainActor`

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/Persistencia/LimpezaDeConta.swift:6-43` percorre IDs e chama a cascata por arquivo.
  - `Loro/Papagaio/Persistencia/LixeiraDeMidia.swift:164-170,199-217` decodifica, filtra e reescreve por item.
  - `Loro/Papagaio/Persistencia/LixeiraDePastas.swift:116-135` reescreve listas globais por pasta/ID.
- **Impacto:** F arquivos e R referências produzem várias leituras e gravações JSON; quando F ≈ R, o custo tende a O(n²), tudo no main actor.
- **Correção:** API em lote com `Set<ArquivoID>`, carregar cada store uma vez, filtrar e salvar uma única vez em um ator serial.
- **Validação:** 100/1.000/5.000 arquivos; encodes e writes constantes por store, não por arquivo.

## PERF-012 — Importação, cópia e bookmarks de mídia bloqueiam o `MainActor`

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/ViewModels/MidiasDaConversaViewModel.swift:13-15,65-110,120-193`.
  - `Loro/Papagaio/Persistencia/MidiasDaConversa.swift:150-166`.
  - `Loro/Papagaio/ViewModels/Biblioteca.swift:695-768,1310-1368`.
- A classe é `@MainActor`; múltiplos URLs são processados em sequência; cada adição copia, resolve atributos, recria bookmarks de todos os anexos e regrava JSON. Duplicar e importar áudio também usa `FileManager.copyItem` antes do próximo `await`.
- **Impacto:** vídeo de vários GB, disco lento ou caixas File Provider podem congelar a janela. Para `k` anexos e `m` novos, são criados aproximadamente `km + m²/2` bookmarks.
- **Correção:** `FileStore`/ator de I/O, `adicionarVarios`, preservar bookmarks existentes, copiar em chunks com progresso/cancelamento e publicar o snapshot uma vez no main actor.
- **Validação:** 50/200 anexos em pasta com 100 itens; um bookmark por item novo e uma persistência por lote.

## PERF-013 — Cancelamento/timeout do OAuth Google pode ficar bloqueado indefinidamente

- **Confiança:** CONFIRMADO por teste/experimento anterior e reproduzido no runner atual
- **Evidências:** `Loro/Papagaio/Integracao/SessaoOAuthGoogle.swift:416-452,484-502`.
- O cancelamento chama `shutdown` no socket de escuta, mas o worker pode continuar bloqueado em `Darwin.accept`; o task group espera o filho e `tarefaDeConexao` permanece ocupada.
- **Impacto:** a UI permanece conectando, novas tentativas são bloqueadas e o runner de testes pode não finalizar. Dois testes atuais falharam por saída prematura do runner.
- **Correção:** `accept` não bloqueante/`DispatchSource`/wakeup por conexão local, fechamento idempotente e conclusão de todas as tarefas filhas.
- **Validação:** 100 cancelamentos sem cliente e com cliente conectado; término em menos de 2 s, zero handle/task residual e timeout explícito no teste/CI.

## PERF-014 — Mesclagem de canais e alinhamento palavra–segmento são quadráticos

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `PapagaioCore/Sources/PapagaioCore/Transcricao/Segmentacao.swift:103-119` usa `contains` em todos os trechos do sistema para cada trecho do microfone.
  - `PapagaioCore/Sources/PapagaioCore/Diarizacao/AlinhamentoDeFalantes.swift:68-140` varre e ordena candidatos duas ou três vezes por palavra.
- **Impacto:** O(M × S) na mesclagem e O(P × S log S) no alinhamento, com arrays temporários; reuniões longas com muitos turnos/segmentos custam dezenas de milhões de comparações.
- **Correção:** sweep line/busca binária por intervalo; encontrar primeiro e segundo sem ordenar tudo; precomputar índices de vizinhos e prefixar IDs de canal uma única vez.
- **Validação:** 250–4.000 segmentos e 1k–50k palavras; contagem de comparações e escala aproximadamente linear após a correção.

## PERF-015 — Downloads de vários GB são iterados byte a byte e serializados globalmente

- **Confiança:** CONFIRMADO
- **Evidência:** `PapagaioCore/Sources/PapagaioCore/Runtime/DownloadDeModelos.swift:135-178`.
- `for try await byte in bytes` executa uma iteração por byte; cada byte entra em `Data`. O modelo Qwen tem cerca de 6,17 GB, mais de 6 bilhões de iterações. Uma fila global também impede downloads de arquivos distintos em paralelo.
- **Impacto:** CPU/allocator desnecessários, baixa vazão e progresso excessivo; writes e checksum são síncronos no ator.
- **Correção:** `URLSessionDownloadTask`/delegate com chunks, escrita por `FileHandle`, resume persistente por destino e concorrência deduplicada apenas para o mesmo destino.
- **Validação:** servidor local com 64 MB/512 MB/1 GB; throughput, CPU, alocações e dois downloads distintos concorrentes.

## PERF-016 — Detalhe reconstrói dossiê, busca e modelo derivado no `body`/por tick

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:164-248,484-529,1460-1600` — dossiê eager no `fileExporter`, busca e `falas` computadas repetidamente.
  - `Loro/Papagaio/Persistencia/FalantePreservadoParaTrecho.swift:20-34` — cada consulta relê e decodifica o mapa inteiro.
  - `PapagaioCore/Sources/PapagaioCore/Diarizacao/FalasDaConversa.swift:74-161` reagrupa a transcrição para cada acesso.
- **Impacto:** trocar busca, seção ou estado do player pode reconstruir transcrição, índices e JSON; o dossiê pode ler mídia/tarefas mesmo com o exportador fechado. O custo cresce com o tamanho da reunião.
- **Correção:** `ModeloDeApresentacaoDaTranscricao` cacheado por revisão, snapshot único de busca/falas, mapa de falantes em memória e dossiê gerado somente no gesto de exportar.
- **Validação:** alternar busca/seção com exportador fechado deve produzir zero geração de dossiê; reprodução por 10 min não deve reagrupar falas sem mudança de transcrição.

---

# Achados de severidade média

## PERF-017 — MCP e OAuth materializam respostas e não fazem single-flight

- **Confiança:** PROVÁVEL, depende do payload e concorrência
- **Evidências:**
  - `Loro/Papagaio/Integracao/ClienteMCP.swift:129-187,203-250` usa `URLSession.data`, converte `Data`→`String`, divide/filter/join e reconverte.
  - `Loro/Papagaio/Integracao/SessaoOAuthGoogle.swift:86-109,221-320` relê Keychain e metadados.
  - `PapagaioCore/Sources/PapagaioCore/Integracao/SessaoOAuth.swift:51-75` e `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:140-183` permitem refresh/inicialização concorrentes.
- **Impacto:** múltiplas cópias para SSE/JSON grande, stream longo espera timeout e chamadas simultâneas podem gerar refresh tokens duplicados ou várias sessões MCP.
- **Correção:** streaming incremental de bytes/SSE, `Decodable` tipado, cache de token e `Task` single-flight para refresh e `initialize`.
- **Validação:** 20–100 callers concorrentes; exatamente uma renovação/inicialização e pico de memória conhecido para respostas de 1/10/100 MB.

## PERF-018 — Fila global do VAD serializa decodificação, janelas e Whisper

- **Confiança:** CONFIRMADO no código
- **Evidências:** `PapagaioCore/Sources/PapagaioCore/Transcricao/DetectorDeAtividadeDeVoz.swift:106-124,173-193` e `PapagaioCore/Sources/PapagaioCore/Transcricao/WhisperEngine.swift:82-123`.
- A exclusão é adquirida em `iniciar` antes do decoder e só liberada em `finalizar`, depois de todas as janelas e inferências Whisper.
- **Impacto:** múltiplos arquivos não podem decodificar/VAD em paralelo; a fila protege um modelo pequeno, mas retém um pipeline muito maior que o VAD.
- **Correção:** estado recurrente por sessão; serializar apenas inferência Silero ou usar instâncias pequenas por job e limitar o número delas.
- **Validação:** duas/quatro transcrições concorrentes; apenas chamadas Silero se sobrepõem.

## PERF-019 — Carga/descarga de diarização tem corrida e fallback destrutivo offline

- **Confiança:** PROVÁVEL/condicionado à concorrência ou modelo corrompido
- **Evidências:**
  - `PapagaioCore/Sources/PapagaioCore/Diarizacao/GerenciadorDeModelosDeDiarizacao.swift:60-81`.
  - `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:47-81`.
- Reentrância durante `preparar` pode criar dois managers; `descarregar` pode ser desfeito quando a carga suspensa termina. O fallback do FluidAudio offline ainda pode apagar o cache pré-estagiado após falha de carga.
- **Impacto:** compilação/carregamento duplicado de CoreML, pico de memória, modelo “descarregado” que volta e perda do cache offline.
- **Correção:** memoizar uma única task de preparação, usar generation token e carregar/copiar modelos locais diretamente sem purge externo.
- **Validação:** várias chamadas simultâneas + descarga; uma carga, descarga vencedora e nenhum asset removido após erro.

## PERF-020 — Merge de equipe é O(remotas × locais) e consulta disco no fluxo

- **Confiança:** CONFIRMADO
- **Evidência:** `Loro/Papagaio/ViewModels/Biblioteca.swift:1138-1174`.
- Para cada conversa remota, concatena `arquivos + arquivosNaLixeira`, procura `first` linearmente e executa `FileManager.fileExists` no main actor.
- **Impacto:** entrada de equipe grande gera O(R × N), cópias de arrays e múltiplas syscalls.
- **Correção:** `[ArquivoID: Arquivo]`, um único merge por snapshot e ator de I/O para mídia; salvar alterações por item/página.
- **Validação:** 100/500/1.000 registros; lookups O(1) e número de `stat` independente do layout da lista.

## PERF-021 — Exportação de pacote pode bloquear a UI e reter ZIP temporário

- **Confiança:** PROVÁVEL, depende do tamanho
- **Evidências:** `Loro/Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1429-1480` e `Loro/Papagaio/Suporte/DossieDaConversa.swift:56-269`.
- Preparação/cópia/ZIP pode estar no fluxo síncrono do botão; dependendo do ramo, cancelar o painel não sempre descarta o arquivo intermediário. O fallback de compartilhamento pode repetir o custo.
- **Impacto:** Main Thread freeze e espaço temporário do tamanho do pacote após cancelamento.
- **Correção:** pedir destino antes, gerar em ator/task de I/O, `defer` de cleanup em sucesso/erro/cancelamento e evitar cópia intermediária quando o destino é pasta.
- **Validação:** áudio de 2–5 GB, cancelar e falhar em cada fase; zero ZIP órfão.

## PERF-022 — `LayoutDeFluxo` mede todas as palavras duas vezes e não usa cache do `Layout`

- **Confiança:** CONFIRMADO
- **Evidência:** `Loro/Papagaio/DesignSystem/Componentes/LayoutDeFluxo.swift:24-105`.
- `sizeThatFits` mede cada subview; `placeSubviews` cria outro array chamando `sizeThatFits` novamente; `cache` é `()`.
- **Impacto:** falas com milhares de palavras repetem layout/distribuição a cada resize ou invalidação.
- **Correção:** cache real de tamanhos/linhas por largura, ou texto atribuído com hit-testing por range e blocos visuais de 200–500 palavras.
- **Validação:** 1k/5k/10k palavras; número de medições por ciclo e tempo de layout.

## PERF-023 — Estado rápido invalida raízes; player mantém timer mesmo pausado

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/ViewModels/GravadorViewModel.swift:237-256` publica waveform/tempo a 20 Hz.
  - `Loro/Papagaio/Funcionalidades/Gravacao/Waveform.swift:10-35` cria um `Path` com um `addRect` por amostra.
  - `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:111-132,229-233` cria timer de 10 Hz na preparação.
- **Impacto:** `ContentView`, biblioteca, cronômetro e notas podem ser invalidados fora da frequência necessária; o player continua acordando 10 vezes/s mesmo pausado.
- **Correção:** waveform isolada em subview/`Canvas`; cronômetro a 1 Hz; timer somente enquanto reproduzindo e suspenso por `scenePhase`; publicar apenas valores alterados.
- **Validação:** Energy Log e contagem de ticks com app pausado, detalhe pausado e gravação ativa.

## PERF-024 — Painel de tarefas filtra/ordena tudo repetidamente e usa pilhas eager

- **Confiança:** CONFIRMADO
- **Evidências:** `Loro/Papagaio/Funcionalidades/Tarefas/TarefasView.swift:48-175,177-217,371-468`.
- Cada coluna recalcula `tarefasVisiveis`; `Calendar.current.startOfDay(for: Date())` é repetido por tarefa; cartões vivem em `VStack` dentro de `ScrollView` externo.
- **Impacto:** cada tecla ou mudança de filtro repete sorts/filters O(T log T) e constrói todos os cartões de cada coluna.
- **Correção:** snapshot único com partições por status/prazo, `hoje` calculado uma vez, índices e colunas lazy/paginadas/virtualizadas.
- **Validação:** 1.000/10.000 tarefas; uma reconstrução por invalidação e apenas células visíveis.

## PERF-025 — Imagens são carregadas no tamanho original, no main actor e sem cache

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/Funcionalidades/Detalhe/Midia/PreviaDoAnexoDeMidia.swift:53-68` usa `NSImage(contentsOf:)` para imagens.
  - `Loro/Papagaio/Persistencia/MiniaturaDeImagem.swift:12-35` e `Loro/Papagaio/Persistencia/AparenciaDoCartao.swift:71-153` fazem resize/caches com orçamento inconsistente.
- **Impacto:** fotos de 40–100 MP são decodificadas em tamanho integral para células de aproximadamente 270×150; rolar para fora e voltar pode repetir I/O/decode; `NSCache` não tem custo total uniforme.
- **Correção:** ImageIO downsample por destino, ator de thumbnails, `NSCache` com `totalCostLimit` e chave `URL+tamanho+modificationDate`.
- **Validação:** 20 imagens de 50 MP; pico próximo ao thumbnail e ausência de `NSImage(contentsOf:)` no Main Thread trace.

## PERF-026 — Inicialização e polling fazem trabalho evitável antes/depois da UI

- **Confiança:** PROVÁVEL, depende de disco, volume e rede
- **Evidências:**
  - `Loro/Papagaio/App/PapagaioApp.swift:41-58` executa migração de status síncrona no `init`.
  - `Loro/Papagaio/Integracao/GoogleCalendarViewModel.swift:152-181` consulta a cada 15 min sem `ETag`, backoff ou coordenação com botão/visibilidade.
  - `Loro/Papagaio/ViewModels/Biblioteca.swift:148-165` carrega SwiftData/outbox no caminho de inicialização.
- **Impacto:** launch espera scans de UserDefaults; Calendar pode baixar respostas idênticas, duplicar polling e continuar trabalho com tela oculta.
- **Correção:** inicialização assíncrona após o primeiro frame, migração em lotes; polling coordenado por uma única task, pausado por `scenePhase`, com ETag/304 e backoff.
- **Validação:** time-to-first-frame com 10k/100k tarefas e requests por sessão com janela oculta/offline.

## PERF-027 — Progresso de download publica atualizações sem throttle

- **Confiança:** CONDICIONAL à velocidade de rede
- **Evidências:** `Loro/Papagaio/ViewModels/ModelosViewModel.swift:69-105,120-140` recebe eventos de 4 MiB e cria `Task { @MainActor }` para cada um.
- **Impacto:** rede muito rápida pode gerar centenas de atualizações/s, enfileirar tasks no main actor e provocar rajadas de SwiftUI sem ganho visual.
- **Correção:** coalescer no downloader para 5–10 Hz ou mudança mínima de percentual/bytes; publicar início/fim/erro imediatamente.
- **Validação:** servidor local de 1 GB e contagem de atualizações no main actor.

## PERF-028 — ONNX faz alocações por quadro e pode vazar recursos em carga parcial

- **Confiança:** CONFIRMADO no wrapper
- **Evidências:**
  - `PapagaioCore/Sources/PapagaioCore/Transcricao/SileroVAD.swift:65-125` e `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:112-215` alocam nomes, buffers, `OrtValue` e outputs por inferência.
  - `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:66-98` só registra `env/opcoes/memoria` em `caixa` após todos os passos; falha parcial não libera os recursos anteriores.
- **Impacto:** até centenas de milhares de chamadas em uma hora, com mallocs/frees e hops entre atores; falhas repetidas de carga podem acumular handles nativos.
- **Correção:** `rodarSequencia` dentro do ator ONNX, reutilizar buffers/arena e executar rollback seguro em `catch`.
- **Validação:** 30 min/1 h de VAD e fault injection em cada etapa de criação; handles/RSS estáveis.

## PERF-029 — Benchmarks não são gate e faltam métricas de cauda, memória e UI

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `.github/workflows/ci.yml:9-42` não executa `bench-papagaio.sh`.
  - `PapagaioCore/Sources/papagaio-eval/Bench.swift:42-116,217-254` não preserva p95/amostras e não falha ao reportar piora.
  - `PapagaioCore/Sources/papagaio-eval/main.swift:540-549` aceita baseline ausente/inválido.
  - Não há `OSSignposter` nem signposts no app/Core.
- **Impacto:** regressões de desempenho podem entrar com build e testes verdes; a auditoria anterior medianou Qwen em `199,6620 s` sem orçamento nem p95.
- **Correção:** gate Release em hardware controlado, amostras p50/p95/CV, memória/allocations/I/O, fixtures versionadas e `OSSignposter` por fase.
- **Validação:** CI deve falhar em piora acima de 15%, caso ausente, ambiente incompatível ou memória fora do orçamento.

---

# Achados de severidade baixa

## PERF-030 — Invalidação global e releitura de metadados por card

- **Confiança:** CONFIRMADO
- **Evidências:** `Loro/Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:338-365,460-515` e `Loro/Papagaio/Persistencia/FotosDePessoas.swift:16-28,121-135`.
- Uma alteração de foto/metadado invalida todos os cards e avatares via contador global; cada card relê preferências e metadados de `UserDefaults`.
- **Impacto:** custo O(cards) mesmo quando um único item muda.
- **Correção:** estado observável por pessoa/arquivo e snapshot de apresentação em memória.
- **Validação:** 500 avatares; uma alteração deve invalidar apenas a pessoa afetada.

## PERF-031 — `FilaEstrita.removeFirst` desloca a fila e não remove waiters cancelados

- **Confiança:** CONFIRMADO, impacto depende do tamanho da fila
- **Evidência:** `PapagaioCore/Sources/PapagaioCore/Transcricao/FilaEstrita.swift:14-37`.
- `removeFirst` em array pode custar O(q) por dequeue; waiters cancelados permanecem retidos até sua vez.
- **Impacto:** filas pequenas hoje, mas reutilizadas por VAD, modelos e downloads podem crescer em rotinas longas.
- **Correção:** índice `head`/deque e `withTaskCancellationHandler` para remover ou ignorar tokens cancelados.
- **Validação:** 10 mil entradas, metade cancelada, confirmar O(q) total e ordem FIFO.

## PERF-032 — Formatadores e `ViewThatFits` reconstroem trabalho evitável

- **Confiança:** CONFIRMADO
- **Evidências:**
  - `Loro/Papagaio/DesignSystem/Componentes/ControleSegmentadoPapagaio.swift:9-27` e `Loro/Papagaio/DesignSystem/Componentes/SeletorDeContextoDaConta.swift:105-135` constroem candidatos/listas eager.
  - `Loro/Papagaio/Funcionalidades/Biblioteca/EditorDeInformacoesDoCard.swift:135-143,345-362` mede dois formulários completos por participante.
  - Diversos cards criam `DateFormatter`/`ByteCountFormatter` em propriedades computadas.
- **Impacto:** microcusto multiplicado por cards, participantes e invalidações; pode crescer se a lista aumentar.
- **Correção:** `FormatStyle`, formatadores estáticos e layout escolhido uma vez por seção/largura.
- **Validação:** Allocations durante busca/filtro em 100–500 cards.

---

# Recomendações por ordem de execução

## Onda 0 — Remover travamentos e criar medição

1. Corrigir o cancelamento do OAuth (`PERF-013`) e adicionar deadlines de teste/CI.
2. Garantir que o callback de ditado não faça escrita síncrona (`PERF-001`).
3. Adicionar `OSSignposter` para fila, I/O, modelos, AEC, SwiftData, CloudKit e UI (`PERF-029`).
4. Criar datasets sintéticos de 100/500/1.000 conversas e 1 min/1 h/3 h de áudio.

## Onda 1 — UI e main actor

1. Extrair serviço de I/O para mídia, duplicação, exportação e thumbnails (`PERF-012`, `PERF-021`, `PERF-025`).
2. Introduzir DTO leve/paginação da biblioteca (`PERF-004`) e busca indexada/debounced (`PERF-005`).
3. Isolar waveform/cronômetro/player timer (`PERF-023`).
4. Gerar dossiê apenas no gesto de exportar e cachear modelo de transcrição (`PERF-016`).

## Onda 2 — Modelos, áudio e memória

1. Criar coordenador global de jobs/modelos (`PERF-002`, `PERF-003`).
2. Transformar AEC em streaming por blocos e eliminar `.pcm` órfão (`PERF-007`).
3. Corrigir ciclo de diarização e fallback offline (`PERF-019`).
4. Reduzir escopo da exclusão global do VAD (`PERF-018`).

## Onda 3 — Persistência e sincronização

1. Dividir SwiftData em saves incrementais (`PERF-006`).
2. Implementar token/paginação incremental do CloudKit (`PERF-008`).
3. Trocar outbox por log/lote e drain single-flight (`PERF-009`).
4. Introduzir APIs em lote para Calendar, lixeiras e limpeza (`PERF-010`, `PERF-011`).

## Onda 4 — Algoritmos e integrações

1. Sweep line/busca por índice para mesclagem e alinhamento (`PERF-014`).
2. Download por chunks e progresso throttled (`PERF-015`, `PERF-027`).
3. Streaming MCP e single-flight OAuth/MCP (`PERF-017`).
4. Reutilizar buffers ONNX e corrigir rollback (`PERF-028`).

---

# Critérios de aceite propostos

Os valores abaixo são SLOs provisórios e devem ser calibrados com hardware mínimo suportado.

| Área | Critério |
|---|---|
| Áudio em tempo real | Nenhuma escrita/JSON/I/O no callback; p99 do callback abaixo do prazo do buffer. |
| AEC | Memória temporária não cresce com a duração; RTF definido para 1 h. |
| Biblioteca | Primeiro conteúdo sem carregar transcrições; busca p95 após debounce abaixo de 50 ms em 1.000 cards. |
| SwiftData | Editar título/resumo não executa delete/insert de `trechos` ou `notas`. |
| CloudKit | Segunda sync sem mudança consome apenas delta; memória limitada a uma página. |
| Outbox | Uma alteração gera uma escrita bounded/lote; somente um drain ativo. |
| Modelos | Jobs pesados nunca excedem o orçamento de memória; uma carga por política, não por clique. |
| Tasks | Alterar uma tecla do editor não invalida o quadro Kanban. |
| Cancelamento | Timeout→estado ocioso e cleanup em menos de 2 s para OAuth/modelos/mídia. |
| CI | Regressão >15%, caso ausente ou memória fora do orçamento reprova. |

# Referências oficiais úteis

- [Creating performant scrollable stacks](https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks)
- [Displaying data in lists](https://developer.apple.com/documentation/swiftui/displaying-data-in-lists)
- [`FetchDescriptor`](https://developer.apple.com/documentation/swiftdata/fetchdescriptor)
- [Using `OSSignposter` to measure performance](https://developer.apple.com/documentation/os/recording-performance-data)
- [Structured concurrency with task groups](https://developer.apple.com/documentation/swift/taskgroup)

# Limitações

- A auditoria não mediu p95, Instruments, Allocations, VM Tracker, Metal System Trace ou consumo de energia do app completo.
- CloudKit, OAuth Google, Granola/MCP, microfone, File Provider e hardware de áudio não foram exercitados contra serviços/dispositivos reais.
- Os números synthéticos herdados da auditoria anterior são mecanismos de custo, não resultados de produção.
- O pacote FluidAudio 0.15.5 é terceiro-party. Foram auditados os wrappers e a fronteira offline; correções internas do FluidAudio devem ser feitas upstream.
- Nenhuma alteração de código de produção foi feita nesta consolidação.

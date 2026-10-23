# A3 — Performance

> **Data:** 2026-09-23 · **escopo:** todos os arquivos de produção em `Papagaio/**` e `PapagaioCore/Sources/**` · **modo:** relatório; nenhum arquivo de produção, teste ou benchmark foi alterado por esta auditoria.
>
> O único arquivo do repositório escrito por este agente é este relatório. Experimentos, fontes auxiliares e logs ficaram em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a3`.
>
> **Legenda de confiança:** `CONFIRMADO` = mecanismo ou número reproduzido nesta auditoria; `PROVÁVEL` = evidência estática forte, sem medição do serviço/interface real; `HIPÓTESE` = benchmark concreto ainda necessário. Não há `HIPÓTESE` aberta neste lote. Uma confirmação de mecanismo sintético não é uma afirmação de latência de produção.

## Resumo executivo

- **4 achados ALTO**, **8 MÉDIO**, **1 BAIXO**; nenhum CRÍTICO.
- Os maiores riscos de custo são: recarregamento dos modelos por operação, reescrita integral do grafo SwiftData em cada salvamento, e o ramo AEC que abandona o processamento em blocos e materializa os dois canais inteiros.
- A busca da biblioteca é recomputada no corpo da visualização a cada tecla; no preflight sintético, 100 arquivos × 300 trechos produziram mediana de `0,512702 s` sem correspondência (`preflight.log:14-18`).
- A sincronização CloudKit não foi exercitada contra serviço real: o achado de carga da zona inteira é `PROVÁVEL`, com base no código e na pesquisa oficial reproduzida em `audit/01-pesquisa/cloudkit.md`.
- O bloqueio de cancelamento do OAuth Google é `CONFIRMADO` pela evidência A2-001; o serviço Google real não foi chamado.

---

## Achados

### A3-001 — MotoresLocais é criado por operação, impedindo reutilização entre arquivos
- **Severidade:** ALTO
- **Confiança:** CONFIRMADO para o ciclo de carga/descarga e para o caminho por operação; o custo de ponta a ponta de cada arquivo não foi medido.
- **Locais:** `Papagaio/ViewModels/Biblioteca.swift:64-71, 846-860, 894-902, 971-975, 1004-1041`; `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:5-27, 39-69, 124-135`; `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:73-81, 106-129`; `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift:53-77`.

**Evidência.** O comentário de `MotoresLocais` promete que Whisper e Qwen não ficam residentes juntos, mas a fila e os dois contextos são campos de **uma instância**. A biblioteca cria uma instância nova no ditado (`Biblioteca.swift:852`), no pipeline (`Biblioteca.swift:896`) e na diarização avulsa (`Biblioteca.swift:1008`). A limpeza do pipeline chama `descarregarTudo()` (`Biblioteca.swift:971-975`), portanto o próximo arquivo não herda o contexto. `CicloDeVidaDeModelos` registra o modelo residente para o monitoramento de pressão, mas não o reutiliza entre instâncias.

**Medição própria.** O executável temporário Release, ligado ao `PapagaioCore` local, criou uma nova `WhisperEngine` por repetição, chamou `preaquecer()` e `descarregar()`: mediana de `1,006931 s`, amostras `7,933477; 1,006931; 0,898499 s` (n=3; `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a3/experimentos.log:1790-1793`). A primeira amostra inclui o carregamento frio de Metal/arquivo; este experimento não calculou p95. O mesmo executável, em uma execução separada, mediu o ciclo Qwen em uma instância nova, com um único trecho sintético de 0–1 s (`"olá"`) e uma geração de resumo; não é carga isolada: mediana `10,352796 s`, amostras `10,574042; 10,268287; 10,352796 s` (n=3; `qwen-experiment.log:2393-2396`). O runtime reportou, na carga instrumentada, `5,74 GiB` de arquivo e `5873,09 MiB` de buffer Metal (`qwen-experiment.log:77, 657`); é reportado apenas como ciclo, nunca como tempo de carga. Uma execução local separada do áudio de teste, incluindo carga e transcrição, mediu `4,780088625 s` para `4,3 s` de áudio (`whisper-local.log:69-75`); o runtime informou `3094,36 MB` para o modelo Whisper (`whisper-local.log:45-66`).

**Refutação dos mitigantes.** A fila serial é uma mitigação de exclusividade: `Biblioteca` processa um arquivo por vez (`:823-839`) e `MotoresLocais` alterna Whisper/Qwen dentro da instância. A instância preserva o contexto apenas enquanto vive; essa fila não o conserva entre operações ou arquivos. O processamento de áudio em blocos e o VAD limitado não removem a carga do modelo; a pressão de memória pode apenas tornar a recarga mais frequente. O número de `1,006931 s` é um mecanismo isolado, não uma promessa de que cada arquivo acrescenta exatamente esse valor.

**Correção sugerida.** Compartilhar um gerente de motores por `Biblioteca` (com uma única fila/invariante) ou manter uma política explícita de residência entre arquivos, respeitando o limite de RAM e a descarga sob pressão. Medir antes/depois com o mesmo áudio de teste e registrar carga, descarga, pico de uso de memória e RTF.

### A3-002 — Cada `salvar` reescreve o grafo inteiro e o pipeline salva duas vezes
- **Severidade:** ALTO
- **Confiança:** PROVÁVEL para o custo integrado de SwiftData; os mecanismos de regex e JSON foram medidos, mas não houve uma biblioteca persistente real com a carga do usuário.
- **Locais:** `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:40-120, 218-239, 413-510`; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:95-100, 160-190`; `Papagaio/ViewModels/Biblioteca.swift:296-298, 121-125`.

**Evidência.** `SwiftDataRepository.salvar` apaga todos os `trechos`, `insights` e `notas` existentes (`:66-75`), recria cada trecho e codifica seu `[Palavra]` em JSON (`:77-103`), e chama `modelContext.save()` (`:120`). Mesmo uma atualização que muda um campo repete o trabalho de todo o grafo. `PipelineDeArquivo` salva a transcrição em `:162` e o resumo em `:189`; a segunda gravação é intencional para não perder a transcrição se o Qwen falhar, mas repete a reescrita.

**Medição própria.** No experimento Release com `ModelContainer` em memória, 20 arquivos × 80 trechos × 10 palavras = 16.000 palavras: salvamento inicial mediano `0,006869 s/arquivo` (n=20), atualização dos 20 registros mediano `0,222033 s` (n=3), `listar` com prefetch + `paraDominio` mediano `0,072617 s` (n=5), e busca sem correspondência mediano `0,003516 s` (n=5). A validação confirmou 20 arquivos e 16.000 palavras em cada listagem (`swiftdata-experiment.log:8-20`). Esses números são de memória e não são SLA de disco.

O preflight separado confirmou os dois custos de mapeamento: 100.000 palavras com regex + trim levaram `104,167 ms` (`1,042 ns/palavra`); com gate `contains("[")`, `246 ns/palavra`, uma diferença medida de `4,2x` (`preflight.log:1-6`). O decode de 15.000 palavras de 1 h de fala levou `26,477 ms`; as projeções para 200 e 500 conversas foram `5,30 s` e `13,24 s` (`preflight.log:8-12`). As projeções não foram medidas com 200/500 registros.

**Refutação dos mitigantes.** `@ModelActor` serializa o `ModelContext` e `relationshipKeyPathsForPrefetching` evita N+1 de fetch; isso protege consistência, não elimina a serialização/decodificação do grafo. As duas gravações preservam uma transcrição cara quando o resumo falha. O custo depende de palavras, notas, insights e de o registro ser novo ou existente.

**Correção sugerida.** Persistir a transcrição como uma entidade imutável/separada ou fazer diff de filhos; guardar o JSON já normalizado quando a cura for necessária; instrumentar `save` por fase e manter a segunda gravação apenas quando o resumo realmente mudou.

### A3-003 — O caminho AEC materializa microfone e sistema inteiros e grava um PCM intermediário
- **Severidade:** ALTO
- **Confiança:** CONFIRMADO para o ramo, a alocação declarada e o custo sintético do AEC; RSS real de uma reunião longa não foi medido.
- **Locais:** `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:222-260, 398-418`; `PapagaioCore/Sources/PapagaioCore/CanceladorDeEco.swift:105-121`; `PapagaioCore/Sources/PapagaioCore/Transcricao/DecodificadorDeAudio.swift:37-63`.

**Evidência.** Quando há dois canais e `usavaFones == false`, `aplicarAEC` chama `DecodificadorDeAudio.amostras` duas vezes (`:406-407`), cada método devolvendo `[Float]` para o arquivo inteiro; só depois executa o cancelador (`:409-412`) e serializa o resultado em `microfone_aec.pcm` (`:415-418`). O caminho normal de transcrição usa `processarEmBlocos` com blocos de 60 s (`DecodificadorDeAudio.swift:44-63`), mas esse processamento em blocos não é usado para os dois arrays do AEC.

**Números.** O baseline Release próprio mediu `aec.processarBlocos` em mediana `0,573178 s` para 5 s sintéticos (n=3; `bench-micro.log:64-76`). Para 1 h de PCM Float32 mono a 16 kHz, um canal ocupa `16.000 × 3.600 × 4 = 230.400.000 B` (cerca de `219,7 MiB`). Os dois arrays de entrada, o array de saída e a conversão para `Data` já pedem cerca de `921,6 MB` (aproximadamente `879 MiB`) antes de filtros, buffers do decoder e alocações transitórias; isso é aritmética de buffers, não uma medição de RSS. O arquivo intermediário também recebe cerca de `230,4 MB` por hora.

**Refutação dos mitigantes.** O AEC é condicional ao fluxo de dois canais; o importador, o VAD e o `WhisperEngine` usam processamento em blocos. O benchmark do VAD (`0,063874 s` para 30 s) não elimina a materialização do AEC. O arquivo temporário é criado dentro da pasta da gravação, portanto a escrita existe mesmo que a transcrição posterior use blocos.

**Correção sugerida.** Fazer AEC em blocos com janela limitada, ou limitar o AEC a uma janela e processar o restante em blocos; medir o uso de memória com um áudio de teste longo. Avaliar também a limpeza do `.pcm` intermediário após a etapa.

### A3-004 — CloudKit refaz a zona inteira e a “paginação” é fatiamento em memória
- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL
- **Locais:** `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:178-197, 212-240, 242-271, 375-393`; `Papagaio/ViewModels/Biblioteca.swift:1138-1174`; pesquisa `audit/01-pesquisa/cloudkit.md:93-117, 176-205`.

**Evidência.** `registrosDaZona` cria `CKFetchRecordZoneChangesOperation`, define `fetchAllChanges = true` e não mantém `CKServerChangeToken` (`:246-270`). A pesquisa oficial registrada em `audit/01-pesquisa/cloudkit.md:93-117` diz que token nulo refaz a carga completa da zona. Só depois os `[CKRecord]` são convertidos em `[Data]` e a “página” de 200 é criada por `Array(registros[indice..<limite])` (`:223-240`); não é cursor do servidor. `baixarComVersoes` ainda percorre todas as páginas e decodifica cada conteúdo (`:382-391`).

**Refutação dos mitigantes.** A API é assíncrona, a fila é serial e cada requisição fica abaixo dos limites de lote; isso evita concorrência, mas não reduz o número de registros/bytes. Não houve chamada real ao CloudKit nesta auditoria, então não se atribui latência, cota ou custo de rede a um número. O caminho de mídia deliberadamente não entra no conteúdo textual (`Sincronizador...:331-335`).

**Correção sugerida.** Persistir token por equipe/banco, usar assinatura/push como gatilho e paginação real; manter um cache local da zona. Medir em ambiente de teste controlado com 1, 50, 200 e 1000 registros, separando download, decodificação e gravação.

### A3-005 — O snapshot de reuniões do Calendar é reescrito repetidamente ao aplicar eventos
- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO para o mecanismo de Codable/UserDefaults; não houve conta Google real.
- **Locais:** `Papagaio/Integracao/GoogleCalendarViewModel.swift:260-296`; `Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:31-83`.

**Evidência.** `aplicar` chama `registrarSeNecessario` para cada evento (`:273-291`); quando o evento já foi convertido, chama também `definir` (`:284-285`). `registrarSeNecessario` e `definir` chamam `todos()` (decodificação de todo o dicionário) e `salvar` (codificação de todo o dicionário + `UserDefaults.set`) (`EstadoDasReunioesCalendar.swift:42-64, 70-83`). `reunioesIgnoradas` ainda faz nova decodificação e ordenação (`:35-40`).

**Medição de mecanismo.** O experimento sintético com metadados de reunião, n=7 após uma execução de aquecimento, medianou: 10 eventos `0,000268667 s`; 100 `0,001592500 s`; 500 `0,006851750 s`; 1.000 `0,017338291 s` por reescrita (`mechanisms.log:1-4`). O conteúdo é menor que uma transcrição real e não inclui latência do Google; `UserDefaults.set` foi medido como chamada lógica, não como gravação efetiva no disco.

**Refutação dos mitigantes.** O estado é composto de metadados sem áudio, a API pagina respostas de 250 eventos e a consulta periódica é de 15 minutos (`GoogleCalendarViewModel.swift:152-161`); portanto não é uma escrita por tecla. Ainda assim, uma sincronização de N eventos executa pelo menos N snapshots completos, e pode executar mais de N quando há eventos convertidos.

**Correção sugerida.** Só persistir quando o registro/estado realmente mudou, agrupar as alterações da página e manter um índice separado para ignorados/convertidos. Instrumentar número de escritas e tamanho do snapshot.

### A3-006 — Busca e listas derivadas da biblioteca são recalculadas no corpo da visualização
- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO para o mecanismo e o corpus sintético; não é medição de corpus real.
- **Locais:** `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:338-365, 377-432, 1061-1124, 1192-1204`; `Papagaio/Suporte/BuscaSemAcento.swift:3-12`; `Papagaio/Funcionalidades/Tarefas/TarefasView.swift:48-175, 191-206`; `Papagaio/Funcionalidades/Midias/MidiasView.swift:30-123, 126-145, 200-253`.

**Evidência.** `arquivosFiltrados` ordena a biblioteca e filtra por pasta/favorito/busca a cada acesso (`:338-365`); `conversaCasaTermo` percorre título, metadados, resumo, todos os trechos e notas (`:377-432`). O corpo da grade o consulta no `ForEach` e novamente no estado vazio (`:1106-1116`). Não há debounce nem cache de resultado. `TarefasView` recompõe `tarefasPorConversa`/`tarefasVisiveis` e cada coluna filtra a lista inteira; `MidiasView` chama `MidiasDaConversa.carregar` por conversa dentro de uma propriedade computada repetida.

**Medição própria.** No preflight, 100 arquivos × 300 trechos (cerca de 5,31 milhões de caracteres) reproduziram o núcleo de ordenação + busca de título, resumo e trechos: sem correspondência, `0,512702 s`; com correspondência no fim, `0,006624 s`; e apenas a ordenação, `0,000006 s` (`preflight.log:14-18`). O experimento não incluiu os campos auxiliares de pasta, metadados, datas e notas que a busca do aplicativo também consulta. A projeção para duas avaliações do núcleo medido foi `≈1,0254 s` por tecla; é aritmética, não p95 nem tempo do aplicativo.

**Refutação dos mitigantes.** `LazyVGrid`/`LazyVStack` reduzem a construção de cards fora da tela, e a busca no SwiftData é separada; a tela principal, porém, já mantém `arquivo.trechos` em memória e paga a varredura local. Em um corpus pequeno o custo pode ser abaixo do limiar perceptível.

**Correção sugerida.** Manter cache da lista derivada por `(biblioteca, consulta, filtros, geração de invalidação)`, colocar a busca em uma tarefa com debounce e mover a normalização para um índice de texto. Medir com 10/100/500 conversas e teclas realisticamente digitadas.

### A3-007 — Detalhe do player reagrupa falas e decodifica o mapa de falantes por linha/tick
- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO para os mecanismos medidos; não houve Instruments no aplicativo.
- **Locais:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:161-233, 1404-1495, 1554-1600`; `PapagaioCore/Sources/PapagaioCore/Diarizacao/FalasDaConversa.swift:64-161`; `Papagaio/Persistencia/FalantePreservadoParaTrecho.swift:20-42`; `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:21-26, 127-131, 229-233`.

**Evidência.** `falas` chama `FalasDaConversa.agrupar` (`:164-167`), que percorre todas as palavras e, para cada fala fechada, procura cada ID no array de trechos para decidir o canal (`FalasDaConversa.swift:116-161`). A lista de falas chama `FalantePreservadoParaTrecho.obter` por linha (`:1467-1473`); a lista de trechos faz o mesmo por linha (`:1558-1561`). Cada chamada carrega e decodifica o mapa inteiro de UserDefaults (`FalantePreservado...:20-34`). O player publica `tempo` a 10 Hz (0,1 s), portanto essas leituras podem repetir a cada tick.

**Medição de mecanismo.** O preflight mediu `0,001639 s` para decodificar um mapa de 3.000 trechos (146.251 B) e `0,012468 s` para varrer 15.000 palavras sem correspondência (`preflight.log:19-23`). A primeira medida exclui a leitura do `UserDefaults` e reflete apenas o `JSONDecoder`; no cenário de 30 linhas visíveis fazendo uma consulta de fallback por linha a 10 Hz, a mesma aritmética dá 300 decodificações/s e `≈49,2%` de um núcleo. Não é ocupação do aplicativo nem p95.

**Refutação dos mitigantes.** `LazyVStack` limita a construção de linhas, a navegação de trecho é binária e o cursor de palavra é incremental (`ReprodutorDeArquivo.swift:64-70, 235-279`). No ramo de falas, o mapa só é consultado no fallback quando não há falante acústico; no ramo de trechos, `obter` é chamado para cada linha. Em arquivos legados, muitas linhas passam pelo fallback.

**Correção sugerida.** Cachear o mapa por conversa com invalidação explícita e pré-computar falas/IDs de linha quando `arquivo` muda; medir o custo de uma recomposição real durante reprodução.

### A3-008 — Há cópias síncronas no `@MainActor` e a prévia de imagem carrega o arquivo sem cache
- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL para o impacto no aplicativo; o mecanismo de imagem foi medido fora da interface.
- **Locais:** `Papagaio/ViewModels/MidiasDaConversaViewModel.swift:25-27, 88-107`; `Papagaio/ViewModels/Biblioteca.swift:19-20, 696-707, 1352-1359`; `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1423-1452`; `Papagaio/Funcionalidades/Detalhe/Midia/PreviaDoAnexoDeMidia.swift:53-82`; `Papagaio/Persistencia/MidiasDaConversa.swift:90-103`.

**Evidência.** `adicionar`, `duplicar` e a importação de áudio do Calendar são métodos de tipos `@MainActor` e chamam `FileManager.copyItem` sem `Task.detached`. `CartaoDeConversa.baixar` também copia o pacote no fluxo do botão. Para anexos do tipo Imagem, `PreviaDoAnexoDeMidia` chama `NSImage(contentsOf:)` antes do `await` e não consulta `NSCache`; apenas vídeos/PDF usam `QLThumbnailGenerator`. Os caches `NSCache` existentes em capas/avatares não cobrem esse fluxo.

**Medição de mecanismo.** `NSImage(contentsOf:)` de uma PNG sintética 2048×2048 teve mediana `0,000186666 s` (n=10; `mechanisms.log:8-9`). A imagem tinha 79.753 B porque o padrão é muito compressível; o número é apenas uma chamada de carregamento, não uma foto real nem p95. Não foi medido `copyItem` porque o custo depende do volume e de APFS clone.

**Refutação dos mitigantes.** A exportação de pasta e a cópia “Salvar em…” de `OpcoesDeCompartilhamento` usam `Task.detached` (`BibliotecaHomeView.swift:560-614`; `OpcoesDeCompartilhamento.swift:31-58`). Há `NSCache` para capas e avatares. Esses mitigantes não alcançam `MidiasDaConversaViewModel.adicionar`, duplicação, Calendar ou a prévia direta.

**Correção sugerida.** Mover cópia/empacotamento para um ator/fila de I/O, mostrar progresso e usar miniatura/decodificação em segundo plano com cache por URL+tamanho. Medir com um anexo real de tamanho conhecido e a interface em Instruments.

### A3-009 — O callback de áudio do System Tap faz duas varreduras por amostra
- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL
- **Locais:** `PapagaioCore/Sources/PapagaioCore/Captura/SystemAudioTap.swift:147-159, 451-471`; `PapagaioCore/Sources/PapagaioCore/Captura/NivelAudio.swift:15-25`.

**Evidência.** `SystemTapCallbackState.consume` entrega o buffer ao writer e, se o formato for Float32, chama `NivelAudio.registrar` (uma varredura RMS) e depois executa outro `for index in 0..<count` para calcular `peak` (`SystemAudioTap.swift:451-471`). O callback é o IOProc de tempo real. A 48.000 amostras/s, isso representa pelo menos 96.000 visitas de amostra por segundo para um canal, sem contar a escrita; a taxa real depende do formato do tap.

**Refutação dos mitigantes.** O writer usa `ExtAudioFileWriteAsync` e não cria `AVAudioPCMBuffer` no callback (`SystemAudioTap.swift:147-159, 350-353`); `NivelAudio` publica por `Atomic`. A medição de pico é usada para decidir se o canal captou som no encerramento, então não é código puramente ocioso. Não houve captura real nem medição de queda de áudio.

**Correção sugerida.** Calcular RMS e pico no mesmo passe, ou acumular pico por vetor/vDSP, e medir a duração do callback com Instruments antes/depois.

### A3-010 — O prompt de entidades enumera todos os contatos para cada arquivo processado
- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL
- **Locais:** `Papagaio/Suporte/PromptDeEntidades.swift:17-35, 38-69`; `Papagaio/ViewModels/Biblioteca.swift:887-898`.

**Evidência.** `construir` é chamado no início de cada `executarProcessamento` (`:888`). `termosDosContatos` executa `enumerateContacts` sobre a base inteira (`:53-69`), acumula nomes e organizações e só depois reduz para 40 termos (`:28-35`). O limite de 40 limita o prompt, não o número de contatos lidos. A agenda é limitada a uma janela de 15 minutos em torno do áudio, mas a lista de contatos não tem limite.

**Refutação dos mitigantes.** As duas buscas são combinadas com `async let` (`:22-27`), permissões negadas retornam vazio e o custo ocorre somente no processamento, não a cada tecla. Não foi autorizado acesso a Contacts nesta auditoria; portanto não há número de segundos ou afirmação sobre a linha de execução principal.

**Correção sugerida.** Cachear um índice de termos por alteração/contato, limitar a consulta aos participantes já conhecidos ou construir o prompt uma vez por equipe/arquivo. Medir com uma lista local sintética de 100/1.000/10.000 contatos, sem acessar a agenda real.

### A3-011 — Cancelamento do OAuth Google deixa uma espera permanente
- **Severidade:** ALTO
- **Confiança:** CONFIRMADO (A2-001)
- **Locais:** `Papagaio/Integracao/SessaoOAuthGoogle.swift:160-185, 416-447, 491-502`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:60-73`; evidência primária `audit/02-achados/A2.md:36-80`.

**Evidência.** O caminho de cancelamento chama `shutdown()` no socket de escuta; no macOS desta máquina o experimento mínimo retornou `errno=57` e `accept()` não despertou em 2 s (`A2.md:59-68`). O task group aguarda o filho indefinidamente, `GoogleCalendarViewModel.conectar` aguarda `tarefa.value`, e `tarefaDeConexao` permanece não nula; tentativas seguintes são bloqueadas pelo guard.

**Refutação dos mitigantes.** O caminho que já tem um cliente conectado pode passar, e o OAuth bem-sucedido não foi medido; a falha é especificamente no cancelamento/timeout sem conexão. A baseline da auditoria observou os dois testes pendurados por até 300 s (`audit/00-mapa.md:396-403`).

**Correção sugerida.** Despertar `accept` com uma conexão local ou substituir o accept bloqueante por uma primitiva cancelável, como indicado em A2-001. Até lá, não usar o timeout da suíte como prova de que a interface recuperou.

### A3-012 — Importação de N reuniões do Granola é sequencial e cada item pode custar duas chamadas MCP
- **Severidade:** BAIXO
- **Confiança:** PROVÁVEL
- **Locais:** `Papagaio/Integracao/GranolaViewModel.swift:171-203`; `Papagaio/Integracao/FonteGranola.swift:40-85`; `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:140-197, 233-274`.

**Evidência.** O loop importa `ids` serialmente (`:180-193`). Para cada id, `FonteGranola.obterReuniao` faz `get_meetings` e, quando `incluirTranscricao=true`, `get_meeting_transcript` (`:48-85`). `ClienteMCP.chamar` passa por `enviar` e obtém token em cada requisição (`:141-197, 233-274`). Portanto a seleção de N reuniões pode produzir até 2N chamadas de ferramenta, mais um salvamento local por reunião aceita; esse é um limite estrutural, não uma medição de rede.

**Refutação dos mitigantes.** A sequência evita mutação concorrente e o código verifica cancelamento entre itens; o plano sem transcrição reduz para uma chamada por reunião. Não foi chamado Granola real, então não se atribui latência, taxa de erro ou custo de token.

**Correção sugerida.** Respeitar um limite de concorrência pequeno, pedir detalhes em lotes quando a ferramenta permitir e mostrar progresso por item; medir com um servidor MCP local e N=1/5/20.

### A3-013 — A outbox local reescreve todo o JSON em cada alteração persistida
- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO para o mecanismo de arquivo/JSON; a fila real com `Arquivo` completo não foi executada.
- **Locais:** `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:55-77, 103-171, 204-220`.

**Evidência.** `carregar` mantém um cache em memória (`:204-209`), portanto o custo dominante não é a releitura: `salvar` codifica a lista inteira e grava `fila-pendente.json` com `.atomic` (`:211-219`). `processar` chama `salvar` após cada operação concluída ou que falhou (`:148-160`). `agendarEnvio` também salva a lista inteira (`:60-76`).

**Medição de mecanismo.** O experimento de forma Codable com n=5 após uma execução de aquecimento medianou `0,000561459 s` para 10 operações, `0,002722625 s` para 100 e `0,014580958 s` para 500 (`mechanisms.log:5-7`). O conteúdo sintético é menor que um `Arquivo` com transcrição; estes números não são vazão do CloudKit.

**Refutação dos mitigantes.** A fila é serial e o cache evita decodificação por item; `.atomic` protege a durabilidade e não deve ser removido. Filas pequenas e poucas retentativas limitam o custo. O achado é a multiplicação de codificações e gravações, não uma suposta corrida.

**Correção sugerida.** Manter um log somente de acréscimo ou separar o conteúdo grande do índice, agrupar remoções/atualizações e fazer compactação apenas quando necessário; medir bytes escritos por operação.

---

## Baseline próprio

### Condições e método

- **Máquina:** Apple M5, 10 núcleos ativos, 24 GiB; macOS 27.0; Swift 6.4/Xcode-beta 27.0. O hardware e a pilha tecnológica são os medidos no mapa, não um SLA.
- **Build:** `swift build -c release` do `PapagaioCore`; o comando do harness levou `50,07 s` (`bench-micro.log:6-13`). Não houve build Release do aplicativo.
- **Micro Release:** `./Scripts/bench-papagaio.sh --so-micro --iteracoes 5 --audio PapagaioCore/Tests/PapagaioCoreTests/Fixtures/fala_ola_mundo.wav --modelos "$HOME/Library/Application Support/Papagaio/Models" --saida /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a3/micro.json`. O harness descarta uma execução de aquecimento; AEC/VAD usam n=3 e os demais n=5, com exceção de navegação n=50. O JSON não rastreado `PapagaioCore/Benchmarks/baseline.json` não foi usado como medição própria.
- **Metal:** confirmado pelo binário (`bench-micro.log:24-35, 57-60`).
- **Preflight:** `swiftc -O audit/04-medicoes/A3-preflight.swift -o /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a3/a3-preflight && /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a3/a3-preflight`; os blocos usam uma execução de aquecimento e retornam a mediana; log: `preflight.log`.
- **Mecanismos de persistência:** `swiftc -O` do experimento temporário `a3-mechanisms.swift`; Calendar 10/100/500/1000, outbox 10/100/500, imagem 2048×2048; `mechanisms.log`.
- **SwiftData:** executável Release temporário com dependência por caminho para o core local, container em memória, 20×80×10 palavras; `swiftdata-experiment.log`.
- **Carga de modelos:** o mesmo executável Release usou Whisper n=3, sem aquecimento descartado, medindo carga+descarga (`experimentos.log:1790-1793`), e Qwen n=3, medindo um ciclo com resumo curto (`qwen-experiment.log:2393-2396`). A primeira amostra de Whisper inclui o carregamento frio; o ciclo Qwen não é carga isolada.
- **Whisper local:** uma única execução, sem repetição nem mediana, incluindo carga e transcrição do áudio de teste de 4,3 s (`whisper-local.log:69-75`).
- **OAuth:** somente experimento local de sockets já executado por A2; nenhuma requisição ao Google.

**Repetições e aquecimento dos experimentos.** O preflight usou uma execução de aquecimento e as seguintes amostras: cura de regex n=5; decode de palavras n=10; busca da biblioteca, ocorrências e dossiê n=7; leituras de pastas n=7; mapa de falantes n=200; metadados n=10.000; ordenação de 2.000 arquivos n=50. O experimento de mecanismos usou uma execução de aquecimento, Calendar n=7, outbox n=5 e imagem n=10. O experimento SwiftData não descartou aquecimento: inserção inicial n=20, atualização n=3, listagem n=5 e busca n=5. O experimento de modelos não descartou aquecimento: Whisper n=3 e Qwen n=3. Todas as referências a “mediana” neste relatório são medianas das amostras declaradas; a execução local de Whisper é uma observação única.

### 11 resultados micro (medianas, segundos)

| Caso | Mediana | n | Entrada |
|---|---:|---:|---|
| `segmentacao.agrupar` | 0,000124 | 5 | 500 segmentos |
| `segmentacao.mesclarCanais` | 0,003084 | 5 | 250 + 250 segmentos |
| `alinhamento.atribuir` | 0,004346 | 5 | 200 trechos × 400 segmentos |
| `filtroRepeticao.remover` | 0,005239 | 5 | 300 trechos |
| `falas.agrupar` | 0,000390 | 5 | 200 trechos |
| `navegacao.indiceAtivo` | 0,000135 | 50 | 200 trechos, 10 mil buscas |
| `exportacao.markdown` | 0,000202 | 5 | 200 trechos |
| `aec.processarBlocos` | 0,573178 | 3 | 5 s sintéticos |
| `vad.janelasDeFala` | 0,063874 | 3 | 30 s sintéticos; Silero disponível |
| `vad.silero.lote` | 0,039318 | 3 | 600 quadros de 512 amostras |
| `idioma.detectar` | 0,003346 | 5 | ~60 mil caracteres |

Fonte primária: `bench-micro.log:64-76`; JSON: `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a3/micro.json`. O harness **não coleta p95**; não há p95 nesta auditoria. AEC é custo de blocos sintéticos, não RTF de uma reunião real. Os números do mapa `audit/00-mapa.md` não foram importados como baseline próprio.

## Cobertura

- **App:** 171/171 arquivos `.swift`, 34.232 linhas, lidos integralmente.
- **Core:** 61/61 arquivos `.swift` sob `PapagaioCore/Sources/`, 11.370 linhas, lidos integralmente (incluindo o CLI de avaliação).
- **Total de produção:** 232/232 arquivos, 45.602 linhas. A numeração auxiliar em `app-sources-numbered.txt` inclui cabeçalhos de arquivos e não substitui essa contagem.
- Não foram alterados produção, testes ou benchmarks por esta auditoria. `audit/00-mapa.md` e `audit/02-achados/A2.md` foram usados como contexto/evidência; o único arquivo de repositório escrito por este agente é este relatório.

## Limitações e cautelas

1. Não há build Release nem Instruments do aplicativo; o build do mapa é Debug e não foi tratado como desempenho de produção.
2. CloudKit, OAuth Google real, Granola/MCP real e permissões de Contacts/Google não foram exercitados; não houve instalação de dependências, push ou configuração de serviço. Os achados desses caminhos são estáticos/`PROVÁVEL`, com exceção do mecanismo OAuth reproduzido por A2.
3. Corpus, agenda, contatos, fila e imagens dos experimentos são sintéticos. Eles não representam automaticamente a biblioteca do usuário.
4. AEC não foi medido com uma hora de áudio/RSS; os bytes por canal são cálculo de buffer, e o número de 5 s é micro sintético.
5. O ciclo Qwen inclui uma geração de resumo curto; o experimento não separou a carga do modelo da inferência, portanto não é carga isolada nem RTF de reunião. A API pública de preaquecimento não foi usada nessa execução.
6. Não há p95, trace de frame principal, Instruments Allocations, TSan ou telemetria de serviço. Os números do harness micro têm aquecimento e n declarados; extrapolações estão marcadas como tais.
7. O working tree já estava sujo com alterações e artefatos paralelos; tempos locais foram afetados por build/cache/carga concorrente e não são SLA.

## Contagens finais

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 0 |
| ALTO | 4 |
| MÉDIO | 8 |
| BAIXO | 1 |
| **Total** | **13** |

| Confiança | Quantidade |
|---|---:|
| CONFIRMADO | 7 |
| PROVÁVEL | 6 |
| HIPÓTESE | 0 |
| **Total** | **13** |

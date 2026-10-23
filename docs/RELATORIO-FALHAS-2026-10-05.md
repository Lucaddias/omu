# Relatório geral de falhas — Ōmu (Papagaio)

- **Data da varredura:** 5 de outubro de 2026
- **Base analisada:** commit `1899273` (`chore: versão 1.3.3`), branch `claude/code-scan-failures-report-5c7090`
- **Escopo:** `PapagaioCore/` (biblioteca + CLI `papagaio-eval`), `Papagaio/` (app), `PapagaioTests/`, `Scripts/`, CI
- **Método:** build + testes automatizados, busca por padrões de risco e leitura arquivo a arquivo

> Este documento **registra** as falhas e propõe a correção de cada uma. Nenhum
> código de produção foi alterado nesta varredura.

## 1. Resultado das verificações automáticas

| Verificação | Resultado |
| --- | --- |
| `xcodebuild test` do app (`Loro`, `PAPAGAIO_TEST_MODE=1`) | **Passou** — 107 testes, 0 falhas |
| `Scripts/testa-papagaio-core.sh` (`swift test`) | **Passou** — 220 testes, 0 falhas, **4 pulados** (dependem dos pesos Whisper/Qwen) |
| `python3 -m unittest Scripts/tests/test_scripts.py` | **Falhou** — 3 de 8 testes (ver TS-03); a CI não executa esta suíte |
| `bash -n` nos 14 scripts de shell e `py_compile` nos 9 de Python | Sem erro de sintaxe |
| Erros de compilação | Nenhum |
| Avisos do compilador no código do projeto | 6 (ver AV-01 a AV-03) |

As suítes Swift passam, então quase todas as falhas abaixo são de **lógica,
robustez, segurança e desempenho que os testes atuais não cobrem**. A única
falha de teste encontrada é a da suíte de scripts (TS-03).

### Avisos do compilador

| ID | Onde | Aviso | Como resolver |
| --- | --- | --- | --- |
| AV-01 | `PapagaioTests/` (4 ocorrências em `#expect`) | Chamada a membro `@MainActor` (`rotuloDoCanal`, `identidadeAcessivel`, `emailSugeridoDaEquipe`) em contexto não isolado (dentro da expansão do `#expect`). Hoje é só aviso; tende a virar erro em versões futuras do compilador. | Marcar os testes (ou a suíte) com `@MainActor`, ou tornar esses helpers puros `nonisolated`. |
| AV-02 | `PapagaioCore/Sources/papagaio-eval/main.swift:77` | Resultado de `withUnsafeMutablePointer` não usado. | Atribuir a `_ =` ou usar o retorno para checar erro do `bind`/`getsockname`. |
| AV-03 | `PapagaioCore/Sources/papagaio-eval/Bench.swift:303` | `String(cString:)` com array está obsoleto. | `String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)`. |

## 2. Escala de severidade

| Nível | Significado |
| --- | --- |
| **Alta** | Perda de dados do usuário, falha de função central ou risco de segurança explorável |
| **Média** | Resultado errado ou degradado em cenário plausível; desempenho que o usuário percebe |
| **Baixa** | Caso de borda, robustez, manutenção ou mensagem enganosa |

## 3. Falhas no `PapagaioCore`

Caminhos relativos a `PapagaioCore/Sources/PapagaioCore/`, salvo indicação.

### 3.1 Captura de áudio

#### C-01 · Alta · Gravação interrompida pelo sistema é apagada ao parar
- **Onde:** `Captura/SessaoGravacao.swift:217-261` e `:370-378`
- **Falha:** `parar()` calcula `duracao = recorder?.currentTime ?? tempoDecorrido`. Quando o `AVAudioRecorder` para sozinho (dispositivo de entrada removido, disco cheio, interrupção), `currentTime` volta a `0`; o timer também sobrescreve `tempoDecorrido` com `0`. O `delegate` só acrescenta um aviso. Resultado: `duracao < duracaoMinima` e **a pasta inteira da gravação é removida**, mesmo com minutos de áudio já gravados. Conferido na iteração 11 com um `AVAudioRecorder` no mesmo formato: gravando, `currentTime` = 2,03 s; pausado, 2,01 s (parar a partir da pausa preserva a duração); depois de `stop()`, 0,00 — o valor que `parar()` lê quando o sistema já encerrou o gravador.
- **Como resolver:** guardar o maior `currentTime` observado (`tempoDecorrido = max(tempoDecorrido, recorder.currentTime)`), marcar `interrompida = true` no delegate e, em `parar()`, usar esse valor; decidir o descarte pela duração real do arquivo (`AVAudioFile.length`/tamanho) e nunca apagar quando `microfone.wav` tem conteúdo. Implementar também `audioRecorderEncodeErrorDidOccur`.

#### C-02 · Baixa (latente) · Detecção de "fones de ouvido" classifica errado
- **Onde:** `Captura/SessaoGravacao.swift:299-339`
- **Falha:** qualquer saída USB (caixa de som, monitor, dock) conta como fone; fone com fio (P2, transporte *built-in*) nunca conta. Como `usavaFones` decide se o cancelamento de eco roda, o AEC seria pulado quando há eco e aplicado quando não há. **Latente:** o app ainda não usa esse valor (ver P-07).
- **Como resolver:** para transporte *built-in*, ler `kAudioDevicePropertyDataSource` (`'hdpn'` = fones); para USB, não presumir — usar `kAudioDevicePropertyTransportType` só para Bluetooth e tratar o resto como "desconhecido" (`nil`), deixando o pipeline decidir por correlação entre os canais.

#### C-03 · Média · Tap do sistema fica preso ao dispositivo de saída do início
- **Onde:** `Captura/SystemAudioTap.swift:69-173`
- **Falha:** o tap é criado com `deviceUID`/`stream` da saída padrão no momento do `start`. Se a pessoa conecta AirPods ou troca a saída durante a reunião, o canal do interlocutor passa a gravar silêncio até o fim, sem aviso.
- **Como resolver:** registrar `AudioObjectAddPropertyListenerBlock` para `kAudioHardwarePropertyDefaultOutputDevice` e recriar tap + aggregate device na troca (mantendo o mesmo `SystemTrackWriter`, com conversão se o formato mudar), ou ao menos registrar um aviso visível.

#### C-04 · Baixa · `stop()` depende do ARC para despejar o arquivo do sistema
- **Onde:** `Captura/SystemAudioTap.swift:191-210`, `:395-413`
- **Falha:** a fila do `ExtAudioFileWriteAsync` só é garantidamente despejada no `ExtAudioFileDispose`, que hoje acontece no `deinit` do writer. `SessaoGravacao.parar()` lê o tamanho do arquivo logo depois (`descartarSistemaSeVazio`, limite de 16 KB) e o pipeline pode abri-lo em seguida; se o bloco do IOProc ainda segurar a referência, o arquivo é lido incompleto ou apagado como "vazio".
- **Como resolver:** chamar `writer?.finalizar()` explicitamente em `stop()` depois de `AudioDeviceStop`/`DestroyIOProcID`.

#### C-05 · Baixa · O tap assume um único buffer intercalado
- **Onde:** `Captura/SystemAudioTap.swift:151-159`, `:399-403`
- **Falha:** só `buffers.first` é gravado e o retorno de `ExtAudioFileWriteAsync` é ignorado. Num formato não intercalado (um buffer por canal) a escrita falha em silêncio ou perde canais.
- **Como resolver:** validar `kAudioFormatFlagIsNonInterleaved` em `tapFormat()` e passar a `AudioBufferList` original; contar erros de escrita nas estatísticas.

#### C-06 · Baixa · Aviso de "tap em silêncio" em reunião presencial
- **Onde:** `Captura/SessaoGravacao.swift:232-236`
- **Falha:** quando nada tocou no Mac (reunião presencial), o pico fica abaixo de `0,0001` e o aviso diz que "a rota de saída não está entregando sinal ao tap" — um falso diagnóstico de defeito.
- **Como resolver:** tratar como caso normal ("nenhum áudio do sistema durante a gravação") e reservar a mensagem de rota para quando há callbacks zero.

#### C-07 · Baixa · Importação que falha deixa pasta órfã
- **Onde:** `Importacao/ImportadorAudio.swift:68-70`
- **Falha:** `criarArquivoImportado` cria a pasta; se `copyItem` lança (disco cheio, permissão), a pasta vazia fica em `Gravacoes/`.
- **Como resolver:** `do { try copyItem } catch { try? removeItem(pasta); throw error }`.

#### C-08 · Baixa (latente) · Renomear a pasta pelo título tem casos de borda
- **Onde:** `Captura/Armazenamento.swift:132-171`
- **Falha:** (a) a comparação `relativoCandidato == relativoAtual` distingue maiúsculas, mas o APFS padrão não: mudar só a caixa do título vira "Título 2"; (b) título começando com `.` cria pasta oculta; (c) caracteres de controle/nova linha passam. Latente: a varredura da iteração 13 mostrou que `renomearParaTitulo` não é chamada por ninguém.
- **Como resolver:** comparar com `caseInsensitiveCompare`/`URL.standardizedFileURL`, remover `.` inicial e caracteres de controle em `nomeDePastaSeguro`.

#### C-09 · Média · `resolver(relativo:)` aceita travessia de diretório
- **Onde:** `Captura/Armazenamento.swift:63-65`
- **Falha:** só `removerGravacao` valida o formato `Gravacoes/<nome>`. Leitura, renomeação, exportação e pipeline resolvem qualquer string persistida, inclusive com `..`. Um `pastaRelativa` corrompido (ou vindo de outra instalação) aponta para fora do container lógico.
- **Como resolver:** centralizar a validação num `func resolverSeguro(relativo:) throws -> URL` (rejeita componentes vazios, `.`/`..` e caminhos absolutos; confere que o resultado tem `raiz` como prefixo após `standardizedFileURL`) e usá-lo em todos os chamadores.

### 3.2 Transcrição e VAD

#### T-01 · Média · Portão de energia veta fala baixa
- **Onde:** `Transcricao/DetectorDeAtividadeDeVoz.swift:166-196` (e `:369-394`)
- **Falha:** o quadro só é fala se `RMS ≥ 0,008` **e** o Silero disser que é fala. Voz distante ou baixa (≈ −45 dBFS) é descartada mesmo com probabilidade alta do modelo — o trecho some da transcrição.
- **Como resolver:** baixar o limiar para um piso de ruído digital (≈ 0,001) ou torná-lo adaptativo (percentil do nível do arquivo); deixar a decisão final com o Silero.

#### T-02 · Média · Idioma detectado de novo a cada janela de 60 s
- **Onde:** `WhisperRuntime/ContextoWhisper.swift:216-221`; `Transcricao/WhisperEngine.swift:85-92`
- **Falha:** com `idioma == nil` cada chamada a `whisper_full` usa `"auto"`. Como o áudio é fatiado em janelas, a detecção roda por janela; uma janela curta ou ruidosa pode sair em espanhol/galego no meio de uma reunião em português.
- **Como resolver:** detectar o idioma uma vez (primeira janela com fala suficiente, via `whisper_lang_auto_detect`) e fixá-lo nas janelas seguintes do mesmo arquivo.

#### T-03 · Baixa · Corte forçado de 60 s duplica/corta palavra na fronteira
- **Onde:** `Transcricao/DetectorDeAtividadeDeVoz.swift:264-266`, `:296-300`
- **Falha:** fala contínua é cortada exatamente em 60 s, com 0,2 s de sobreposição que é transcrita duas vezes.
- **Como resolver:** procurar o quadro de menor energia nos últimos ~2 s da janela para cortar, e descartar palavras da janela seguinte cujo `start` caia dentro da sobreposição.

#### T-04 · Média · Respostas curtas do microfone são descartadas
- **Onde:** `Transcricao/Segmentacao.swift:92-99`
- **Falha:** `mesclarCanais` remove **todo** trecho do microfone com menos de 0,5 s, com ou sem sistema ativo. "Sim.", "Não.", "Ok." somem da conversa (e do resumo).
- **Como resolver:** aplicar o corte só quando houver trecho do sistema sobreposto no tempo **e** `noSpeechProb` alto; caso contrário, manter.

#### T-05 · Baixa · `confianca` do trecho se perde nas transformações
- **Onde:** `Transcricao/Segmentacao.swift:39-49`, `Transcricao/FiltroDeRepeticao.swift:49-52` e `:79-83`, `Diarizacao/ResolvedorDeFalantes.swift:255-273`, `Persistencia/SwiftDataRepository.swift:527-534`
- **Falha:** esses pontos recriam `Trecho` sem `confianca` (e alguns sem `noSpeechProb`); além disso o campo não é persistido. Efeito visível: com "Mostrar confiança" ligado, o selo por trecho de `LinhaDeTranscricao.swift:39-40` e `:86` nunca aparece (só a marcação por palavra, que é persistida, funciona).
- **Como resolver:** usar cópias (`var copia = trecho`) ou um `func com(...)` que preserve todos os campos; recalcular `confianca` em `agrupar` com `Trecho.confiancaMedia(palavras)`; decidir se o campo deve ser persistido ou removido do domínio.

#### T-06 · Baixa · Inferência longa bloqueia o pool cooperativo e não cancela no meio
- **Onde:** `WhisperRuntime/ContextoWhisper.swift:222-224`, `LlamaRuntime/ContextoLlama.swift:231-262`
- **Falha:** `whisper_full` roda síncrono dentro do ator (uma thread do pool presa por janela) e não tem `abort_callback`; o cancelamento só é percebido entre janelas.
- **Como resolver:** configurar `params.abort_callback` lendo uma bandeira atômica acionada por `withTaskCancellationHandler`; considerar um executor serial próprio para os atores de inferência.

#### T-07 · Baixa · Regra de emoji duplicada em dois módulos
- **Onde:** `WhisperRuntime/ContextoWhisper.swift:372-392` e `Dominio.swift:383-411`
- **Como resolver:** mover a regra para um alvo pequeno compartilhado (ou aplicá-la só no `WhisperEngine`, que já filtra).

#### T-08 · Baixa · Só a primeira trilha de áudio é lida
- **Onde:** `Transcricao/DecodificadorDeAudio.swift:121`
- **Falha:** arquivos com duas trilhas (gravação de tela com sistema + microfone) perdem uma delas.
- **Como resolver:** usar `AVAssetReaderAudioMixOutput` com todas as trilhas de áudio.

#### T-09 · Baixa · `SessaoOnnx` vaza recursos em erro e usa threads demais
- **Onde:** `OnnxApi/SessaoOnnx.swift:102-118`
- **Falha:** se `CreateSession` falha, `env`, `opcoes` e `memoria` já criados não são liberados; a sessão usa o número padrão de threads intra-op para um modelo de 2 MB chamado ~112 mil vezes por hora de áudio.
- **Como resolver:** liberar os três no caminho de erro (ou guardá-los na `Caixa` antes de criar a sessão) e chamar `SetIntraOpNumThreads(opcoes, 1)`.

### 3.3 Pipeline de processamento

#### P-01 · Média (latente) · Falha na tradução descarta a transcrição pronta
- **Onde:** `Processamento/PipelineDeArquivo.swift:164-175`
- **Falha:** `atualizado.trechos = try await traduzir(...)` roda **antes** do primeiro `repositorio.salvar`. A tradução falha com facilidade (contagem de itens diferente, item vazio, JSON inválido) e o erro sobe: minutos de transcrição já concluída não são salvos. Contraria o próprio comentário do método ("perder a transcrição… seria jogar fora a parte cara"). **Latente:** o app hoje monta o pipeline sem `traduzir` (`Papagaio/ViewModels/Biblioteca.swift:980-1009`), então só dispara quando a tradução automática for ligada (a CLI já usa).
- **Como resolver:** salvar logo após a transcrição; tratar a tradução como etapa opcional (`do/catch` que mantém o original e registra aviso) e salvar de novo se ela der certo.

#### P-02 · Média (latente) · Falha do cancelamento de eco derruba a transcrição inteira
- **Onde:** `Processamento/PipelineDeArquivo.swift:244-252`, `:414-432`
- **Falha:** `aplicarAEC` decodifica o canal do sistema com `try`; um `sistema.caf` corrompido/truncado lança e a gravação não é transcrita — exatamente o caso que as linhas 254-261 dizem evitar ("o canal do sistema é acessório"). A `SessaoGravacao` já descarta arquivos vazios ou em silêncio, então o gatilho é um arquivo danificado ou não finalizado (ver C-04). **Latente:** só passa a ocorrer quando o app gravar `usavaFones` (ver P-07); hoje vale para a CLI e os testes.
- **Como resolver:** `urlMicrofone = (try? await aplicarAEC(...)) ?? canais.microfone!`, registrando o motivo.

#### P-03 · Média (latente) · Cancelamento de eco é lento e carrega tudo em memória
- **Onde:** `Processamento/PipelineDeArquivo.swift:419-426`; `CanceladorDeEco.swift:70-98`
- **Falha:** os dois canais inteiros viram `[Float]` (≈ 230 MB por hora cada, mais a saída) e o NLMS refaz, **por amostra**, uma cópia de 4.096 elementos com `%`, dois produtos vetoriais e uma atualização escalar: ~2,4 × 10¹¹ iterações por hora de áudio, sem ponto de cancelamento nem progresso. **Latente:** só passa a ocorrer quando o app gravar `usavaFones` (ver P-07); hoje vale para a CLI e os testes.
- **Como resolver:** processar em blocos por `processarEmBlocos`; manter o buffer de referência duplicado (2×L) para ler a janela contígua sem `%`; atualizar a norma de forma incremental; usar `vDSP_vsma` na atualização; ou adotar NLMS em blocos no domínio da frequência. Checar `Task.isCancelled` por bloco.

#### P-04 · Média (latente) · `microfone_aec.pcm` nunca é apagado
- **Onde:** `Processamento/PipelineDeArquivo.swift:428-431`
- **Falha:** o PCM Float32 temporário (≈ 230 MB por hora) fica para sempre dentro da pasta da gravação — ocupa disco, aparece no Finder e pode entrar em exportações. **Latente:** só passa a ocorrer quando o app gravar `usavaFones` (ver P-07); hoje vale para a CLI e os testes.
- **Como resolver:** gravar em `FileManager.default.temporaryDirectory` e remover com `defer` depois de transcrever o microfone.

#### P-05 · Média · Primeiro salvamento acontece tarde demais
- **Onde:** `Processamento/PipelineDeArquivo.swift:120-175`
- **Falha:** entre o fim da transcrição e o primeiro `salvar` rodam diarização, resolução de falantes (carrega o Qwen) e tradução. Fechar o app ou sofrer um *jetsam* nesse intervalo perde a transcrição.
- **Como resolver:** salvar imediatamente após `transcrever` e novamente após cada etapa decorativa.

#### P-06 · Baixa · AEC sem alinhamento nem detecção de fala simultânea
- **Onde:** `CanceladorDeEco.swift`
- **Falha:** microfone e sistema começam em instantes diferentes (o tap sobe depois do recorder) e o filtro causal de 256 ms não cobre atraso negativo; sem detector de *double-talk* o filtro diverge quando os dois falam juntos e distorce a voz do usuário.
- **Como resolver:** estimar o atraso por correlação cruzada antes de filtrar; congelar a adaptação quando a energia do erro supera a da referência (detector de Geigel) — ou trocar por `AVAudioEngine` com *voice processing* na captura.

#### P-07 · Média · O indicador de fones nunca é gravado: o cancelamento de eco não roda no app
- **Onde:** `Papagaio/ViewModels/GravadorViewModel.swift:228-234`; `Papagaio/ViewModels/Biblioteca.swift:317-339`; condição em `Processamento/PipelineDeArquivo.swift:245`
- **Falha:** `SessaoGravacao.Resultado.usavaFones` é calculado, mas `aoProduzirAudio` não o repassa e `Biblioteca.registrar` cria o `Arquivo` sem ele. Como `arquivo.usavaFones` é sempre `nil`, a condição `usavaFones == false` nunca é verdadeira: gravações sem fones são transcritas com o eco do alto-falante no microfone (o mesmo texto aparece nos dois canais e só a deduplicação por semelhança de `mesclarCanais` o contém). O cancelador, seus testes e a detecção de fones existem, mas estão desligados na prática.
- **Como resolver:** incluir `usavaFones` na assinatura de `aoProduzirAudio`/`registrar` — **depois** de corrigir P-02, P-03 e P-04, que passam a valer no mesmo instante.

#### P-08 · Baixa · Reprocessar pode deixar o resumo antigo junto da transcrição nova
- **Onde:** `Processamento/PipelineDeArquivo.swift:110`, `:175-204`
- **Falha:** `atualizado` nasce como cópia do arquivo, com o resumo anterior. No reprocessamento, o primeiro salvamento grava os trechos novos **com o resumo velho**; se a nova transcrição sair vazia (retorno antecipado) ou o resumo falhar, a conversa fica com um resumo que não corresponde ao texto.
- **Como resolver:** zerar `resumo`/`engineResumo` antes do primeiro salvamento de um reprocessamento.

### 3.4 Sumarização (Qwen / llama.cpp)

#### S-01 · Média · A gramática permite JSON inválido
- **Onde:** `Sumarizacao/GramaticaDoResumo.swift:23-24`, `Sumarizacao/GramaticaDaTraducao.swift:12-13`
- **Falha:** `char ::= [^"\\] | …` aceita quebra de linha e outros caracteres de controle crus dentro de strings. O `JSONDecoder` rejeita esse JSON, o que dispara o *reprompt* e, na segunda falha, erro.
- **Como resolver:** `char ::= [^"\\\x00-\x1F] | "\\" (…)`.

#### S-02 · Média · Resumo truncado vira erro com mensagem enganosa
- **Onde:** `Sumarizacao/QwenEngine.swift:176-194`
- **Falha:** o prompt pede "não comprima", mas a saída é limitada a 4.096 tokens. Se truncar, o JSON fica aberto; a correção reenvia só os primeiros 4.000 caracteres e, se falhar de novo, lança `ErroLlama.gramaticaInvalida` ("a gramática GBNF foi recusada"), que não é o que aconteceu.
- **Como resolver:** detectar truncamento (parou por `maxTokens`), limitar tamanhos na gramática (ex.: máx. de temas/passos) ou fechar o JSON de forma tolerante; criar um erro próprio (`resumoIncompleto`).

#### S-03 · Baixa · Margem do passe único não conta o prompt
- **Onde:** `Sumarizacao/QwenEngine.swift:63-67`; `LlamaRuntime/ContextoLlama.swift:206-210`
- **Falha:** a decisão usa só os tokens da transcrição (≤ 28.000), mas `completar` exige `prompt completo < 32.768 − 4.096 = 28.672`. Transcrições perto do teto lançam `promptGrandeDemais` em vez de cair no map-reduce.
- **Como resolver:** contar os tokens do prompt montado, ou reduzir `tetoDeEntrada` descontando o tamanho fixo das instruções.

#### S-04 · Baixa · Map-reduce não limita a etapa de redução
- **Onde:** `Sumarizacao/QwenEngine.swift:198-223`
- **Falha:** cada parcial pode ter 2.048 tokens; com mais de ~13 blocos (gravações muito longas) o prompt de redução estoura a janela.
- **Como resolver:** redução hierárquica (reduzir em grupos até caber).

#### S-05 · Baixa · `NotImplemented` usado como erro de transcrição vazia
- **Onde:** `Sumarizacao/QwenEngine.swift:58-60`
- **Como resolver:** erro de domínio próprio (`ErroDeResumo.transcricaoVazia`).

#### S-06 · Baixa · Texto do usuário é tokenizado com tokens especiais ativos
- **Onde:** `LlamaRuntime/ContextoLlama.swift:281-288`
- **Falha:** `llama_tokenize(..., parse_special: true)` vale para o prompt inteiro. Uma transcrição, nota ou título importado contendo `<|im_end|>`/`<|im_start|>` altera a estrutura do prompt (injeção).
- **Como resolver:** tokenizar o molde com `parse_special: true` e o conteúdo do usuário com `false`, concatenando os tokens; ou neutralizar `<|` no texto inserido.

#### S-07 · Baixa · Citação literal com muleta no meio é rejeitada
- **Onde:** `Sumarizacao/ValidacaoDeCitacoes.swift:65-68`, `:99-106`
- **Falha:** os vícios de fala são removidos da citação **antes** de procurá-la na transcrição; se a fala real tem "né"/"tipo" no meio, a versão limpa deixa de ser substring do trecho e a citação é descartada.
- **Como resolver:** localizar com o texto original (ou remover os mesmos vícios do trecho normalizado na comparação) e limpar só para exibir.

#### S-08 · Baixa · Rótulos internos de canal vazam para o resumo e viram "responsáveis"
- **Onde:** `Sumarizacao/QwenEngine.swift:251-258`; `Papagaio/Modelos/Tarefas/TarefaDaConversa.swift:90-95`
- **Falha:** a transcrição entregue ao modelo marca cada linha com `(eu)`, `(interlocutor)` ou `(desconhecido)` — o canal de origem — e pede que ele preencha `responsavel` a partir disso. Os próximos passos voltam com esses rótulos, e `responsavelSaneado` só filtra `null`/`nil`/`n/a`/`none`: a tarefa aparece atribuída a "interlocutor" ou "desconhecido". A diarização (vozes distintas e os nomes que a pessoa deu a elas) não entra no prompt, então em áudio importado todas as falas chegam como "desconhecido".
- **Como resolver:** montar o prompt com os nomes de voz quando existirem ("Voz 1", nome dado pela pessoa) e traduzir os rótulos de canal na volta ("eu" → a própria pessoa; demais → sem responsável).

### 3.5 Persistência (SwiftData)

#### D-01 · Média · `id` dos modelos não é único
- **Onde:** `Persistencia/ModelosSwiftData.swift:29`, `:14`
- **Falha:** `ArquivoPersistido.id` e `EspacoPersistido.id` não têm `@Attribute(.unique)`. A unicidade depende de todo acesso passar por um único `ModelContext`; dois contextos sobre o mesmo container (ou uma corrida de "buscar depois inserir") criam duplicatas que `buscarPersistido(...).first` esconde.
- **Como resolver:** `@Attribute(.unique) public var id` (com migração leve) ou `#Unique<ArquivoPersistido>([\.id])`.

#### D-02 · Baixa · `apagar` usa o armazenamento padrão fixo
- **Onde:** `Persistencia/SwiftDataRepository.swift:338-342`
- **Como resolver:** injetar o `Armazenamento` no repositório (ou receber a closure do chamador), como já é feito na variante de teste.

#### D-03 · Baixa · Registro com caminho fora do padrão fica preso na lixeira
- **Onde:** `Persistencia/SwiftDataRepository.swift:352-360`
- **Falha:** se `pastaRelativa` não tiver o formato `Gravacoes/<nome>`, `removerGravacao` lança e o registro nunca pode ser excluído definitivamente.
- **Como resolver:** para caminho inválido, apagar só o registro e registrar o caso no log.

#### D-04 · Baixa · Salvamento e listagem fazem trabalho demais
- **Onde:** `Persistencia/SwiftDataRepository.swift:105-153`, `:253-275`
- **Falha:** qualquer `salvar` (renomear, mexer numa nota) apaga e reinsere todos os trechos, insights e notas; a listagem da biblioteca pré-carrega todas as relações de todos os arquivos.
- **Como resolver:** métodos de atualização parcial (`atualizarTitulo`, `atualizarNotas`); projeção leve para os cartões.

#### D-05 · Baixa · Decodificação de palavras falha em silêncio
- **Onde:** `Persistencia/SwiftDataRepository.swift:507`
- **Como resolver:** registrar o erro no `logger`, como o caminho de escrita já faz.

### 3.6 Reprodução

#### R-01 · Média · Falha ao abrir o áudio é silenciosa
- **Onde:** `Reproducao/ReprodutorDeArquivo.swift:96-97`, `:136-137`
- **Falha:** `try? AVAudioPlayer(...)`; se o arquivo principal não abrir, `tocar()` simplesmente não faz nada e a interface mostra um player normal.
- **Como resolver:** expor `erroDeAbertura` (ou init que lança) e mostrar estado de erro; se só o secundário abrir, promovê-lo a primário.

#### R-02 · Baixa · Canais de durações diferentes dessincronizam o estado
- **Onde:** `Reproducao/ReprodutorDeArquivo.swift:191-201`, `:229-233`
- **Falha:** `tempo`/`tocando` seguem só o primário; quando ele acaba antes, a interface mostra "pausado em 0" com o outro canal tocando; cada `saltar` ajusta os dois `currentTime` separadamente, acumulando deriva.
- **Como resolver:** usar `AVAudioEngine` com dois `AVAudioPlayerNode` no mesmo relógio, ou ressincronizar com `play(atTime:)` após cada salto e derivar `tocando` de qualquer um dos players.

#### R-03 · Baixa · Temporizador de 10 Hz continua com o player pausado
- **Onde:** `Reproducao/ReprodutorDeArquivo.swift:127-131`
- **Como resolver:** ligar o timer em `tocar()` e desligar em `pausar()`/fim.

### 3.7 Modelos, download e ciclo de vida

#### M-01 · Média · Download de 9 GB iterado byte a byte
- **Onde:** `Runtime/DownloadDeModelos.swift:150-161`
- **Falha:** `for try await byte in bytes` passa ~9,2 bilhões de bytes um a um por um iterador assíncrono — CPU alta e download bem mais lento que a rede permite.
- **Como resolver:** `URLSessionDataDelegate` (`didReceive data`) gravando blocos, ou `URLSessionDownloadTask` com `Range`.

#### M-02 · Média · URLs dos pesos não fixam a revisão
- **Onde:** `Runtime/Preflight.swift:26`, `:33`
- **Falha:** os links usam `resolve/main`, mas o SHA-256 é fixo. Se o repositório no Hugging Face for atualizado ou removido, toda instalação nova falha no checksum sem alternativa.
- **Como resolver:** apontar para `resolve/<commit>/…` e/ou hospedar um espelho próprio; exibir mensagem acionável no erro de checksum.

#### M-03 · Baixa · `FilaEstrita.entrar()` não é cancelável
- **Onde:** `Transcricao/FilaEstrita.swift:18-28`
- **Falha:** uma tarefa cancelada continua na fila até o dono atual sair (pode ser um download de horas ou um resumo de minutos).
- **Como resolver:** `withTaskCancellationHandler` removendo a continuação da fila e lançando `CancellationError`.

#### M-04 · Baixa · Bookmark da pasta de modelos
- **Onde:** `Runtime/PastaDeModelosDoUsuario.swift:30-51`
- **Falha:** cada `resolver()` chama `startAccessingSecurityScopedResource` sem par; e um volume apenas desmontado faz o app **esquecer** a escolha.
- **Como resolver:** resolver uma vez e guardar em cache; só `esquecer()` quando o bookmark não resolve (não quando o acesso falha temporariamente).

#### M-05 · Baixa · Descarga sob pressão e na saída
- **Onde:** `Runtime/CicloDeVidaDeModelos.swift:32-45`, `:91-115`
- **Falha:** `.warning` já descarrega tudo (recarregar 3–6 GB a cada janela sob pressão contínua); na saída, se o ator estiver no meio de uma inferência, o tempo limite de 2 s expira e o processo pode abortar no destrutor estático do ggml.
- **Como resolver:** descarregar só em `.critical` ou só o modelo ocioso; na saída, sinalizar cancelamento da inferência (ver T-06) antes de esperar.

#### M-06 · Baixa · Macs com menos de 18 GB ficam bloqueados
- **Onde:** `Runtime/Preflight.swift:89`, `:104-108`
- **Observação:** decisão de produto registrada no código ("não há modo reduzido"); fica anotada porque exclui os Macs de 16 GB. **Como resolver:** medir o pico real com Qwen Q4 e, se couber, baixar o mínimo ou oferecer um modelo menor.

#### M-07 · Média · Com menos de 20 GB livres o app recusa transcrever, mesmo com os modelos instalados
- **Onde:** `Runtime/Preflight.swift:104-118`; usado em `Papagaio/ViewModels/Biblioteca.swift:898-901`, `:941-945`
- **Falha:** `avaliar()` testa o espaço livre (`discoMinimo` = 20 GB, dimensionado para o download) **antes** de verificar se os pesos já estão no disco. Depois de baixar os 9 GB, um Mac que fique com menos de 20 GB livres recebe `.discoInsuficiente` — que bloqueia — em todo processamento e em todo ditado, com a mensagem "São necessários 20 GB livres para os modelos".
- **Como resolver:** verificar os pesos primeiro e exigir espaço só para o que falta baixar (mais uma folga pequena para o trabalho).

#### M-08 · Baixa · Um peso inválido já presente nunca é substituído
- **Onde:** `Runtime/DownloadDeModelos.swift:82-87`
- **Falha:** se o arquivo final existe com tamanho ou SHA diferente (cópia truncada, revisão antiga do mesmo nome), `validar` lança e o download para ali; o arquivo ruim não é removido, então "Baixar" falha para sempre até alguém apagá-lo à mão dentro do container.
- **Como resolver:** em `tamanhoInvalido`/`checksumInvalido` do arquivo final, movê-lo para `.parcial` (se menor) ou apagá-lo e seguir com o download.

#### M-09 · Baixa · O aviso de "Mac muito quente" nunca aparece
- **Onde:** `Runtime/Preflight.swift:52`, `:75-77`, `:121-122`; `Papagaio/ViewModels/ModelosViewModel.swift:45`; `Papagaio/ViewModels/Biblioteca.swift:899`, `:942`
- **Falha:** o `Preflight` detecta o estado térmico crítico e tem a mensagem pronta ("Seu Mac está muito quente. Transcrever agora vai ficar lento e esquentar mais. Dá para adiar."), mas o app trata `.termicoCritico` como "pronto" em todos os pontos: o cartão de modelos não aparece, o processamento começa sem aviso e não existe a opção de adiar que a mensagem promete.
- **Como resolver:** mostrar a mensagem como aviso não bloqueante na fila ou no cartão, com "Adiar" e "Transcrever mesmo assim"; reavaliar o estado antes de cada item da fila.

### 3.8 Idioma

#### I-01 · Baixa (latente) · Detecção de idioma frágil dispara tradução indevida
- **Onde:** `Processamento/IdiomaDeProcessamento.swift:66-71`, `:86-100`
- **Falha:** (latente — depende da tradução automática, que o app ainda não liga) basta o `NLLanguageRecognizer` errar num texto curto (pt → es/gl) para o pipeline "traduzir" português para português — o que apaga os timestamps por palavra e reescreve o texto.
- **Efeito já ativo:** desde `94bf1e8` o mesmo resultado escolhe o idioma pedido ao resumidor (`PipelineDeArquivo.swift:184-192`); um erro de detecção entre português e inglês em gravações curtas produz o resumo no idioma errado.
- **Como resolver:** exigir confiança mínima (`languageHypotheses`) e tamanho mínimo de texto; restringir `languageConstraints`; na dúvida, não traduzir.

### 3.9 Integrações no Core (usadas só pela CLI `papagaio-eval`)

#### G-01 · Média · Duas implementações com o mesmo nome; os testes cobrem a que o app não usa
- **Onde:** `Integracao/{ClienteMCP,SessaoOAuth,FonteGranola}.swift` × `Papagaio/Integracao/{ClienteMCP,SessaoOAuth,FonteGranola}.swift`
- **Falha:** o app declara tipos próprios `ClienteMCP`, `SessaoOAuth`, `FonteGranola`, `ErroOAuth` e `ErroMCP` que **sombreiam** os públicos do Core. `PapagaioCoreTests/IntegracaoTests.swift` testa a versão do Core, que só a CLI usa — a cobertura do fluxo real do app é ilusória e as duas versões já divergiram.
- **Como resolver:** manter uma única implementação (a do app, movida para o Core) e apagar a outra; apontar os testes para ela.

#### G-02 · Baixa · `ClienteMCP` do Core fora da especificação
- **Onde:** `Integracao/ClienteMCP.swift:148-183`, `:292-315`
- **Falha:** faz um `GET` inicial que pode ficar preso num fluxo SSE; não lê `Mcp-Session-Id` da resposta do `initialize`; não envia `notifications/initialized`; exige versão de protocolo idêntica; junta todos os eventos `data:` num JSON só.
- **Como resolver:** eliminar junto com G-01 (a versão do app já trata parte disso).

#### G-03 · Baixa · `SessaoOAuth` do Core
- **Onde:** `Integracao/SessaoOAuth.swift:46-76`, `:104-126`; `Integracao/AutenticacaoOAuth.swift:287-296`
- **Falha:** `state` é gerado e nunca conferido; resposta de *refresh* sem `refresh_token` apaga o antigo; duas renovações concorrentes podem invalidar a credencial; `estaAutenticado()` pode abrir o navegador; sem `expires_in` reautentica em toda chamada.
- **Como resolver:** eliminar junto com G-01 ou corrigir cada ponto (preservar o refresh token antigo, unificar a renovação numa `Task` compartilhada, separar "consultar" de "autenticar").

#### G-04 · Baixa · Datas de eventos do Google Calendar
- **Onde:** `Integracao/ReuniaoExterna.swift:111-136`
- **Falha:** evento de dia inteiro é interpretado como meia-noite **UTC** e aparece no dia anterior em fusos negativos (Brasil); data inválida vira `Date()` sem aviso.
- **Como resolver:** interpretar `date` no fuso local (`TimeZone.current`) e devolver `nil`/descartar o evento quando a data não for legível.

#### G-05 · Baixa · `CofreDeTokens`
- **Onde:** `Integracao/CofreDeTokens.swift:14-28`
- **Falha:** `salvar` faz `SecItemDelete` + `SecItemAdd` (se o `Add` falhar, a credencial antiga já se foi) e não usa o *data protection keychain*.
- **Como resolver:** `SecItemUpdate` com *fallback* para `SecItemAdd`; acrescentar `kSecUseDataProtectionKeychain: true`.

#### G-06 · Baixa · O `ClienteMCP` do Core derruba o processo em qualquer chamada com argumentos
- **Onde:** `Integracao/ClienteMCP.swift:185-191`, `:233-242`; usado por `Integracao/FonteGranola.swift:242-254` e por `PapagaioCore/Sources/papagaio-eval/main.swift:435-449`
- **Falha:** `chamarUmaVez` coloca o dicionário `[String: ValorJSON]` direto em `"arguments"` e o entrega a `JSONSerialization.data(withJSONObject:)`. Um *enum* Swift não é um tipo JSON: com qualquer argumento a chamada levanta `NSInvalidArgumentException` ("Invalid type in JSON write (__SwiftValue)"), que o Swift não captura — o processo termina. Reproduzido com a mesma estrutura. Só as chamadas sem argumentos (`get_account_info`, `list_meetings`) funcionam; `papagaio-eval granola --detalhe <id>` cai ao pedir a reunião. O app não é afetado (usa a própria implementação — G-01).
- **Como resolver:** converter com `parametros.mapValues(\.comoAny)` antes de serializar — ou eliminar esta cópia junto com G-01.

## 4. Falhas no app (`Papagaio/`)

### 4.1 Biblioteca, gravação e fila de processamento

#### B-01 · Alta · Duplicar uma conversa sem áudio copia a raiz do armazenamento para dentro de si mesma
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:739-761`; ação sem restrição em `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:1306` e `:1323-1329`
- **Falha:** conversas sem áudio têm `pastaRelativa == ""` — é o caso das reuniões importadas do Granola e de **toda conversa recebida de outro membro da equipe** (o CloudKit zera a pasta). `armazenamento.resolver(relativo: "")` devolve a própria raiz (`…/Application Support/Papagaio`), que existe; `copyItem(at: raiz, to: raiz/Gravacoes/<novoID>)` passa a copiar **todas as gravações e os modelos (≈ 9 GB)** para dentro da nova pasta, recursivamente.
- **Reprodução:** feita em diretório temporário com a mesma sequência de chamadas — a cópia aninha `Gravacoes/NOVO/Gravacoes/NOVO/…` até estourar o tamanho do caminho (`NSCocoaErrorDomain 514`). Com dados reais, cada nível copia a biblioteca inteira: disco cheio antes do erro.
- **Como resolver:** em `duplicar`, tratar `origemCompleta.semAudio` à parte (cópia só do registro, `pastaRelativa: ""`); fazer `Armazenamento.resolver` recusar string vazia (ver C-09); esconder "Duplicar" quando não fizer sentido.

#### B-02 · Alta · Edições feitas durante o processamento são sobrescritas
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:928-1027`; `PapagaioCore/…/Processamento/PipelineDeArquivo.swift:110-203`
- **Falha:** o pipeline parte de uma fotografia do `Arquivo` tirada no início e chama `repositorio.salvar(atualizado)` duas vezes, regravando **título, data, duração e notas** com os valores antigos. Renomear a conversa, preencher a ficha ou escrever notas enquanto ela transcreve (minutos) — tudo isso é permitido pela interface — volta ao estado anterior quando o processamento termina. O mesmo vale para `diarizarTranscricao` (`:1116-1124`).
- **Como resolver:** o pipeline deve gravar só o que produz. Criar no repositório `atualizarResultadoDoProcessamento(id:trechos:resumo:engines:)` (ou reler o registro atual antes de cada `salvar` e copiar dele título, datas e notas).

#### B-03 · Alta · Arrastar um áudio durante a gravação "perde" a gravação em curso
- **Onde:** `Papagaio/ViewModels/GravadorViewModel.swift:382-416`; `Papagaio/Funcionalidades/Biblioteca/CartaoNovaConversa.swift:105-111`; `Papagaio/App/ContentView.swift:740-750`
- **Falha:** `importar(_:)` faz `estado = .processando` e depois `.ocioso` sem olhar se há gravação. O cartão "nova conversa" esconde o botão Importar durante a gravação, mas o `dropDestination` continua ativo. Resultado: o selo "Gravando" some, o microfone **segue gravando sem nenhum indicador**, e a próxima gravação chama `anterior.descartar()` — apagando a que estava em andamento.
- **Como resolver:** não usar o estado da gravação para a importação (estado próprio `importando`), e recusar/adiar importações enquanto `gravando`; desligar o `dropDestination` nesse período.

#### B-04 · Alta · Sair do app (ou travar) durante a gravação perde a gravação
- **Onde:** `Papagaio/App/PapagaioApp.swift` (sem `applicationShouldTerminate`); `Papagaio/ViewModels/GravadorViewModel.swift:200-244`
- **Falha:** o `Arquivo` só é criado em `parar()`. ⌘Q, logout ou crash no meio de uma reunião deixam a pasta em `Gravacoes/` sem registro no banco (e o WAV possivelmente sem cabeçalho final). Nada reencontra essa pasta depois.
- **Como resolver:** (1) `applicationShouldTerminate` devolvendo `.terminateLater` até `gravador.parar()` concluir; (2) registrar um rascunho do `Arquivo` ao iniciar a gravação; (3) na abertura, varrer `Gravacoes/` atrás de pastas sem registro e oferecer recuperação.

#### B-05 · Média · Gravação de reunião do Calendar é descartada se a criação do arquivo falhar
- **Onde:** `Papagaio/App/ContentView.swift:535-548`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:212-232`; `Papagaio/ViewModels/Biblioteca.swift:1415-1426`
- **Falha:** quando a gravação nasce de uma reunião pendente, o resultado de `importarAudioParaReuniao` é ignorado (`_ =`). Se `criarArquivoDeReuniaoPendente` devolver `nil` (já existe conversa com o mesmo `idExterno`, falha ao salvar, view model liberado), o áudio recém-gravado fica órfão no disco e não aparece em lugar nenhum.
- **Como resolver:** se o retorno for `nil`, cair em `nova.registrar(titulo:pastaRelativa:…)` e notificar.

#### B-06 · Média · Ditado e "diarizar" carregam modelos fora da fila
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:897-912`, `:1067-1131`
- **Falha:** cada um cria o seu próprio `MotoresLocais`. Com um arquivo em processamento, ditar uma nota carrega um segundo Whisper (3 GB) ao lado do Qwen (6 GB), e "diarizar" pode carregar um segundo Qwen — a invariante "nunca os dois residentes" deixa de valer num Mac de 18 GB. Além disso os contextos se registram no `CicloDeVidaDeModelos` com a mesma chave: o `remover` de um apaga o registro do outro. E o ditado ainda disputa a fila única do VAD (`DetectorDeAtividadeDeVoz.filaDoSilero`), que o pipeline segura durante a transcrição de cada canal: a nota ditada fica em "transcrevendo" por minutos e, se a pessoa sair da tela nesse meio-tempo, o texto ditado se perde.
- **Como resolver:** um único `MotoresLocais` na `Biblioteca`, com todas as operações passando pela mesma fila; ou bloquear ditado/diarização enquanto `processando`.

#### B-07 · Média · A abertura do app espera a rede do CloudKit
- **Onde:** `Papagaio/App/ContentView.swift:488-491` e `:582`
- **Falha:** para quem participa de alguma equipe, `reconciliarEquipesExcluidas()` (uma consulta ao banco público por equipe) roda **antes** de `nova.preparar()`. Com rede lenta, a biblioteca aparece vazia até o CloudKit responder ou expirar.
- **Como resolver:** carregar a biblioteca primeiro e reconciliar em segundo plano.

#### B-08 · Média · A fila de processamento se perde ao reabrir o app ou trocar de espaço
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:265-267`, `:289-307`
- **Falha:** a fila vive só em memória. Fechar o app com itens pendentes (ou com um em andamento) os deixa como "pronto para transcrever" sem aviso; trocar de perfil/equipe faz `filaDeProcessamento.removeAll()`. Arquivos recusados por falta de modelos também não são retomados quando o download termina. E se um arquivo do espaço anterior ainda estiver processando, ao terminar ele não passa por `sincronizar`, não gera aviso de conclusão nem ficha pendente (`:1023-1025`).
- **Como resolver:** persistir os IDs pendentes e reenfileirar em `carregar()` quando `processamentoAutomatico` estiver ligado; ao trocar de espaço, manter a fila por espaço.

#### B-09 · Baixa · `excluirDadosDaConta` não é atômica
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:604-613`
- **Falha:** as pastas são removidas uma a uma com `try`; a primeira falha (ou um `pastaRelativa` fora do padrão) interrompe com parte da mídia já apagada e os registros ainda no banco — e a exclusão da conta nunca conclui.
- **Como resolver:** apagar o banco primeiro (ou marcar para exclusão), remover as pastas com `try?` coletando erros, e relatar o que sobrou.

#### B-10 · Baixa · Pontas soltas em `criarArquivoDeReuniaoPendente`
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:1423-1426`, `:1441-1468`
- **Falha:** o erro "áudio não encontrado" é guardado sob um `ArquivoID()` aleatório que nenhuma tela lê (o mesmo acontece em `registrar`, `:340-345`: se o primeiro salvamento falhar, a gravação fica no disco sem registro e sem aviso visível); cópia que falha deixa pasta vazia; um arquivo externo chamado `microfone.wav` é recusado como "pasta inesperada"; o novo arquivo não passa por `sincronizar` nem recebe `importadoEm`.
- **Como resolver:** devolver `Result`/lançar o erro para quem chamou; limpar a pasta no `catch`; distinguir "gravação interna" por parâmetro, não pelo nome do arquivo.

#### B-11 · Média · Abrir a conversa antes do resumo impede para sempre as tarefas sugeridas
- **Onde:** `Papagaio/Persistencia/TarefasDaConversa.swift:16-30`; chamado em `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:489-494`; lido também por `Papagaio/Persistencia/TarefasGeraisStore.swift:5-17`
- **Falha:** na primeira abertura da conversa, `carregar` cria as tarefas a partir de `resumo.proximosPassos` e **grava o resultado mesmo quando a lista está vazia**. Se a pessoa abre a conversa enquanto ela ainda transcreve (ou com o processamento automático desligado), fica salvo `[]`; quando o resumo chega, as duas lojas encontram a chave preenchida e nunca mais geram as sugestões. O mesmo bloqueio vale após "Gerar novo resumo": próximos passos novos não viram tarefas.
- **Como resolver:** não gravar lista vazia (como `TarefasGeraisStore` já faz) e guardar junto das tarefas a "assinatura" do resumo que as originou, para acrescentar as sugestões de um resumo novo sem tocar nas tarefas existentes.

#### B-12 · Baixa · Cancelar um processamento gera o aviso "Transcrição falhou"
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:1043-1050`; tipos de erro em `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:56`, `LlamaRuntime/ContextoLlama.swift:8`, `PapagaioCore/…/Runtime/DownloadDeModelos.swift:15`
- **Falha:** o `catch` de `executarProcessamento` não distingue `CancellationError`: mover para a lixeira (ou "Cancelar processamento") dispara a notificação de falha do sistema. Além disso, `ErroWhisper`, `ErroLlama`, `ErroOnnx`, `ErroSilero` e `ErroDownload` só implementam `CustomStringConvertible`; a notificação usa `localizedDescription` e sai como "The operation couldn't be completed (… error 2)" — o mesmo problema que `ErroCaptura` já corrigiu para si.
- **Como resolver:** tratar `CancellationError` (e execução substituída) em silêncio; adotar `LocalizedError` nesses tipos, devolvendo a `description`.

#### B-13 · Baixa · Duração indefinida vira `NaN` e derruba a exportação
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:1461-1463`, `:1536-1541`; `PapagaioCore/…/Exportacao/ExportacaoMarkdown.swift:93-96`
- **Falha:** ao anexar áudio a uma reunião pendente, a duração vem de `(try? await asset.load(.duration).seconds) ?? 0`; para mídia de duração indefinida `seconds` é `NaN` (o `try?` não cobre isso) e o valor é salvo. `ExportacaoMarkdown.duracao` faz `Int(segundos)` sem checar — conferido: `Int(.nan)` encerra o processo ("Double value cannot be converted to Int…"). Compartilhar, baixar ou copiar essa conversa fecha o app; o `JSONEncoder` da fila do iCloud também recusa o valor.
- **Como resolver:** validar `isFinite && > 0` em `duracaoDoAudio` (como o `ImportadorAudio` já faz) e usar em `ExportacaoMarkdown` a mesma função protegida do app (`segundosValidos`).

#### B-14 · Média · Toda tarefa sugerida nasce com prazo e prioridade inventados
- **Onde:** `Papagaio/Persistencia/TarefasDaConversa.swift:16-28`; `Papagaio/Persistencia/TarefasGeraisStore.swift:20-33`; `Papagaio/ViewModels/TarefasDaConversaViewModel.swift:34`, `:108`, `:129-132`; `Papagaio/Funcionalidades/Detalhe/Tarefas/NovaTarefaDaConversaSheet.swift:35`, `:169`; `Papagaio/Funcionalidades/Tarefas/TarefasView.swift:748`, `:776` (o editor do painel geral faz o mesmo, com "hoje" como padrão)
- **Falha:** o resumo não traz prazo (`ProximoPasso` só tem descrição e responsável), mas cada sugestão recebe `prazo = data da conversa + 7 + índice dias`, e as duas primeiras recebem prioridade "alta". Como as sugestões só são criadas na primeira vez que a aba de tarefas (ou o painel geral) é aberta, qualquer conversa com mais de uma semana — um áudio antigo importado, reuniões passadas do Granola, ou simplesmente uma conversa cuja aba ninguém abriu — já nasce com todas as tarefas vencidas: ao aceitar, `RegraDePrazoDaTarefa.ajustada` sobe a prioridade para alta, a tarefa cai na coluna "Atrasada" e sai a notificação "vence <data passada> e foi marcada como prioridade alta". Além disso o formulário usa `Date` não opcional: não dá para criar nem manter uma tarefa sem prazo, e `salvarEdicao` grava `prazoDaTarefa` sempre — corrigir só o título de uma tarefa sem prazo grava "daqui a 7 dias" por baixo. O estado "Sem deadline" existe na interface e é inalcançável.
- **Como resolver:** criar sugestões com `prazo: nil` e prioridade neutra (o modelo não informou nenhuma das duas); se o prazo interessa, dar um campo opcional para ele no formato do resumo — hoje o *prompt* pede "donos e prazos sempre que possível" (`Sumarizacao/GramaticaDoResumo.swift:50-51`), mas a gramática só tem `descricao` e `responsavel` (`:20`); formulário com prazo opcional ("Sem prazo"); em `salvarEdicao`, só tocar no prazo quando a pessoa o alterou.

### 4.2 Ditado e mensagens da gravação

#### GV-01 · Média · O ditado pode enviar áudio à Apple
- **Onde:** `Papagaio/ViewModels/GravadorViewModel.swift:472-474`; texto de permissão em `Loro.xcodeproj/project.pbxproj:465`
- **Falha:** `requiresOnDeviceRecognition` só é ligado quando o reconhecedor suporta; caso contrário o `SFSpeechRecognizer` usa os servidores da Apple, enquanto a descrição de uso afirma que o texto é processado "no seu Mac, sem sair dele".
- **Como resolver:** exigir reconhecimento local (`guard reconhecedor.supportsOnDeviceRecognition`) e, sem ele, pular os parciais e usar só o Whisper.

#### GV-02 · Baixa · Reconhecedor do ditado fixo em `pt_BR` e erros crus na interface
- **Onde:** `Papagaio/ViewModels/GravadorViewModel.swift:554`, `:185`, `:429`
- **Falha:** quem usa o app em inglês recebe parciais em português; falhas de gravação/importação aparecem como `"\(error)"`.
- **Como resolver:** usar o idioma do app/sistema; passar por `localizedDescription` com mensagem amigável.

#### GV-03 · Baixa · Notas de uma gravação nova podem ser apagadas pelo fim da anterior
- **Onde:** `Papagaio/ViewModels/GravadorViewModel.swift:217-243`
- **Falha:** em `parar()`, o estado volta a `.ocioso` antes de `await aoProduzirAudio(...)` (que em equipe inclui a espera de CK-15) e `limparDepoisDeGravar()` roda só depois. Se a pessoa inicia outra gravação nesse intervalo e já marca algo, essa limpeza tardia apaga as notas e o rascunho da gravação **nova**.
- **Como resolver:** limpar antes do `await` (as notas já foram copiadas para a chamada) ou atrelar a limpeza ao identificador da gravação.

#### GV-04 · Média · "Cancelar" descarta a gravação inteira sem confirmação em três dos quatro lugares
- **Onde:** `Papagaio/Funcionalidades/Gravacao/PainelDeGravacao.swift:125-127` (tela de gravação); `Papagaio/Funcionalidades/Gravacao/PainelFlutuanteDeGravacao.swift:106-108` (painel flutuante); `Papagaio/App/PapagaioApp.swift:147-149` (menu da barra do sistema); só `Papagaio/App/ContentView.swift:1119-1141` (selo) pergunta antes; efeito em `Papagaio/ViewModels/GravadorViewModel.swift:118-136`
- **Falha:** `cancelar()` apaga o áudio e as notas da gravação em curso ("nenhum arquivo foi criado"), sem lixeira. O selo de gravação pede confirmação ("O áudio capturado até agora é descartado"), mas o botão "Cancelar" da tela de gravação, o "×" do painel flutuante — um ícone pequeno colado ao de finalizar — e "Cancelar gravação" do menu da barra, logo abaixo de "Finalizar gravação", executam direto. Um clique errado ao tentar finalizar uma reunião de uma hora perde tudo.
- **Como resolver:** a mesma confirmação nos quatro pontos (centralizada em quem chama `cancelar()`), ou — melhor — cancelar mandando a gravação para a lixeira, de onde dá para recuperar.

#### GV-05 · Média · Notas escritas com a gravação pausada são ignoradas e se perdem ao finalizar
- **Onde:** `Papagaio/ViewModels/GravadorViewModel.swift:318-332` (`adicionarNota`), `:360-372` (`inserirMarcador`), `:200-244` e `:374-376` (`parar` → `confirmarRascunhoDaNota`); telas em `Papagaio/Funcionalidades/Gravacao/NotasDuranteGravacao.swift:88-97` e `PainelFlutuanteDeGravacao.swift:169-176`
- **Falha:** as duas funções só agem com `estado == .gravando`. Com a gravação pausada — justamente quando sobra tempo para anotar — Enter não faz nada e nada avisa; o texto fica no campo. Ao finalizar a partir da pausa, `parar()` chama `adicionarNota()` para aproveitar o rascunho, mas o estado ainda é `.pausado`: a nota é recusada de novo e `limparDepoisDeGravar()` apaga o rascunho. O que foi digitado durante a pausa some sem aviso.
- **Como resolver:** aceitar notas e marcadores também em `.pausado` (o instante é `tempoDeGravacao`, que fica congelado na pausa); em `parar()`, confirmar o rascunho sem depender do estado.

### 4.3 Equipes e CloudKit

#### CK-01 · Alta (segurança) · Qualquer conta pode disparar a limpeza local de uma equipe
- **Onde:** `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:280-317`; `Papagaio/App/ContentView.swift:847-869`, `:894-901`; `Papagaio/Persistencia/EquipesDoUsuario.swift`
- **Falha:** ao abrir, cada instalação lê no **banco público** o registro `equipe-excluida.<id>` e, se estiver "concluída", apaga do Mac todas as conversas, mídia e lixeira daquela equipe. Nada verifica **quem** criou o marcador. O ID da equipe é previsível (`<nome>-<6 hex>`) e conhecido por todo membro e ex-membro; e o papel de "proprietário" que libera `excluirEquipeGlobalmente` vem de um campo em `UserDefaults` (`bancoCloudKit == "privado"`), editável à mão. Um participante (ou ex-participante) consegue publicar o marcador e fazer todos os Macs da equipe se limparem.
- **Como resolver:** só aceitar o marcador se `marcador.creatorUserRecordID` for o dono da zona (`donoDaZonaCloudKit`); melhor ainda, confirmar a exclusão pela própria zona compartilhada (`CKError.zoneNotFound`/`userDeletedZone`) em vez de um sinal público; e mover para a lixeira local com prazo em vez de apagar de imediato.

#### CK-02 · Alta (segurança) · Código de entrada sem autenticidade e com permissão de escrita
- **Onde:** `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:59-73`, `:91-106`, `:383-385`, `:410-416`
- **Falha:** o código de 6 caracteres aponta para a URL do `CKShare` num registro do banco público que qualquer conta autenticada pode criar. (a) Não há unicidade: outro registro com o mesmo código pode apontar para uma zona de terceiros, e `entrarNaEquipe` usa o primeiro resultado — quem digita o código legítimo pode cair na zona errada e passar a sincronizar conversas para lá. (b) `publicPermission = .readWrite`: quem tiver o código lê **e altera/apaga** tudo. (c) O campo é consultável, o que permite tentativa em massa.
- **Como resolver:** antes de aceitar, conferir que o criador do registro do código é o dono do share (`registro.creatorUserRecordID == metadados.ownerIdentity.userRecordID`) e que o registro `Equipe` da zona traz o mesmo código; usar `publicPermission = .readOnly` (promoção a escrita pelo proprietário) ou `.none` com aprovação; aumentar o código e expirar/rotacionar; recusar um convite cujo `espacoID` ou `id` já pertença a outra equipe local (`EquipesDoUsuario.incluirOuAtualizar` hoje substitui a entrada existente).

#### CK-03 · Média · Cada sincronização baixa a zona inteira
- **Onde:** `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:178-198`, `:242-272`; `Papagaio/ViewModels/Biblioteca.swift:1226-1259`
- **Falha:** `CKFetchRecordZoneChangesOperation` roda sem *change token*: todos os registros e todos os `CKAsset` voltam a cada troca de espaço; a "paginação" só fatia um vetor já carregado; e cada conversa recebida é regravada por inteiro no SwiftData, mudou ou não.
- **Como resolver:** persistir `serverChangeToken` por zona e aplicar só o delta; comparar `atualizadoEm` com a última revisão aplicada antes de salvar.

#### CK-04 · Média · Um registro ilegível derruba o download de todos
- **Onde:** `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:253-268`, `:385`, `:407-422`
- **Falha:** falha em um registro (`recordWasChangedBlock`) ou payload que não decodifica (versão mais nova do app, campo novo obrigatório) faz a função inteira lançar. Uma conversa problemática bloqueia a equipe toda.
- **Como resolver:** pular o registro com erro, registrar no log e continuar; versionar o payload com campos opcionais.

#### CK-05 · Média · Exclusões e restaurações remotas não chegam
- **Onde:** `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:246-272`; `PapagaioCore/…/Persistencia/SwiftDataRepository.swift:91-93`
- **Falha:** registros apagados no iCloud nunca são removidos localmente (não há `recordWithIDWasDeletedBlock`); qualquer edição posterior recria o registro para todos. E como `salvar` só altera `apagadoEm` quando o valor recebido não é `nil`, uma conversa restaurada por um colega continua na lixeira dos outros.
- **Como resolver:** tratar exclusões no delta (ver CK-03); dar ao repositório um caminho de sincronização que aplique `apagadoEm` tal como veio.

#### CK-06 · Média · A fila do iCloud pode travar para sempre
- **Onde:** `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:41-52`, `:152-162`
- **Falha:** (a) se `fila-pendente.json` não decodificar (arquivo truncado ou `Arquivo`/`EquipeDisponivel` com campo novo após atualização), `estadoInicial` vira falha permanente e todo agendamento/processamento passa a lançar; (b) erros que não melhoram com repetição — registro já inexistente na remoção, membro só-leitura, cota — são repetidos indefinidamente com *backoff*.
- **Como resolver:** em erro de leitura, mover o arquivo para quarentena e recomeçar vazio (avisando); classificar `CKError` (`unknownItem` na remoção = sucesso; `permissionFailure`/`quotaExceeded` = parar e avisar).

#### CK-07 · Média · Conflito resolve por "quem envia por último", no documento inteiro
- **Onde:** `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:65-80`; `Papagaio/ViewModels/Biblioteca.swift:1237-1243`
- **Falha:** se há edição local pendente, a versão remota é ignorada e o envio seguinte a substitui por completo — a edição do colega (nota, correção de transcrição) some sem fusão.
- **Como resolver:** fundir por campo (notas por `id`, trechos por `id`, metadados por data) ou, no mínimo, guardar a versão perdedora como cópia de conflito.

#### CK-08 · Baixa · Criar equipe e trocar código não são retomáveis
- **Onde:** `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:48-88`, `:245-274`
- **Falha:** se a publicação do código falhar depois de criar zona e share, a equipe não é salva localmente e a zona fica órfã no iCloud; em `rotacionarCodigo`, falha após trocar o share deixa a equipe local apontando para um share apagado. O código novo não verifica colisão com outro já publicado. Em `entrarNaEquipe`, o registro `equipe` é lido da zona compartilhada logo após `accept`; se a zona ainda não estiver visível, a entrada falha embora o convite já tenha sido aceito no servidor.
- **Como resolver:** persistir o estado intermediário e tornar cada passo idempotente; checar a existência do código antes de publicar.

#### CK-09 · Baixa · Mudanças locais que não entram na fila são desfeitas
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:1116-1124`, `:1487-1520`
- **Falha:** `diarizarTranscricao`, `criarArquivoDeReuniaoPendente` e `registrarExterna` (`:412-425`, importação do Granola) salvam sem `sincronizar`; no próximo download a versão remota (sem a mudança) vence.
- **Como resolver:** chamar `sincronizar` em todo caminho que grava num espaço de equipe (centralizar num único `salvarESincronizar`).

#### CK-10 · Baixa · Lista de equipes é apagada por um erro de leitura
- **Onde:** `Papagaio/Persistencia/EquipesDoUsuario.swift:7-17`
- **Falha:** `carregar` devolve `[]` se a decodificação falhar; a próxima chamada a `salvar` grava a lista vazia por cima.
- **Como resolver:** distinguir "sem dados" de "dados ilegíveis" e preservar o blob original nesse caso.

#### CK-11 · Baixa · Identificador de participante instável
- **Onde:** `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:481-485`
- **Falha:** sem `userRecordID` nem e-mail, cai em `UUID()` novo a cada leitura — alterar permissão/remover esse participante nunca encontra o alvo.
- **Como resolver:** usar um identificador derivado do próprio `CKShare.Participant` (por exemplo o índice estável + `acceptanceStatus`) ou ocultar as ações quando não houver ID.

#### CK-12 · Média · Configurações da equipe que não têm efeito
- **Onde:** `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:3-32`; `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:271-286`
- **Falha:** "Visibilidade dos arquivos: somente administradores" e "Recebimento de arquivos: aguardar revisão" são gravadas no registro da equipe, mas nenhum outro ponto do app as lê — todos os membros continuam vendo e recebendo tudo. Quem administra a equipe acredita ter restringido o acesso.
- **Como resolver:** implementar as duas regras (no download e na listagem) ou remover os controles até existirem.

#### CK-13 · Baixa · A lista local de membros nunca é preenchida
- **Onde:** `Papagaio/Persistencia/MembrosDasEquipes.swift`; leitores em `Papagaio/App/ContentView.swift:135-140` e `Papagaio/Suporte/ClassificacaoDeParticipantes.swift:17-21`
- **Falha:** não existe chamada a `MembrosDasEquipes.salvar` em produção. Por isso `responsaveisDaEquipeAtiva` (sugestões de responsável nas tarefas) vem sempre vazio e a classificação Equipe × Externos das reuniões do Calendar só reconhece a própria pessoa. E a alternativa que resolveria o caso sem equipe está pronta e não é usada: `ResponsavelDaTarefa.disponiveis(em:)` (`Papagaio/Modelos/Tarefas/ResponsavelDaTarefa.swift:25-55`), que lista as pessoas da ficha da própria conversa, só é chamada pelos testes.
- **Como resolver:** alimentar a lista a partir dos participantes do `CKShare` (com o nome editável que já existe) ou remover essa loja.

#### CK-14 · Média · Uma edição concluída depois de trocar de espaço vai para o espaço errado
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:646-736` (`renomear`, `atualizarMetadados`, `atualizarNotas`, `atualizarTrechos`), `:1155-1174` (`substituir`, `sincronizar`); gatilho em `Papagaio/App/ContentView.swift:238-242`, `:631-638`
- **Falha:** esses métodos suspendem (`await`) e, ao voltar, chamam `substituir` e `sincronizar` sem conferir se `arquivo.espaco` ainda é o espaço aberto — `registrar` confere, eles não. Se o espaço muda nesse intervalo (aceitar um convite de equipe com uma conversa pessoal aberta já basta: o detalhe some, o `onDisappear` salva as notas — ver V-02), a conversa é **inserida na lista do novo espaço** e entra na fila do iCloud **da nova equipe**: uma conversa pessoal é enviada inteira para a zona compartilhada. Os outros Macs a ignoram ao baixar (o `espaco` não confere), mas o conteúdo fica na zona.
- **Como resolver:** capturar o espaço e a equipe no início de cada operação e, ao retomar, só tocar em `arquivos` e na fila se `editado.espaco == espaco`; em `sincronizar`, enviar sempre para a equipe dona do `arquivo.espaco`, nunca para "a equipe ativa".

#### CK-15 · Média · Toda operação local espera a tentativa de envio ao iCloud
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:1163-1209`; chamadas em `:358`, `:467`, `:506`, `:666`, `:699`, `:713`, `:732`, `:803`, `:1027`
- **Falha:** `sincronizar` aguarda `retomarSincronizacaoCloudKit()`, que processa **a fila inteira** pela rede antes de devolver o controle. Em equipe, registrar uma gravação só enfileira a transcrição depois dessa tentativa; salvar notas fica em "Salvando…"; mover para a lixeira mantém o cartão bloqueado — tudo no ritmo da rede.
- **Como resolver:** agendar o envio (gravação na fila durável) e devolver na hora; processar a fila numa tarefa separada, única por biblioteca.

#### CK-16 · Média · "Excluir conta" deixa equipes órfãs — no Mac e no iCloud
- **Onde:** `Papagaio/App/ContentView.swift:1002-1039`; `Papagaio/Persistencia/MembrosDasEquipes.swift:34-46`
- **Falha:** a exclusão apaga só o espaço pessoal, mas remove **todos** os vínculos de equipe (`EquipesDoUsuario.remover`). As conversas das equipes continuam no banco e no disco, sem nenhuma entrada que permita abri-las ou apagá-las; e para equipes criadas pela pessoa, a zona e o compartilhamento seguem no iCloud sem que o proprietário tenha mais como administrá-los ou excluí-los (os dados de referência do share só existiam nessa lista local).
- **Como resolver:** na exclusão da conta, oferecer explicitamente "excluir minhas equipes" (zona + marcador) e "sair das equipes de terceiros", apagando os espaços locais correspondentes; nunca descartar a referência de uma equipe própria sem concluir uma das duas ações.

#### CK-17 · Baixa · Para quem é membro, abrir "Gerenciar equipe" grava dados errados da equipe
- **Onde:** `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:383-393`; `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:160-178`; `Papagaio/App/ContentView.swift:818-823`
- **Falha:** quem não é dono só consegue ler o próprio participante, então `participantes` tem um item — e a tela grava `quantidadeDeMembros = participantes.count` na equipe e persiste (`EquipesDoUsuario.salvar`). A equipe que ao entrar mostrava "5 membros" passa a mostrar "1 membro" em todos os seletores, até sair e entrar de novo. Além disso `meuParticipante` devolve `permissao: .escrita` fixo: quem foi rebaixado a somente leitura pelo dono continua vendo "pode editar" na própria linha (e as edições dessa pessoa são recusadas pelo iCloud — ver CK-06).
- **Como resolver:** só atualizar a contagem no ramo do dono (lista completa) ou usar `CKShare.participants.count` no ramo do membro; ler a permissão real em `share.currentUserParticipant?.permission`.

#### CK-18 · Baixa · O nome da equipe vira nome da zona do iCloud
- **Onde:** `Papagaio/App/ContentView.swift:884-900` (`adicionarEquipe`); `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:51-55`, `:373-375` (`nomeDaZona`), `:518-520` (marcador de exclusão)
- **Falha:** o identificador da equipe é o nome digitado (minúsculas, sem acentos, espaços viram hífen) mais seis caracteres, e esse identificador entra no nome da zona (`equipe.<id>`) e de um registro público. A documentação do CloudKit exige nomes de zona e de registro em ASCII, com até 255 caracteres. Conferido executando a mesma derivação: "🚀 Foguete", "設計チーム" e "Straße" geram nomes não ASCII, e um nome de 300 letras gera 314 caracteres; o cliente aceita montar o identificador, então a recusa só viria do servidor, como "Não foi possível criar a equipe no iCloud: <erro técnico>". A resposta do servidor não foi exercitada.
- **Como resolver:** derivar zona e registros só de um UUID (o nome já fica no campo `nome`); validar o nome na tela (tamanho máximo, não vazio).

#### CK-19 · Média · Excluir a equipe não pode ser repetido depois de uma falha no meio
- **Onde:** `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:280-302` (`excluirEquipeGlobalmente`); chamada em `Papagaio/App/ContentView.swift:828-842`
- **Falha:** a exclusão tem quatro passos em bancos diferentes — gravar o marcador público como "preparando", apagar o código, apagar a zona, regravar o marcador como "concluída". O comentário diz que repetir é seguro e o código até tolera a zona já apagada, mas cada tentativa cria um `CKRecord` **novo** com o mesmo ID do marcador e o salva com a política padrão; se o marcador da primeira tentativa já está no servidor, o CloudKit recusa com `serverRecordChanged` logo no primeiro passo. Basta a rede cair uma vez depois do primeiro `save` para a exclusão nunca mais passar. Se a queda foi antes de apagar a zona, a equipe continua existindo e não há como excluí-la pelo app; se foi depois, a zona já saiu, o marcador fica preso em "preparando", o Mac do dono continua mostrando a equipe e os Macs dos participantes nunca recebem o sinal para limpar a cópia local (`equipeFoiExcluida` só aceita "concluída"). Lido no código e conferido contra o comportamento documentado do CloudKit; não exercitado contra o servidor.
- **Como resolver:** buscar o marcador antes (`record(for:)`) e reaproveitar o registro existente, ou salvar com `modifyRecords(saving:…, savePolicy: .changedKeys)`; teste com um transporte falso que falha entre os passos. Ao corrigir CK-01 (quem pode criar o marcador), manter esse caminho de retomada.

### 4.4 Integrações (Google Calendar e Granola)

#### IN-01 · Alta · `prompt=none` impede a primeira conexão ao Google
- **Onde:** `Papagaio/Integracao/SessaoOAuthGoogle.swift:210`
- **Falha:** pela documentação do OAuth do Google, `prompt=none` proíbe telas de login e de consentimento; para quem nunca autorizou o app, o retorno é `error=interaction_required`/`consent_required`, que o app mostra como "Autorização cancelada ou recusada". Só funciona para contas que já tinham consentido antes. *(Não executado aqui — exige credenciais; validar com uma conta nova.)*
- **Como resolver:** usar `prompt=consent` (garante `refresh_token`) no primeiro fluxo, ou omitir o parâmetro; mapear `interaction_required` para uma nova tentativa interativa.

#### IN-02 · Média · Configuração documentada do cliente Google tende a falhar na troca do código
- **Onde:** `Config/SETUP-GOOGLE.md`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:229-235`
- **Falha:** a instrução pede um cliente do tipo *Aplicativo para computador* e o app não envia `client_secret`. Para esse tipo, o endpoint de token do Google exige o segredo (mesmo com PKCE); sem ele responde `client_secret is missing`. *(A confirmar em execução.)*
- **Como resolver:** incluir o `client_secret` do cliente desktop (o Google o trata como não confidencial) via `Secrets.xcconfig`, ou usar cliente do tipo iOS/macOS com redirecionamento por esquema próprio.

#### IN-03 · Média · A renovação forçada do token nunca é usada
- **Onde:** `Papagaio/Integracao/ClienteMCP.swift:129-158`; `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:31`, `:64`, `:102`
- **Falha:** os dois clientes recebem `obterToken(Bool)`, mas sempre chamam com `false`. Um `401` (token revogado ou expirado antes da hora) vira "respondeu algo inesperado" e se repete até a expiração local.
- **Como resolver:** em `401/403`, chamar `obterToken(true)` e repetir a requisição uma vez.

#### IN-04 · Média · Transcrição do Granola vira um único trecho de um só falante
- **Onde:** `Papagaio/Integracao/FonteGranola.swift:166-185`
- **Falha:** só o rótulo inicial (`Me:`/`Them:`) é lido; o resto do texto, com as demais viradas, entra como um trecho de `0` a `0` s atribuído ao primeiro falante. As falas do interlocutor ficam como se fossem do usuário e a conversa tem duração zero.
- **Como resolver:** dividir por `(?m)^\s*(Me|Them)\s*:` em segmentos alternados; guardar a ordem (ver nota abaixo) e estimar tempos quando a fonte não os der.
- **Nota:** `TrechoPersistido` não tem campo de ordem; trechos com o mesmo `start` não têm sequência garantida ao recarregar (`SwiftDataRepository.swift:500`). Acrescentar `ordem` antes de importar vários segmentos sem tempo.

#### IN-05 · Média · Um evento com data inválida derruba a lista do Calendar
- **Onde:** `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:145`, `:197`
- **Falha:** `decodificarEvento` lança `dataInvalida` e o `try` dentro do `compactMap` aborta a página inteira.
- **Como resolver:** devolver `nil` para o evento ruim e registrar no log.

#### IN-06 · Baixa · Sessões OAuth sem exclusão mútua
- **Onde:** `Papagaio/Integracao/SessaoOAuth.swift:79-98`, `:240`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:86-109`, `:198`
- **Falha:** duas chamadas simultâneas com token vencido fazem duas renovações (ou abrem dois navegadores), e o verificador PKCE fica num único item do Keychain — um fluxo sobrescreve o do outro.
- **Como resolver:** transformar as sessões em `actor` com uma `Task` de renovação compartilhada; manter o verificador em memória, por fluxo.

#### IN-07 · Baixa · Granola: *refresh* inválido nunca é limpo
- **Onde:** `Papagaio/Integracao/SessaoOAuth.swift:87-91`, `:274-283`, `:298`
- **Falha:** com `invalid_grant` a sessão falha em toda chamada até a pessoa desconectar manualmente (a versão Google apaga o token); o corpo do pedido de token vai em JSON (a RFC 6749 pede `x-www-form-urlencoded`); os metadados são buscados de novo a cada renovação.
- **Como resolver:** apagar o `refresh_token` em `invalid_grant` e cair no fluxo interativo; usar *form-urlencoded*; guardar os metadados em memória.

#### IN-08 · Baixa · `ClienteMCP` do app
- **Onde:** `Papagaio/Integracao/ClienteMCP.swift:171-188`, `:203-236`
- **Falha:** ignora `result.isError`; não confere o `id` da resposta; junta todos os eventos `data:` de um SSE num JSON só; não reinicializa quando o servidor invalida a sessão (`404`).
- **Como resolver:** tratar `isError` como erro de ferramenta; escolher o evento cujo `id` casa com o pedido; em `404` com sessão, zerar `idSessao`/`inicializado` e repetir.

#### IN-09 · Baixa · Servidor de retorno do Google aceita só a primeira conexão
- **Onde:** `Papagaio/Integracao/SessaoOAuthGoogle.swift:493-540`, `:484-486`
- **Falha:** uma pré-conexão vazia do navegador (ou outro processo local) consome a única tentativa e o fluxo termina em "resposta inválida"; qualquer `error=` vira "autorização cancelada".
- **Como resolver:** continuar aceitando conexões até chegar um `/oauth/callback` com o `state` certo (dentro do tempo limite) e repassar o código de erro real.

#### IN-10 · Baixa · Datas ilegíveis viram "agora" e textos ficam com entidades HTML
- **Onde:** `Papagaio/Integracao/FonteGranola.swift:132`, `:156`, `:305`; `PapagaioCore/…/Integracao/ReuniaoExterna.swift:130-136`
- **Falha:** quando a data não é reconhecida a reunião entra com a data atual, sem aviso; o título vem de atributo sem `desescaparEntidades()` (`R&amp;D`).
- **Como resolver:** manter a data como opcional e mostrar "data desconhecida"; desescapar atributos.

#### IN-11 · Baixa · Falha da transcrição pode impedir a importação da reunião
- **Onde:** `Papagaio/Integracao/FonteGranola.swift:58-61`
- **Falha:** `transcricao = try await transcricaoDaReuniao(id:)` — se o servidor responder com erro JSON-RPC (plano sem transcrição), a reunião inteira não é importada, ao contrário do que o comentário promete.
- **Como resolver:** `try?` e importar com notas e resumo.

#### IN-12 · Baixa · Sem rede na abertura, o Calendar fica em "falhou" e não tenta de novo
- **Onde:** `Papagaio/Integracao/GoogleCalendarViewModel.swift:76-100`, `:152-167`
- **Falha:** a reconexão automática da abertura depende de renovar o token e ler a conta; se a rede não estiver disponível nesse instante, o estado vira `.falhou`, o temporizador de sincronização nem é criado e nada volta a tentar até a pessoa clicar em "Tentar novamente".
- **Como resolver:** distinguir erro de rede de erro de autorização e reagendar a conexão (com espera crescente, ou ao detectar rede com `NWPathMonitor`).

#### IN-13 · Média · Com a sessão do Google vencida, o app abre o navegador sozinho a cada 15 minutos
- **Onde:** `Papagaio/Integracao/GoogleCalendarViewModel.swift:152-181` (temporizador → `carregarReunioes`); `Papagaio/Integracao/SessaoOAuthGoogle.swift:86-109` (`tokenDeAcesso`), `:124-158` (`fluxoDeAutorizacao`), `:281-287` (apaga o *refresh token* em `invalid_grant`)
- **Falha:** `tokenDeAcesso` cai no fluxo interativo sempre que não há token válido nem *refresh token* — e quem a chama, na prática, é o temporizador de sincronização. Quando o Google invalida o *refresh token* (revogação, troca de senha, ou os 7 dias de validade de um cliente em modo de teste), a primeira tentativa o apaga ("fluxo completo na próxima") e, a partir daí, a cada 15 minutos o app sobe um servidor local e abre o navegador numa página de autorização que ninguém pediu, esperando 180 s — com `prompt=none` (IN-01) ela ainda volta com erro. Enquanto isso a tela continua mostrando "conectado". Derivado do código; não executado.
- **Como resolver:** separar "obter token sem interação" (usado por temporizador e chamadas de fundo) de "autorizar" (só no botão Conectar); sem token renovável, passar o estado para "sessão expirada — conectar de novo" e parar o temporizador.

### 4.5 Configuração e assinatura do app

#### AP-01 · Média · *Library validation* desligada
- **Onde:** `Config/Papagaio.entitlements` (`com.apple.security.cs.disable-library-validation`)
- **Falha:** o *hardened runtime* deixa de exigir que as bibliotecas carregadas sejam assinadas pelo mesmo time — abre espaço para injeção de `dylib`. Os frameworks embutidos (whisper, llama, onnxruntime) podem ser reassinados no *Embed & Sign*. No mesmo tema de endurecimento do binário: a configuração Release do app leva `OTHER_LDFLAGS = "-Wl,-export_dynamic"` (`Loro.xcodeproj/project.pbxproj`, posta em todas as configurações por `Scripts/adiciona-target-de-testes.rb:16-20` para os testes hospedados) — a versão distribuída mantém todos os símbolos exportados e sem eliminação de código não usado; o ideal é restringir a opção à configuração Debug.
- **Como resolver:** remover o entitlement e validar que os três frameworks carregam assinados com o time `8CTC75M93B`.

#### AP-02 · Baixa · Textos de permissão: valores antigos no projeto e um sem tradução
- **Onde:** `Loro.xcodeproj/project.pbxproj:461-465`; `Papagaio/InfoPlist.xcstrings`; `Config/Info.plist` (`NSAudioCaptureUsageDescription`)
- **Falha:** *(corrigido na iteração 13 — a primeira versão deste item dizia que os diálogos mostravam "O Papagaio".)* Os quatro `INFOPLIST_KEY_…UsageDescription` do projeto ainda trazem o nome antigo, mas o catálogo `InfoPlist.xcstrings` os substitui em português e em inglês por textos com "Ōmu" — na prática a pessoa não vê o nome antigo; o que sobra é uma fonte desatualizada que voltaria a aparecer se o catálogo fosse removido. O defeito visível é outro: o texto do pedido de captura do áudio do sistema (`NSAudioCaptureUsageDescription`) existe só no `Info.plist`, em português, e não está no catálogo — com o Mac em inglês, esse diálogo aparece em português.
- **Como resolver:** atualizar os quatro valores do projeto para o mesmo texto do catálogo e incluir `NSAudioCaptureUsageDescription` no `InfoPlist.xcstrings` com a tradução.


#### AP-03 · Baixa · Falha ao abrir a biblioteca não tem saída
- **Onde:** `Papagaio/App/ContentView.swift:590-592`
- **Falha:** se `Biblioteca()` lançar (banco não abre), sobra só uma faixa de erro; não há "tentar de novo" nem diagnóstico.
- **Como resolver:** botão de nova tentativa e opção de exportar/renomear o banco danificado.

#### AP-04 · Média · ⌘N abre uma segunda janela com uma segunda biblioteca inteira
- **Onde:** `Papagaio/App/PapagaioApp.swift:86-122` (`WindowGroup` sem `.commands`); `Papagaio/App/ContentView.swift:48`, `:465-582` (cada janela cria a sua `Biblioteca` e reatribui os retornos do gravador); `Papagaio/ViewModels/Biblioteca.swift:164-209`; `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:30-36`, `:204-220`
- **Falha:** a cena é um `WindowGroup`, que ganha "Nova Janela" (⌘N) no menu Arquivo, e nada o remove. Cada janela monta um `ContentView` com `@State` próprio: uma segunda `Biblioteca` sobre o mesmo banco, com fila de processamento, motores (Whisper e Qwen) e `FilaPersistenteCloudKit` próprios. Consequências: a mesma conversa pode ser processada em paralelo nas duas janelas, com os modelos carregados duas vezes (M-06 já mostra como a memória é justa); as duas filas do iCloud guardam o arquivo em memória e uma sobrescreve as operações pendentes da outra; `gravador.aoProduzirAudio` passa a apontar para a janela aberta por último, e a gravação termina registrada só nela; uma janela não vê as mudanças da outra. O macOS ainda pode restaurar as duas janelas na próxima abertura. Derivado do código; não executado.
- **Como resolver:** trocar por uma cena de janela única (`Window`) ou remover o comando com `CommandGroup(replacing: .newItem) {}`; subir `Biblioteca` e as integrações para o nível do app, para existirem uma vez só.

### 4.6 Dados auxiliares, anexos e privacidade

#### PS-01 · Média · Anexos de conversas sem áudio ficam fora de `Gravacoes/`
- **Onde:** `Papagaio/ViewModels/Biblioteca.swift:1310-1315`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:133`; `Papagaio/Persistencia/LixeiraDeMidia.swift:267-300`; `PapagaioCore/…/Persistencia/SwiftDataRepository.swift:358-360`
- **Falha:** para conversas sem áudio (Granola, conversas de colegas) a "pasta da conversa" é `…/MidiaIndisponivel/<id>/`. Consequências: (a) um anexo enviado à lixeira não pode ser restaurado nem apagado — `validarCaminhos` exige `Gravacoes/<conversa>`; (b) ao apagar a conversa ou a conta, essa pasta e os anexos continuam no disco, porque só `pastaRelativa` não vazia é removida.
- **Como resolver:** dar a toda conversa uma pasta real em `Gravacoes/<id>` (criada sob demanda para anexos) e apagar por ID, não por `pastaRelativa`.

#### PS-02 · Média · Tarefas e outros dados do usuário vivem em `UserDefaults`
- **Onde:** `Papagaio/Persistencia/TarefasGeraisStore.swift`, `TarefasDaConversa.swift`, `MidiasDaConversa.swift`, `PreferenciasVisuaisDoArquivo.swift`, `LixeiraDe*.swift`
- **Falha:** tarefas, anexos, ficha da entrevista, favoritos e lixeiras são blobs JSON em preferências, uma chave por conversa. (a) Se um blob não decodificar (mudança de formato), `carregar` trata como "sem tarefas", recria as sugestões do resumo e **grava por cima** das tarefas da pessoa; (b) nada disso entra na sincronização de equipe — colegas não veem tarefas nem ficha; (c) não há transação com o SwiftData; (d) as duas lojas de tarefas escrevem na mesma chave com lógicas de criação duplicadas.
- **Como resolver:** mover para modelos SwiftData ligados ao `ArquivoPersistido` (e ao payload do CloudKit); nunca sobrescrever em erro de leitura; unificar as duas lojas.

#### PS-03 · Média · O *prompt* de nomes consulta Contatos e Calendário em todo processamento
- **Onde:** `Papagaio/Suporte/PromptDeEntidades.swift:26-46`, `:63-80`; chamado em `Papagaio/ViewModels/Biblioteca.swift:967`
- **Falha:** (a) o pedido de acesso a Contatos e Calendário aparece no meio da primeira transcrição automática, sem explicação nem opção nos Ajustes; (b) todos os contatos são lidos a cada conversa; (c) o corte é `sorted().prefix(40)` sobre contatos + calendário juntos — ficam os 40 primeiros **em ordem alfabética**, que quase nunca são os participantes da reunião, e os nomes do evento são descartados; (d) nomes aleatórios no `initial_prompt` puxam o Whisper para grafias erradas.
- **Como resolver:** tornar opcional (preferência explícita); priorizar participantes do evento e da ficha; usar contatos só para casar nomes já candidatos.

#### PS-04 · Média · O canal do sistema ocupa ~1,4 GB por hora
- **Onde:** `PapagaioCore/…/Captura/SystemAudioTap.swift:136-143`, `:357-393`
- **Falha:** `sistema.caf` é gravado no formato nativo do tap (em geral Float32, 48 kHz, estéreo ≈ 384 KB/s) e fica assim para sempre; com o microfone, uma reunião de uma hora chega a ~1,5 GB (mais 230 MB se o cancelamento de eco for ligado — P-04). Exportar/duplicar multiplica isso.
- **Como resolver:** depois de `parar()` (fora do tempo real), converter para ALAC/AAC ou PCM 16 bits mono; manter o original só até a transcrição terminar.

#### PS-05 · Baixa · Lixeira de mídia guarda caminhos absolutos
- **Onde:** `Papagaio/Persistencia/LixeiraDeMidia.swift:58-68`, `:105-110`
- **Falha:** `caminhoOriginal`/`caminhoNaLixeira` são absolutos; se o caminho do container mudar (outro usuário, restauração, migração), nenhum item pode ser restaurado ou apagado.
- **Como resolver:** guardar caminhos relativos à raiz do `Armazenamento`.

#### PS-06 · Baixa · Estado das reuniões do Calendar cresce sem limite
- **Onde:** `Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:52-64`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:274-292`
- **Falha:** todo evento já visto é guardado para sempre (título, descrição, nomes e e-mails dos participantes); a cada sincronização o dicionário inteiro é decodificado e regravado uma vez por evento.
- **Como resolver:** podar registros `ativa` fora da janela; acumular as mudanças e gravar uma vez por sincronização.

#### PS-07 · Baixa · "Excluir conta" deixa resíduos
- **Onde:** `Papagaio/Persistencia/LimpezaDeConta.swift:26-43`; `Papagaio/ViewModels/PerfilViewModel.swift:103-116`
- **Falha:** ficam no Mac as chaves `fotoDaPessoa.<nome>` (nomes de entrevistados), `cacheNomePorEmail` (nomes e e-mails de participantes do Calendar), `falantePreservado.<id>` de cada conversa apagada (`FalantePreservadoParaTrecho.limpar` nunca é chamado), os anexos de PS-01 e as pastas; o consentimento do *Sign in with Apple* não é revogado (a diretriz 5.1.1(v) da App Store pede a revogação na exclusão de conta).
- **Como resolver:** incluir essas lojas na cascata; documentar/implementar a revogação (exige serviço próprio) ou orientar a pessoa a revogar em Ajustes.

#### PS-08 · Baixa · Pequenos defeitos nas lojas auxiliares e nos modelos
- **Onde e falha:**
  - `Papagaio/Suporte/ListaDePessoas.swift:12-17` — `nomesDePessoas` separa também por vírgula, enquanto o formulário, a contagem de participantes e a migração de fotos separam só por linha: um nome como "Silva, Ana" (formato comum em diretórios corporativos e no Calendar) vira duas pessoas nos avatares e nos rótulos, e uma só na contagem.
  - `Papagaio/Persistencia/PreferenciasVisuaisDoArquivo.swift:50-70`; `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1397-1402`; `BibliotecaHomeView.swift:1050-1057` — `criarPasta` trata "Cliente X" e "cliente x" como a mesma pasta, mas o rótulo da conversa e a pasta aberta guardam o texto como foi digitado, e as comparações são exatas: a conversa fica com um selo de pasta que não está em pasta nenhuma, e "Criar pasta" abre uma pasta fantasma vazia.
  - `Papagaio/ViewModels/PerfilViewModel.swift:118-129` — campo vazio é trocado pelo valor anterior: não dá para apagar o nome ou o e-mail do perfil, e a tela restaura o texto antigo sem explicar.
  - `Papagaio/Modelos/AnexoDeMidiaDaConversa.swift:11-18` — o tipo do anexo vem de listas fixas de extensão: `webp`, `heif`, `tif`, `mkv`, `webm`, `flac`, `aac`, `caf` e `ogg` caem em "Arquivo" e somem dos filtros por tipo.
  - `Papagaio/Modelos/ReuniaoPendenteCalendar.swift:38-47` — o fim da reunião não é guardado; o estado assume uma hora de duração, então a segunda hora de uma reunião de duas aparece como "pendente", em vermelho.
  - `Papagaio/Suporte/DossieDaConversa.swift:18-22`, `:56-90`, `:177-188`, `:283-293` — a exportação lista como tarefas as sugestões ainda não aceitas (com o prazo inventado de B-14 e o responsável cru, inclusive o literal "null"); "Baixar" de uma conversa deixa de fora os anexos que "Baixar" de uma pasta inclui; e a exportação da pasta inteira falha se dois anexos da mesma conversa tiverem o mesmo nome (eles vivem em subpastas com o título da época, e todos são copiados para uma única pasta "Mídia").
  - `Papagaio/Persistencia/FotosDePessoas.swift:54-64`; `AparenciaDoCartao.swift:93-103`; `AparenciaDasPastas.swift:246-256` — foto, banner e capa são um *bookmark* para o arquivo original; quando ele não resolve (volume desmontado, arquivo movido para fora do alcance), a associação é apagada de vez — o mesmo padrão de M-04.
  - `Papagaio/ViewModels/Biblioteca.swift:763-779`; `Papagaio/Persistencia/PreferenciasVisuaisDoArquivo.swift:223-250` — "Duplicar" recria os trechos só com tempo, texto, canal e palavras: a confiança e o indicador de "sem fala" de cada trecho, o falante preservado (guardado pelo id do trecho) e a cor ou o banner do cartão não vão para a cópia.
  - `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:199-209`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:262-296` — a resposta da pessoa ao convite é lida (`responseStatus`) e nunca usada: reuniões que ela recusou continuam aparecendo em "Próximas 24h".
- **Como resolver:** um único separador para nomes; normalizar o nome da pasta para a grafia já cadastrada antes de gravar o rótulo; permitir limpar os campos do perfil; classificar anexos por `UTType`; guardar o horário de término do evento; exportar só tarefas aceitas, com `responsavelValido`, e nomes únicos na pasta "Mídia"; copiar as imagens escolhidas para o contêiner do app em vez de depender do arquivo original.

#### PS-09 · Baixa · O e-mail da conta do Granola vai em claro para o log do sistema
- **Onde:** `Papagaio/Integracao/GranolaViewModel.swift:88`
- **Falha:** `registro.info("Conectado: \(conta.email, privacy: .public)")` marca o e-mail como público. No log unificado do macOS isso fica legível no Console, em `log show` e em qualquer *sysdiagnose* enviado a terceiros. É o único dado pessoal marcado como público no app (as outras oito ocorrências de `.public` são mensagens de erro e endereços de servidor).
- **Como resolver:** tirar o `privacy: .public` (o padrão já oculta) ou registrar só "Conectado".

### 4.7 Telas

#### V-01 · Média · "Baixar" e "Compartilhar" do cartão travam a janela e engolem erros
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1430-1454`, `:1456-1478`
- **Falha:** `DossieDaConversa.pacoteComAudio` (cópia do áudio + zip, até gigabytes) roda na thread principal — a tela de detalhe já usa `Task.detached`, o cartão não. Em `baixar()`, o pacote é montado **antes** de a pessoa escolher a pasta, todos os erros passam por `try?` (falhou = nada acontece) e o zip temporário nunca é descartado. Mesma família: `Papagaio/ViewModels/MidiasDaConversaViewModel.swift:88-112` copia o anexo escolhido na thread principal — um vídeo de vários gigabytes vindo de outro disco congela a janela até a cópia terminar.
- **Como resolver:** escolher o destino primeiro; empacotar em segundo plano com indicador; mostrar o erro; chamar `descartarArquivoTemporario` no fim.

#### V-02 · Média · Fechar uma conversa sempre regrava e reenvia a conversa inteira
- **Onde:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:517-523`, `:1375-1385`; `Papagaio/ViewModels/Biblioteca.swift:705-717`
- **Falha:** o `onDisappear` chama `salvarNotasAgora()` mesmo sem alteração. Cada abertura de conversa termina em `repositorio.salvar` (reescreve todos os trechos) e, em equipe, num novo envio ao iCloud com revisão nova — o que ainda marca a conversa como "edição local pendente" e faz o próximo conflito favorecer quem só leu (ver CK-07). As notas gravadas são as carregadas na abertura, então mudanças vindas de fora nesse intervalo são desfeitas.
- **Como resolver:** marcar "sujo" ao editar e salvar só nesse caso.

#### V-03 · Baixa · "Salvar em…" apaga o destino antes de copiar
- **Onde:** `Papagaio/Suporte/OpcoesDeCompartilhamento.swift:28`, `:45-48`
- **Falha:** se a cópia falhar depois do `removeItem`, o arquivo que já existia no destino se perdeu; o título do serviço não passa por `.localized`.
- **Como resolver:** copiar para um temporário ao lado e usar `replaceItemAt`.

#### V-04 · Baixa · Download dos modelos sem retomada automática
- **Onde:** `Papagaio/ViewModels/ModelosViewModel.swift:94-113`
- **Falha:** qualquer queda de rede encerra o download de 9 GB com `"\(error)"`; cancelar pode exibir o erro de cancelamento do `URLSession` (só `CancellationError` é tratado). Além disso, `cancelar()` (`:150-155`) zera o estado sem esperar a tarefa antiga: se a pessoa clicar em "Baixar" de novo antes de ela terminar, o fim da tarefa antiga desliga `baixando` e `progresso` do download novo — o botão "Baixar" reaparece com um download em curso e um novo clique inicia um segundo download do mesmo arquivo.
- **Como resolver:** repetir com espera crescente (o `Range` já existe); tratar `URLError.cancelled` como cancelamento.

#### V-05 · Média · "Gerar novo resumo" refaz a transcrição e apaga as correções manuais
- **Onde:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1112-1117`; `Papagaio/App/ContentView.swift:650-653`; `Papagaio/Funcionalidades/Biblioteca/MenuDeArquivoAberto.swift:42-47`; `PapagaioCore/…/Processamento/PipelineDeArquivo.swift:120-126`
- **Falha:** o botão e o item "Reprocessar" chamam `enfileirarProcessamento`, que roda o pipeline inteiro — inclusive o Whisper — e grava `trechos` novos. Trechos corrigidos à mão, falas fundidas e os falantes preservados são descartados, sem pedido de confirmação; os nomes dados às vozes continuam presos aos rótulos antigos (`S1`, `S2`…), que a nova diarização pode atribuir a outras pessoas. Não existe caminho para resumir a transcrição **já editada**, embora o comentário de `Biblioteca.atualizarTrechos` diga que é isso que o reprocessamento faz. Em conversas sem áudio (Granola, equipe) a ação está habilitada e termina em erro "não há áudio".
- **Como resolver:** criar `PipelineDeArquivo.resumirExistente(_:)` (só Qwen sobre os trechos atuais) e ligá-lo a "Gerar novo resumo"; pedir confirmação em "Reprocessar" quando houver edição manual; desabilitar as duas ações sem áudio.

#### V-06 · Média · A lixeira promete apagar em 30 dias e nada apaga
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:451`; `Papagaio/Funcionalidades/Biblioteca/Lixeira/CartaoDaLixeira.swift:36-45` (e os cartões de mídia, pasta e tarefa)
- **Falha:** o subtítulo diz "serão removidos permanentemente após 30 dias" e cada cartão mostra a contagem ("Exclui em 12 dias", "Exclui hoje"), mas não há rotina de expurgo: só `apagarDefinitivamente`/`esvaziarLixeira`, acionadas à mão. Áudio e transcrições "excluídos" ficam no disco indefinidamente.
- **Como resolver:** expurgar em `Biblioteca.preparar()` (e uma vez por dia) os itens com `apagadoEm` há mais de 30 dias, cobrindo conversas, mídia, pastas e tarefas — ou remover a promessa do texto.

#### V-07 · Baixa · Três cópias da gravação da ficha, com regras diferentes
- **Onde:** `Papagaio/App/ContentView.swift:677-724`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:925-949`; `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1273-1308`
- **Falha:** as três salvam os mesmos metadados, mas divergem: o cartão grava `participantes = nil` quando não há nomes, as outras duas gravam `1`; o editor do detalhe não chama `FotosDePessoas.migrarAoEditarNomes`, então corrigir um nome por ali solta a foto da pessoa.
- **Como resolver:** uma função única (`FichaDaEntrevista.salvar(para:)`) usada pelos três pontos.

#### V-08 · Baixa · A transcrição recalcula tudo a cada tique do player
- **Onde:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:164-172`, `:202-233`, `:1466`, `:1526-1532`, `:1562`
- **Falha:** `falas`, `ocorrenciasDaBusca`, `vozesAcusticas`, `nomesDeVoz` e `metadados` são propriedades calculadas lidas várias vezes por avaliação do `body`, e o `body` depende de `reprodutor.tempo` (10 Hz). Em uma hora de conversa isso refaz o agrupamento de ~9.000 palavras, varre a busca e decodifica JSON do `UserDefaults` dezenas de vezes por segundo; `transcricaoDeTrechos` ainda faz `firstIndex(where:)` por linha (quadrático). Pior: o `.fileExporter(document: DocumentoMarkdown(conteudo: DossieDaConversa.gerar(arquivo: arquivo)))` (`:524-531`) monta o Markdown inteiro da conversa — transcrição, anexos com *bookmarks* e tarefas, lidas (e, na primeira vez, gravadas) do `UserDefaults` — em toda avaliação do `body`, e `mostrandoExportador` (`:55`) nunca passa a `true`: é um exportador que ninguém consegue abrir e que custa a cada quadro.
- **Como resolver:** guardar `falas` e o resultado da busca em `@State`, recalculando só quando `trechos`/termo mudam; isolar a leitura de `tempo` numa subview pequena; passar o índice pelo `enumerated()`.

#### V-09 · Baixa · Editar uma fala que divide um trecho deixa tempos incoerentes
- **Onde:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1662-1737`
- **Falha:** o pedaço restante do trecho mantém o `start`/`end` do trecho original e a fala editada nasce com `start = fala.inicio`; quando os dois começam no mesmo instante, a ordem depois de recarregar não é garantida (o banco ordena só por `start`), e o destaque do player usa intervalos que já não correspondem ao texto.
- **Como resolver:** recalcular `start`/`end` do restante a partir das palavras que sobraram e persistir uma ordem explícita (ver nota em IN-04).

#### V-10 · Baixa · As citações do resumo não aparecem em tela nenhuma
- **Onde:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1063-1135`
- **Falha:** o modelo é instruído a extrair até três citações e o Core as valida contra a transcrição, mas a aba Resumo mostra só visão geral e temas; as citações existem apenas na busca e no Markdown exportado.
- **Como resolver:** exibir a seção (com salto para o instante) ou tirar as citações do prompt para economizar tokens.

#### V-11 · Baixa · A busca da biblioteca varre todas as transcrições a cada tecla
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:338-442`
- **Falha:** `arquivosFiltrados` ordena a lista e, por conversa, decodifica a ficha do `UserDefaults`, formata datas e percorre todos os trechos com comparação insensível a acento — tudo na thread principal e a cada avaliação do `body`.
- **Como resolver:** aplicar *debounce* ao termo, pré-normalizar um índice de texto por conversa e calcular fora da *main*.

#### V-12 · Baixa · Pastas são globais entre perfil e equipes
- **Onde:** `Papagaio/Persistencia/PreferenciasVisuaisDoArquivo.swift:60-70`; `Papagaio/Funcionalidades/Biblioteca/PastasDaBiblioteca.swift:28-45`
- **Falha:** a lista de pastas e os rótulos vivem em chaves únicas do `UserDefaults`. Apagar a pasta "Cliente X" no perfil pessoal move para a lixeira só as conversas desse espaço, mas remove o rótulo também das conversas da equipe que usavam o mesmo nome. (No mesmo arquivo, `renomearPasta` recusa mudar só maiúsculas/minúsculas do nome, e `LixeiraDeTarefas.restaurar` não faz nada — sem aviso — quando a conversa da tarefa não está na lista atual.)
- **Como resolver:** prefixar as chaves com o `EspacoID`.

#### V-13 · Baixa · `biblioteca!` em Configurações depende da ordem de inicialização
- **Onde:** `Papagaio/Funcionalidades/Configuracoes/ConfiguracoesView.swift:505`, `:530`
- **Falha:** o desembrulho forçado só é seguro porque `ContentView.abrir()` atribui `biblioteca` antes de `googleCalendar`; inverter essas duas linhas derruba o app no clique de "Conectar".
- **Como resolver:** `guard let biblioteca` e botão desabilitado enquanto for `nil`.

#### V-14 · Baixa · Compartilhar fica bloqueado sem resumo
- **Onde:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:651-660`
- **Falha:** conversas cujo resumo falhou (ou importadas sem resumo) não podem ser compartilhadas pela tela de detalhe, embora transcrição e notas existam.
- **Como resolver:** habilitar quando houver qualquer conteúdo exportável.

#### V-15 · Alta · A tela de detalhe trabalha sobre uma cópia que nunca é atualizada
- **Onde:** `Papagaio/App/ContentView.swift:631-638`, `:1198-1252` (`ArquivoCompletoCarregado`); efeitos em `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:164`, `:349-351`, `:1626-1654`, `:1662-1731`
- **Falha:** desde o commit `738b566` ("perf(E004): defer word decoding in library lists", 29/09/2026) o detalhe deixou de ler `biblioteca.arquivo(id:)` e passou a receber um `Arquivo` carregado **uma vez** por `.task(id: id)`. Nada o recarrega quando a biblioteca muda. Consequências: (a) se o processamento termina com a conversa aberta, transcrição e resumo não aparecem; o estado volta a "pronto para transcrever" e o botão "Transcrever" reaparece — clicar refaz tudo; (b) depois de editar título ou ficha, o cabeçalho continua com o valor antigo; (c) ao corrigir um trecho, a tela continua mostrando o texto antigo e a correção seguinte é calculada sobre a lista velha (`trechos.map { … }`), **sobrescrevendo a correção anterior**. O `onChange(of: trechos)` que existia para atualizar o player nunca mais dispara.
- **Como resolver:** recarregar a versão completa quando a conversa mudar — por exemplo um contador de revisão por arquivo na `Biblioteca` (incrementado em `substituir`) usado em `.task(id:)`, ou fazer `substituir` publicar a versão completa e o detalhe voltar a ler da biblioteca. Acrescentar um teste que edita dois trechos em sequência e confere os dois.

#### V-16 · Média · O título do resumo sempre se sobrepõe ao título dado pela pessoa
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:123`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:93`; `PapagaioCore/…/Processamento/PipelineDeArquivo.swift:193-198`
- **Falha:** toda a interface mostra `arquivo.resumo?.titulo ?? arquivo.titulo`, e o pipeline grava o título que o modelo inventou a cada resumo. Um título digitado antes de o resumo existir (na ficha, ou vindo do evento do Calendar) é substituído na tela quando o processamento termina; depois de renomear, "Gerar novo resumo"/"Reprocessar" troca o título de novo. Nada registra que o título foi escolhido pela pessoa.
- **Como resolver:** guardar a origem do título (automático × manual); usar o do resumo só enquanto for automático, e preservar o manual em reprocessamentos.

#### V-17 · Baixa · O cartão da lixeira despeja a transcrição inteira
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/Lixeira/CartaoDaLixeira.swift:11-18`, `:83-87`
- **Falha:** sem resumo, a descrição do cartão é `trechos.map(\.texto).joined(…)` exibida sem `lineLimit` e com `fixedSize(vertical: true)`: uma conversa de uma hora na lixeira vira um cartão com milhares de palavras, e o texto é remontado a cada redesenho.
- **Como resolver:** limitar a um trecho inicial (`prefix`) e a 3–4 linhas, como o cartão da biblioteca.

#### V-18 · Baixa · O avatar da conta é lido do disco e decodificado a cada redesenho
- **Onde:** `Papagaio/DesignSystem/Componentes/BotoesDaBarra.swift:9-16` (`AvatarDaContaNaBarra`, na barra superior de todas as telas); `Papagaio/Funcionalidades/Perfil/ComponentesDoPerfil.swift` (`AvatarDoPerfil`, usado em `CartaoDeIdentidadeDoPerfil.swift:29`)
- **Falha:** nas duas vistas a foto é uma propriedade calculada que faz `NSImage(contentsOf: url)` — leitura de arquivo e decodificação em tamanho original, na *main thread* — toda vez que o `body` é avaliado, sem cache nem redução. A barra superior é reavaliada a cada mudança de estado da janela (busca, troca de aba, popovers), então uma foto de vários megabytes é relida continuamente para ocupar um círculo de poucos pontos. As fotos de participantes já resolvem isso com cache (`FotosDePessoas.imagem(de:)` + `MiniaturaDeImagem.reduzir`); o avatar da conta ficou de fora. Mesma família: `Papagaio/Funcionalidades/Detalhe/Midia/PreviaDoAnexoDeMidia.swift:64-68` guarda a imagem em tamanho original como miniatura de cada cartão da grade de mídias, em vez de pedir uma miniatura reduzida como faz para os outros tipos.
- **Como resolver:** passar pelo mesmo caminho das outras fotos: um cache (`NSCache` por URL + data de modificação) que guarda a miniatura já reduzida por `MiniaturaDeImagem.reduzir`, invalidado quando a pessoa troca a foto.

#### V-19 · Baixa · Tabela de participantes: erros escondidos e página fora do intervalo
- **Onde:** `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:209-227`, `:378-434`; `Papagaio/Funcionalidades/Equipes/TabelaDaEquipe.swift:14-18`, `:76-86`
- **Falha:** (a) falha ao renomear ou alterar permissão grava `erroDosParticipantes`, que aparece atrás da folha ainda aberta — "Salvar" parece não fazer nada, e ao fechar a folha a tabela inteira foi trocada pela mensagem, até apertar "Atualizar"; (b) não há estado "salvando": dois cliques enviam duas vezes; (c) o erro nunca é limpo no sucesso — trocar de equipe durante a carga cancela a primeira chamada, cujo erro pode chegar depois do `erro = nil` da segunda e ficar na tela com a lista já carregada; (d) depois de remover alguém a página não é reajustada: se a última página esvaziar, a tabela fica vazia com "4 de 4 membros" e só o botão "anterior" ativo.
- **Como resolver:** erro e estado de andamento próprios em cada folha; limpar `erroDosParticipantes` no sucesso e ignorar `CancellationError`; `pagina = min(pagina, ultimaPagina)` depois de cada carga.

#### V-20 · Baixa · A página de Mídias relê anexos e resolve *bookmarks* várias vezes por redesenho
- **Onde:** `Papagaio/Funcionalidades/Midias/MidiasView.swift:45-59` (`midiasPorConversa`), consultada em `:131`, `:135`, `:200`, `:221` e, por `conversasVisiveis`/`midiasVisiveis`, em `:240`, `:253`, `:282`, `:306`; `Papagaio/Persistencia/MidiasDaConversa.swift:28-50`
- **Falha:** `midiasPorConversa` é uma propriedade calculada: para cada conversa da biblioteca lê o `UserDefaults`, decodifica JSON e resolve um *bookmark* com escopo de segurança por anexo. O `body` a consulta cerca de dez vezes por avaliação, e a tela é reavaliada a cada tecla da busca e a cada clique de filtro — com biblioteca grande, buscar em Mídias engasga. Efeito colateral do mesmo desenho: quando o último anexo de uma conversa selecionada sai, o id continua em `conversasSelecionadas`; o cartão da conversa some do seletor e o título da grade vira "1 conversas selecionadas", até "Limpar seleção". O painel de Tarefas repete o desenho (`TarefasView.swift:52-64` é recalculada em cada uso dentro do `body`, e `:565-570` tem a mesma seleção órfã), só que lendo de um cache em memória.
- **Como resolver:** carregar uma vez por mudança (`@State` recarregado em `.task(id:)` com `versaoDasMidias` e a lista de arquivos) e derivar os filtros desse valor; ao recarregar, interseccionar `conversasSelecionadas` com os ids que ainda têm mídia.

#### V-21 · Baixa · Pequenos defeitos de interface encontrados na leitura integral das telas
- **Onde e falha:**
  - `Papagaio/Funcionalidades/Perfil/CartaoDeIdentidadeDoPerfil.swift:49` — sem e-mail no perfil, o cartão mostra "email@exemplo.com" como se fosse o dado da pessoa.
  - `Papagaio/DesignSystem/Componentes/SeletorDeContextoDaConta.swift:155` — o nome da equipe passa por `.localized`: com o sistema em inglês, uma equipe chamada "Tarefas" aparece como "Tasks" no menu da conta e como "Tarefas" no resto do app.
  - `Papagaio/DesignSystem/Componentes/BotaoDeAjudaPapagaio.swift:43-54` — o "i" abre um *popover* ao passar o mouse e também tem `.help` com o mesmo texto: depois de um segundo os dois balões aparecem sobrepostos.
  - `Papagaio/Funcionalidades/Gravacao/NotasDuranteGravacao.swift:145-152` — começar a editar outra nota descarta, sem aviso, o que estava sendo digitado na primeira.
  - `Papagaio/Funcionalidades/Detalhe/Player/BarraDeAudioDaConversa.swift:205`, `:282` — os formatos `%.2gx` e `%.1fx` arredondam os rótulos de velocidade: o menu mostra "1.2x" para 1,25 e o botão mostra "0.8x" para 0,75 (conferido executando os dois formatos). `alternarVelocidade()` (`:285-290`) não é chamada por ninguém.
  - `Papagaio/Funcionalidades/Detalhe/NotasDaConversa.swift:49-58`, `:379-384` — com um filtro de `#etiqueta` ativo, apagar a etiqueta enquanto edita a nota faz a linha sumir no meio da digitação.
  - `Papagaio/Funcionalidades/Configuracoes/ConfiguracoesView.swift:192-194` — a dica de acessibilidade "novos áudios não entram na fila até você selecionar Transcrever" está presa ao alternador "Exibir ficha automaticamente", não ao de pausar o processamento: o VoiceOver descreve o controle errado.
  - `Papagaio/Funcionalidades/Configuracoes/ConfiguracoesView.swift:407`, `:479-482` — só as 20 primeiras reuniões do Granola são listadas, sem "ver mais" nem aviso; e, se a importação salvar ao menos uma, todas as marcadas são desmarcadas, inclusive as que falharam.
  - `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:1226-1232`, `:1246-1249`, `:1261-1264` — na lixeira, apagar de vez um anexo, uma tarefa ou uma pasta acontece no primeiro clique; só a conversa pede confirmação (e, na página de Mídias, o mesmo anexo pede).
  - `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:866`, `:1017-1036` — "Esvaziar lixeira" e "Restaurar tudo" não alcançam as reuniões ignoradas do Calendar, e os dois botões ficam desabilitados quando só elas estão na lixeira.
  - `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:717-745` — o "i" da data repete o par *popover* + `.help` do botão de ajuda.
  - `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:234-240`, `:269`, `:285` — a busca na transcrição anuncia "Ocorrência anterior (Shift+Enter)", mas não existe esse atalho (Shift+Enter cai no mesmo `onSubmit` e vai para a próxima); e, antes de digitar, a barra mostra "0 ocorrências".
  - `Papagaio/ViewModels/Biblioteca.swift:1084` — sem os modelos de diarização no pacote, a mensagem mostrada à pessoa manda rodar `Scripts/bootstrap-runtimes.sh`, uma instrução de desenvolvimento.
- **Como resolver:** texto neutro ("Sem e-mail") no cartão; formatar a velocidade com `%g`; manter visível a nota em edição mesmo fora do filtro; mover a dica para o alternador certo; paginar a lista do Granola e desmarcar só o que foi salvo; pedir confirmação em toda exclusão definitiva e incluir as reuniões ignoradas nas ações da lixeira; não localizar conteúdo digitado pela pessoa; manter só o *popover* (o `accessibilityHint` já cobre leitores de tela); concluir a edição pendente antes de abrir a próxima.

#### V-22 · Baixa · Ajustar o volume com a roda do mouse não funciona
- **Onde:** `Papagaio/DesignSystem/Componentes/RodaDoMouse.swift:27-45`; uso em `Papagaio/Funcionalidades/Detalhe/Player/BarraDeAudioDaConversa.swift:231-235`
- **Falha:** a `NSView` que deveria capturar a rolagem devolve `nil` em `hitTest` (para não roubar cliques) e é aplicada como `background`. O comentário diz que o AppKit entrega `scrollWheel` "pela cadeia de responders mesmo sem hit testing", mas a cadeia sobe da view atingida para as *superviews* — uma view folha que nunca é atingida não está nela. Reproduzido fora do app com cópia fiel do componente: com `hitTest → nil` a view atingida é a `NSHostingView` e `scrollWheel` chega 0 vezes; com o `hitTest` padrão (controle) chega 1 vez. Não foi exercitado com mouse real dentro do app. Mesmo sem o `nil`, como *background* ela só seria atingida nos vãos entre os controles.
- **Como resolver:** capturar com `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` instalado em `viewDidMoveToWindow`, consumindo o evento só quando o ponteiro estiver dentro dos limites da view (e removendo o monitor ao sair da janela).

#### V-23 · Baixa · Trocar a conversa ao editar uma tarefa duplica a tarefa
- **Onde:** `Papagaio/Funcionalidades/Tarefas/EditorDeTarefaGeralSheet.swift:52-81`; `Papagaio/Funcionalidades/Tarefas/TarefasView.swift:753-783`; `Papagaio/ViewModels/TarefasDoPainelViewModel.swift` (`salvar(_:em:substituindo:)`)
- **Falha:** no painel geral o editor deixa escolher outra conversa também no modo de edição. `salvar` procura a tarefa pelo id na lista da conversa **nova**; como não acha, cai no `append` — e a original continua na conversa antiga. Resultado: a mesma tarefa (mesmo UUID) em duas conversas, cada cópia evoluindo sozinha. Além disso a edição reconstrói a tarefa do zero e marca `prioridadeDefinidaManualmente: true` mesmo quando a pessoa não tocou na prioridade.
- **Como resolver:** ao salvar com conversa diferente, remover da conversa de origem antes de inserir na nova (ou travar o seletor de conversa na edição); editar por mutação da tarefa existente, como faz `TarefasDaConversaViewModel.salvarEdicao`.

#### V-24 · Baixa · Tarefas ocultas e coluna "Atrasada" não fazem o que a tela indica
- **Onde:** `Papagaio/Persistencia/TarefasOcultasStore.swift`; `Papagaio/Funcionalidades/Detalhe/Tarefas/TarefasDaConversaView.swift:23`, `:82-89`; `Papagaio/Funcionalidades/Tarefas/TarefasView.swift:42`, `:421-427`, `:503-512`, `:790-796`; `Papagaio/Funcionalidades/Tarefas/ColunaDeTarefasGerais.swift:23-27`; `Papagaio/ViewModels/TarefasDoPainelViewModel.swift` (`mover`)
- **Falha:** (a) as duas telas gravam na mesma loja com chaves de formatos diferentes — a aba da conversa usa `tarefa.id.uuidString`, o painel geral usa `"<conversa>-<tarefa>"`. Ocultar numa não oculta na outra, mas o painel conta todas as entradas: o botão "Ocultas" aparece e mostra "N ocultas" mesmo sem nada oculto ali; a loja nunca é podada (tarefas excluídas ficam) e é global entre perfil e equipes. (b) A coluna "Atrasada" aceita soltura ("Solte uma tarefa aqui") com destino "Não iniciado", e o comentário diz que a tarefa vencida "volta para cá no próximo recálculo" — mas `mover` grava `atrasoReconhecido = true`, então ela nunca volta: soltar em "Atrasada" sempre manda para "Não iniciado" e ainda desliga o aviso de atraso. O parâmetro `permiteSoltar`, documentado como `false` para essa coluna, nunca é passado. (c) O aviso "vence em … e foi marcada como prioridade alta" (`Papagaio/ViewModels/TarefasDaConversaViewModel.swift:123-141`, `:194-217`) e a legenda da folha "a tarefa será marcada como prioridade alta" (`NovaTarefaDaConversaSheet.swift:171-175`) aparecem mesmo quando a prioridade não muda — toda edição marca a prioridade como manual, e a regra não mexe em prioridade manual — e o aviso se repete a cada arraste da tarefa entre colunas.
- **Como resolver:** uma chave única (a composta) nas duas telas, contando só ids que existem no quadro atual e podando ao excluir; passar `permiteSoltar: false` na coluna "Atrasada" (e na seção equivalente da conversa).

#### V-25 · Média · Data digitada com ano de dois dígitos vira o ano 26
- **Onde:** `Papagaio/DesignSystem/PapagaioTheme.swift:257-306` (`DataDigitada.formatos` e `lendo`), `:474-483` (`CampoDeDataPapagaio.aplicarTextoDigitado`); usado no prazo das tarefas (`NovaTarefaDaConversaSheet.swift:169`, `EditorDeTarefaGeralSheet.swift:150`) e na data da conversa (`EditorDeInformacoesDoCard.swift:250`)
- **Falha:** os formatos são tentados em ordem e `dd/MM/yyyy` vem antes de `dd/MM/yy`; o `DateFormatter` aceita "26" como o ano 26 d.C., então o formato de dois dígitos nunca é alcançado. Conferido executando a mesma lista de formatos: `13/08/26` → 13/08/**0026**; `13-08-26` → idem; `31/02/2026` → 03/03/2026 (data inexistente aceita e "corrigida" em silêncio, em vez de "Data não reconhecida"). Uma tarefa com prazo no ano 26 fica dois mil anos atrasada; uma conversa datada assim vai para o fim da biblioteca. Além disso, "Usar" troca a data inteira pela lida, que vem à meia-noite: confirmar o campo sem mexer apaga a hora da conversa (14:32 vira 00:00).
- **Como resolver:** validar o resultado — ano menor que 100 soma 2000 (ou tentar `yy` antes de `yyyy` quando o ano tiver até dois dígitos); recusar quando a data reformatada não bater com o texto digitado (pega 31/02); preservar hora e minuto da data anterior. Um teste de unidade com essas entradas.

#### V-26 · Média · A confirmação de apagar pasta promete o contrário do que acontece
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/GradeDePastas.swift:257-272`; `Papagaio/Funcionalidades/Biblioteca/PastasDaBiblioteca.swift:19-45`; `Papagaio/Persistencia/PreferenciasVisuaisDoArquivo.swift:74` (comentário)
- **Falha:** o diálogo diz "As N conversas continuam na biblioteca — só deixam de estar nesta pasta" (e o comentário explica que o texto existe para "tirar o susto"). Mas `PastasDaBiblioteca.apagar` faz o oposto, de propósito: move todas as conversas da pasta para a lixeira. Quem confirma achando que só o rótulo some vê as conversas desaparecerem da biblioteca. São recuperáveis pela lixeira, mas a confirmação de uma ação destrutiva está errada — e o comentário de `PreferenciasVisuaisDoArquivo` ainda descreve o comportamento antigo.
- **Como resolver:** alinhar texto e ação — "As N conversas vão para a lixeira junto com a pasta; dá para restaurar a pasta inteira ou uma conversa" — nos dois idiomas, e atualizar o comentário antigo.

#### V-27 · Média · Remover uma pessoa da ficha passa a foto dela para a pessoa seguinte
- **Onde:** `Papagaio/Persistencia/FotosDePessoas.swift:101-135` (`renomear`, `migrarAoEditarNomes`); chamadas em `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1299-1300` e `Papagaio/App/ContentView.swift:705-707` (ficha da conversa nova); formulário em `EditorDeInformacoesDoCard.swift:292-332`, `:437-440`
- **Falha:** ao salvar a ficha, as fotos são migradas comparando a lista antiga e a nova de nomes **posição a posição**, e `renomear` sobrescreve o destino sem checar. Remover a pessoa do meio desloca as linhas: de [Ana, Bruno, Carla] para [Ana, Carla] o par vira (Bruno → Carla) — a foto do Bruno é gravada na chave da Carla (apagando a dela) e o Bruno fica sem foto. Como a foto é guardada por nome, o rosto errado aparece em todas as conversas em que a Carla participa. Mesmo efeito ao inserir alguém no meio ou reordenar. No sentido oposto, uma foto escolhida enquanto o nome ainda está sendo digitado ("Ana" → "Ana Silva") fica presa ao nome parcial e some.
- **Como resolver:** só tratar como renomeação quando a quantidade de linhas não mudou e exatamente aquela linha foi alterada (ou dar um id estável a cada pessoa da ficha); nunca sobrescrever uma foto existente no destino; escolher a foto pela pessoa, não pelo texto corrente do campo.

#### V-28 · Baixa · Na aba Tarefas da conversa não dá para excluir uma tarefa
- **Onde:** `Papagaio/ViewModels/TarefasDaConversaViewModel.swift:154-163` (`excluirTarefaEmEdicao`, sem nenhuma chamada); `Papagaio/Funcionalidades/Detalhe/Tarefas/NovaTarefaDaConversaSheet.swift:42`, `:179-194` (botão "Excluir" e confirmação, só exibidos quando `aoExcluir` é passado); `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:571-582` (a folha de edição é criada sem `aoExcluir`)
- **Falha:** a exclusão com lixeira está implementada nas duas pontas — o *view model* tem a função e a folha tem o botão com confirmação — mas a tela de detalhe não liga uma à outra. Na aba Tarefas da conversa só é possível ocultar, concluir ou editar uma tarefa aceita; para apagar é preciso ir ao painel geral de Tarefas e achar o cartão.
- **Como resolver:** passar `aoExcluir: { tarefasDaConversaVM.excluirTarefaEmEdicao(conversaTitulo: titulo) }` na folha de edição.

#### V-29 · Média · A exportação ignora os nomes dados às vozes
- **Onde:** `PapagaioCore/…/Exportacao/ExportacaoMarkdown.swift:66-73`, `:102-108`; `Papagaio/Suporte/DossieDaConversa.swift:6-26`; os nomes ficam em `Papagaio/Persistencia/PreferenciasVisuaisDoArquivo.swift:209-221` (`nomesDeVoz`) e as vozes em `Palavra.falanteAcustico`
- **Falha:** o Markdown que alimenta "Compartilhar", "Baixar", "Copiar conversa inteira" e a exportação de pastas rotula cada linha só pelo canal — "Eu" ou "Interlocutor". As vozes separadas pela diarização e os nomes que a pessoa atribuiu em "Quem é quem?" (e os falantes preservados nas correções) não entram: uma reunião com quatro pessoas nomeadas na tela sai com dois falantes no arquivo. A ficha (participantes, descrição, modalidade) também fica de fora, e todos os títulos do documento ("Criado em", "Visão geral", "Transcrição"…) saem em português mesmo com o app em inglês.
- **Como resolver:** exportar por fala (`FalasDaConversa.agrupar`), usando `RotuloDeVoz.exibicao` com o mapa de nomes da conversa; incluir a ficha no cabeçalho; passar os rótulos pelo catálogo de traduções.

### 4.8 Código morto e manutenção

#### DC-01 · Média · O filtro de repetição do Whisper nunca roda
- **Onde:** `PapagaioCore/…/Transcricao/FiltroDeRepeticao.swift`; única chamada em `PapagaioCore/Sources/papagaio-eval/CasosDeMicroBench.swift:69`
- **Falha:** `FiltroDeRepeticao.remover` — a defesa contra frases repetidas em cascata — não é chamado por `PipelineDeArquivo` nem por `WhisperEngine`. As repetições chegam à transcrição e ao resumo.
- **Como resolver:** aplicar por canal antes de `Segmentacao.agrupar`/`mesclarCanais` (corrigindo antes T-05 para não perder metadados).

#### DC-02 · Baixa · Tipos sem nenhum uso em produção
- **Onde:** `NotasDaConversaViewModel` (189 linhas), `MigracaoDeRemocaoDeEquipes`, `LimpezaDeDadosFabricados`, `SwiftDataRepository.migrarTodosOsEspacos`/`buscar(termo:)`, `FormatacaoDoResumo`, `CabecalhoDePagina`, `MetadadoDoCard`, `BotaoDeFormatoDaEntrevista`, `SeloDeTipoDoArquivo`, `Diagnostico`
- **Falha:** código que ninguém chama (alguns só os testes). Dois deles são perigosos se religados: `MigracaoDeRemocaoDeEquipes` apaga as equipes e `migrarTodosOsEspacos` funde todos os espaços no pessoal — sobras de quando equipes tinham sido removidas do produto. Uma varredura por script na iteração 13 (funções declaradas sem nenhuma outra referência em produção) acrescenta: `Biblioteca.restaurarTudoDaLixeira`, `ContentView.selecionarEquipe`, `GoogleCalendarViewModel.obterDetalhesReuniao`, `FonteGoogleCalendarAPI.obterEventoDetalhado`, `SessaoOAuthGoogle.obterInfoConta`, `ModelosViewModel.bytesJaBaixados`, `LixeiraDeMidia.limparRegistros`, `LixeiraDePastas.pastaDe`, `PreferenciasVisuaisDoArquivo.imagemDaCapa`, `CartaoDeConversa.colunaDePessoas`/`textoDePessoas`, `ArquivoDetalheView.falanteExibidoParaFala`, `larguraDeLeituraPapagaio` e, no Core, `Armazenamento.renomearParaTitulo`/`removerTodasAsGravacoes`, `Trecho.comTextoEditado`, `ReuniaoExterna.fromGoogleEvent`, `MotoresLocais.descarregarResumo` e `DetectorDeAtividadeDeVoz.contemFala` (esta só nos testes).
- **Como resolver:** apagar, junto com os testes que só exercitam esse código.

#### DC-03 · Baixa · Modo `--diagnostico-tap` embarcado no app
- **Onde:** `Papagaio/App/PapagaioApp.swift:70-73`; `Papagaio/Diagnostico/DiagnosticoTap.swift`
- **Falha:** qualquer build aceita o argumento, roda a matriz de testes do tap, grava `~/diagnostico-tap.txt` e sai — inclusive com `Thread.sleep` na thread principal.
- **Como resolver:** envolver em `#if DEBUG` (o próprio comentário diz que é temporário).

#### DC-04 · Baixa · Duas fontes de tradução e textos fora do catálogo
- **Onde:** `Papagaio/Suporte/Localizacao.swift:12-24`; `Papagaio/Suporte/TabelaDeStrings.swift` (1.124 linhas); exemplos sem `.localized` em `GranolaViewModel.swift:197-198`, `ContentView.swift:1224`, `MidiasDaConversa.swift:13-15`, `SwiftDataRepository.swift:21`
- **Falha:** o inglês existe no `Localizable.xcstrings` **e** numa tabela em código; as duas divergem com o tempo, e há mensagens que nunca passam pela tradução. Auditoria por script na iteração 13: das 773 chaves literais usadas com `.localized`, 769 têm tradução e nenhuma tem especificador de formato divergente entre a chave e a tradução (0 em 1.131 chaves do catálogo). Faltam em inglês: quatro mensagens novas da abertura de conversa (`Biblioteca.swift:26`, `:932`, `:1078`; `ContentView.swift:1249`) e textos que chegam por variável — os tipos de anexo "Vídeo" e "Áudio", os dois modelos de cartão e suas descrições, os oito nomes de cor de pasta, os avisos da gravação e as mensagens de erro e de pré-requisitos vindas do Core (as que têm valores interpolados nem podem casar com uma chave).
- **Como resolver:** manter só o catálogo; um teste que varre literais de interface sem `.localized`.

#### DC-05 · Baixa · *Force unwrap* em URL vinda do servidor
- **Onde:** `Papagaio/Integracao/SessaoOAuth.swift:242`, `:256`
- **Falha:** `URLComponents(url: metadados.autorizacao, …)!` e `componentes.url!` usam endpoints lidos do `.well-known` do servidor; um valor malformado derruba o app.
- **Como resolver:** `guard let` com `ErroOAuth.respostaInvalida`.

#### DC-06 · Baixa · Pequenos defeitos na CLI `papagaio-eval`
- **Onde:** `PapagaioCore/Sources/papagaio-eval/main.swift:77-81`, `:98`
- **Falha:** o retorno de `getsockname` é ignorado (porta `0` se falhar — é o aviso AV-02) e a resposta HTTP declara `Content-Length: 20` para um corpo de 21 bytes. `diarizar --pasta` (`:321-322`) lê `argumentos[i + 1]` sem conferir o tamanho e cai com índice fora do intervalo quando a opção vem por último; o texto de uso ainda diz "Esta fase só confirma que PapagaioCore linka fora do app" (`:48`). Nos casos de *benchmark* (lidos linha a linha na iteração 14): `CasosDeMacroBench.rodar` exige os pesos do Whisper mesmo em `--somente-qwen` e `--triagem-qwen` (`:81-85`); nesses modos, e quando o arquivo de `--audio` não existe, a mensagem é "nenhum áudio fornecido" (`:165-206`); o campo `incluirDiarizacao` não é lido por ninguém (`:17`); `--comparar` com um arquivo ilegível pula a comparação sem avisar (`main.swift:613-616`).
- **Como resolver:** checar o retorno e calcular o tamanho a partir do corpo.

#### DC-07 · Baixa · A checagem "um processo só" da CLI nunca falha
- **Onde:** `PapagaioCore/Sources/papagaio-eval/ContagemDeProcessos.swift:10-28`
- **Falha:** usa `/bin/ps -o pid= --ppid <pid>`, opção que o `ps` do macOS não aceita (`illegal option -- -`, conferido nesta máquina). Com a saída de erro descartada e o código de saída ignorado, a função devolve sempre `0` filhos — o critério de aceite "sem subprocesso" passa mesmo que haja um.
- **Como resolver:** `pgrep -P <pid>` (ou `proc_listchildpids`) e tratar código de saída diferente de zero como erro.

#### DC-08 · Baixa · A personalização dos campos do cartão ficou sem tela
- **Onde:** `Papagaio/Funcionalidades/Biblioteca/PersonalizacaoDoCartao.swift` (ninguém instancia); `Papagaio/Funcionalidades/Configuracoes/PersonalizacaoDosCartoes.swift:8-45` (`ListaDeCamposDoCartao`, usada só por ela); `Papagaio/Persistencia/CamposDoCartao.swift:18-35`, `:73-86`; leitura em `CartaoDeConversa.swift:34`, `:168-171`
- **Falha:** a folha "Personalizar cartões" deixou de ser aberta em algum ponto (a chamada saiu no commit `fe48e4d`), mas o cartão continua obedecendo à preferência `camposVisiveisDoCartao`. Quem desligou "Data e hora" ou "Participantes" numa versão anterior ficou com o campo escondido e sem tela para religar (`ligarCamposNovos` só liga campos novos). Dentro do que sobrou há mais restos: o campo "Entrevistador e entrevistado" (`.pessoas`) não é consultado por nenhuma tela, o aviso "Sem descrição" citado no catálogo não existe, e os bits `.capa`, `.origem` e `.modalidade` não têm uso.
- **Como resolver:** decidir — religar a folha (em Configurações, ao lado de "Modelo do cartão") ou remover a preferência e passar a mostrar todos os campos; em qualquer caso, tirar do catálogo o que não tem efeito.

## 5. Testes, CI e repositório

#### TS-01 · Média · Os caminhos mais críticos não têm teste automático
- **Onde:** `PapagaioCore/Tests/PapagaioCoreTests/`, `PapagaioTests/`
- **Falha:** os 4 testes que exercitam Whisper e Qwen de verdade são pulados sem os pesos (logo, sempre na CI); `SessaoGravacao`/`SystemAudioTap`, o transporte real do CloudKit, o `ClienteMCP`/`SessaoOAuth` **do app** e a interação pipeline × edição (B-02) não têm cobertura; parte da suíte testa código morto (DC-02) e a versão do Core das integrações que o app não usa (G-01). Nenhuma das falhas "Alta" deste relatório quebra um teste hoje.
- **Como resolver:** testes de regressão para B-01 a B-05 e C-01 com os *doubles* que já existem; um job noturno com os pesos em cache para os testes reais.

#### TS-02 · Baixa · Avisos e ferramentas ausentes na CI
- **Onde:** `.github/workflows/ci.yml`
- **Falha:** a CI não trata avisos como erro (AV-01 a AV-03 passam), não roda *linter* nem mede cobertura; cada execução baixa ~200 MB de runtimes sem cache.
- **Como resolver:** `SWIFT_TREAT_WARNINGS_AS_ERRORS` nos alvos do projeto, `actions/cache` para `PapagaioCore/Frameworks` (chave = hash do `bootstrap-runtimes.sh`).

#### TS-03 · Média · A suíte dos scripts está quebrada e fora da CI
- **Onde:** `Scripts/tests/test_scripts.py:61-85`; `Scripts/testa-papagaio-core.sh:40-58`, `:85-95`
- **Falha:** `test_attribute_recovery_rebuilds`, `test_scratch_path_with_spaces` e `test_scratch_path_equals` falham (3 de 8). Eles esperam o comportamento antigo do script (`xattr -cr` na pasta de produtos e um segundo `swift test` **sem** `--skip-build`); o script atual limpa com `find … xattr -c`, assina com `codesign` e roda `swift test --skip-build`. Como o `ci.yml` não executa essa suíte, a divergência passou despercebida.
- **Como resolver:** atualizar os três testes para o fluxo novo (com um `codesign` falso e um `.xctest` de mentira no diretório temporário) e acrescentar `python3 -m unittest Scripts/tests/test_scripts.py` à CI.

#### TS-04 · Baixa · Testes do app tocam o `UserDefaults` real e dependem de tempo
- **Onde:** `PapagaioTests/PastasDaBibliotecaTests.swift:69-164`; lojas com `UserDefaults.standard` por padrão usadas em `PapagaioTests/BibliotecaTests.swift`; esperas em `PapagaioCore/Tests/PapagaioCoreTests/ReproducaoTests.swift:158-197`
- **Falha:** como os testes rodam hospedados no app, `UserDefaults.standard` é o domínio de preferências real de quem desenvolve — pastas e chaves de tarefas de teste ficam lá; alguns testes aguardam 100–400 ms de relógio e podem oscilar em máquinas lentas.
- **Como resolver:** injetar `UserDefaults(suiteName:)` em todas as lojas nos testes; trocar esperas por relógio injetado ou expectativas.

#### TS-05 · Baixa · O portão de qualidade do cenário C2 não tem como aprovar
- **Onde:** `Scripts/perf/validar-c2.py:108-113`; `Scripts/perf/qualidade.py:41-80`, `:91-150`; tolerância em `Scripts/perf/gerar-fixtures.sh:96`, `:122`; dados sintéticos em `PapagaioCore/Sources/papagaio-eval/CasosDeMacroBench.swift:330-357`
- **Falha:** WER, DER e memória do lado B são comparados com o lado A, mas o desvio de *timestamp* é comparado com um teto absoluto de 100 ms. A própria referência passa desse teto: recalculando com o script atual sobre os artefatos guardados de uma execução real (`~/OmuPerf/runs/medicao-core-C2-20260924T231832-67060`), o Whisper dá 2.023 ms nos dois lados e o caso do resumo dá 23.650 ms — este por construção, porque as palavras sintéticas terminam 14,35 s depois do início do trecho e o gabarito diz 38 s. O `qualidade-c2.json` daquela execução está com `"aceito": false` com WER idêntico em A e B. Resultado: `medir-core.sh C2` termina sempre com erro e a pessoa aprende a ignorar o portão. No mesmo cálculo, o WER do caso do resumo dá 19,4 % comparando o texto com ele mesmo, porque os trechos sintéticos têm 40 s e a janela de comparação tem 30 s.
- **Como resolver:** tornar o critério relativo (`timestamp_b <= timestamp_a + tolerância`), como os demais; nos casos do Qwen, em que a transcrição de entrada é a própria referência, pular *timestamp* e WER e validar só o resumo/tradução.

#### TS-06 · Baixa · Pequenos defeitos nos scripts de apoio
- **Onde:** `Scripts/bench-papagaio.sh:45`, `:88-90`, `:99`; `Scripts/perf/testes.sh:6`, `:10-12`, `:26`; `Scripts/perf/perfil.sh:5`; `Scripts/perf/build-core.sh:35`; `Scripts/perf/build-perf.sh:40`; `Scripts/perf/gerar-fixtures.sh:20`; `Scripts/perf/qualidade.py:355-361`; `Scripts/perf/validar-c2.py:29-30`; `Scripts/perf/validar-stress.py:90`; `Scripts/perf/estatistica.py:109`, `:209`; `Scripts/perf/medir-core.sh:8`, `:33`; `Scripts/generate_translations.py:468`, `:521-523`; `Scripts/build_complete_catalog.py:765-782`
- **Falha:** (1) `bench-papagaio.sh` e `perf/testes.sh` não criam `~/OmuPerf/estado/` antes de criar a trava; numa pasta nova a mensagem é "Outra medição está ativa" (reproduzido), quando o problema é a pasta que falta. (2) Cinco scripts mandam a saída do pré-voo (`ambiente.sh`) só para um arquivo; quando ele reprova (bateria, temperatura, `STOP`), o script sai com código 10–20 sem escrever nada no terminal (reproduzido com `STOP`: saída vazia, código 20). (3) `OMU_PERF_DIR` é respeitada por oito scripts e ignorada por `perfil.sh`, `testes.sh`, pelos quatro validadores em Python e pela CLI (`main.swift:530-565`), que fixam `~/OmuPerf`; com a variável definida, as travas ficam em pastas diferentes e os validadores recusam os caminhos. (4) O texto de uso de `medir-core.sh` lista C1, C2 e P7, mas o script também aceita Q2 e T2. (5) `python3 Scripts/generate_translations.py` falha com `ModuleNotFoundError: No module named 'Scripts'` (reproduzido), e lê `tmp/keys.json` relativo à pasta de onde é chamado. (6) `build_complete_catalog.py` regrava o catálogo inteiro e, para toda chave sem tradução, grava o próprio texto em português como "inglês"; rodado numa cópia, ele incluiu assim as quatro mensagens citadas em DC-04 — depois disso, nenhuma auditoria as acharia como faltantes.
- **Como resolver:** `mkdir -p "$STATE_DIR"` antes das travas; em caso de pré-voo reprovado, imprimir as duas últimas linhas do log; ler `OMU_PERF_DIR` em todos (ou removê-la de todos); no gerador, deixar a tradução ausente em vez de copiar a chave e listar no fim o que falta.

#### TS-07 · Baixa · Testes que não verificam o que o título promete, ou que fixam uma falha registrada
- **Onde:** `PapagaioTests/BibliotecaTests.swift:162-187`, `:190-205`, `:394-403`; `PapagaioCore/Tests/PapagaioCoreTests/ValidacaoDeCitacoesTests.swift:110-120`; `PapagaioCore/Tests/PapagaioCoreTests/CapturaTests.swift:161-164`; `PapagaioTests/GoogleCalendarTests.swift:195-216`; `PapagaioTests/TarefasDaConversaViewModelTests.swift:59-77`; `PapagaioTests/OAuthGoogleTests.swift:114-130`
- **Falha:** (1) "Erro de carregamento fica visível" só confere que **não** há erro no caminho feliz — nenhum erro é provocado. (2) "O mesmo arquivo não entra duas vezes na fila" confere apenas que a fila esvaziou; passaria com três entradas. (3) "Dois arquivos na fila nunca processam ao mesmo tempo" depende de observar a sobreposição a cada 20 ms, mas sem pesos nem áudio o processamento falha na hora; o resultado da espera é ignorado. (4) "Acento, caixa e pontuação diferentes ainda localizam a fala" tem uma única asserção, e ela verifica uma **rejeição** — o caso positivo que o título descreve não é testado. (5) "Gravação mais curta que 1 s é descartada" confere só a constante `duracaoMinima`; o caminho de descarte, que é onde mora C-01, fica sem teste. (6) Três testes afirmam comportamentos que este relatório registra como falha e vão precisar mudar junto com a correção: data inválida derruba a lista (IN-05), as duas primeiras sugestões nascem com prioridade alta (B-14) e a ausência de `client_secret` (um dos caminhos de correção de IN-02). Varredura por script dos 328 testes: 1 sem asserção (legítimo, "não explode"), 4 com espera de resultado ignorado, 6 com espera por relógio (TS-04).
- **Como resolver:** em (1), injetar um repositório que falha e conferir `erroDeCarregamento`; em (2) e (3), expor o tamanho da fila e usar um processador falso com latência controlada; em (4), acrescentar o caso positivo; em (5), testar `SessaoGravacao` com um gravador falso; em (6), ajustar os testes na mesma mudança que corrigir cada item.

#### RP-01 · Média · Arquivos pessoais e temporários versionados
- **Onde:** `outputs/CV_Luca_Dias_*.docx|pdf` (7 arquivos), `output/pdf/resolucao_algebra_linear_lista1_dre65.pdf`, `tmp/` (58 arquivos no total, incluindo `tmp/pdfs/contact-*.jpg`)
- **Falha:** currículos e trabalhos acadêmicos sem relação com o produto estão no histórico de um repositório que o README aponta como público — exposição de dados pessoais e ruído no clone.
- **Como resolver:** `git rm` + entradas no `.gitignore`; se o repositório é público, reescrever o histórico (`git filter-repo`) para remover os documentos pessoais.

#### RP-02 · Baixa · O *bootstrap* não confere a versão do que já está instalado
- **Onde:** `Scripts/bootstrap-runtimes.sh` (função `baixar`)
- **Falha:** se o `.xcframework` já existe, o download é pulado sem verificar se corresponde ao `LLAMA_TAG`/`WHISPER_TAG` atuais; depois de trocar a versão, quem já tinha os binários continua com os antigos.
- **Como resolver:** gravar um arquivo de versão ao lado do framework e comparar; baixar de novo se divergir.

#### RP-03 · Média · A política de privacidade publicada contradiz o que o app faz
- **Onde:** `privacy.html:23`, `:28`, `:39`, `:65`, `:70-72` (página ligada em `index.html`); comportamento real em `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:140-160`, `Papagaio/Suporte/PromptDeEntidades.swift:49-99`, `Papagaio/Integracao/` (Google Calendar e Granola), `Config/Papagaio.entitlements:33-35`; o próprio `README.md:13-14`
- **Falha:** a política afirma que o Ōmu "não utiliza, nesta versão, CloudKit, sincronização entre dispositivos ou colaboração em nuvem" e "não mantém uma cópia em nuvem", e que não solicita "contatos". O app envia título e conteúdo textual das conversas de equipe para o CloudKit (o README diz isso com todas as letras), pede acesso a Contatos e ao Calendário para montar o *prompt* de nomes (PS-03) e conversa com Google Calendar e Granola — serviços que o texto nem menciona. A página ainda traz os avisos de rascunho ("Este documento é um modelo…", "O responsável pelo aplicativo deve preencher os dados abaixo antes da publicação") e a data de 5 de agosto de 2026, anterior às equipes. Não é defeito de código, mas é o documento que a pessoa usuária e a revisão da loja leem, e a LGPD pede que ele descreva o tratamento real.
- **Como resolver:** reescrever as seções 2, 5 e 6 com o que existe hoje (CloudKit das equipes e o que sobe, Contatos/Calendário e para quê, Google e Granola como operadores opcionais, Sign in with Apple), tirar os avisos de rascunho e revisar a data; incluir a atualização da política no roteiro de lançamento de cada recurso que mexe com dados.

#### RP-04 · Baixa · O README aponta para arquivos que não existem
- **Onde:** `README.md:28-29`, `:121-122`, `:130`
- **Falha:** as duas capturas de tela (`docs/assets/biblioteca-vazia.jpeg`, `docs/assets/equipe-cloudkit-anonimizada.png`), o plano (`PLANO-APLICACAO-INTELIGENCIA-PRODUTO-PAPAGAIO.md`), a revisão (`docs/REVISAO-PLANO-E-FLUXOS-2026-08-28.md`) e a pasta `docs/historico/` não estão no repositório — a página inicial mostra imagens quebradas e dois links mortos. Os comentários do código também remetem a um `DECISIONS.md` que não está no repositório (`PapagaioCore/Package.swift:21`, `:67`; `PapagaioCore/Sources/PapagaioCore/Dominio.swift:449`).
- **Como resolver:** versionar os arquivos citados ou tirar as referências; um verificador de links na CI evita a repetição.

## 6. Sumário

### Contagem por severidade (após a iteração 15)

| Área | Alta | Média | Baixa |
| --- | ---: | ---: | ---: |
| Core — captura | 1 | 2 | 6 |
| Core — transcrição e VAD | 0 | 3 | 6 |
| Core — pipeline | 0 | 6 | 2 |
| Core — sumarização | 0 | 2 | 6 |
| Core — persistência, reprodução, modelos, idioma, integrações (CLI) | 0 | 6 | 18 |
| App — biblioteca, gravação, fila e tarefas | 4 | 6 | 4 |
| App — ditado e gravação | 0 | 3 | 2 |
| App — equipes e CloudKit | 2 | 10 | 7 |
| App — integrações | 1 | 5 | 7 |
| App — configuração | 0 | 2 | 2 |
| App — dados auxiliares e privacidade | 0 | 4 | 5 |
| App — telas | 1 | 9 | 19 |
| Código morto e manutenção | 0 | 1 | 7 |
| Testes, CI e repositório | 0 | 4 | 7 |
| **Total (170)** | **9** | **63** | **98** |

### Por onde começar

| Ordem | ID | Por quê |
| --- | --- | --- |
| 1 | **B-01** | Um clique em "Duplicar" numa conversa de equipe ou do Granola pode encher o disco. Correção de poucas linhas. |
| 2 | **B-03**, **B-04**, **C-01**, **GV-04**, **GV-05** | Caminhos diferentes para perder uma gravação em andamento — inclusive um clique em "Cancelar" sem confirmação — e as notas escritas durante a pausa. |
| 3 | **V-15**, **B-02**, **V-05** | Edições desaparecem em silêncio: a tela de detalhe não recarrega (cada correção apaga a anterior), o pipeline sobrescreve o que foi editado durante o processamento, e "Gerar novo resumo" refaz a transcrição. |
| 4 | **CK-01**, **CK-02** | Equipes: limpeza remota não autenticada e código de entrada sequestrável. |
| 5 | **P-05**, **P-07** | A transcrição se perde se o app fechar antes do primeiro salvamento; e o cancelamento de eco está desligado por um parâmetro que não é repassado — ao ligá-lo, corrigir junto P-02 a P-04. |
| 6 | **M-07**, **IN-01** (e **IN-02**) | Dois bloqueios de função: com menos de 20 GB livres nada é transcrito, mesmo com os modelos instalados; e a conexão com o Google Calendar provavelmente falha para contas novas (validar em execução). |
| 7 | **DC-01**, **T-04**, **T-01**, **B-11** | Qualidade do resultado: filtro de repetição desligado, respostas curtas e fala baixa descartadas, tarefas sugeridas que nunca aparecem. |
| 8 | **CK-14**, **CK-15**, **CK-03** a **CK-07**, **CK-19** | Sincronização: edição que vaza para a equipe errada ao trocar de espaço, operações locais presas à rede e a robustez geral antes de ampliar o uso em equipe. Inclui a exclusão de equipe, que fica presa para sempre se a rede cair no meio. |
| 9 | **V-06**, **V-26**, **PS-01**, **PS-07** | Promessas de exclusão que o app não cumpre: lixeira de 30 dias, a confirmação de apagar pasta que diz o contrário do que faz, anexos e resíduos da conta. |
| 10 | **B-14**, **V-25**, **V-27** | Dados errados gravados em silêncio em ações do dia a dia: prazos inventados nas tarefas, ano de dois dígitos virando o ano 26, e fotos trocadas entre pessoas ao editar a ficha. |
| 11 | **TS-03**, **TS-01**, **RP-01** | Consertar a suíte dos scripts e ligá-la à CI; testes de regressão para os itens acima; tirar arquivos pessoais do repositório. |
| 12 | **RP-03** | Antes de qualquer distribuição pública: a política de privacidade publicada nega o uso de CloudKit e de Contatos que o app faz, e ainda traz avisos de rascunho. |

## 7. Cobertura desta varredura

| Parte do código | Situação |
| --- | --- |
| `PapagaioCore/Sources/PapagaioCore` e *runtimes* (≈ 10.200 linhas) | Lido linha a linha (iteração 1); **segunda leitura completa nas iterações 6, 11 e 12** |
| `Papagaio/ViewModels`, `CloudKit`, `Integracao`, `App`, `Persistencia`, `Suporte`, `Modelos` (≈ 12.500 linhas) | Lido linha a linha (iterações 1 e 2); **segunda leitura completa nas iterações 9, 10 e 11** |
| `Papagaio/Funcionalidades` — telas (≈ 17.400 linhas) | `ArquivoDetalheView` lido inteiro e lógica das demais extraída (iteração 2); **todas as telas relidas linha a linha na iteração 8** (só comentários e modificadores puramente visuais de uma linha foram omitidos da leitura) |
| `Papagaio/DesignSystem` (≈ 2.600 linhas) | Lógica extraída e lida (iteração 2); **relido linha a linha na iteração 8** |
| `PapagaioCore/Sources/papagaio-eval` (CLI, ≈ 2.000 linhas) | Compilado (2 avisos); `main.swift` lido inteiro duas vezes (iterações 2–3 e 12); **casos de *benchmark*, medidor e diagnóstico lidos linha a linha na iteração 14** |
| `PapagaioTests`, `PapagaioCore/Tests` (≈ 7.900 linhas, 328 testes) | Executados (327 testes, 4 pulados); revisão de isolamento e fragilidade (iteração 2); **iteração 14: os 328 testes varridos por script (asserções, saídas silenciosas, esperas) e lidos — os do app e `PipelineTests` na íntegra, os demais do Core pelo título e pelas asserções de cada teste** |
| `Scripts/` e CI (≈ 4.800 linhas) | `bootstrap`, `testa-papagaio-core`, CI e suíte dos scripts lidos e executados (iterações 1–2); **todos os demais lidos linha a linha na iteração 14**, com execução em pasta de rascunho do `bench-papagaio.sh` (até a trava e o pré-voo) e dos geradores do catálogo, e recálculo do portão de qualidade sobre artefatos de uma medição real; `medir.sh` e `medir-core.sh` não foram executados (dependem das builds de perf) |
| `README.md`, `index.html`, `privacy.html`, `Config/`, `ci_scripts/` | **Lidos na iteração 14** e conferidos contra o código e contra os arquivos do repositório |
| `Loro.xcodeproj` (configurações de build e *scheme*), `PapagaioCore/Package.swift`, `.gitignore`, Xcode Cloud | **Lidos na iteração 15**; busca por segredos versionados em todo o repositório (nenhum encontrado) |
| `Papagaio/Suporte/PerfProbe.swift`, `TabelaDeStrings.swift` | `PerfProbe` lido inteiro na iteração 12 (instrumentação só da build de perf, sem achados); a tabela de traduções foi varrida por padrões |

### Histórico das iterações

| Iteração | O que cobriu | Falhas novas |
| --- | --- | ---: |
| 1 | Core inteiro; view models, CloudKit, integrações, entrada do app, persistência e suporte | 108 |
| 2 | Telas, tarefas, CLI, testes e scripts | 14 |
| 3 | Conferência: CLI de *benchmark*, fluxo de dados da tela de detalhe, tratamento de erros do processamento | 3 (e 2 recalibradas) |
| 4 | Conferência: funcionalidades implementadas e não ligadas, valores não finitos, ordem das checagens, títulos dos testes | 7 (e 4 marcadas como latentes) |
| 5 | Releitura como segundo leitor (pontos de suspensão da biblioteca, lojas de pastas e lixeiras, segmentação) e percurso das jornadas de uso | 5 |
| 6 | Segunda leitura do VAD em fluxo, Whisper, resumo, download e integrações; amostra aleatória de 7 arquivos de tela | 3 (todas baixas) |
| 7 | Segunda amostra aleatória (8 arquivos de tela e de modelo) | 1 (baixa) |
| 8 (lote A) | Leitura integral, linha a linha, das telas: `DesignSystem`, `Gravacao`, `Equipes`, `Perfil`, `Midias` (≈ 5.000 linhas) | 4 (todas baixas) |
| 8 (lote B) | Leitura integral: `Detalhe` (player, notas, mídia, tarefas, transcrição), `Tarefas`, `Configuracoes` (≈ 6.300 linhas); reprodução do componente da roda do mouse | 4 (1 média, 3 baixas) e 6 itens somados a achados existentes |
| 8 (lote C) | Leitura integral: `Biblioteca` inteira e `PapagaioTheme.swift` (≈ 6.600 linhas); execução dos formatos de data digitada | 3 (todas médias) e 3 itens somados a V-21 |
| 9 | Releitura, com as lentes da iteração 8, de `Persistencia`, `Modelos`, `Suporte` e dos *view models* menores (≈ 5.900 linhas) | 2 (baixas) e 2 itens somados a V-01 e V-04 |
| 10 | Releitura de `App`, `CloudKit`, `Integracao`, `Biblioteca.swift` e `GravadorViewModel.swift` (≈ 7.500 linhas); execução da derivação do nome de zona | 5 (4 médias, 1 baixa) e 4 itens somados a achados existentes |
| 11 | Releitura de `ArquivoDetalheView`, `TarefasDaConversaViewModel` e, no Core, captura, importação, *pipeline*, persistência, reprodução, domínio, exportação e diarização (≈ 6.900 linhas); teste do gravador em pausa | 2 (1 média, 1 baixa) e 5 itens somados a achados existentes |
| 12 | Segunda leitura de *runtimes*, `Core/Runtime`, restante de transcrição e sumarização, integrações do Core, `main.swift` da CLI e `PerfProbe` (≈ 5.900 linhas); reprodução do `ClienteMCP` do Core | 2 (baixas) e 2 itens somados a achados existentes |
| 13 | Verificações de outro tipo: auditoria do catálogo de traduções por script, `Info.plist` e catálogo de permissões, varredura de funções sem uso, e reconferência contra o código das 9 falhas altas e de 4 médias | 0 novas; 1 item corrigido (AP-02) e 4 complementados (DC-02, DC-04, CK-13, C-08) |
| 14 | O que ainda não tinha leitura linha a linha: casos de *benchmark* e diagnóstico da CLI, todos os scripts de perf e de tradução, CI, `Config/`, README, site e política de privacidade, e os 328 testes (≈ 14.000 linhas); reprodução do `bench-papagaio.sh`, dos geradores do catálogo e do portão C2 | 6 (1 média, 5 baixas) e 1 item somado a DC-06 |
| 15 | Configurações de build, *scheme*, `Package.swift`, `.gitignore`, busca por segredos; releitura por amostragem aleatória (4 trechos, ≈ 900 linhas) com a pergunta "o que acontece ao repetir depois de uma falha no meio?" | 1 (média) e 2 itens somados a AP-01 e RP-04 |

<!-- CONTINUA: iteração 15 achou CK-19 (média) numa amostra aleatória de código já lido duas vezes — sinal de que ainda há falha não registrada, principalmente em operações de vários passos. Últimas passadas: 2, 2, 0, 6, 1. Próxima passada (16): aplicar a pergunta "o que acontece ao repetir depois de uma falha no meio?" a todas as operações de vários passos com efeito em disco, UserDefaults ou rede (Biblioteca: duplicar, excluir conta, lixeira, importação; LixeiraDeMidia; PastasDaBiblioteca; Granola/Calendar; fila do CloudKit; download de modelos), e mais uma amostra aleatória. -->

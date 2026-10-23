# A1 — Correção

**Data:** 2026-09-23  
**Escopo:** 232 arquivos `.swift` de produção (`Papagaio/**`: 171; `PapagaioCore/Sources/**`: 61), 45.602 linhas.  
**Método:** leitura integral do mapa e dos fontes, busca de todos os callers/guards e probes locais focados. Não foram usados `A2.md` nem `A5-testes.md` como evidência final. Não houve acesso a OAuth, CloudKit, microfone/Process Taps ou outros serviços reais.

## Legenda

- **Severidade:** `CRÍTICO`, `ALTO`, `MÉDIO`, `BAIXO`, `INFO`.
- **Confiança:** `CONFIRMADO` (reproduzido/medido), `PROVÁVEL` (cadeia de código forte, mas sem serviço/hardware real), `HIPÓTESE` (evidência insuficiente).

## Resumo

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 0 |
| ALTO | 6 |
| MÉDIO | 15 |
| BAIXO | 1 |
| INFO | 0 |
| **Total** | **22** |

| Confiança | Quantidade |
|---|---:|
| CONFIRMADO | 11 |
| PROVÁVEL | 11 |
| HIPÓTESE | 0 |
| **Total** | **22** |

| Prioridade | Achados |
|---|---|
| P0 — destravar confiança e impedir perda de dados | A1-002, A1-007 |
| P1 — restaurar integrações e integridade de áudio | A1-001, A1-003, A1-004, A1-005, A1-006, A1-012, A1-013, A1-020, A1-021 |
| P2 — consistência de domínio, persistência e UI | A1-008, A1-009, A1-010, A1-011, A1-014, A1-015, A1-016, A1-017, A1-018, A1-019, A1-022 |

---

## A1-001 — `prompt=none` impede a primeira autorização do Google

**Severidade:** ALTO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Integracao/SessaoOAuthGoogle.swift:104-108`
- `Papagaio/Integracao/SessaoOAuthGoogle.swift:209-210`

```swift
if let guardado, guardado.expiraEm > Date() {
    return guardado.valor
}
return try await fluxoDeAutorizacao()
// ...
URLQueryItem(name: "prompt", value: "none"),
```

**Cenário de reprodução**

1. Instale o app sem access token e sem refresh token e toque em **Conectar Google Calendar**.
2. `tokenDeAcesso(forcandoRenovacao:)` não encontra token e chama `fluxoDeAutorizacao()`.
3. A URL enviada ao Google contém `prompt=none`.
4. Sem consentimento prévio, essa solicitação sem interação não autoriza e não produz o callback loopback esperado. O navegador mostra erro; o servidor local não recebe `/oauth/callback` e o app entra na espera de 180 s — que também esbarra em A1-002.

**Guardas buscadas para refutar**

- Não há ramo de “primeira conexão” que remova `prompt=none`.
- O único chamador de `prepararAutorizacao` é o fluxo interativo em `:124-157`.
- O refresh token é consultado antes do fluxo em `:98-108`, mas não elimina a primeira conexão.
- `OAuthGoogleTests.swift:114-130` valida PKCE/state, mas não exige consentimento interativo.

**Causa**

Uma escolha de autorização silenciosa foi aplicada ao único fluxo que precisa abrir consentimento. `prompt=none` é adequado para tentar reutilizar uma sessão já autorizada, não para uma pessoa sem autorização.

**Correção sugerida**

- Usar o fluxo interativo normal na primeira conexão (`prompt=consent` ou nenhum `prompt`).
- Opcionalmente tentar `none` apenas quando já existe autorização persistida e, em `interaction_required`, cair para o fluxo interativo.
- Acrescentar teste que fixe a semântica do primeiro consentimento sem abrir navegador real.

---

## A1-002 — Timeout/cancelamento do OAuth Google não consegue despertar `accept()`

**Severidade:** ALTO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `Papagaio/Integracao/SessaoOAuthGoogle.swift:164-183`
- `Papagaio/Integracao/SessaoOAuthGoogle.swift:423-447`
- `Papagaio/Integracao/SessaoOAuthGoogle.swift:491-497`

```swift
Darwin.shutdown(listener.fileDescriptor, SHUT_RDWR)
// ...
let cliente = Darwin.accept(socket, $0, &tamanho)
guard cliente >= 0 else { throw CancellationError() }
```

**Cenário de reprodução**

1. `ServidorOAuthLocal.aguardarCodigo()` entra no worker bloqueado em `accept()`, sem cliente conectado.
2. A task é cancelada ou o timeout de `aguardarCodigo` vence.
3. `shutdown()` no socket de escuta retorna erro, o `accept()` continua bloqueado e a continuation nunca é retomada.
4. Como `withThrowingTaskGroup` aguarda os filhos estruturados antes de sair, o fluxo também não retorna o erro de timeout.

Probe local `oauth_shutdown_probe`:

```text
shutdown_result=-1 errno=57 accept_woke_without_new_connection=false
accept_remained_blocked
```

Os dois testes de cancelamento do app ficam pendurados nesse caminho.

**Guardas buscadas para refutar**

- `ConexaoOAuthLocal.cancelar()` só consegue fechar uma conexão já registrada; não há cliente no cenário de timeout.
- `parar()` chama `shutdown` no listener, não no socket aceito.
- O teste com um cliente conectado antes do cancelamento passou; isso confirma que o defeito é especificamente `accept()` sem conexão.
- Não há `DispatchSource`, socket de despertar, self-pipe nem segunda conexão de cancelamento.

**Causa**

`shutdown(SHUT_RDWR)` em Darwin não é um mecanismo confiável para acordar `accept()`; nesse estado retorna `ENOTCONN` (`errno=57`). A task Swift é cancelável, mas a syscall POSIX bloqueante não é.

**Correção sugerida**

- Substituir o worker bloqueante por um mecanismo explicitamente cancelável (`DispatchSource` para o listener ou uma conexão loopback de despertar com estado de geração).
- Manter a posse/fechamento do descritor em um único dono para impedir reuso de FD.
- Fazer a continuation ser retomada exatamente uma vez por callback, timeout ou cancelamento.
- Manter os testes de cancelamento com timeout explícito no gate.

---

## A1-003 — Parser SSE do MCP concatena eventos diferentes e rejeita respostas válidas

**Severidade:** ALTO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `Papagaio/Integracao/ClienteMCP.swift:171-185`
- `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:292-313`

```swift
let payloadsDeDados = linhas
    .filter { $0.hasPrefix("data:") }
    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
// ...
let json = payloadsDeDados.joined(separator: "\n")
```

**Cenário de reprodução**

O Streamable HTTP pode enviar mais de um evento SSE na mesma resposta, por exemplo notificação/progresso e o envelope final. O probe `app_mcp_probe` devolveu dois `data:` JSON-RPC válidos e separados por linha em branco; o cliente tenta interpretá-los como um único documento:

```text
sse_error=respostaInvalida
```

O probe do cliente core reproduziu o mesmo mecanismo com `respostaInvalida("JSON inválido na resposta")`.

**Guardas buscadas para refutar**

- Não há parser por evento SSE; apenas `split("\n")`.
- A correlação de `id` do core ocorre em `ClienteMCP.swift:274-279`, depois da tentativa de parser que já falha.
- O cliente app nem sequer valida o `id` esperado antes de extrair `result`.
- Não há teste com notificação + resposta no mesmo fluxo SSE.

**Causa**

Linhas `data:` de eventos distintos foram tratadas como fragmentos de um único JSON. Isso é diferente de vários `data:` que pertencem ao mesmo evento, caso em que devem ser unidos.

**Correção sugerida**

- Implementar um parser SSE que separe eventos por linha em branco, acumule somente os `data:` de cada evento e reconstitua cada JSON individualmente.
- Descartar notificações sem `id` e selecionar o envelope cujo `id` corresponde ao pedido.
- Adicionar testes para: um evento, `data:` multilinha, notificação + resposta, resposta + evento tardio e IDs divergentes.

---

## A1-004 — Token rejeitado com 401 não força renovação; o retry nem chega a existir no cliente do app

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `Papagaio/Integracao/ClienteMCP.swift:129-157`
- `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:30-45,63-88,101-153,156-174`
- `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:141-143,185-198`
- `Papagaio/Integracao/SessaoOAuth.swift:79-97`

```swift
let token = try await obterToken(false)
// ...
guard status == 200 || status == 202 else {
    throw ErroMCP.protocolo(...)
}
```

**Cenário de reprodução**

1. O token local ainda parece válido, mas foi revogado no servidor.
2. A terceira requisição do probe (`tools/call`) recebe 401.
3. O cliente app obtém token três vezes, todas com `forcar == false`, e propaga:

```text
401_error=protocolo(codigo: 401, mensagem: "unauthorized") token_calls=3
```

A API do Google também só chama `obterToken(false)` e não distingue 401 para uma renovação. No cliente core há retry apenas em `chamarUmaVez`; um 401 durante `initialize` escapa porque a inicialização está fora desse retry.

**Guardas buscadas para refutar**

- Não há segunda chamada no cliente app.
- A API Google ignora o parâmetro de força em todas as requisições.
- `SessaoOAuth` e `SessaoOAuthGoogle` ainda retornam o access token não expirado quando `forcar=true` e não há refresh, inclusive se ele foi o token rejeitado.
- O core só envolve `tools/call` no retry, não `inicializarSeNecessario`.

**Causa**

O parâmetro de renovação existe, mas os transports não o acionam após 401/403. A flag de força também não representa “token rejeitado” quando não existe refresh.

**Correção sugerida**

- Centralizar uma tentativa de reautenticação por requisição: em 401/403, limpar o access token rejeitado, pedir `forcarRenovacao=true` e repetir uma única vez.
- Ao forçar sem refresh, não devolver o mesmo token apenas porque o relógio local diz que ele expira depois.
- Incluir `initialize`/GET de sessão no mesmo fluxo de recuperação.
- Não repetir notifications nem operações não idempotentes sem uma regra explícita.

---

## A1-005 — Operações pesadas não são mutuamente exclusivas globalmente

**Severidade:** ALTO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/ViewModels/Biblioteca.swift:39-45`
- `Papagaio/ViewModels/Biblioteca.swift:852,894-896,1004-1008`
- `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:16-27,179-193`
- `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift:53-55,68-76`

```swift
private var filaDeProcessamento: [ArquivoID] = []
// ...
let motores = MotoresLocais(pastaDeModelos: pastaDeModelos, ciclo: ciclo)
```

**Cenário de reprodução**

1. A fila serial processa a conversa A e cria um `MotoresLocais` em `:896`.
2. Durante a transcrição/resumo, a pessoa dita uma nota em B (`:852`) ou pede diarização de B (`:1008`).
3. Cada operação cria seu próprio ator e sua própria `FilaEstrita`; portanto as duas podem carregar Qwen/Whisper ao mesmo tempo.
4. O `CicloDeVidaDeModelos` compartilha apenas o registro; ele não é uma trava de exclusão. O dicionário também sobrescreve contextos com o mesmo identificador, podendo deixar um deles sem descarregamento monitorado.

**Guardas buscadas para refutar**

- `filaDeProcessamento` protege apenas `executarProcessamento`; `transcreverDitado` e `diarizarTranscricao` não passam por ela.
- Não existe `MotoresLocais` compartilhado como propriedade da `Biblioteca`.
- A exclusão em `MotoresLocais.comExclusividade` é local à instância.
- O monitor de memória pode descarregar um contexto enquanto o ator ainda o considera em uso.

**Causa**

A invariante de memória foi implementada por instância, mas a interface permite operações concorrentes que não compartilham a instância.

**Correção sugerida**

- Ter um único `MotoresLocais` compartilhado por `Biblioteca` ou um coordenador global de recursos pesados.
- Serializar ditado, diarização e pipeline no mesmo mecanismo de exclusão, com prioridade/cancelamento explícitos.
- Só libere recursos ociosos; registrar uma concessão por uso, não apenas uma referência “residente”.
- Identificar contextos por instância/geração, não apenas por `WhisperEngine.identificador`.

---

## A1-006 — Ditado de nota não é cancelado quando a tela desaparece

**Severidade:** ALTO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:513-520`
- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1386-1400`
- `Papagaio/ViewModels/GravadorViewModel.swift:571-579`

```swift
.onDisappear {
    tarefaDeSalvamentoDasNotas?.cancel()
    salvarNotasAgora()
    reprodutor?.encerrar()
    reprodutor = nil
}
// ...
Task { @MainActor in
    if ditado.gravando { await ditado.concluir(...) }
    else { await ditado.iniciar() }
}
```

**Cenário de reprodução**

1. Inicie o ditado de uma nota e navegue para outra conversa antes de concluí-lo.
2. A task não estruturada criada em `alternarDitado` não pertence ao `.task` da SwiftUI view e não é cancelada em `onDisappear`.
3. Como a task pode reter a interface/`DitadoDeNota`, `CapturaDeDitado` continua com o mecanismo de captura ativo; o microfone pode permanecer ligado e o arquivo temporário permanece até uma ação posterior.

**Guardas buscadas para refutar**

- `DitadoDeNota.cancelar()` existe, mas não possui chamador no detalhe.
- `onDisappear` cancela apenas o debounce das notas e o player.
- A task de ditado não é armazenada em `@State`.
- `captura` só é liberada em `concluir` ou `cancelar`.

**Causa**

O ciclo de vida da captura foi tratado como estado local da tela, mas o trabalho que o mantém vivo é externo e não estruturado.

**Correção sugerida**

- Armazenar a task de ditado, cancelá-la em `onDisappear` e chamar `ditado.cancelar()`.
- Estender o cancelamento para o estado `transcrevendo`, invalidando a geração para que um resultado tardio não volte a modificar a tela.
- Garantir `removeTap`, parada do engine e remoção do CAF em `deinit` e em todos os exits.

---

## A1-007 — Saves de um agregado inteiro perdem edições concorrentes

**Severidade:** ALTO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:105,160-162,187-190`
- `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:66-75`
- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1361-1381`
- `Papagaio/ViewModels/Biblioteca.swift:660-669`

```swift
var atualizado = arquivo
// ... trabalho longo ...
try await repositorio.salvar(atualizado)
// ...
Task { @MainActor in
    await aoAtualizarNotas(atualizadas)
}
```

**Cenário de reprodução**

Há duas rotas para o mesmo defeito:

1. **Salvas de notas concorrentes:** dois `salvarNotasAgora()` criam tasks não ordenadas. O probe forçou o segundo save a terminar primeiro e imprime:

   ```text
   save_2=novo
   save_1=antigo
   ```

   O snapshot antigo termina por último. A mesma estrutura existe no view model de notas.

2. **Edição durante o pipeline:** a transcrição pode levar minutos. `PipelineDeArquivo` copia o `Arquivo` inicial em `atualizado`; se a pessoa adiciona uma nota ou altera metadados enquanto o modelo trabalha, os dois saves de `:162` e `:189` regravam trechos, resumo **e também** as notas/metadados antigos. `SwiftDataRepository.salvar` apaga todas as relações filhas e reinsere o snapshot recebido.

**Guardas buscadas para refutar**

- `@MainActor` serializa a entrada, mas não a conclusão relativa de tasks não estruturadas.
- O repositório é actor, portanto serializa chamadas; não existe versão/revisão que rejeite snapshot antigo.
- `Biblioteca.atualizarNotas` parte do `arquivo` capturado pela interface, não do estado mais recente relido do repositório.
- `substituir(editado)` também pode devolver ao estado em memória um agregado velho.

**Causa**

`Arquivo` é tratado simultaneamente como snapshot de valor e como registro mutável. Salvar um campo derivado acaba usando semântica de “substituir tudo”, sem merge otimista.

**Correção sugerida**

- Criar operações de repositorio por campo (`salvarNotas`, `salvarMetadados`, `salvarResultadoDoPipeline`) ou uma revisão/versão de alteração com conflito explícito.
- Fazer o pipeline reler o registro atual e fundir apenas `trechos`, `resumo` e engines; nunca substituir notas/metadados sem verificar a revisão da entrada.
- Serializar saves de uma tela e descartar respostas de geração anterior antes de atualizar a UI.
- Adicionar teste de lost update para: notas durante pipeline, metadados durante pipeline e dois saves rápidos.

---

## A1-008 — `ValorJSON` rejeita `null`, apesar de ter um caso para JSON nulo

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:33-68,74-89,208-224`

```swift
switch qualquer {
case let s as String: self = .texto(s)
case let b as Bool: self = .booleano(b)
case let n as NSNumber: self = .numero(n.doubleValue)
// não há case para NSNull
// ...
}
```

**Cenário de reprodução**

`JSONSerialization` representa JSON `null` como `NSNull`. Um resultado MCP válido como:

```json
{"speaker": null, "text": "ok"}
```

faz `ValorJSON(de:)` retornar `nil`; `ClienteMCP` então responde `resultado ... sem JSON válido`. O probe com a fonte real de produção imprimiu:

```text
converted=nil
```

**Guardas buscadas para refutar**

- O enum já possui `.nulo` e `comoAny` o representa, mas o inicializador nunca o produz.
- Não há normalização anterior de `NSNull` no cliente.
- Não há teste de resultado com campo opcional nulo.

**Causa**

O conversor de `JSONSerialization` para a árvore `Sendable` esqueceu o caso de bridging `NSNull`.

**Correção sugerida**

- Reconhecer `NSNull` antes de `NSNumber` e inicializar `.nulo`.
- Manter `NSNumber` depois de `Bool`, preservando a distinção JSON booleana.
- Adicionar testes com `null` no topo, em arrays e em campos opcionais de Granola.

---

## A1-009 — Falha ao buscar transcrição do Granola aborta a importação da reunião

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Integracao/FonteGranola.swift:48-60,74-85`
- `Papagaio/Integracao/GranolaViewModel.swift:151-153,178-192`

```swift
if incluirTranscricao {
    transcricao = try await transcricaoDaReuniao(id: id)
}
```

**Cenário de reprodução**

1. Selecione uma reunião do Granola em um plano sem `get_meeting_transcript`, ou durante indisponibilidade temporária da tool.
2. O comentário do produto diz que notas e resumo devem ser salvos mesmo sem transcrição.
3. O `try` propaga o erro; `GranolaViewModel` não chama `registrarExterna`, marca a reunião como falha e nada é importado.

**Guardas buscadas para refutar**

- Não há `catch` entre `obterReuniao` e o chamador.
- O chamador sempre solicita `incluirTranscricao: true` na importação.
- A implementação core equivalente, `PapagaioCore/.../FonteGranola.swift:249-270`, contém o `do/catch` que confirma a intenção de degradação.
- Não há teste para plano sem transcrição no cliente app.

**Causa**

O comentário e a implementação divergem: a fonte app trata a transcrição como obrigatória, apesar de o contrato neutro definir `transcricao` como opcional.

**Correção sugerida**

- Tratar erro de entitlement/plano como `transcricao: nil`, registrar a reunião com notas/resumo e mostrar apenas um aviso não bloqueante.
- Reenviar cancelamentos e erros que indiquem falha de transporte/sessão conforme a política da UI; não esconder todos os erros sob “sem transcrição”.
- Testar Basic, tool indisponível, timeout e cancelamento separadamente.

---

## A1-010 — Parser de transcrição do Granola reconhece somente o primeiro rótulo de falante

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Integracao/FonteGranola.swift:164-185,198-200`

```swift
if let resultado = rotuloInicial.firstMatch(in: corrido, ...) {
    falante = FalanteExterno.rotulo(...)
    fala = String(corrido[marcado.upperBound...])
}
return [SegmentoDeTranscricaoExterna(falante: falante, texto: fala, inicio: 0, fim: 0)]
```

**Cenário de reprodução**

Para o texto documentado:

```text
Me:Olá.
Them:Oi.
Me:Podemos continuar?
```

A função devolve **um** segmento, atribui tudo a `Me` e mantém `Them:` dentro do texto. As viradas documentadas no próprio arquivo (`transcrição ... com quem falou marcado no início`) deixam de existir no modelo.

**Guardas buscadas para refutar**

- A regex é ancorada apenas no começo (`^`).
- Não há separação por linha/turno no chamador.
- `Biblioteca.registrarExterna` apenas mapeia a lista devolvida; ela não separa o texto.
- O mapeador do core possui suporte a lista de segmentos, mas o app usa sua implementação interna `FonteGranola`.

**Causa**

O parser aceita apenas o formato de uma única fala, apesar de o contrato descrever múltiplas viradas.

**Correção sugerida**

- Fazer scan linha a linha dos rótulos `Me:`, `Them:` e nomes reais, emitindo um segmento por turno.
- Manter `inicio/fim = nil` quando o texto não os fornece; não inventar timestamp.
- Preferir o payload estruturado quando disponível e usar o parser textual apenas como fallback.

---

## A1-011 — Falhas de escrita no Keychain do OAuth Granola são engolidas

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Integracao/SessaoOAuth.swift:231-240`
- `Papagaio/Integracao/SessaoOAuth.swift:352-357`

```swift
if let dados = try? JSONEncoder().encode(cliente) {
    try? cofre.salvar(dados, conta: "client")
}
// ...
let par = gerarAtributoPKCE()
try? cofre.salvar(Data(par.verificador.utf8), conta: "pkce")
```

**Cenário de reprodução**

1. Simule Keychain sem espaço, item bloqueado ou erro `errSec*`.
2. A URL de autorização é aberta mesmo sem PKCE persistido.
3. A troca do código carrega verifier vazio e falha no servidor com mensagem genérica.
4. Se access/refresh/expiração não forem salvos, `conectar()` ainda pode reportar sucesso na sessão atual, mas a próxima abertura autentica de novo.

**Guardas buscadas para refutar**

- Não há verificação após nenhum dos `try?`.
- `trocarCodigo` não tem como distinguir “verificador nunca salvo” de uma resposta inválida do servidor.
- Não há teste com `CofreDeTokens` que falhe no meio do fluxo.
- O core equivalente propaga `try persistir(...)` e não possui esse comportamento de ignorar erro.

**Causa**

Persistência de credencial foi tratada como best effort até para dados necessários à continuidade e à segurança da troca.

**Correção sugerida**

- Tornar `urlDeAutorizacao`/persistência do verificador throws e mapear `ErroDoCofre` para mensagem acionável.
- Falhar a conexão se o registro necessário não puder ser salvo; para access/refresh, definir explicitamente um estado degradado ou propagar o erro.
- Manter `try?` apenas em revogação/log best effort, nunca no PKCE obrigatório.

---

## A1-012 — Duplicar reunião sem áudio tenta copiar a raiz do container

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `Papagaio/ViewModels/Biblioteca.swift:357-366`
- `Papagaio/ViewModels/Biblioteca.swift:696-710`

```swift
pastaRelativa: "",
// ...
let origem = armazenamento.resolver(relativo: arquivo.pastaRelativa)
let destino = armazenamento.resolver(relativo: pastaNovaRelativa)
if origemExiste {
    try FileManager.default.copyItem(at: origem, to: destino)
}
```

**Cenário de reprodução**

Uma reunião externa tem `pastaRelativa == ""`; `resolver(relativo: "")` retorna a raiz `Papagaio`. Como a raiz existe, `duplicar` tenta copiá-la para `Gravacoes/<novo-id>`, que está dentro da própria origem. O probe do sistema de arquivos retornou:

```text
root_copy_error=The item couldn’t be saved because the file name “dest” is invalid.
```

A duplicação de qualquer `Arquivo.semAudio` falha antes de criar a cópia.

**Guardas buscadas para refutar**

- Não há `if arquivo.semAudio` antes da cópia.
- A pasta de resultado é sempre não vazia, mesmo quando a origem não representa áudio.
- A cópia de anexos só ocorre depois da cópia da pasta, então nunca salva esse caminho.
- O teste de duplicação cobre somente pasta normal com anexos.

**Causa**

Ausência de pasta foi reutilizada como “fonte de disco” sem separar o caso sem áudio.

**Correção sugerida**

- Tratar `semAudio` antes de `armazenamento.resolver`: a cópia deve preservar `pastaRelativa == ""` e os dados textuais.
- Criar um helper específico para copiar anexos do diretório sintético `MidiaIndisponivel/<id>`, se esses anexos devem acompanhar a cópia.
- Adicionar teste de duplicação para reunião Granola sem áudio.

---

## A1-013 — Lixeira de mídia rejeita caminhos de reuniões sem áudio

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `Papagaio/ViewModels/Biblioteca.swift:1210-1215`
- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:127-136`
- `Papagaio/Persistencia/LixeiraDeMidia.swift:267-299`

```swift
return armazenamento.raiz
    .appendingPathComponent("MidiaIndisponivel", isDirectory: true)
    .appendingPathComponent(arquivo.id.rawValue.uuidString, isDirectory: true)
// ...
guard componentesDaConversa.count == componentesDasGravacoes.count + 1,
      componentesDaConversa.prefix(...) == componentesDasGravacoes
else { throw Erro.caminhoForaDasGravacoes }
```

**Cenário de reprodução**

1. Em uma reunião importada sem áudio, adicione um anexo. Ele é armazenado ao lado do marcador `MidiaIndisponivel/<id>`.
2. Remova o anexo: `mover` aceita o caminho porque ele está dentro da pasta da conversa.
3. Ao restaurar, `validarCaminhos` exige que a pasta derivasse de `Gravacoes`; a raiz `MidiaIndisponivel` é rejeitada.

Probe:

```text
sem_audio_restore=false original_exists=true lixeira_exists=true
```

**Guardas buscadas para refutar**

- `validarOrigem` usa a pasta da conversa e não exige `Gravacoes`.
- `validarCaminhos` reconstrói outro contrato, mais estreito.
- O item continua recuperável no disco, mas a UI só oferece restauração e ela sempre retorna `false`.

**Causa**

A validação de segurança foi fixada no layout de áudio local e não no conjunto de raízes de conversa que o próprio app cria.

**Correção sugerida**

- Parametrizar a pasta canônica da conversa e validar `Gravacoes/<id>` e `MidiaIndisponivel/<id>` contra a mesma raiz confiável.
- Evitar inferir a pasta apenas pela profundidade; persistir/validar a raiz canônica ao mover.
- Manter as proteções contra `..`, symlink e prefixos irmãos.

---

## A1-014 — Agrupamento recria o `id` do trecho

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Transcricao/Segmentacao.swift:31-48`
- `PapagaioCore/Tests/PapagaioCoreTests/PipelineTests.swift:531-554,572-579`

```swift
trechos.append(Trecho(
    start: primeiro.start,
    end: ultimo.end,
    texto: acumulados.map(\.texto).joined(separator: " "),
    // nenhum id: o init gera outro UUID
))
```

**Cenário de reprodução**

A entrada de um segmento com UUID conhecido é agrupada e volta com outro UUID. O probe comparou entrada/saída, e a suíte real falha em duas asserções:

```text
trechos[0].id == idDoTrecho → false
```

Isso invalida edição inline, seleção de busca e rótulos de falante preservados por trecho/ID. A falha direta está em `core-full-second.log:287-296`.

**Guardas buscadas para refutar**

- `marcar(_:como:)` e `comPalavras` preservam `id`; apenas o fechamento do grupo o perde.
- O teste do pipeline explicitamente exige a identidade da entrada.
- Não há reconciliação posterior por ID no chamador.
- A segmentação pode agregar vários segmentos; a intenção de qual identidade preservar precisa ser explícita, mas não pode ser um UUID aleatório.

**Causa**

O construtor de agregação foi usado sem propagar a identidade do primeiro segmento do grupo.

**Correção sugerida**

- Preservar o ID do primeiro segmento, ou criar uma identidade determinística derivada dos membros, se a semântica de “grupo” exigir um novo ID.
- Documentar a regra de estabilidade e adicionar teste para agrupamento, tradução, diarização e persistência.

---

## A1-015 — Confiança e `noSpeechProb` do trecho não sobrevivem às transformações nem ao SwiftData

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Transcricao/Segmentacao.swift:33-48`
- `PapagaioCore/Sources/PapagaioCore/Diarizacao/ResolvedorDeFalantes.swift:253-273`
- `PapagaioCore/Sources/PapagaioCore/Persistencia/ModelosSwiftData.swift:91-105`
- `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:77-103,428-460`
- UI: `Papagaio/Funcionalidades/Detalhe/Transcricao/LinhaDeTranscricao.swift:38-41,86-93`

```swift
return Trecho(
    start: primeiro.start,
    end: ultimo.end,
    texto: ...,
    palavras: palavras,
    noSpeechProb: noSpeech
    // confianca não é passada
)
```

**Cenário de reprodução**

Mesmo que a palavra individual mantenha confiança, o cabeçalho do trecho perde seus campos. O probe de round-trip produziu:

```text
trecho_confianca=nil noSpeech=nil palavra_confianca=Optional(0.91)
```

O resolvedor reconstrói outro `Trecho` sem os mesmos campos; o modelo SwiftData sequer declara colunas para eles. Após reload, a porcentagem e o realce de baixa confiança do trecho desaparecem.

**Guardas buscadas para refutar**

- `Palavra.confianca/noSpeechProb` têm round-trip coberto e preservado.
- `Trecho.confianca/noSpeechProb` são parte do contrato de domínio, mas não têm propriedade persistente.
- Não há fallback de `Trecho` para agregação das palavras na UI.
- A segmentação calcula `noSpeech`, mas descarta `confianca` mesmo antes do banco.

**Causa**

Metadados em nível de palavra foram preservados, enquanto metadados em nível de segmento foram perdidos em três reconstruções independentes.

**Correção sugerida**

- Calcular e propagar agregados em cada transformação, usando a mesma regra de duração definida em `Trecho.confiancaMedia`.
- Adicionar campos opcionais ao modelo SwiftData e atribuir/ler ambos no mapeador.
- Testar perda de confiança por realce, por translation e por persistência.

---

## A1-016 — Busca não encontra texto que existe apenas em `InsightPersistido.detalhe`

**Severidade:** MÉDIO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:192-199,400-410`
- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:414-425`

```swift
var porInsight = FetchDescriptor<InsightPersistido>(
    predicate: #Predicate { $0.texto.localizedStandardContains(limpo) }
)
// ...
inserir(..., descricao: passo.descricao, detalhe: passo.responsavel)
```

**Cenário de reprodução**

Crie um próximo passo com descrição “Enviar orçamento” e responsável “Luca”. Busque por `Luca`:

- a consulta do repositório verifica apenas `InsightPersistido.texto`;
- o filtro local também consulta apenas `proximosPassos.descricao`, não `.responsavel`.

O probe retornou `busca_detalhe_count=0`, embora o detalhe exista no banco.

**Guardas buscadas para refutar**

- A inserção realmente grava `detalhe` em `:407-409`.
- O comentário do bucket B promete procurar “insight”, mas não promete subcampo; o restante do produto, porém, já trata responsável como texto pesquisável na tarefas.
- Não há teste de busca por responsável.

**Causa**

A consulta e o filtro local enumeram parte dos campos do mesmo modelo e omitiram `detalhe`.

**Correção sugerida**

- Incluir `detalhe` na busca de insights, preservando a semântica de acento/caixa.
- Adicionar o responsável à busca local de próximos passos.
- Manter uma única definição de campos pesquisáveis para evitar backend/UI divergirem.

---

## A1-017 — Alterar a conversa no editor duplica a tarefa

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Funcionalidades/Tarefas/EditorDeTarefaGeralSheet.swift:52-57`
- `Papagaio/Funcionalidades/Tarefas/TarefasView.swift:729-750,753-783`
- `Papagaio/ViewModels/TarefasDoPainelViewModel.swift:27-35`

```swift
Button(conversa.resumo?.titulo ?? conversa.titulo) {
    conversaSelecionada = conversa.id
}
// ...
painelDeTarefas.salvar(tarefaAtualizada, em: arquivo, substituindo: tarefaEmEdicao != nil)
```

**Cenário de reprodução**

1. Edite uma tarefa da conversa A.
2. No seletor, escolha a conversa B e salve.
3. O código cria/substitui a tarefa em B, mas nunca remove a entrada de A.
4. O mesmo UUID aparece nos dois stores; a tarefa fica duplicada e continua editável nos dois lugares.

**Guardas buscadas para refutar**

- O menu de conversa permanece ativo em modo de edição.
- `TarefasDoPainelViewModel.salvar` só escreve no arquivo recebido.
- Não há `remove`/rollback no `TarefaGeral` original.
- O editor não distingue “mover” de “copiar”.

**Causa**

A troca de conversa foi interpretada como nova associação, mas a operação de persistência é apenas “salvar nesta lista”.

**Correção sugerida**

- Se o seletor representa mover, remover a tarefa de A somente depois de persistir B e compensar em caso de falha.
- Se a edição não deve mover, desabilitar o seletor e mostrar a conversa original.
- Se a intenção for copiar, criar novo UUID e rotular explicitamente a ação como cópia.

---

## A1-018 — Editar tarefa sem prazo cria uma data que a pessoa não escolheu

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/Modelos/Tarefas/TarefaDaConversa.swift:8-13`
- `Papagaio/ViewModels/TarefasDaConversaViewModel.swift:102-109,129-132`
- `Papagaio/Funcionalidades/Tarefas/TarefasView.swift:742-749,768-779`

```swift
prazoDaTarefa = tarefa.prazo ?? Self.prazoPadrao
// ...
tarefa.prazo = prazoDaTarefa
// ...
prazoDoEditor = tarefa.tarefa.prazo ?? Date()
```

**Cenário de reprodução**

1. Carregue uma tarefa cujo `prazo == nil` (o modelo e o filtro “sem data” suportam esse estado).
2. Edite somente o título ou responsável e salve.
3. O editor substitui `nil` por uma semana no detalhe (`TarefasDaConversaViewModel`) ou por hoje no painel geral.
4. A tarefa deixa de aparecer em “sem prazo” e pode ser classificada como atrasada ou ter a prioridade alterada sem pedido explícito.

**Guardas buscadas para refutar**

- `TarefaDaConversa.prazo` é `Date?`, não há invariante que exija data.
- `FiltroDeDeadlineTarefa` tem caso `.semPrazo`.
- Não há um mecanismo que distinga “não toquei no prazo” no momento de inicializar/salvar.

**Causa**

Formulários usam `Date` não opcional como estado de edição e usam valores padrão como se fossem o valor original.

**Correção sugerida**

- Modelar o binding como `Date?`, com ação explícita “Sem prazo”.
- Ao abrir, apenas preencher o controle; ao salvar, atribuir `nil` quando o valor não foi alterado.
- Unificar o default entre os dois editores ou removê-lo do caminho de edição.

---

## A1-019 — Tarefa cancelada da fila CloudKit fica esperando o processamento anterior

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:103-123`

```swift
if processando {
    await withCheckedContinuation { esperas.append($0) }
} else {
    processando = true
}
defer { ... esperas.removeFirst().resume() ... }
try Task.checkCancellation()
```

**Cenário de reprodução**

1. A primeira chamada está dentro de `sincronizador.enviar` e aguarda rede.
2. A segunda chamada entra e fica em uma `CheckedContinuation<Void, Never>`.
3. Cancele a segunda task enquanto a primeira ainda está em `CloudKit`.
4. A flag de cancelamento não é observada até a continuation ser retomada; a task cancelada continua pendente e ocupa a fila de esperas.

**Guardas buscadas para refutar**

- `CheckedContinuation<Void, Never>` não lança `CancellationError`.
- `Task.checkCancellation()` só aparece depois do `await` da espera.
- Não há `withTaskCancellationHandler` ao redor de `esperas`.
- O `defer` só drena uma espera quando o processamento corrente termina.

**Causa**

Um semáforo manual com continuações não canceláveis foi usado onde uma primitive async cancellable seria mais segura.

**Correção sugerida**

- Usar um coordenador de posse com `withTaskCancellationHandler`; ao cancelar, remover a espera e liberar o próximo consumidor.
- Guardar a identidade/geração de cada espera para não retomar uma continuation já cancelada.
- Testar cancelamento enquanto a primeira operação está deliberadamente suspensa, não apenas depois de liberá-la.

---

## A1-020 — Player considera o canal principal como estado único e deixa o secundário tocando

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:136-153,229-232`

```swift
primario.play(atTime: inicio)
secundario?.play(atTime: inicio)
tocando = true
// ...
tempo = primario?.currentTime ?? 0
tocando = primario?.isPlaying ?? false
```

**Cenário de reprodução**

1. Use dois canais em que o sistema tenha duração maior que `microfone.wav` (o tap pode começar/continuar depois do microfone).
2. Inicie a reprodução paralela.
3. Quando o primário termina, `atualizarTempo` muda `tocando` para `false`, mas não chama `secundario.stop()` nem ajusta o relógio.
4. A UI mostra pausa enquanto o canal secundário ainda toca; um novo play pode operar em um primário já no fim.

**Guardas buscadas para refutar**

- `duracao` usa `max(primary, secondary)`, reconhecendo que as durações podem diferir.
- O estado de transporte, seek e `isPlaying` ignora completamente o secundário.
- Só `encerrar()` para ambos; não há guarda de fim de nenhum canal.
- Não há delegate/observer para o primário.

**Causa**

O player foi projetado como se os dois canais sempre tivessem exatamente o mesmo estado e a mesma duração. O estado publicado, o cursor e as ações de transporte observam apenas `primario`, enquanto `secundario` recebe apenas a chamada inicial de reprodução.

**Correção sugerida**

- Modelar os dois canais no estado de transporte e parar ambos quando qualquer canal obrigatório terminar ou quando o primário chegar ao fim.
- Ao final, zerar/pausar o cursor de forma determinística e evitar que `play()` tente retomar um primário no fim.
- Adicionar teste com canais de durações diferentes e com primário ausente.

---

## A1-021 — Falhas de captura/importação deixam mídia órfã

**Severidade:** MÉDIO  
**Confiança:** PROVÁVEL

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Importacao/ImportadorAudio.swift:64-72`
- `PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift:97-118`
- `Papagaio/ViewModels/Biblioteca.swift:296-300,1354-1368`
- `Papagaio/ViewModels/GravadorViewModel.swift:169-177`

```swift
let destino = try armazenamento.criarArquivoImportado(...)
try FileManager.default.copyItem(at: origem, to: destino)
// ...
catch {
    erros[...] = "Não foi possível copiar..."
    return nil
}
```

**Cenário de reprodução**

- `criarArquivoImportado` cria a pasta antes de `copyItem`; se a cópia falhar, a pasta/arquivo parcial fica.
- `SessaoGravacao` cria a pasta antes de `AVAudioRecorder`; se o inicializador lançar, o catch do `GravadorViewModel` não chama `descartar()` na sessão local.
- `criarArquivoDeReuniaoPendente` faz rollback no erro de persistência, mas não no erro de cópia.
- `Biblioteca.registrar` não remove `pastaRelativa` quando `repositorio.salvar` falha, embora a mídia já tenha sido produzida.

**Guardas buscadas para refutar**

- Há rollback explícito em alguns caminhos (`SessaoGravacao` quando `record()` retorna `false`, e reuniões após falha do repositório), mas não em todos os erros de criação/cópia.
- Não há reconciliação de pastas órfãs na inicialização.
- `removerTodasAsGravacoes` só ocorre na limpeza de conta, não após cada operação.

**Causa**

A propriedade do diretório temporário não foi transferida com uma transação/compensação uniforme para todas as fronteiras.

**Correção sugerida**

- Criar uma abstração de preparação de mídia com `defer` de rollback até o chamador assumir a propriedade.
- Remover a pasta em qualquer erro de `criar`, `copy`, `AVAudioRecorder`, duração ou persistência.
- Em `Biblioteca.registrar`, chamar `removerGravacao` no erro de salvamento e registrar a falha sem esconder a mídia órfã.
- Adicionar reconciliação de pastas sem registro apenas na inicialização, preservando Gravações ativas.

---

## A1-022 — Testes do app falham por comparar texto português com localidade inglesa

**Severidade:** BAIXO  
**Confiança:** CONFIRMADO

**Local e trecho**

- `PapagaioTests/EquipesCloudKitTests.swift:211,223-225,235-236`
- `PapagaioTests/InterfaceTests.swift:50`
- `PapagaioTests/MidiasDaConversaViewModelTests.swift:19,31`

```swift
#expect(equipe.resumoDeMembros == "participantes ainda não carregados")
#expect(esquema.contains("proprietário"))
#expect(mensagem.contains("desbloquear"))
```

**Cenário de reprodução**

Na localidade `en-BR`/`en_BR`, o código de produção localiza corretamente as strings, mas os testes esperam literais portugueses. A execução observada produziu, por exemplo:

```text
"participants not loaded yet"
"No speech was recognized in this audio."
"Unlock your iPhone before importing this file."
```

Foram observadas 6 funções de teste falhando (10 problemas), independente do travamento OAuth; a saída está em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit0/app-test.log:4409-4527`.

**Guardas buscadas para refutar**

- Alguns testes vizinhos usam `.localized` corretamente (`InterfaceTests.swift:64-73`).
- As asserções com literais não definem localidade nem usam a chave.
- A falha é de contrato de teste, não de esquema CloudKit ou de acesso a arquivo.

**Causa**

A barreira de CI mistura teste de comportamento com teste de catálogo/localização e depende da localidade da máquina.

**Correção sugerida**

- Fixar a localidade na preparação de teste ou comparar com a mesma resolução `.localized` usada pela produção.
- Para mensagens de negócio, testar códigos/estruturas e frases estáveis; testar o catálogo em uma suíte separada com `en` e `pt-BR`.
- Remover a dependência de localidade do CI e manter uma barreira de localidade explícita.

---

## Candidatos refutados ou não contabilizados

### Data do Granola com `GMT-3`

`FonteGranola.swift:251-284` remove o sufixo e passa `GMT-3` para `DateFormatter.timeZone`. A diferença de três horas observada no probe é a representação correta do mesmo instante; não é perda de deslocamento. O mapeador do core também trata datas sem hora explicitamente em UTC.

### Nomes legados de PCM sem reprodução separada

O pipeline enumera `microfone.pcm`, `sistema.pcm` e `sistema.wav` em `PipelineDeArquivo.swift:347-356`, mas a gravação legada também produzia `gravacao.m4a` (`SessaoGravacao` histórico). `Biblioteca.audio` já cai para essa mixagem em `:1255-1268`. Portanto não foi contabilizado como “áudio ausente”; apenas a reprodução em dois canais legados não é reconstruída.

### Segredo OAuth opcional no core

`Optional(nil)` em um dicionário JSON pode ser serializado como `null`; o probe de `JSONSerialization` confirmou `{"client_secret":null}`. Não foi classificado como defeito de persistência.

## Limitações e integridade da auditoria

- Não houve chamada a Google, Granola, CloudKit real, microfone, Process Taps ou download de dependências.
- OAuth, SSE, persistência SwiftData, lixeira, transformações e concorrência foram exercitados apenas com fakes/probes locais, sem alterar produção.
- A suíte do app não forneceu contagem final confiável enquanto o servidor OAuth continuava bloqueado; o problema está documentado em A1-002.
- Arquivos modificados/não rastreados preexistentes foram preservados; este relatório é o único arquivo produzido por esta auditoria.

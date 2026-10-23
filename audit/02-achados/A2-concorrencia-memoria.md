# A2 — Concorrência, estado e memória

> **Auditoria independente:** 2026-09-23 · Swift 6.4 / Xcode 27.0 / macOS 27.0
>
> **Modo:** relatório. Nenhum arquivo de produção, teste, manifesto ou configuração foi alterado.
>
> **Escopo lido:** `audit/00-mapa.md` integral; os 232 `.swift` de produção em `Papagaio/**` e `PapagaioCore/Sources/**`; e os 33 `.swift` de teste em `PapagaioCore/Tests/**` e `PapagaioTests/**`.
>
> **Escrita desta execução:** somente este arquivo. Os documentos e demais arquivos já sujos do working tree foram preservados.

## 1. Resumo e contagens

Foram aceitos **8 achados**. A contagem não inclui hipóteses condicionais não reproduzidas nem observações refutadas.

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 0 |
| ALTO | 4 |
| MÉDIO | 2 |
| BAIXO | 1 |
| INFO | 1 |
| **Total** | **8** |

| Confiança | Quantidade |
|---|---:|
| **CONFIRMADO** | 3 |
| **PROVÁVEL** | 5 |
| **HIPÓTESE** aceita | 0 |

`CONFIRMADO` significa que o comportamento foi reproduzido nesta execução ou que a prova de posse/contrato é direta e sem alternativa plausível. A consequência de memória de modelos simultâneos, por exemplo, continua `PROVÁVEL` porque não houve medição de RSS/footprint com os pesos carregados.

### Resultado dos quatro itens preliminares de `audit/02-achados/A2.md`

| Item preliminar | Resultado independente |
|---|---|
| `A2-001` — OAuth Google | **Aceito como CONFIRMADO.** O teste de produto ficou no primeiro caso de cancelamento; o experimento de socket reproduziu `shutdown` com `errno=57` sem despertar `accept()`. |
| `A2-002` — ditado | **Aceito em formato reduzido como PROVÁVEL.** A ausência de cancelamento e a janela de reentrância são fatos; a continuação do microfone após a destruição da view depende do ciclo de vida do AVFoundation/Speech e não foi observada com TCC. |
| `A2-003` — exclusividade de modelos | **Aceito em formato reduzido como PROVÁVEL.** A colisão do registro e a existência de instâncias independentes são confirmáveis; o resultado de jetsam/GB simultâneos não foi medido. |
| `A2-004` — callbacks CloudKit | **Refutado como data race.** O header do SDK garante execução serial dos callbacks da operação. A hipótese de continuação esquecida não foi demonstrada. |

Os demais itens do relatório preliminar foram reclassificados: o `assumeIsolated` do Sign in with Apple não tem prova de thread errada; o cache de aparência tem limpeza nos caminhos de exclusão; e a troca de espaço não invalida trabalho/edições tardias, mas a justificativa original sobre a guarda de identificador era imprecisa.

---

## 2. Método e limites de confiança

1. Li o mapa e o relatório preliminar sem reutilizar suas conclusões.
2. Para cada candidato, segui os chamadores até o limite relevante: `Task` não estruturada, `onDisappear`, `deinit`, `NotificationCenter`, `Timer`, `actor`, filas, `CheckedContinuation`, guards de espaço/lixeira, `NSLock`, `@unchecked Sendable` e `nonisolated(unsafe)`.
3. Executei buscas finais em todo o produto por `Task`, `Task.detached`, `withCheckedContinuation`, `actor`, `MainActor`, `assumeIsolated`, `DispatchSemaphore`, `NSLock`, `Timer`, `addObserver`, `static var`, `onDisappear`, `cancel`, `MotoresLocais`, callbacks CloudKit e `DitadoDeNota`.
4. Experimentos de mecanismo foram compilados com `clang`/`swiftc` no diretório temporário autorizado. Só o experimento do OAuth foi confrontado com o teste do aplicativo; os demais programas auxiliares reproduzem literalmente o padrão de controle, mas não são substitutos de um teste de integração.
5. Não usei Instruments, TSan em execução, conta CloudKit real, navegador real, permissão TCC nem hardware de microfone. Não houve medição de memória de modelos, tempo de download ou throughput.

A distinção entre fato e inferência aparece em cada achado. Não há número de memória ou throughput neste relatório sem a condição de medição explicitada.

---

## 3. Achados

### A2-001 — `shutdown()` no socket de escuta não cancela `accept()` do OAuth Google

- **Severidade:** ALTO
- **Confiança:** **CONFIRMADO**
- **Locais:** `Papagaio/Integracao/SessaoOAuthGoogle.swift:160-185`, `:416-452`, `:484-498`; `PapagaioTests/OAuthGoogleTests.swift:47-83`, `:169-194`.

**Evidência de código**

```swift
// :423-441
try await withCheckedThrowingContinuation { continuacao in
    Self.filaDeSocket.async {
        let codigo = try Self.receberCallback(
            no: listener.fileDescriptor,
            conexao: conexao,
            estadoEsperado: estadoEsperado
        )
        ...
    }
} onCancel: {
    conexao.cancelar()
    Darwin.shutdown(listener.fileDescriptor, SHUT_RDWR)
}
```

O worker fica em `Darwin.accept` (`:491-495`). `parar()` também chama `shutdown` no descriptor de escuta (`:444-448`) e apenas faz `listener = nil`; não há `close()` nesse caminho. O `FileHandle` continua capturado pelo closure que executa o worker, portanto o closure não perde a propriedade do ator.

**Reprodução**

O experimento mínimo em `$TMP/oauth_shutdown_accept.c` fez `socket → bind → listen`, iniciou `accept` em outra thread e chamou `shutdown` no socket de escuta:

```text
$ clang -Wall -Wextra -Werror oauth_shutdown_accept.c -o oauth_shutdown_accept && ./oauth_shutdown_accept
shutdown_result=-1 shutdown_errno=57 accept_done_after_300ms=0
self_connect=0 accept_done_after_self_connect=1 accept_errno=0
```

O `57` é `ENOTCONN` no macOS desta máquina: a operação nem chega a ser um cancelamento válido do socket de escuta. O `accept` só acordou quando o próprio experimento fez `connect`.

No produto, a execução completa do app em `$TMP/app-tests-repro.log:330-338` chegou a:

```text
Test "Cancelar a espera fecha o servidor local e desbloqueia o callback" started.
** BUILD INTERRUPTED **
```

O wrapper encerrou o processo após 120 s; não houve resultado do teste. A baseline anterior já registrava os dois casos pendurados em `audit/00-mapa.md:396-412`. O caso `cancelarOAuthComClienteSilencioso` (`:169-194`) não é contrapeso: ele conecta um cliente antes de cancelar, portanto `accept` já retornou e `ConexaoOAuthLocal` consegue fechar o cliente (`:595-609`).

**Cenário e impacto**

Timeout de 180 s, cancelamento do `GoogleCalendarViewModel` ou uma tentativa que não recebe callback deixam a task de `aguardarCodigo` presa no filho de `withThrowingTaskGroup`. O grupo não sai enquanto o filho não retornar. A task de conexão de `GoogleCalendarViewModel` (`GoogleCalendarViewModel.swift:60-73`) permanece não nula; tentativas seguintes são ignoradas pelo guard (`:61`). O usuário precisa reiniciar o processo.

Não afirmo deadlock matemático eterno: uma conexão posterior pode despertar o `accept`. O defeito confirmado é que **cancelamento e timeout não descongelam a operação**; sem uma nova conexão, ela fica bloqueada.

**Correção sugerida (não aplicada):** usar `DispatchSource` de leitura ou uma conexão local de wakeup que passe pelo ramo já existente de `conexao.cancelada`, em vez de `shutdown` no listener. O teste de produto deve ter um limite externo independente.

---

### A2-002 — O ditado não pertence ao ciclo de vida da tela e pode ser iniciado duas vezes

- **Severidade:** ALTO
- **Confiança:** **PROVÁVEL** (a falta de guard e a corrida são demonstráveis; a persistência do microfone após a destruição não foi observada com TCC)
- **Locais:** `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:41-82`, `:1028-1055`, `:513-520`, `:1386-1400`; `Papagaio/ViewModels/GravadorViewModel.swift:415-482`, `:491-579`; `Papagaio/Funcionalidades/Detalhe/NotasDaConversa.swift:152-166`.

**Evidência de ciclo de vida**

```swift
// ArquivoDetalheView.swift:82
@State private var ditado = DitadoDeNota()

// :513-520
.onDisappear {
    tarefaDeSalvamentoDasNotas?.cancel()
    salvarNotasAgora()
    reprodutor?.encerrar()
    reprodutor = nil
}
```

A troca de seção substitui `notasDaConversa` por outro resultado do `switch` (`:1042-1055`), mas não executa o `onDisappear` do pai. O `@State` e o objeto `DitadoDeNota` continuam vivos enquanto a tela permanece. A busca final em produção e testes não encontrou nenhuma chamada `ditado.cancelar()`; o método existe em `GravadorViewModel.swift:571-579`, mas permanece sem chamador.

`DitadoDeNota.iniciar()` instala o tap e inicia o motor (`:427-469`). `CapturaDeDitado` não possui `deinit`; portanto não há uma garantia explícita de `removeTap`, `motor.stop()` e `endAudio()` quando a view é destruída. A afirmação mais forte que a prova permite é: **o código não cancela a captura ao sair; enquanto o objeto/task for retido, a captura continua**. O comportamento do AVFoundation depois da liberação do objeto depende de framework/sistema operacional e não foi medido.

**Corrida de início**

`alternarDitado` cria uma `Task` sem armazenamento a cada clique (`:1386-1400`). `iniciar()` começa assim:

```swift
// GravadorViewModel.swift:509-543
guard !ocupado else { return }
estado = .ocioso
textoParcial = ""
guard await autorizarMicrofone() else { ... }
guard await autorizarFala() else { ... }
...
estado = .gravando
```

Entre o guard e `estado = .gravando` existem awaits de permissões e criação do reconhecedor. Duas tasks podem passar pelo mesmo guard antes de a primeira alterar o estado. Cada uma cria seu próprio arquivo e `CapturaDeDitado`; a segunda atribuição a `captura` (`:542`) pode perder o controle da primeira. O botão só fica desabilitado para `.transcrevendo` (`NotasDaConversa.swift:152-166`), não para uma fase `.starting`.

Também não há handle para a task de `alternarDitado`; se a view desaparecer durante `transcrever`, a task pode concluir e chamar `salvarNotasAgora` depois. Isso conecta com a falta de escopo de edição em A2-004.

**Cenário e impacto**

- iniciar ditado → trocar de Notas para Transcrição: a view deixa de mostrar o indicador, mas o objeto continua retido e o pedido de Speech pode continuar enviando parciais;
- dois acionamentos durante a autorização: duas capturas competem pelo microfone e uma fica sem dono explícito;
- `.caf` temporário (`:532-533`) só é removido em `concluir`/`cancelar`; destruição/interrupção pode deixá-lo no diretório temporário.

**Correção sugerida (não aplicada):** representar `.iniciando`/`.parando`, armazenar e invalidar a task, usar um identificador de geração, chamar `ditado.cancelar()` no desaparecimento da tela e dar limpeza explícita em `CapturaDeDitado`. Injetar uma captura falsa permitiria testar a corrida sem TCC.

---

### A2-003 — A exclusividade de Whisper/Qwen é por instância e o registro global troca a geração do residente

- **Severidade:** ALTO
- **Confiança:** **PROVÁVEL** (fato de posse confirmado; uso simultâneo de pesos/jetsam não medido)
- **Locais:** `Papagaio/ViewModels/Biblioteca.swift:842-861`, `:873-977`, `:987-1041`; `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:5-27`, `:39-69`, `:179-213`; `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift:14-77`; `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:73-129`; `PapagaioCore/Sources/PapagaioCore/Diarizacao/GerenciadorDeModelosDeDiarizacao.swift:12-15`, `:85-87`.

**Evidência**

`MotoresLocais` declara a fila como propriedade de cada instância:

```swift
// MotoresLocais.swift:16-22
public actor MotoresLocais {
    private var contextoWhisper: ContextoWhisper?
    private var contextoLlama: ContextoLlama?
    private let fila = FilaEstrita()
    private let ciclo: CicloDeVidaDeModelos?
}
```

O app cria três instâncias locais apontando para o mesmo `ciclo`: ditado (`:852`), pipeline (`:896`) e diarização (`:1008`). `transcreverDitado` não tem guarda de pipeline; `diarizarTranscricao` só impede o mesmo arquivo/uma fase local (`:987-1002`). Logo, duas operações diferentes podem usar duas filas independentes.

O ciclo, por outro lado, indexa somente por identificador:

```swift
// CicloDeVidaDeModelos.swift:21, :53-59
private var residentes: [String: any Residente] = [:]
public func registrar(_ residente: any Residente) {
    residentes[residente.identificador] = residente
}
public func remover(_ identificador: String) {
    residentes[identificador] = nil
}
```

`WhisperEngine.identificador` e `GerenciadorDeModelosDeDiarizacao.identificador` são constantes (`WhisperEngine.swift:43-49`, `:145-147`; `GerenciadorDeModelosDeDiarizacao.swift:15`). O mesmo identificador substitui o residente anterior; a limpeza de uma geração remove a entrada da outra.

Compilei o `CicloDeVidaDeModelos.swift` real com dois residentes falsos de mesmo identificador:

```text
$ swiftc -parse-as-library -swift-version 6 CicloDeVidaDeModelos.swift ciclo_colisao.swift -o ciclo_colisao && ./ciclo_colisao
ids=["whisper-large-v3"]
primeiro_descarregou=false segundo_descarregou=true
ids_fim=[]
```

**Cenário e impacto**

Um pipeline em transcrição e um ditado em outra conversa podem manter dois contextos Whisper. Uma diarização em outro arquivo pode, adicionalmente, registrar seu gerenciador sob a chave da diarização do pipeline. A pressão de memória descarrega o lote visível no dicionário, mas pode deixar o contexto substituído sem monitoramento. O comentário de `MotoresLocais` afirma exclusividade global (`:5-15`), mas a fila só é global dentro da instância.

O modelo Whisper declarado tem 3.095.033.483 bytes e o Qwen 6.169.341.984 bytes (`audit/00-mapa.md:99-102`; `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:24-31`). Esses são tamanhos de arquivo, não medição de RSS. **Não afirma-se** que dois ResidentSets foram medidos nesta auditoria; a duplicação de posse é o defeito comprovado.

**Correção sugerida (não aplicada):** compartilhar um coordenador de `MotoresLocais` por biblioteca/processo e serializar ditado/diarização com a fila de processamento; alternativamente, registrar com token de geração e só remover se o resident for o mesmo objeto.

---

### A2-004 — Edições e tarefas tardias não são escopadas ao espaço/ao dono do arquivo

- **Severidade:** ALTO
- **Confiança:** **PROVÁVEL** (cadeia de posse estática; não foi executado um teste com `SwiftDataRepository` deliberadamente atrasado)
- **Locais:** `Papagaio/App/ContentView.swift:561-595`, `:897-933`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:922-945`, `:1361-1400`; `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:1277-1301`; `Papagaio/ViewModels/Biblioteca.swift:211-237`, `:599-692`, `:1067-1085`; `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:40-64`.

Este achado reúne a causa comum “trabalho iniciado por uma tela não recebe um token de geração/dono”. Ele também corrige o item preliminar sobre troca de espaço.

**Edições tardias**

O detalhe captura um valor `arquivo` e cria tasks sem handle:

```swift
// ContentView.swift:575-593
aoAtualizarNotas: { notas in
    await biblioteca.atualizarNotas(notas, de: arquivo)
},
...
aoAtualizarMetadados: { titulo, data, duracao in
    Task {
        await biblioteca.atualizarMetadados(arquivo, ...)
    }
}
```

`ArquivoDetalheView.salvarNotasAgora` também cria uma task não cancelável (`:1378-1381`), e `alternarDitado` cria a task que pode atravessar a navegação (`:1386-1400`). O mesmo padrão existe nos cards (`BibliotecaHomeView.swift:1281-1292`).

No destino, os métodos apenas verificam se uma operação de lixeira está em andamento:

```swift
// Biblioteca.swift:660-672
guard !operacoesDeLixeiraEmAndamento.contains(arquivo.id) else { return }
var editado = arquivo
editado.notas = notas
try await repositorio.salvar(editado)
substituir(editado)
await sincronizar(editado)
```

`substituir` insere o arquivo quando não encontra o id (`:1067-1072`). `SwiftDataRepository.salvar` cria um registro quando não encontra o id (`SwiftDataRepository.swift:40-64`). Não há verificação de `arquivo.espaco == espaco`, geração da tela, `Task.isCancelled` ou existência atual.

Cenários:

1. editar notas/metadados no espaço A, trocar para B antes de a task.save executar: a task pode salvar o payload A e `substituir` pode inseri-lo na lista de B;
2. a mesma task chama `sincronizar` (`:1075-1085`) usando a equipe atualmente selecionada, sem verificar que o arquivo pertence àquele espaço;
3. excluir definitivamente o arquivo enquanto a task está pendente: depois que `operacoesDeLixeiraEmAndamento` é removido, um save tardio pode recriar o registro no SwiftData. O guard de lixeira cobre apenas a janela da operação, não uma edição já capturada.

`registrar` mostra o padrão que falta nesses métodos: depois do await ele recheca `espacosExcluidos` e `espaco` (`Biblioteca.swift:302-318`). Não há equivalente em `atualizarMetadados`, `atualizarNotas`, `atualizarTrechos` ou `renomear`.

**Pipeline tardio**

`usarEspaco` limpa a fila e as listas (`:221-229`), mas não cancela `tarefaDeProcessamento` nem muda `identificadorDaExecucao`. O pipeline pode continuar seu bloco síncrono Whisper/Qwen, salvar o registro do espaço antigo (`:162`, `:189` em `PipelineDeArquivo.swift`) e atualizar fases. A guarda final de UI (`:943-945`) pode descartar a substituição na lista nova, mas não desfaz o trabalho nem os saves no repositório. Portanto a formulação preliminar de que a guarda de identificador “muda/falha” não é exata: o identificador permanece o mesmo; a guarda de membro da lista é que normalmente falha.

**Correção sugerida (não aplicada):** capturar `contextoDoEspaco`/geração junto de cada edição, verificar id + espaço imediatamente antes de `salvar`, `substituir` e `sincronizar`; rejeitar ids excluídos; armazenar/cancelar tasks de edição no ciclo de vida da view. Cancelar e aguardar o pipeline antes de trocar de espaço e usar uma geração de execução separada para qualquer trabalho deliberadamente assíncrono.

---

### A2-005 — Cancelamento perdido no registro do callback OAuth do Granola

- **Severidade:** MÉDIO
- **Confiança:** **CONFIRMADO**
- **Locais:** `Papagaio/Integracao/ApresentadorDeSessaoDeAutorizacao.swift:24-56`; `Papagaio/Integracao/GerenciadorDeCallbackDeAutorizacao.swift:19-52`; `Papagaio/Integracao/GranolaViewModel.swift:109-127`; `Papagaio/Integracao/SessaoOAuth.swift:182-190`.

**Evidência**

```swift
// ApresentadorDeSessaoDeAutorizacao.swift:24-55
try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuacao in
        GerenciadorDeCallbackDeAutorizacao.compartilhado
            .aguardar(estado: estadoEsperado) {
                continuacao.resume(with: resultado)
            }
        ...
    }
} onCancel: {
    GerenciadorDeCallbackDeAutorizacao.compartilhado.resolver(
        estado: estadoEsperado,
        com: .failure(.autorizacaoNegada)
    )
}
```

`resolver` remove e resolve apenas uma entrada existente (`:46-52`). Se a task já está cancelada quando `withTaskCancellationHandler` inicia, `onCancel` pode rodar antes de `aguardar` registrar a continuação. A chamada de cancelamento encontra o dicionário vazio; o corpo da operação registra a espera depois, e ninguém a resolve.

Reproduzi esse padrão exato com `$TMP/continuation_cancel_race_probe.swift`:

```text
$ swiftc -parse-as-library -swift-version 6 continuation_cancel_race_probe.swift -o continuation_cancel_race_probe && ./continuation_cancel_race_probe
onCancel
resolver: cancelamento, callback=false
registrado
operation corpo
continuation terminou antes de resolução manual: false
resolver: resolução manual de limpeza, callback=true
```

**Cenário e impacto**

`GranolaViewModel.encerrarLocalmenteParaExclusaoDoPerfil` cancela e aguarda a task de conexão (`:109-115`). Na janela acima, a exclusão de conta pode ficar presa até a task de timeout de 300 s de `Apresentador...:40-49` (ou mais, se a task não for executada). O mesmo padrão afeta qualquer chamador que cancele uma task durante o registro do callback. O caso normal, em que a task é cancelada depois do registro, funciona; o problema é a corrida de registro, não o lock do gerenciador.

**Correção sugerida (não aplicada):** registrar e armar o cancelamento atomicamente sob o lock do manager, retornar um token de registro, verificar `Task.isCancelled` antes/depois do registro e reter/cancelar explicitamente a task de timeout.

---

### A2-006 — Esperas canceladas permanecem nas filas de exclusão

- **Severidade:** MÉDIO
- **Confiança:** **CONFIRMADO** para o comportamento da fila; o impacto no produto depende da duração da operação de rede/nativa ativa.
- **Locais:** `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:103-119`; `PapagaioCore/Sources/PapagaioCore/Transcricao/FilaEstrita.swift:14-37`; chamadores `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:179-193`, `PapagaioCore/Sources/PapagaioCore/Transcricao/DetectorDeAtividadeDeVoz.swift:320-365`, `PapagaioCore/Sources/PapagaioCore/Runtime/DownloadDeModelos.swift:62-75`.

**Evidência**

```swift
// FilaPersistenteCloudKit.swift:108-118
if processando {
    await withCheckedContinuation { esperas.append($0) }
} else {
    processando = true
}
defer {
    if esperas.isEmpty { processando = false }
    else { esperas.removeFirst().resume() }
}
try Task.checkCancellation()
```

`CheckedContinuation<Void, Never>` não é sensível a cancelamento. A verificação ocorre somente depois de a continuação ser retomada. A mesma forma de fila está em `FilaEstrita.entrar` (`:18-28`); seus chamadores só verificam o cancelamento depois de `entrar` retornar.

Uma reprodução auxiliar do formato exato de ator/continuação/defer mediu que uma espera cancelada permaneceu retida durante toda a operação ativa:

```text
$ swiftc -parse-as-library -swift-version 6 fila_waiter_cancel.swift -o fila_waiter_cancel && ./fila_waiter_cancel
B finished before releasing A: false
B finished after releasing A: true
```

**Cenário e impacto**

Uma segunda solicitação de sincronização/retry/modelo/VAD, cancelada enquanto a primeira está em CloudKit ou trabalho nativo síncrono, permanece em `esperas`, retendo sua task e seus contextos capturados. Só executa `Task.checkCancellation` quando o dono atual chega ao `defer`. Se o dono espera por uma chamada nativa longa ou rede parada, a task cancelada permanece viva por todo esse intervalo. Várias esperas canceladas também podem causar atraso de fila.

Este não é um bug de wakeup perdido: os caminhos normal e de erro de `FilaPersistente` usam `defer`, e `FilaEstrita` libera nos `do/catch` dos chamadores. O defeito é latência de cancelamento e retenção, não corrupção permanente da fila.

**Correção sugerida (não aplicada):** tornar as esperas identificáveis e sensíveis a cancelamento, remover entradas canceladas antes de conceder a vez e usar um handler de cancelamento que não retome a mesma continuação duas vezes.

---

### A2-007 — O encerramento bloqueia a main thread por até 2 s

- **Severidade:** BAIXO
- **Confiança:** **PROVÁVEL** (o bloqueio e o teto são diretos; não medi o tempo real de unload)
- **Local:** `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift:91-114`.

```swift
// :93-113
observadorDeSaida = NotificationCenter.default.addObserver(
    ..., queue: .main
) { [weak self] _ in
    guard let self else { return }
    let espera = DispatchSemaphore(value: 0)
    Task {
        await self.descarregarTudo()
        espera.signal()
    }
    _ = espera.wait(timeout: .now() + 2)
}
```

A fila do observer é `.main` e o handler é síncrono, portanto `espera.wait` bloqueia o run loop principal até o descarregamento terminar ou o timeout fixo de dois segundos. As tasks de descarregamento não exigem `MainActor`, então não foi encontrado deadlock; este é um custo de responsividade limitado, não um congelamento infinito confirmado. O próprio código aceita descarregamento parcial no timeout (`:102-107`).

**Correção sugerida (não aplicada):** expor a liberação do ponteiro nativo como uma operação síncrona e limitada, ou reduzir/medir a espera; testar a saída com um resident e com um descarregamento em andamento.

---

### A2-008 — Cache residual sem limite para nomes de pessoas; caches de arquivo/pasta têm limpeza

- **Severidade:** INFO
- **Confiança:** **PROVÁVEL** somente para crescimento sem limite; nenhuma medição de bytes/alocações foi feita.
- **Locais:** `Papagaio/Persistencia/FotosDePessoas.swift:30-35`, `:44-67`, `:156-165`; `Papagaio/Persistencia/AparenciaDoCartao.swift:71-81`, `:121-137`, `:156-166`; `Papagaio/Persistencia/AparenciaDasPastas.swift:230-234`, `:274-312`; `Papagaio/Persistencia/CorDominanteDeImagem.swift:17-40`; `Papagaio/Persistencia/LimpezaDeConta.swift:7-16`.

`FotosDePessoas.urlsResolvidas` é um dicionário com duração da sessão, sem LRU ou expiração; uma sessão longa que encontra muitos nomes normalizados distintos cresce sem limite. Esta é uma observação residual, não um vazamento medido nem evidência de efeito de vários gigabytes.

A afirmação preliminar original era ampla demais: a aparência de uma conversa é removida por `AparenciaDoCartao.remover` (`:129-137`), chamada por `LimpezaDeArquivo.executar` (`LimpezaDeConta.swift:7-16`); a de pasta é removida por `AparenciaDasPastas.esquecer` (`:93-102`); as imagens decodificadas ficam em `NSCache`, não nos dicionários ilimitados de URL. Fotos de pessoas são indexadas por nome, não por conversa, e são mantidas intencionalmente quando apenas uma conversa é excluída.

**Correção sugerida (não aplicada):** medir primeiro a quantidade de nomes distintos; se importar, usar cache limitado ou limpeza explícita de sessão. Não tratar os caches de cartão/pasta como vazamento ilimitado sem nova reprodução.

---

## 4. Hipóteses e refutações que não foram promovidas a achado

### CloudKit callbacks: A2-004 preliminar refutado

`SincronizadorDaBibliotecaCloudKit.swift:246-270` armazena `registros` e `erroPorRegistro` mutáveis em closures que escapam. A forma seria insegura se os callbacks pudessem se sobrepor, mas o contrato do SDK instalado diz o contrário. O header local afirma:

- `recordChangedBlock`/`recordWasChangedBlock` executam serialmente em relação aos outros closures da operação: `CKFetchRecordZoneChangesOperation.h:118`, `:132`;
- os callbacks de zona e o resultado final também são seriais: `:172`, `:183-186`.

Assim, a data race de `Array` proposta em A2-004 não é aceita. O código não tem lock separado, mas não precisa dele para essa garantia documentada. Um callback que nunca chega seria outra hipótese de infraestrutura; o header define o callback final como o callback de término da operação, e nenhuma execução real de CloudKit foi feita para provar esse caso. Não há achado para ele.

### `MainActor.assumeIsolated` no Sign in with Apple: não confirmado

`PerfilViewModel.swift:241-247` é uma asserção de runtime: se AuthenticationServices chamar o provider fora do executor principal, `assumeIsolated` pode abortar. Porém, o SDK local marca `ASAuthorizationController` como `NS_SWIFT_UI_ACTOR` (`ASAuthorizationController.h:30`) e o protocolo provider continua sendo um callback Objective-C `nonisolated` (`:32-38`). Não há teste, Main Thread Checker nem captura da thread nesse fluxo. Permanece `HIPÓTESE`, não um achado aceito. O timer de `ReprodutorDeArquivo.swift:127-131` e o completion de animação em `JanelaFlutuanteDeGravacao.swift:186-191` têm contexto explícito de main/AppKit e não foram tratados como casos equivalentes não provados.

### Outras hipóteses de posse verificadas

- `ContextoWhisper`, `ContextoLlama` e o runtime de diarização isolam seus managers C/vendor não-Sendable; não foi encontrado use-after-free causado pelo handler de pressão. O risco de A2-003 é posse duplicada, não uma race de ponteiro C confirmada.
- Os chamadores de `FilaEstrita` liberam em caminhos normal e de erro. Os testes de concorrência do VAD passam; a lacuna é latência de espera cancelada, não uma liberação perdida.
- A posse de timers/observers é geralmente limitada: `ReprodutorDeArquivo` usa bloco fraco e `isolated deinit` (`:127-131`, `:210-225`); `SessaoGravacao` invalida timer e para recorder/tap (`:341-354`); `PerfilViewModel` remove observer (`:36-49`); `JanelaFlutuanteDeGravacao` usa observer fraco e estado de duração do app (`:160-167`).
- `ClienteMCP` extrai a task de inicialização sob `NSLock` e a espera depois de liberar o lock (`:77-99`); não foi encontrado lock atravessando `await`.
- `NivelAudio` usa `Atomic<UInt32>` (`:10-39`), e `SystemAudioTap` confina estatísticas ao IOProc e protege pausa com `OSAllocatedUnfairLock` (`SystemAudioTap.swift:416-469`).
- Os usos de `Task.detached` fazem cópias/zips e geralmente são aguardados antes de o chamador continuar. Não formam uma race de atualização perdida comprovada; a falta de cancelamento cooperativo é risco residual apenas quando o chamador abandona uma exportação, e não foi contada.

### Risco condicional de múltiplas janelas (não contado)

`PapagaioApp` usa `WindowGroup` (`Papagaio/App/PapagaioApp.swift:60-64`). Cada `ContentView.abrir` constrói uma `Biblioteca` e seu próprio `CicloDeVidaDeModelos`/`FilaPersistenteCloudKit` (`ContentView.swift:422-460`), enquanto o caminho da outbox deriva da mesma raiz de armazenamento (`:159-163`). Se mais de uma janela de produção estiver aberta, monitores de modelo por instância e atores de outbox sobre o mesmo arquivo não formam um coordenador global demonstrado. Não foi executada uma reprodução de UI com várias janelas; isso permanece `HIPÓTESE` condicional, não achado.

---

## 5. Testes e reproduções executados

Nos caminhos abaixo, `$TMP` significa `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a2`.

| Verificação | Resultado |
|---|---|
| `clang ... oauth_shutdown_accept.c && ./oauth_shutdown_accept` | `shutdown=-1`, `errno=57`, `accept` não acordou em 300 ms; acordou após uma auto-conexão. Log: `$TMP/oauth-shutdown-accept.log`. |
| `xcodebuild test -project Loro.xcodeproj -scheme Loro -destination 'platform=macOS' ... -parallel-testing-enabled NO -derivedDataPath .../oauth-derived` com wrapper de 120 s | O teste de cancelamento iniciou e o run foi interrompido sem resultado; o log também contém as falhas de localização anteriores. Log: `$TMP/app-tests-repro.log:330-338`. |
| `swiftc ... fila_waiter_cancel.swift && ./fila_waiter_cancel` | Waiter cancelado não terminou antes da liberação do dono; terminou depois. Log: `$TMP/fila_waiter_cancel.log`. |
| `swiftc ... continuation_cancel_race_probe.swift && ./continuation_cancel_race_probe` | `onCancel` resolveu antes do registro; a continuação não terminou antes da resolução manual. Log: `$TMP/continuation_cancel_race_probe.log`. |
| `swiftc ... CicloDeVidaDeModelos.swift ciclo_colisao.swift && ./ciclo_colisao` | A segunda geração substituiu a primeira no dicionário; somente a segunda foi descarregada. Log: `$TMP/ciclo_colisao.log`. |
| `swift test --scratch-path .../core-scratch --filter 'RuntimeTests|DetectorDeAtividadeDeVozTests|PipelineTests'` | 39 testes em 3 suítes; 38 passaram e o teste de identidade do pipeline reproduziu a falha já conhecida com 2 issues. Log: `$TMP/core-focused-test.log`. |
| `swift test --scratch-path .../core-tsan-scratch --sanitize thread --filter 'IsolamentoDeSessoesDoVADTests|RuntimeTests'` | Não chegou a executar TSan: a compilação dos testes falhou no diagnóstico Swift 6 `sending 'sobrecarga' risks causing data races` em `DetectorDeAtividadeDeVozTests.swift:164` (e no mesmo comando para `DiarizacaoTests.swift`). Não foi tirada conclusão de TSan. Log: `$TMP/core-tsan-test.log`. |

O diretório `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a2` continha todos esses logs, binários e dados derivados. Nenhum deles foi necessário para a árvore do projeto.

---

## 6. Cobertura por pasta

Contagem física por `wc -l` no momento da auditoria. O corpus numerado inclui headers/separadores e, por isso, tem contagem maior:

| Área | Arquivos `.swift` | Linhas |
|---|---:|---:|
| `Papagaio/` total | **171** | **34.232** |
| `Papagaio/App` | 5 | 1.296 |
| `Papagaio/CloudKit` | 4 | 1.301 |
| `Papagaio/DesignSystem` | 22 | 2.623 |
| `Papagaio/Diagnostico` | 2 | 265 |
| `Papagaio/Funcionalidades` | 64 | 17.400 |
| `Papagaio/Integracao` | 9 | 2.550 |
| `Papagaio/Modelos` | 18 | 846 |
| `Papagaio/Persistencia` | 23 | 2.604 |
| `Papagaio/Suporte` | 14 | 2.015 |
| `Papagaio/ViewModels` | 10 | 3.332 |
| `PapagaioCore/Sources/` total | **61** | **11.370** |
| `PapagaioCore/Sources/PapagaioCore` | 49 | 8.847 |
| `PapagaioCore/Sources/WhisperRuntime` | 2 | 366 |
| `PapagaioCore/Sources/LlamaRuntime` | 2 | 284 |
| `PapagaioCore/Sources/OnnxApi` | 1 | 228 |
| `PapagaioCore/Sources/DiarizationRuntime` | 1 | 96 |
| `PapagaioCore/Sources/papagaio-eval` | 6 | 1.549 |
| `PapagaioCore/Tests/` | **20** | **4.837** |
| `PapagaioTests/` | **13** | **2.893** |
| **Produção total** | **232** | **45.602** |
| **Testes total** | **33** | **7.730** |

Também foram lidos integralmente `audit/00-mapa.md` (669 linhas), `audit/02-achados/A2.md` (554 linhas) e os dois corpus numerados preservando as linhas originais. A cobertura de produção é integral no escopo solicitado, não uma amostra dos hotspots. A leitura dos testes incluiu `OAuthGoogleTests`, `EquipesCloudKitTests`, `BibliotecaTests`, `RuntimeTests`, `DetectorDeAtividadeDeVozTests`, `RefatoracaoCoreTests` e os demais 27 arquivos.

### Buscas finais relevantes

- `ditado.cancelar`: **0 chamadores**; somente a definição em `GravadorViewModel.swift:571`.
- `MotoresLocais(`: três chamadas de produção, todas em `Biblioteca.swift:852`, `:896`, `:1008`.
- `Darwin.shutdown` no OAuth: apenas listener (`:440`, `:447`) e cliente aceito (`:598`, `:605`); não há `close()` do listener nesse caminho.
- `recordWasChangedBlock`/`fetchRecordZoneChangesResultBlock`: um local de produção, `SincronizadorDaBibliotecaCloudKit.swift:253-270`, refutado como race pelo contrato serial do SDK.
- `DispatchSemaphore.wait`: uma ocorrência de produto, `CicloDeVidaDeModelos.swift:113`.
- `Timer`, `addObserver`, `deinit`, `removeTap`, `Task.isCancelled`, `checkCancellation`, `NSLock`, `Atomic` e `nonisolated(unsafe)` foram cruzados com seus chamadores; os escapes com lock/actor e os caminhos de cleanup estão listados acima.

---

## 7. Limitações e estado final

- Não houve acesso a uma segunda conta/área CloudKit real; a garantia de serialidade veio do cabeçalho local do SDK, não de TSan ou uma chamada de rede real.
- TSan não executou por erro de compilação nos testes sob Swift 6; não foi tratado como evidência de race ou de ausência de race.
- Não houve teste com TCC, microfone, Speech ou destruição de uma view real para o ditado; por isso a sobrevivência do engine após `deinit` continua sendo inferência.
- Não houve `Instruments/Allocations`, footprint/RSS, execução de dois modelos de 3/6 GB ou medição de pico. Números de arquivo não foram convertidos em afirmação de RAM.
- Não foi executado um cenário de duas janelas; o risco de `WindowGroup` ficou explicitamente condicional.
- O working tree já continha alterações e arquivos não rastreados de outros agentes/usuário. Eles não foram limpos, revertidos ou incluídos como produto desta auditoria; a única gravação feita por esta auditoria é `audit/02-achados/A2-concorrencia-memoria.md`.

**Nenhuma correção foi aplicada.** A ordem de tratamento sugerida pela auditoria é: A2-001 (destravar OAuth e fechar o gate), A2-004 (impedir escritas tardias), A2-002/A2-003 (ciclo de vida e coordenador de modelos), A2-005/A2-006 (cancelamento de continuações/filas) e, por fim, A2-007/A2-008 (medição/limite de caches).

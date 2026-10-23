# A6 — Dados, persistência e integrações

> **Data:** 2026-09-23  
> **Escopo lido:** 82 arquivos Swift de produção (36 no Core e 46 no app), 16.697 linhas; 6 arquivos de Config com 137 linhas; 13 arquivos relevantes de teste com 160 casos `@Test`; `README.md:86-98` e os chamadores necessários em `Papagaio/App/ContentView.swift` e `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift`.  
> **Modo:** relatório. Nenhum arquivo de produção, teste, configuração, dependência, banco ou serviço foi alterado. O único arquivo do repositório escrito por esta execução é este.  
> **Limite de confiança:** `CONFIRMADO` exige reprodução nesta execução ou prova de controle direta sem alternativa plausível; `PROVÁVEL` deixa uma dependência externa sem execução real.

## 1. Resumo e contagens

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 3 |
| ALTO | 7 |
| MÉDIO | 6 |
| BAIXO | 0 |
| INFO | 0 |
| **Total** | **16** |

| Confiança | Quantidade |
|---|---:|
| **CONFIRMADO** | 6 |
| **PROVÁVEL** | 10 |
| **HIPÓTESE** | 0 |
| **Total** | **16** |

Os três maiores riscos são: **A6-001** (edição de nota comprovadamente apagada por save antigo do pipeline), **A6-002** (retry CloudKit pode sobrescrever a edição concorrente de outro cliente) e **A6-003** (marcador público não autenticado pode ordenar exclusão local de uma equipe).

---

## 2. Achados

### A6-001: Save antigo do pipeline apaga notas editadas durante o processamento
- Severidade: CRÍTICO
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:40-120`; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:101-189`; `Papagaio/App/ContentView.swift:561-592`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1361-1381`
- Evidência: o repositório substitui o agregado inteiro, inclusive as relações de notas:

```swift
// SwiftDataRepository.swift:66-75,109-118
for antigo in persistido.trechos ?? [] { modelContext.delete(antigo) }
// ... insights e notas também são apagados
for antiga in persistido.notas ?? [] { modelContext.delete(antiga) }
// ...
for (ordem, nota) in a.notas.enumerated() {
    let persistida = NotaPersistida(id: nota.id)
    // reinsere apenas as notas do snapshot recebido
}
```

O pipeline copia o arquivo no início e salva o mesmo snapshot duas vezes, mesmo depois de minutos de processamento:

```swift
// PipelineDeArquivo.swift:105,160-162,187-189
var atualizado = arquivo
// ... transcrição, diarização, tradução e resumo ...
try await repositorio.salvar(atualizado)
// ... resumir pode levar minutos ...
try await repositorio.salvar(atualizado)
```

A reprodução isolada com o repositório real, container SwiftData em memória e a mesma ordem de chamadas produziu:

```text
/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a6/proofs.log:40-42
LOST_UPDATE_ANTES=["nota criada durante pipeline"]
LOST_UPDATE_DEPOIS=["nota inicial"]
NOTA_EDITADA_SOBREVIVEU=false
```

- Cenário de falha: a pessoa abre a conversa enquanto a transcrição roda, adiciona uma nota e recebe “Salvo”; quando o pipeline faz seu primeiro ou segundo save, a nota editada é removida do SwiftData e o snapshot antigo volta a ser a fonte da verdade. Metadados/título editados durante o mesmo intervalo podem suffers a mesma troca.
- Como reproduzir: `cd /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a6 && swift run AuditA6`. O harness está em `Sources/AuditA6/main.swift:12-39`: salva a nota antiga, salva a edição da UI e então executa o save tardio com o snapshot do pipeline. Alternativa manual: iniciar o processamento, editar Notas antes do resumo terminar e comparar a lista após o “Transcrição concluída”.
- O que procurei para refutar: `modelContext.rollback()` existe em `SwiftDataRepository.swift:351-361`, e há proteção contra ressuscitar item da lixeira em `:53-58`; o repositório também é `@ModelActor`. Procurei versão, `@Attribute(.unique)`, merge, `salvarNotas` dedicado, compare-and-swap e `reload` antes do save: none existe no escopo. Os testes `PersistenciaTests.swift:230-247` e `PipelineTests.swift:153-187` provam apenas substituição intencional e dois saves, não uma edição concorrente.
- Causa raiz: `Arquivo` é um snapshot de valor, mas `salvar` possui semântica de substituição total; não há revisão, lock por arquivo nem merge entre campos editados pelo usuário e campos derivados pelo pipeline.
- Correção sugerida: separar operações de domínio (`salvarResultadoDoPipeline`, `salvarNotas`, `salvarMetadados`) e fazer o pipeline reler a revisão atual antes de gravar apenas `trechos`, `resumo` e engines. Alternativamente, adicionar revisão otimista e rejeitar/reconciliar snapshots antigos. Impacto: migração de esquema pequena se houver nova revisão; risco principal é perder uma atualização concorrente durante a migração. Não aplicar nesta auditoria.
- Referência: fonte primária local; `audit/01-pesquisa/ai-runtimes.md` não é necessária para esta causa.

### A6-002: Retry de conflito CloudKit sobrescreve a edição que ganhou o servidor
- Severidade: CRÍTICO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:156-175,274-283`; `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:126-160`; `Papagaio/ViewModels/Biblioteca.swift:1138-1171`
- Evidência: a每次 tentativa relê o registro atual e, em seguida, substitui todo o payload local:

```swift
// SincronizadorDaBibliotecaCloudKit.swift:156-175
let registro = try await registroExistente(ouNovo: recordID, no: banco)
registro[Campo.conteudo] = CKAsset(fileURL: temporario)
registro[Campo.titulo] = payload.arquivo.titulo as NSString
registro[Campo.atualizadoEm] = payload.atualizadoEm as NSDate
_ = try await banco.save(registro)
```

A fila preserva o mesmo snapshot após `serverRecordChanged` e tenta novamente:

```swift
// FilaPersistenteCloudKit.swift:137-160
try await sincronizador.enviar(arquivo, para: operacao.equipe, revisao: operacao.revisao)
// ...
catch {
    atuais[indice].tentativas = min(atuais[indice].tentativas + 1, 10)
    try salvar(atuais)
}
```

- Cenário de falha: A e B editam a mesma conversa offline. A grava primeiro; B recebe conflito, volta à fila e, no retry, lê o registro de A, mas substitui seu `CKAsset` e campos pelo snapshot inteiro de B. A edição de A deixa de existir no servidor e será trazida de volta como estado remoto winners.
- Como reproduzir: com um transporte CloudKit de teste que mantenha `systemChangeTag`, fazer A salvar, fazer B enviar snapshot com a system tag antiga, deixar o primeiro save de B falhar com `.serverRecordChanged` e executar o segundo retry. O resultado esperado no produto é apenas o payload de B; a correção precisa expor as duas revisões/ancestors. Não foi executado contra CloudKit real.
- O que procurei para refutar: a outbox é durável, serializa consumidores e revalida que a operação não foi substituída durante a rede (`FilaPersistenteCloudKit.swift:103-130`); o `recordName` também é estável por `Arquivo.id`. Procurei `ancestorRecord`, `serverRecord`, `clientRecord`, merge por campo, revisão base, `changeToken`, criação de cópia em conflito e keyed upsert: não existem. O teste `EquipesCloudKitTests.swift:317-340` só exercita a política de “pendência local versus remoto”, não um `CKError.serverRecordChanged`.
- Causa raiz: conflito é tratado como falha transitória genérica; o retry não parte da revisão que perdeu, mas do registro atual com o payload inteiro do cliente perdedor.
- Correção sugerida: tratar `.serverRecordChanged` pelo código, usar `ancestorRecord/serverRecord/clientRecord` e uma revisão/base de sync. Para um documento indivisível, Offering o conflito ao usuário ou criando uma cópia é mais seguro que Last-Write-Wins silencioso. Impacto: protocolo de sync e migração de registros concorrentes; risco de的特殊冲突 de duplicação deve ser explicitamente resolvido.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` §3.4.5-6, R-07/R-11, A5.

### A6-003: Marcador público de exclusão pode ordenar apagamento local sem autoria
- Severidade: CRÍTICO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:276-317,518-520`; `Papagaio/App/ContentView.swift:758-795`; `README.md:86-94`
- Evidência: o sinal que manda todas as instalações apagarem dados locais é um registro público de ID determinístico, e a leitura confia somente no string de estado:

```swift
// ServicoDeEquipesCloudKit.swift:285-292,307-313
let marcador = CKRecord(
    recordType: TipoDeRegistro.equipeExcluida,
    recordID: Self.idDoMarcadorDeExclusao(para: equipe.id)
)
marcador[Campo.estadoDaExclusao] = EstadoDoMarcadorDeExclusao.preparando.rawValue as NSString
// ...
return (marcador[Campo.estadoDaExclusao] as? String)
    == EstadoDoMarcadorDeExclusao.concluida.rawValue
```

O chamador transforma `true` em remoção de SwiftData, mídia, lixeiras e vínculos locais (`ContentView.swift:761-795`). Não há `creatorUserRecordID`, comparação com `donoDaZonaCloudKit`, assinatura ou nonce. O SDK local confirma que o campo de criador existe em `.../CloudKit.swiftinterface:835-845`.
- Cenário de falha: no modelo padrão do banco público, um participante que conhece o `id` da equipe cria antecipadamente `equipe-excluida.<id>` com `estadoDaExclusao = concluida`. A tentativa legítima do dono colide com um registro de outro criador; outros Macs leem o marcador e apagam a cópia local como se o proprietário tivesse excluído a zona. Roles customizadas no container podem reduzir a viabilidade, por isso a confiança é provável, não confirmada.
- Como reproduzir: em ambiente de teste com dois Apple Accounts, conta A entra na equipe e obtém `id`; conta B cria o registro público com o mesmo recordName e estado `concluida`; conta A/C executam `equipeFoiExcluida`. Experimento decisivo com container real e roles controlados; não foi executado.
- O que procurei para refutar: creation workspace e `CKShare` são atômicos dentro da zona (`ServicoDeEquipesCloudKit.swift:63-68`), e a exclusão usa dois estados `preparando/concluida` (`:276-301`). Procurei validação de criador, owner, nonce, assinatura, data monotônica e registro autenticado alternativo: não há. Os testes só cobraminuída de zona, payload e transporte; não há teste do marcador público adversarial.
- Causa raiz: um canal público usado como comando destrutivo é tratado como fonte de autoridade sem vínculo criptográfico/autoral com a equipe.
- Correção sugerida: validar `creatorUserRecordID` e `equipeID` contra o owner conhecido e mover a decisão para canal autenticado; para exclusão, preferir registro privado do owner ou prova assinada. Se o marcador legado permanecer, faça migração一次 e rejeite registros não assinados. Impacto: продуктовые dados existentes exigem rollout coordenado; risco é manter cópias que deveriam ser apagadas.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-03, CK-03, A1/A6.

### A6-004: Reuniões importadas de Calendar/Granola não entram na outbox da equipe
- Severidade: ALTO
- Confiança: **CONFIRMADO**
- Local: `Papagaio/ViewModels/Biblioteca.swift:273-381,1303-1421`; `Papagaio/Integracao/GranolaViewModel.swift:171-202`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:212-230`; `Papagaio/ViewModels/Biblioteca.swift:1075-1085`
- Evidência: áudio local chama `sincronizar` logo após salvar (`Biblioteca.swift:297-315`), mas os dois caminhos externos apenas salvam e inserem em memória:

```swift
// Biblioteca.swift:368-381 — Granola
try await repositorio.salvar(arquivo)
arquivos.insert(arquivo, at: 0)
return arquivo

// Biblioteca.swift:1371-1421 — Calendar
try await salvarReuniaoNoRepositorio(arquivo)
arquivos.insert(arquivo, at: 0)
// ... não há await sincronizar(arquivo)
```

A busca de todos os call sites mostrou nove chamadas de `sincronizar` (registro, lixeira, edição, duplicação e fim do pipeline), mas nenhuma em `registrarExterna` ou `criarArquivoDeReuniaoPendente`. Os únicos chamadores são `GranolaViewModel.swift:186` e `GoogleCalendarViewModel.swift:220`, e nenhum sincroniza depois.
- Cenário de falha: um membro da equipe importa uma reunião do Granola ou converte uma pendência do Google Calendar. A UI confirma e o arquivo existe apenas neste Mac. Se não houver uma edição posterior que dispare `sincronizar`, os demais membros nunca recebem a conversa; uma perda do Mac perde a única cópia.
- Como reproduzir: criar/selecionar uma equipe com CloudKit ativo, desabilitar processamento automático, importar uma reunião externa e inspecionar `fila-pendente.json`; alternatively editar o título e verificar que só a edição posterior cria a entrada. O grep de call sites está reproduzível no comando registrado na seção 7.
- O que procurei para refutar: `registrar` e todas as mutações normais sincronizam; há outbox durável e retry. Procurei um wrap de autosync no repository, no app init ou nos VMs: não existe. `GoogleCalendarTests.swift:41-106` valida a cópia local, mas não injeta equipe; não há teste Granola→equipe.
- Causa raiz: a informação “este arquivo nasceu local ou externo” queda fora do protocolo comum de persistência; o terminal externo-ends apenas no SwiftData e ignora a projeção de equipe.
- Correção sugerida: extrair `persistirEOuSincronizar` e usar em todos os caminhos; somente marcar a importação concluída após entrada durable na outbox, sem apagar a cópia local se a fila falhar. Impacto: baixo no código, fecha a lacuna cliente-servidor.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-01, §3.4.

### A6-005: `idExterno` só é idempotente dentro de uma lista em memória
- Severidade: ALTO
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Sources/PapagaioCore/Dominio.swift:496-500`; `PapagaioCore/Sources/PapagaioCore/Persistencia/ModelosSwiftData.swift:47-50`; `Papagaio/ViewModels/Biblioteca.swift:321-380,1316-1340`; `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:351-368`
- Evidência: o domínio chama `idExterno` de âncora de idempotência, mas a criação de `Arquivo` usa o UUID local padrão e o CloudKit grava esse UUID como recordName:

```swift
// Biblioteca.swift:326-366
/// A importação é idempotente por `idExterno`
let idExternoCompleto = "\(identificador):\(reuniao.id)"
guard !arquivos.contains(where: { $0.idExterno == idExternoCompleto }),
      !arquivosNaLixeira.contains(where: { $0.idExterno == idExternoCompleto })
// ...
let arquivo = Arquivo(/* id não fornecido => UUID() */)
// ...
id: arquivo.id.rawValue.uuidString // recordName no CloudKit
```

Não há `@Attribute(.unique)` para `id`, `idExterno` ou um índice composto `(espaco,idExterno)`. O guard ocorre antes de um `await`, portanto duas importações concorrentes no mesmo Mac também podem observar a lista vazia antes de a primeira completar o save.
- Cenário de falha: A e B importam a mesma reunião Granola antes de sincronizar. Cada Mac cria um UUID diferente; ao subsequentemente editar/sincronizar, os dois recordNames entram no CloudKit e o download faz upsert de ambos. O mesmo `idExterno` aparece duplicado em todas as bibliotecas, apesar da comentário idempotente.
- Como reproduzir: duas Bibliotecas in-memory/equipes distintas, mesmo `ReuniaoExterna(id: "m1", identificador: "granola")`; Observe UUIDs diferentes; envie ambos por um transporte fake e baixe o conjunto. O resultado atual são dois `Arquivo` com mesmo `idExterno` e IDs distintos. A suíte não tem esse caso.
- O que procurei para refutar: o guard local evita double-click sequencial no mesmo VM; `idExterno` faz round-trip e os testes cobrem idempotência de `Arquivo.id`. Procurei unique constraint, upsert por `idExterno`, recordName determinístico e resolução de duplicatas no download: não existem. Nenhum teste de app menciona `registrarExterna` ou `idExterno` para Granola.
- Causa raiz: a chave de idempotência existe apenas como coluna e é comparada contra um array local; a identidade de armazenamento continua sendo um UUID gerado por dispositivo.
- Correção sugerida: derive um UUID estável de `espaco + identificador + reuniao.id` e use-o também como recordName, ou crie uma constraint composta e reconcilie por `idExterno` no download. Defina política para cópias legadas já duplicadas. Impacto: migração de records externos existentes; risco de colisão exige namespace explícito.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-01, §3.4.

### A6-006: Exclusão remota não chega aos clientes que ficaram offline
- Severidade: ALTO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:242-271,371-394`; `Papagaio/ViewModels/Biblioteca.swift:1138-1174`; `/Applications/Xcode-beta.app/.../CloudKit.swiftinterface:1335-1358`
- Evidência: a operação de zona instala apenas `recordWasChangedBlock`; não há `recordWithIDWasDeletedBlock`, token anterior nem conjunto de IDs Authority para reconciliação:

```swift
// SincronizadorDaBibliotecaCloudKit.swift:246-270
let operacao = CKFetchRecordZoneChangesOperation()
operacao.fetchAllChanges = true
operacao.recordWasChangedBlock = { _, resultado in
    // só adiciona CKRecord sucesso em `registros`
}
```

No download, cada payloadDecoderado é salvo; não há remoção de locals ausentes no remoto (`Sincronizador...:371-394`; `Biblioteca.swift:1147-1171`). O SDK mostra callback de deleção como API separada (`CloudKit.swiftinterface:1341-1348`).
- Cenário de falha: A exclui definitivamente uma conversa enquanto B está offline. B ainda a possui; ao voltar, a zona não devolve o record, mas o download só faz upsert, então a conversa apagada por A continua em B, inclusive na lixeira e na busca.
- Como reproduzir: duas contas iCloud de teste; criar e sincronizar no Mac A; desligar rede/serviço no Mac B; remover definitivamente em A; religar B e executar `usarEspaco`. A hipótese é confirmada se B continuar listando o UUID; teste real não foi executado.
- O que procurei para refutar: paginação de 200, carga completa e paginação de payload existem; o outbox remove o record remoto. Procurei tombstones, `recordWithIDWasDeletedBlock`, `serverChangeToken`, `changeTokenExpired`, `fetchDatabaseChanges` e diff autoritativo: zero no escopo. `EquipesCloudKitTests.swift:26-50` cobre 205 registros, mas não exclusões.
- Causa raiz: o protocolo de sincronização modela apenas upsert; a ausência de um record no resultado não é tratada como operação de exclusão.
- Correção sugerida: persistir `CKServerChangeToken` e IDs de deleção/tombstones, tratar `recordWithIDWasDeletedBlock` e忽然 mudança canelada; em full resync, reconciliar o conjunto remoto sem apagar gravations fora da zona/pending. Impacto: protocolo e migration de cursor; risco é remover item local por full load incompleto.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-07, §3.4.4-6, A4.

### A6-007: Rotação do código apaga o share antes de conseguir publicar o novo
- Severidade: ALTO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:242-273`; `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:450-460`
- Evidência: a operação é uma sequência cross-database sem recuperação intermediária:

```swift
// ServicoDeEquipesCloudKit.swift:258-267
_ = try await banco.modifyRecords(
    saving: [novo], deleting: [antigo.recordID], atomically: true
)
try await invalidarCodigoAnterior(equipe.codigoDeEntrada)
try await publicarCodigo(novoCodigo, para: url)
```

O comentário do próprio código reconhece que trocar o `CKShare` remove participantes existentes (`:242-244`). O chamador só atualiza a referência local quando toda a função retorna:

```swift
// GestaoDeEquipeView.swift:455-459
let atualizada = try await servicoDeEquipes.rotacionarCodigo(da: equipe)
aoAtualizarEquipe(atualizada)
```

- Cenário de falha: a troca私有→share novo conclui, mas a invalidação do código público ou a publicação do novo código falha por rede/schema. O método lança; a UI continua com o ID do share antigo, que já foi apagado; participantes existentes foram removidos e o código novo não aparece. Repetir a ação não consegue recomeçar porque `compartilhamento(da:)` procura o share antigo.
- Como reproduzir: adapter CKDatabase injetável que deixa `modifyRecords` succeed e faz o próximo `records/ modifyRecords` falhar; assert estado remoto e referência local. Em serviço real,也需要 simular quota/offline entre as chamadas.
- O que procurei para refutar: a troca do share é atômica e há invalidação do código anterior. Procurei estado `rotationPending`, persistência do novo share ID antes da próxima chamada, retry idempotente da publicação e recovery após `unknownItem`: não existem. Não há teste de `rotacionarCodigo`; o fake de Equipes só cobre transporte de conversas.
- Causa raiz: uma operação lógica com três armazenamento noncoordenados é executada como fail-fast, embora o primeiro passo já tenha invalidado o estado anterior.
- Correção sugerida: persistir um estado de rotação durável com `novoShareID/novoCodigo` immediately após a troca; retries should publish/invalidate from that state and only mark complete after URL is visible. Impacto: rollout de estado de equipe; risco de México duplicada de share need handling.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-07, §3.3, A3.

### A6-008: Primeiro consentimento Google usa `prompt=none`
- Severidade: ALTO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/Integracao/SessaoOAuthGoogle.swift:86-109,124-157,196-218`; `PapagaioTests/OAuthGoogleTests.swift:114-130`
- Evidência: sem token persistido, o único caminho剩 é o fluxo interativo, mas a URL proíbe telas:

```swift
// SessaoOAuthGoogle.swift:98-108
if !forcar, let guardado, guardado.expiraEm > Date().addingTimeInterval(60) {
    return guardado.valor
}
return try await fluxoDeAutorizacao()

// :209-210
URLQueryItem(name: "prompt", value: "none"),
```

- Cenário de falha: primeira conexão em um perfil sem consentimento anterior. O Google responde `interaction_required`/falha de autenticação em vez de redirecionar com código; o app não apresenta consentimento e a integração Calendar não conecta.
- Como reproduzir: remover somente os itens Google do Keychain em ambiente de teste, usar um profile sem consentimento prévio e chamar `conectar`; capturar a URL ou a resposta local. Não foi executado contra Google.
- O que procurei para refutar: o fluxo usa PKCE, state e loopback; há `access_type=offline`. Procurei um ramo específico de primeira autorização, `prompt=consent` ou fallback de `interaction_required`; não existe. O teste de URL valida PKCE/state e não afirma a semântica de consentimento.
- Causa raiz: a política de retomada silenciosa foi aplicada ao único ramo que precisa de consentimento humano.
- Correção sugerida: remova `prompt=none` no primeiro consentimento; tente `none` apenas quando já há autorização persistida e caia para consentimento em `interaction_required`. Teste a construção dos dois URLs sem abrir rede.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-10, §4.2.1, G7.

### A6-009: Rejeição de token Granola não vira estado recuperável
- Severidade: ALTO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/Integracao/ClienteMCP.swift:129-165`; `Papagaio/Integracao/SessaoOAuth.swift:75-113,289-312,331-358`; `Papagaio/Funcionalidades/Configuracoes/ConfiguracoesView.swift:353-365`
- Evidência: o cliente app sempre pede token sem forçar renovação e converte 401/403 em erro de protocolo comum:

```swift
// ClienteMCP.swift:134-157
let token = try await obterToken(false)
// ...
guard status == 200 || status == 202 else {
    throw ErroMCP.protocolo(...)
}
```

No refresh, `invalid_grant` também apenas lança e não apaga o refresh inválido (`SessaoOAuth.swift:289-312,331-349`). A tela de falha oferece somente “Tentar novamente” (`ConfiguracoesView.swift:353-365`), que repete o mesmo segredo.
- Cenário de falha: token revogado antes do `expiraEm`, ou refresh token expirado. Toda chamada MCP recebe 401/`invalid_grant`; o app não força refresh, não limpa o segredo inválido e não oferece desconectar no estado de falha. A Granola fica inutilizável até-keychain externo干预.
- Como reproduzir: fake `URLProtocol`/transporte que retorna 401 no `tools/call` e `invalid_grant` no token; chamar `conectar()` duas vezes e contar chamadas/refresh persistido. O cliente Core possui o retry de 401 em `PapagaioCore/.../Integracao/ClienteMCP.swift:185-198`, evidenciando que a árvore app é a que perde a recuperação.
- O que procurei para refutar: há revogação best-effort, token de acesso com expiração e DCR; o Core tem uma tentativa de retry. No app não há `forcarRenovacao` após status, nem `apagar(refresh_token)` em `invalid_grant`, nem estado “reautenticar”. Não há testes do `SessaoOAuth`/`ClienteMCP` app.
- Causa raiz: rejeição de autenticação não é representada como transição de estado; ela é tratada como falha de protocolo/refresh genérica e repetida.
- Correção sugerida: classificar 401/403/`invalid_grant`, limpar somente o segredo rejeitado, forçar uma renovação e depois uma reautenticação interativa; não repetir `tools/call` sem uma regra de idempotência. O impacto é médio e deve incluir fixture de servidor.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-11, §5.1-5.3, M2/M3.

### A6-010: Falha de transcrição Granola impede a importação de notas e resumo
- Severidade: ALTO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/Integracao/FonteGranola.swift:48-85`; `Papagaio/Integracao/GranolaViewModel.swift:171-202`; `PapagaioCore/Sources/PapagaioCore/Integracao/FonteGranola.swift:242-272`
- Evidência: o app exige a transcrição, apesar de o contrato e o comentário dizerem que ela é opcional:

```swift
// FonteGranola.swift:58-61,76-85
if incluirTranscricao {
    transcricao = try await transcricaoDaReuniao(id: id)
}
// ...
let resposta = try await cliente.chamar(
    ferramenta: "get_meeting_transcript", argumentos: ["meeting_id": id]
)
```

`GranolaViewModel` só chama `registrarExterna` depois de `obterReuniao` retornar; o `catch` de `:190-192` abandona a reunião. A implementação Core equivalente captura a falha da transcrição e devolve a reunião sem ela (`PapagaioCore/.../FonteGranola.swift:249-270`).
- Cenário de falha: plano Basic ou tool indisponível. O usuário não perde acesso à API de detalhe, mas o produto não salva notas/resumo; a tela de importação mostra falha para uma reunião que poderia ser importada.
- Como reproduzir: mock do `ClienteMCP` que responde `get_meetings` e lança em `get_meeting_transcript`; chamar `GranolaViewModel.importar` com a fonte ativa. Não foi feita chamada de rede real.
- O que procurei para refutar: há `transcricao: nil` no tipo, o mapper e a árvore Core tratam ausência; o comentário do app declara degradação. Não há catch local nem teste de entitlement Basic; os testes Core cobrem mapeamento, mas não a implementação app.
- Causa raiz: uma capability opcional foi implementada como pré-requisito do fluxo de importação.
- Correção sugerida: isolar a chamada de transcrição em `do/catch`, preservar detalhe e sinalizar “sem transcrição”; reenviar cancelamento e erros de transporte conforme a política. Impacto: baixo, com teste de contrato por plano.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-12/R-13, §5.3.

### A6-011: Gate de energia pula quadros de silêncio e quebra o estado recurrente do Silero
- Severidade: MÉDIO
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Sources/PapagaioCore/Transcricao/DetectorDeAtividadeDeVoz.swift:128-157,296-365`; `PapagaioCore/Sources/PapagaioCore/Transcricao/SileroVAD.swift:110-137`
- Evidência: o detector calcula energia para todos os quadros, mas entrega ao Silero apenas os índices candidatos; os quadros silenciosos não avançam `contexto`/`estado`:

```swift
// DetectorDeAtividadeDeVoz.swift:139-155
if usaSilero, !indicesComEnergia.isEmpty {
    let candidatos = indices.map { ... }
    let probabilidades = try await sileroVAD.probabilidadesDeFala(quadros: candidatos)
    for (indice, probabilidade) in zip(indices, probabilidades) {
        falaPorQuadro[indice] = probabilidade >= limiarFala
    }
}

// SileroVAD.swift:112-137
var entrada = contexto
entrada.append(contentsOf: janela)
defer { contexto = Array(entrada.suffix(...)) }
// ... estado = estadoNovo
```

O experimento com o modelo real do repositório comparou a sequência completa (fala + silêncio + fala) com a sequência efetivamente饣送 ao modelo (fala + fala), usando 100 quadros candidatos e silencios de 1–30 quadros. Em 255 combinações controladas, a versão com estado completo classificou a fala como ≥0,5 e a versão sem silêncio como <0,5; exemplo:

```text
/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a6/proofs.log:56-61
VAD_CASOS_FALA_PERDIDA_NO_GATE=255
VAD_FALA_PERDIDA full=0.7152701020240784 gated=0.49954351782798767 frame=7 silence=1
```

Esse número é uma contagem de combinações do experimento, não frequência em reuniões de produção.
- Cenário de falha: pausas reais entre palavras/turnos não atualizam o estado recurrente; uma janela seguinte pode ser classificada diferente e perder fala ou enviar ruído ao Whisper. A transcrição resultante fica incorreta mesmo com o modelo correto.
- Como reproduzir: `cd /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a6 && swift run AuditA6`; comparar as linhas `VAD_*` com o fixture `fala_ola_mundo.wav`.
- O que procurei para refutar: a fila `FilaEstrita` isola sessões, `novaSequencia` zera no início e os testes cobrem能量, silêncio e concorrência (`DetectorDeAtividadeDeVozTests.swift:22-169`). Procurei passagem de todos os quadros, reset por那段 de silêncio e teste de estado após pausa: não existe. O pin WIP atual só expõe `SileroVAD.urlDoModeloPadrao`; o `git diff` mostrou que a lógica de gate não foi alterada.
- Causa raiz: um pré-filtro de energia foi inserido antes de um modelo stateful, mas o estado do modelo foi compartilhado como se cada candidato fosse uma sequência independente.
- Correção sugerida: enviar todos os quadros de 512 amostras ao Silero na ordem, usando energia apenas para uintersection downstream; ou manter um estado explicitamente independente para cada candidato. Validar com WER e taxa de falso negativo, sem usar o número do probe como SLA.
- Referência: `audit/01-pesquisa/ai-runtimes.md` §7.2, E14/E26; `audit/01-pesquisa/cloudkit-integracoes.md` não é necessária.

### A6-012: Substituição de token no Keychain apaga o valor antigo antes de inserir o novo
- Severidade: MÉDIO
- Confiança: **PROVÁVEL**
- Local: `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:14-27`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:303-309`; `Papagaio/Integracao/SessaoOAuth.swift:331-358`; `Papagaio/ViewModels/PerfilViewModel.swift:136-147`
- Evidência: o cofre executa delete e add como duas operações, sem update transacional:

```swift
// CofreDeTokens.swift:20-26
SecItemDelete(atributos as CFDictionary)
var novo = atributos
novo[kSecValueData as String] = dados
let status = SecItemAdd(novo as CFDictionary, nil)
guard status == errSecSuccess else { throw ... }
```

Os dois clientes OAuth chamam `guardar` com `try?`; logo, uma falha de `SecItemAdd` pode deixar a credencial anterior removida sem erro visível (`SessaoOAuthGoogle.swift:303-309`; `SessaoOAuth.swift:352-358`). O perfil Apple usa o mesmo delete-before-add e remove o ID anterior antes do `SecItemAdd` (`PerfilViewModel.swift:136-147`).
- Cenário de falha: Keychain bloqueado, cheio ou com erro transitório no `SecItemAdd`; o app continua com o token em memória, mas no relançamento não encontra refresh/client/ID anterior e solicita nova autorização ou perde o perfil local.
- Como reproduzir: fake Security API é difícil porque o cofre chama `SecItem*` diretamente; em máquina de teste, causar `errSecInteractionNotAllowed`/item locked e salvar um item existente. Não foi induzido erro real do Keychain nesta auditoria.
- O que procurei para refutar: há `contasExistentes`, revogação e propagação de erro no PKCE do Google; não há `SecItemUpdate`, transação, backup do valor anterior ou teste do cofre real. Os testes OAuth usam apenas um dublê de dicionário (`OAuthGoogleTests.swift:138-167`).
- Causa raiz: a operação de “atualizar” foi implementada como “apagar e recriar”, enquanto o chamador trata a parte persistente como best effort.
- Correção sugerida: tentar `SecItemUpdate` e só usar `SecItemAdd` em `errSecItemNotFound`; propagar erro para credenciais obrigatórias e manter logout/revogação como best effort. Impacto: baixo; testar com protocolo de Keychain injetável.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` §8.1-8.2, A10.

### A6-013: Migração de status marca conclusão antes de应用到 todas as tarefas
- Severidade: MÉDIO
- Confiança: **CONFIRMADO**
- Local: `Papagaio/Persistencia/MigracaoDeStatusDeTarefas.swift:18-39`; `Papagaio/App/PapagaioApp.swift:49-58`
- Evidência: a flag é gravada antes do loop e nunca é removida se uma chave falhar:

```swift
// MigracaoDeStatusDeTarefas.swift:22-39
guard !defaults.bool(forKey: chaveDeControle) else { return }
defaults.set(true, forKey: chaveDeControle)

for chave in defaults.dictionaryRepresentation().keys where chave.hasPrefix(prefixoDeChave) {
    guard let dados = defaults.data(forKey: chave),
          var tarefas = try? JSONDecoder().decode(...)
    else { continue }
    // ...
    guard mudou, let novos = try? JSONEncoder().encode(tarefas) else { continue }
    defaults.set(novos, forKey: chave)
}
```

A migração é chamada no init do app (`PapagaioApp.swift:57`).
- Cenário de falha: uma chave antiga tem JSON corrompido/incompatível, ou o processo encerra após a flag. As tarefas dessa chave não são migradas; o próximo lançamento vê a flag e pula todas, deixando status legado em “Em andamento” para sempre.
- Como reproduzir: em `UserDefaults` de teste, gravar uma lista válida e outra com JSON inválido sob `tarefasDaConversa.*`, chamar `executarUmaVez` e chamar novamente; a segunda chamada não processa a chave inválida. A leitura do código é determinística; não foi criado teste.
- O que procurei para refutar: a operação por registro é idempotente e a app invoca a migração uma vez. Procurei marker de progresso, versionamento por chave, backup, `defer`/rollback e repetição após falha: não existem. Não há teste de `MigracaoDeStatusDeTarefas` em `PapagaioTests` ou Core.
- Causa raiz: marker de conclusão é escrito como pré-condição, não como confirmação pós-migração.
- Correção sugerida: processar cada chave, registrar contagem/erro e escrever a flag apenas depois de todas as chaves elegíveis; repetir a operation idempotente em próximo launch. Impacto: baixo, mas requiere testar crash entre chaves.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` não trata esta migração; fonte primária local.

### A6-014: Agrupamento recria o UUID do trecho
- Severidade: MÉDIO
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Sources/PapagaioCore/Transcricao/Segmentacao.swift:25-49`; `PapagaioCore/Sources/PapagaioCore/Dominio.swift:112-145`; `Papagaio/Persistencia/FalantePreservadoParaTrecho.swift:4-27`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1560-1585`
- Evidência: `fechar()` cria `Trecho` sem propagar `id`, e o init gera outro UUID:

```swift
// Segmentacao.swift:39-48
trechos.append(Trecho(
    start: primeiro.start,
    end: ultimo.end,
    texto: acumulados.map(\.texto).joined(separator: " "),
    speaker: primeiro.speaker,
    palavras: palavras
))
```

A reprodução com a função real e UUID conhecido produziu:

```text
/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a6/proofs.log:43-45
TRECHO_ORIGINAL_ID=A83FF0D6-53D8-4DAF-85AA-E487B739C9AF
TRECHO_AGRUPADO_ID=ABFC67DC-86A0-4B25-9606-218F2B25A1FB
TRECHO_ID_PRESERVADO=false
```

O mapa de nomes preservados é keyed pelo UUID do trecho/fala (`FalantePreservadoParaTrecho.swift:9-21`), e a UI usa o ID para edição e ocorrência de busca (`ArquivoDetalheView.swift:1560-1585`).
- Cenário de falha: uma transformação de segmentação/tradução/diarização rompe a identidade; um rótulo de falante salvo por trecho deixa de ser encontrado, e um item em edição/selecionado deixa de apontar para o mesmo trecho. A suíte real já exige a identidade em `PipelineTests.swift:554,579`.
- Como reproduzir: `swift run AuditA6` no diretório temporário ou executar o teste `pipelineTraduzAntesDeSalvarEResumir`; o primeiro imprime a diferença, o segundo já é uma regressão conocida.
- O que procurei para refutar: `marcar` e `comPalavras` propagam ID; o problema está somente no fechamento do grupo. Procurei reconciliação posterior por ID e política determinística de grupo: não existe. Os testes de segmentação preservam tempo/texto, mas não ID.
- Causa raiz: o agregador reconstrói um valor sem copiar a identidade do primeiro membro.
- Correção sugerida: propagar o ID do primeiro segmento ou definir determinística a partir dos membros; adicionar testes de identidade em agrupamento, mesclagem, tradução, diarização e persistência. Impacto: baixo, mas é preciso escolher semântica para grupo.
- Referência: `audit/01-pesquisa/ai-runtimes.md` §7.1/§7.3; `audit/00-mapa.md:367-375`.

### A6-015: Janela entre cópia de mídia e registro SwiftData deixa gravação órfã
- Severidade: MÉDIO
- Confiança: **PROVÁVEL**
- Local: `PapagaioCore/Sources/PapagaioCore/Importacao/ImportadorAudio.swift:64-81`; `Papagaio/ViewModels/GravadorViewModel.swift:169-177,191-225`; `Papagaio/ViewModels/Biblioteca.swift:273-307,1341-1378`; `PapagaioCore/Sources/PapagaioCore/Captura/Armazenamento.swift:172-180`
- Evidência: a pasta é criada antes da cópia e o caller não recebe compensação quando o registro falha:

```swift
// ImportadorAudio.swift:68-70
let destino = try armazenamento.criarArquivoImportado(id: id, extensao: extensao)
try? FileManager.default.removeItem(at: destino)
try FileManager.default.copyItem(at: origem, to: destino)
```

`GravadorViewModel` entrega o resultado por callback e descarta a referência da sessão antes de a `Biblioteca` salvar (`GravadorViewModel.swift:203-225`). `Biblioteca.registrar` retorna `nil` no erro de `repositorio.salvar` sem remover `pastaRelativa` (`:296-300`). O mesmo padrão aparece na cópia de reunião Calendar (`:1353-1368`). Só a exclusão de conta chama `removerTodasAsGravacoes` (`Armazenamento.swift:172-180`).
- Cenário de falha: disco cheio, bookmark expirado, falha de SwiftData ou encerramento entre `copyItem`/captura e o save. A gravação fica em `Gravacoes/<id>` sem `ArquivoPersistido`; o app não a lista e não há reconciliação de pastas no startup. Para áudio originally captured, os bytes podem ficar inacessíveis apesar de a operação ter sido solicitada.
- Como reproduzir: fazer `salvarReuniaoNoRepositorio` lançar depois de criar/copiar a pasta, ou instrumentar um `Task` encerrado entre o callback e `registrar`; `GoogleCalendarTests.swift:108-156` já demonstra o rollback de uma reunião, mas não a janela de `ImportadorAudio`/`registrar` normal.
- O que procurei para refutar: há rollback explícito quando `AVAudioRecorder.record()` falha (`SessaoGravacao.swift:109-118`) e quando a reunião Calendar não consegue persistir (`Biblioteca.swift:1371-1378`). Procurei `defer` de ownership, journal de “pending media” e scan de pastas órfãs no launch: não existem.
- Causa raiz: a posse do diretório temporário é transferida do gravador/importador para a biblioteca sem uma transação ou estado intermediário durável.
- Correção sugerida: mantener un objeto de preparación con rollback `defer` hasta que el registro assuma a propriedade; en registro, eliminar la carpeta en error y hacer reconciliación de huérfanos al iniciar sin tocar en grabaciones ativas. Impacto: mediano para捕獲中的 estados, baixo para两条常态路径.
- Referência: `audit/01-pesquisa/ai-runtimes.md` no trata este storage path; `audit/01-pesquisa/cloudkit-integracoes.md` no.

### A6-016: Backoff da fila ignora `CKError.retryAfterSeconds`
- Severidade: MÉDIO
- Confiança: **PROVÁVEL**
- Local: `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:103-170,199-202`; `Papagaio/ViewModels/Biblioteca.swift:1088-1135`; `/Applications/Xcode-beta.app/.../CloudKit.swiftinterface:740-755`
- Evidência: qualquer erro recebe o mesmo backoff local, e o código não consulta a dica do SDK:

```swift
// FilaPersistenteCloudKit.swift:152-160,199-202
catch {
    atuais[indice].tentativas = min(atuais[indice].tentativas + 1, 10)
    atuais[indice].proximaTentativa = agora.addingTimeInterval(Self.atraso(...))
}
return min(5 * pow(2, Double(expoente)), 15 * 60)
```

`agendarRetryCloudKit` ainda limita o atraso a 15 minutos (`Biblioteca.swift:1123-1129`). O SDK 27 expõe `CKError.retryAfterSeconds` (`CloudKit.swiftinterface:740-755`).
- Cenário de falha: CloudKit responde `requestRateLimited`/`zoneBusy` com retry-after superior ao backoff chosen; a fila tenta cedo demais, recebe o mesmo limite e repete. Isso pode transformar uma pausa temporária em uma sequência de requisiplicas e erro persistente.
- Como reproduzir: fake de `CKError` com `retryAfterSeconds = 3600`, `agendarEnvio` e `processar(ignorarBackoff: true)`; a próxima data observada é no máximo 900 s, não 3600 s. Um teste de integração deve confirmar o código real do serviço, que não foi chamado.
- O que procurei para refutar: há persistência, backoff exponencial, teto de 15 minutos, diagnóstico textual de schema e cancelamento. Procurei `retryAfterSeconds`, `CKErrorRetryAfterKey`, `requestRateLimited`, `zoneBusy`, jitter e dead-letter por código: zero no escopo. `EquipesCloudKitTests.swift:239-286` cobre apenas o atraso fixo.
- Causa raiz: a política de retry reduz todos os erros CloudKit a “transient” e não respeita o contrato de quota/busy do serviço.
- Correção sugerida: classificar `CKError.Code`, ler `retryAfterSeconds`, adicionar jitter e separar retryable/permanent/owner-action; persistir o hint quando ele for maior que o backoff. Impacto: baixo no código, importante para estabilidade de produção.
- Referência: `audit/01-pesquisa/cloudkit-integracoes.md` R-08, §3.4.7, A5.

---

## 3. Matriz de dados e integrações

| Subsistema | Fonte durable / identidade | Controles que existem | Lacuna principal | Achados |
|---|---|---|---|---|
| Biblioteca local | SwiftData: `EspacoPersistido`, `ArquivoPersistido`, `TrechoPersistido`, `InsightPersistido`, `NotaPersistida`; `Arquivo.id` UUID | `@ModelActor`, `cloudKitDatabase: .none`, cascade e rollback de `ModelContext` | Substituição do agregado sem revisão; `idExterno` sem unique; sem `VersionedSchema` | A6-001, A6-005, A6-014 |
| Arquivos de captura/importação | `Application Support/Papagaio/Gravacoes/<id>`, caminhos relativos | nomes canônicos, fallback de legado, validação contra traversal, `Data.write(.atomic)` em alguns paths | Não há journal de ownership/rollback em todos os caminhos | A6-015 |
| UserDefaults auxiliares | tarefas, notas, mídia, favoritos, Calendar, voz, filas de pasta | chaves versionadas em Calendar; JSON e `try?` em stores | escritas não transacionais, flag de migração antecipada, stores paralelas sem versão | A6-013 |
| Outbox CloudKit | `fila-pendente.json`, operation UUID + `(equipe.id, arquivo.id)` | JSON atômico, coalescing, persistência, backoff | não honora retry-after; retry de conflito pode sobrescrever | A6-002, A6-016 |
| Zona/registros CloudKit | `Conversa` por UUID, `CKAsset` JSON, `atualizadoEm` | payload versionado, `CKRecord` atômico no envio de um item, fetch paginado em memória | sem change token, deleções, conflict merge e payload máximo testado | A6-002, A6-006 |
| Equipes/convites | zona custom por equipe, `CKShare`, registros `CodigoDeEquipe`/`EquipeExcluida` | criação local atômica, URL de share,账号 guard | public marker não autoral, código sem unicidade, rotação não recuperável | A6-003, A6-007 |
| Google Calendar | OAuth Keychain + estado local `google-calendar-api:<event.id>` | PKCE/state/loopback, paginação de `nextPageToken`, estado de ignorada/convertida | primeiro consentimento `prompt=none`; sem sync token; snapshot full-window | A6-008 |
| Granola/MCP | DCR + OAuth no Keychain + payload local `idExterno` | importador tem dupla fallback de parser e gracefully degrada na árvore Core | app exige transcrição; rejeição de token não recupera; redirect/revisão legada | A6-009, A6-010 |
| Credenciais | Keychain `CofreDeTokens` | delete-on-logout, `contasExistentes`, PKCE | delete-before-add, `try?` em guardar | A6-012 |
| Captura/IA | WAV/CAF, `Trecho`/`Palavra` Codable, JSON de palavras | fallback de canal, pipeline salva transcrição antes do resumo, testes de round-trip | estado Silero não atravessa silêncio; IDs de grupo; sem quote transacional | A6-011, A6-014 |
| Migrações | flags `UserDefaults` e defaults dos modelos | flags específicas e campos opcionais | marker de sucesso antes do trabalho; não há plano SwiftData versionado | A6-013 |

## 4. Cobertura e buscas realizadas

### Arquivos e linhas

- Core, nos oito diretórios solicitados: **36 arquivos / 6.908 linhas**.
  - Persistencia 2/688; Processamento 2/521; Exportação 1/110; Importação 1/97; Integração 7/1.468; Captura 7/1.333; Transcrição 7/1.282; Sumarização 5/674; Diarização 4/735.
- App, nos quatro diretórios solicitados: **46 arquivos / 9.789 linhas**.
  - CloudKit 4/1.301; Persistência 23/2.604; Integração 9/2.552; ViewModels 10/3.332.
- Config textual versionado/secret template: **6 arquivos / 137 linhas**; `Config/Secrets.xcconfig` não foi lido.
- Testes relevantes lidos integralmente: **13 arquivos / 160 `@Test`**. Não foram executadas suítes completas nesta auditoria; o único probe novo é o executável temporário descrito nos achados.

### Buscas estáticas finais

Executadas no escopo e nos testes, com `rg`:

```text
@Attribute(.unique)|@Attribute                         -> 0
VersionedSchema|SchemaMigrationPlan                   -> 0
serverChangeToken|previousServerChangeToken           -> 0
recordWithIDWasDeletedBlock|changeTokenExpired        -> 0
CKErrorRetryAfterKey|retryAfterSeconds|requestRateLimited|zoneBusy -> 0 no produto
creatorUserRecordID                                    -> 0 no produto
CKDatabaseSubscription|CKRecordZoneSubscription|fetchDatabaseChanges -> 0
sincronizar(                                           -> 9 chamadas de produto, nenhuma nos dois caminhos externos
MigracaoDeStatusDeTarefas                              -> implementação + init; 0 teste
SessaoOAuth/ClienteMCP/GranolaViewModel                -> 0 teste da árvore app
idExterno                                              -> guarda local + round-trip; 0 unique/upsert CloudKit
```

Também foram seguidas as fatorações de `registrarExterna`, `criarArquivoDeReuniaoPendente`, `PipelineDeArquivo`, `SwiftDataRepository`, `FilaPersistenteCloudKit`, `FonteGoogleCalendarAPI`, `FonteGranola` e `CofreDeTokens` até os chamadores de UI e os testes.

## 5. Limitações e refutação final

- Não houve login, OAuth real, CloudKit real, Google Calendar real, Granola real, push, banco real, alteração de schema ou alteração de configuração. Portanto, conflitos, exclusões remotas, marker público, rotação, quotas e callbacks externos permanecem `PROVÁVEL` quando o resultado depende do serviço.
- O harness temporário compilou contra o pacote local e o modelo `silero_vad.onnx` existente; não alterou o repositório. O probe de VAD mede diferença de classificação em combinações controladas, não throughput, WER ou frequência em produto.
- O working tree já continha alterações de terceiros em `DetectorDeAtividadeDeVoz.swift`/`SileroVAD.swift`; o diff mostrado durante a auditoria indicava alteração apenas do accessor `urlDoModeloPadrao`, enquanto a lógica de gate auditada permaneceu igual.
- Não há cobertura de execução para duas contas iCloud, dois Macs, callbacks de OAuth cancelado, schema/roles de produção, `CKError` real, paginação de cursor nativo, `CKAsset` acima de limite, ou falha de disco/Keychain real. Esses casos foram mantidos como limitações, não como falhas de performance ou confusão de schema.
- Guardas que realmente reduzem risco e foram encontradas: `@ModelActor` + rollback SwiftData; cascade de exclusão; caminhos relativos e anti-traversal; outbox JSON atômico; coalescing por equipe/arquivo; payload CloudKit versionado; paginação Google; PKCE/state; `contasExistentes` sem decifrar segredo; locks/filas de VAD; testes de round-trip e rollback de mídia. Elas não cobrem os conflitos e janelas descritos acima.
- Nenhuma afirmação de velocidade, throughput, RAM, custo de CloudKit ou latência foi feita. Os únicos números novos são contagens de classify VAD e de arquivos/linhas/achados.

## 6. Contagem final

- **16 achados:** 3 CRÍTICO, 7 ALTO, 6 MÉDIO.
- **6 CONFIRMADO**, **10 PROVÁVEL**, **0 HIPÓTESE**.
- **3** achados com reprodução/prova local direta: A6-001, A6-011 e A6-014; os demais têm prova de código e/ou实验 de mechanism sem serviço real.
- Arquivo único escrito: `audit/02-achados/A6-dados-integracoes.md`.

# 01 — Pesquisa: CloudKit (CKShare, zonas compartilhadas, banco público/privado, sync)

> **Pesquisador P3** · auditoria multiagente · modo relatório (nenhuma chamada de rede
> ao CloudKit foi feita; nenhum `CKOperation` foi executado contra o serviço real).
> Toda afirmação sobre o **nosso código** cita `arquivo:linha` lido nesta execução.
> Toda fonte foi acessada em **23/09/2026**. SDK de referência: **MacOSX27.0.sdk /
> Xcode-beta 27.0** (medido na auditoria `audit/00-mapa.md:26-25`; interface local em
> `…/MacOSX.sdk/System/Library/Frameworks/CloudKit.framework/…/arm64e-apple-macos.swiftinterface`).
>
> **Legenda:** OFICIAL = Apple (docs/WWDC/technote/SDK). SECUNDÁRIA = fórum, blog,
> espelho de transcript (marcado). NÃO VERIFICADO = declarado como tal.

---

## 1. Versão/estado atual do CloudKit

O CloudKit **não tem número de versão próprio**: ele evolui por SDK/framework. O
framework `CloudKit` documenta disponibilidade `iOS 8.0+ … macOS 10.10+ … visionOS 1.0+`
([F1], acessada 23/09/2026, copyright "2026 Apple Inc." no JSON da página). O SDK que
este app usa hoje é o **MacOSX27.0.sdk** (Xcode-beta 27.0), confirmado nesta máquina.

Estado e mudanças relevantes (OFICIAL, verificado nesta execução):

- **Bancos:** três escopos — `privateCloudDatabase`, `sharedCloudDatabase`,
  `publicCloudDatabase`, todos expostos por `CKContainer`
  (docs `CKContainer`, JSON `…/documentation/cloudkit/ckcontainer.json` — seções
  "Getting the Public and Private Databases"). Nosso container explícito:
  `ServicoDeEquipesCloudKit.swift:40` e `SincronizadorDaBibliotecaCloudKit.swift:340`
  (`CKContainer(identifier: "iCloud.com.papagaio.Papagaio")`), batendo com o entitlement
  `Config/Papagaio.entitlements:11-18`.
- **Zone-wide sharing (CKShare de zona inteira):** introduzido iOS 15/macOS 12 e
  apresentado no WWDC21 "What's new in CloudKit" [F14]: inicializador
  `CKShare(recordZoneID:)` compartilha **todos** os registros da zona; apagar o
  `CKShare` descompartilha; `hierarchicalRootRecordID`/`rootRecord` ficam `nil` em shares
  de zona. **É exatamente o modelo usado pelo app** (`ServicoDeEquipesCloudKit.swift:59`,
  `:252`).
- **APIs async/await + `Swift.Result`:** WWDC21 [F14] — variantes async de
  `CKContainer`/`CKDatabase` e blocos `…ResultBlock` substituem callbacks antigos. Nosso
  código já usa as variantes async (`try await banco.save(...)`,
  `SincronizadorDaBibliotecaCloudKit.swift:175`) e os blocos Result
  (`recordWasChangedBlock`/`fetchRecordZoneChangesResultBlock`, `:253`, `:261`).
- **`encryptedValues` (WWDC21 [F14]):** payload de valores criptografados por chave do
  Keychain do usuário, decisão feita **na criação do campo**. Nosso app **não usa**
  `encryptedValues` (grep = 0); ver §4 — dados do banco público e do share vão em claro
  do ponto de vista do servidor (criptografia em trânsito/persistência é da Apple, mas
  o conteúdo é legível por qualquer cliente que acesse o registro).
- **Novas APIs de controle de share no SDK atual:** `CKShare.allowsAccessRequests`,
  `blockedIdentities`, `requesters`, `oneTimeURL(for:)`, `blockRequesters(_:)`
  presentes nas docs [F10] e na interface local (`grep oneTimeURL` → linha 1093).
  **Não verifiquei a versão exata de introdução** (provavelmente macOS 15+/iOS 18+ —
  não afirmo). Nosso código não os usa.
- **CloudKit Dashboard → "CloudKit Console"** (renomeado; WWDC22 [F16], WWDC24 [F17]):
  recursos novos = zonas compartilhadas no console (share público/privado por código),
  "Act As iCloud", containers ocultos, telemetria e alertas.
- **SwiftData/CloudKit:** o app **não** usa sincronização SwiftData↔CloudKit —
  `ModelConfiguration(…, cloudKitDatabase: .none)`
  (`PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:29-35`,
  comentário na `:7`). Grep `NSPersistentCloudKitContainer` = **0** no repo.
- **Limites publicados hoje:** `CKError.limitExceeded` (docs atuais, copyright 2026)
  = **400 itens (records/shares) por operação**, **2 MB por request (sem assets)**,
  com a ressalva de que "o servidor pode mudar seus limites a qualquer momento";
  o app deve **dividir a operação ao meio e tentar de novo** [F6]. Registro de 1 MB e
  asset de 50 MB só constam da **CloudKit Web Services Reference arquivada**
  (atualizada 2016-06-13) [F21] — ARCHIVE, **não confirmado para o SDK atual**.
  Quota diária de transações: **não encontrei página oficial com números atuais**
  (o fórum oficial de desenvolvedores relata que a tabela de preços/limites foi
  removida do site — SECUNDÁRIA [F25]); a página oficial de produto só afirma
  "up to 1PB of storage for your app's public data" [F20].

---

## 2. Gargalos conhecidos e anti-padrões documentados

Cada item traz: **(a)** o que a Apple documenta e **(b)** onde isso toca o nosso código.

### 2.1 Limites de lote e de tamanho (OFICIAL)

- **400 itens/operação, 2 MB/request** → `CKError.limitExceeded`; remedy = dividir e
  reenviar [F6].
- `CKError.batchRequestFailed`: **zonas customizadas são atômicas** — se um item falha,
  o lote inteiro falha; verifique os erros por item (`CKError.partialFailure`) e reenvie
  [F7][F8].
- Limits antigos (200 ops/request, 200 records/response, registro 1 MB, asset 50 MB):
  só na referência arquivada [F21] — usar como ordem de grandeza, não como garantia.
- **No nosso código:** os lotes são de 1–2 registros por chamada
  (`modifyRecords(saving: [registro, compartilhamento], …)`
  `ServicoDeEquipesCloudKit.swift:63-68`; `saving: [registro]` `:208-209`, `:258-263`;
  `saving: [], deleting: ids` `:430-431`) — nunca estouram 400 itens, mas também
  **nunca aproveitam lote**: cada operação da fila é um round-trip próprio
  (`for operacao in elegiveis` → `sincronizador.enviar/remover` de 1 em 1,
  `FilaPersistenteCloudKit.swift:126-147`).

### 2.2 `fetchAllChanges` e custo de `CKFetchRecordZoneChangesOperation` (OFICIAL)

A página da operação [F9] diz textualmente (parafraseado): o token do servidor é um
ponteiro opaco para um ponto da história da zona; **sem token (ou com token nulo) você
refaz a carga completa da zona**; cada batch devolve um novo token; os tokens "são
seguros para cache em disco" e **não são compatíveis entre tipos de operação**; a
operação só funciona em bancos **private/shared** — no público gera erro; e recomenda:
buscar tudo na **primeira** execução, cachear, **assinar** (`CKDatabaseSubscription`
para private, ou subscription no shared) e buscar mudanças **ao receber push**;
"não é necessário buscar a cada launch nem agendar buscas em intervalos regulares".

- **No nosso código:** `operacao.fetchAllChanges = true` com **nenhum token**
  (`SincronizadorDaBibliotecaCloudKit.swift:247-249`) — ou seja, **toda chamada
  refaz a carga total da zona**. Grep `serverChangeToken|previousServerChangeToken` =
  **0** no repo. Custo prático: `baixarAtualizacoesDaEquipe()` roda **a cada troca de
  espaço/entrada em equipe** (`Biblioteca.swift:211-236` → `:1138-1174`) e traz a zona
  inteira, decodificando cada `CKAsset` para `Data` (`Sincronizador…:212-221`).

### 2.3 Reaproveitamento de `CKServerChangeToken` (OFICIAL)

- `CKError.changeTokenExpired` = "o token de mudança expirou" [F11] — remedy: refazer
  carga completa (token nulo) e recachear.
- O app **não tem cache de token algum** (greps acima = 0) — logo nunca sofre
  `changeTokenExpired`, **ao custo permanente de downloads completos** (trade-off
  documentado, não um bug).

### 2.4 Zonas deletadas (OFICIAL)

- `CKError.zoneNotFound` = "a zona de registros especificada não existe" [F12];
  `CKError.unknownItem` = "o registro especificado não existe" [F13].
- **No nosso código:** exclusão global apaga a zona no dono
  (`ServicoDeEquipesCloudKit.swift:295`) e grava marcador público `EquipeExcluida`
  (`:285-301`). O tratamento de zona ausente é feito **por substring de
  `localizedDescription`**: `DiagnosticoDaSincronizacaoCloudKit.mensagem` casa
  `"zone does not exist"` (`SincronizadorDaBibliotecaCloudKit.swift:106-108`) —
  anti-padrão: depende do texto (idioma/versão) em vez de `CKError.code`.
  `unknownItem` é tratado por código em 3 pontos (`Servico…:296`, `:314`;
  `Sincronizador…:280`).

### 2.5 `CKError` de retry/backoff (OFICIAL)

| Código | O que a Apple manda fazer (paráfrase) | Fonte |
|---|---|---|
| `.requestRateLimited` | CloudKit está limitando a taxa; **ler `CKErrorRetryAfterKey`** em `userInfo` e esperar esses segundos antes de repetir | [F1]…[F2] |
| `.zoneBusy` | "Tente de novo em alguns segundos; se persistir, **aumente o delay exponencialmente**" + `CKErrorRetryAfterKey` | [F3] |
| `.serviceUnavailable` | CloudKit indisponível (retry posterior) | [F4] |
| `.networkFailure` | Rede ok mas CloudKit inacessível: retry imediato **com backoff**; monitorar reachability | [F5] |
| `.networkUnavailable` | Rede indisponível: mesmo conselho de backoff | [F5b] |
| **TN3162 (technote)** | Throttles existem quando o app emite "muitos requests em pouco tempo" ou "picos recorrentes de muitos dispositivos ao mesmo tempo"; a resposta traz tempo de espera; **"a melhor estratégia é evitar os throttles: minimizar o número de operações e tratar erros de toda operação CloudKit"**; não há API para configurar a expiração | [F18] |

- **No nosso código:** backoff existe **só no nível da fila**:
  `FilaPersistenteCloudKit.atraso(para:)` = `min(5 * 2^(n-1), 900)` s, tentativas
  limitadas a 10 (`FilaPersistenteCloudKit.swift:154-158`, `:199-202`), reagendado por
  `Biblioteca.agendarRetryCloudKit` (`Biblioteca.swift:1123-1135`).
  **Porém:** o `catch` é genérico (`catch { … }` `FilaPersistenteCloudKit.swift:152`)
  — **nenhum código `CKError` é inspecionado** (grep `CKError` = 3, todos
  `.unknownItem`) e **`CKErrorRetryAfterKey` nunca é lido** (grep = 0). Consequência:
  um `.requestRateLimited` com `retryAfter` de 60 s pode ser reenviado em 5 s (1ª
  retentativa), e um `.zoneBusy` que pede backoff exponencial recebe o mesmo tratamento
  de um timeout de rede — **anti-padrão documentado pela própria Apple [F2][F3][F18].**
  Erros que **não** melhoram repetindo (schema não publicado, `zone does not exist`)
  são bloqueados por substring (`DiagnosticoDaSincronizacaoCloudKit.exigeAcaoDoProprietario`,
  `Sincronizador…:116-122`; consumo em `Biblioteca.swift:1111-1113`).

### 2.6 Throttle de subscriptions e custo de notificações (OFICIAL)

- TN3162 [F18] vale para **qualquer** operação, inclusive salvar subscriptions.
- `CKQuerySubscription`: as subscriptions são **por usuário** ("A subscription applies
  only to the user that creates it"); só funcionam em **public e private** (no shared a
  `CKDatabaseSubscription` é o caminho [F9]); "o sistema **agrupa (coalesces)** as
  notificações — não dependa delas para mudanças específicas; CloudKit pode omitir
  dados para caber no limite de payload do APNs; trate a notificação como indício e
  **busque as mudanças com `CKQueryOperation`**"; escopar por `zoneID` **reduz o nº de
  notificações**; criar a subscription **na primeira execução** e persistir flag local
  para não re-salvar [F15]. QA1917 (arquivo Apple, ARCHIVE) reforça: subscriptions
  precisam existir **por usuário** e aparecerem no console daquele usuário [F22].
- **No nosso código:** grep `CKSubscription|CKNotification|CKDatabaseSubscription` =
  **0** — não há subscription nenhuma. O "polling" é por evento de UI: fetch completo
  ao abrir/trocar de equipe (`Biblioteca.swift:236`, `:1147`) e 1 fetch público por
  equipe na abertura do app (`ContentView.swift:441` → `:761-782`). Ou seja: **nem
  push, nem token, nem assinatura** — pior latência e maior custo de request do que o
  padrão recomendado [F9][F15].

### 2.7 Escrita sem batch / N+1 de queries e round-trips (OFICIAL + aplicação)

- A Apple documenta (TN3162 [F18]) que **minimizar o nº de operações** é a defesa
  primária contra throttle; o transcript do WWDC15 "CloudKit Tips and Tricks"
  (SECUNDÁRIA [F23] — página oficial redireciona para o índice, ver §8) diz: "quando
  sua app usa a convenience API um item por vez em vários lugares, use a versão
  `CKOperation` em lote — melhora a execução e **economiza seu quota de requests**";
  também `resultsLimit` e `desiredKeys` para não baixar o que não se usa. O sample
  oficial de sharing recomenda **cache local da zona** "para não consultar o servidor
  ao navegar" [F19].
- **No nosso código — N+1/round-trips concretos (evidência lida):**
  1. `salvar` = **fetch + save** por conversa: `banco.record(for: id)` +
     `banco.save(registro)` (`SincronizadorDaBibliotecaCloudKit.swift:160`, `:175`;
     `registroExistente` `:274-283`) → 2 round-trips × fila sequencial.
  2. `atualizarNome` = fetch + `modifyRecords` (`Servico…:204-210`);
     `atualizarConfiguracoes` = fetch + save (`:139-141`); padrão read-modify-write.
  3. `participantes(da:)` =2 fetches encadeados (share `:151` + registro de nomes
     `:153`).
  4. Reconciliação de exclusão = **1 query pública por equipe, sequencial** no launch
     (`for equipe in candidatas { … equipeFoiExcluida … }`, `ContentView.swift:762-777`;
     cada `equipeFoiExcluida` = `publicCloudDatabase.record(for:)` `Servico…:309`).
  5. `entrarNaEquipe` =1 query pública (`:98`) + `shareMetadata` (`:104`) + `accept`
     (`:341`) +1 fetch no shared (`:344`) —4 round-trips, aceitável para um login.
  6. `paginar` usa cursor **falso**: a "página" de200 (`tamanhoDaPagina`, `:149`) é
     fatiada **em memória a partir da carga completa** (`:223-240`), não com cursor
     servidor (`CKQueryOperation.Cursor` existe, `:5` e `:185-189` só simulam).
- Queries `CKQuery`: só2, ambas no banco público (`Servico…:94`, `:420`), com
  `records(matching:)` sem `resultsLimit`/`desiredKeys` (grep `resultsLimit` =
  0, `desiredKeys` = 0). `CKQueryOperation` é restrito a **uma zona por query** e
  paginaa por cursor [F24].

### 2.8 QuotaExceeded (OFICIAL)

`CKError.quotaExceeded` tem tratamento **diferente por banco** [F10b]:
- **público:** "o container da sua app não tem armazenamento suficiente; usuários
  individuais não podem fazer nada — gerencie no CloudKit Dashboard";
- **privado:** "o usuário não tem espaço iCloud" → mandar para os ajustes do iCloud;
- **shared:** "o dono da zona não tem espaço" → o participante só pode contatar o dono.
- **No nosso código:** grep de `quotaExceeded` = **0** — o código de fila trataria como
  erro genérico e **re-tentaria até10 vezes** (`FilaPersistenteCloudKit.swift:155-158`)
  um erro que **não resolve sozinho**. Para equipes em `shared`, um quota cheio do dono
  viraria loop de retry do participante. **Relevante:** mídia vai como `CKAsset` na
  conversa (`Sincronizador…:167`) — no **shared** banco isso consome quota do **dono**.

### 2.9 Consistência cliente×servidor e merge de edições concorrentes (OFICIAL)

- `CKError.serverRecordChanged` (docs, copyright 2026): a versão do servidor é mais
  nova; **o app deve resolver o conflito**; o erro traz **3 cópias** no `userInfo`
  (local, servidor, original) e a fusão deve ser feita **na cópia `serverRecord`**,
  senão o conflito repete (as outras cópias têm change tag antigo) [F10c].
  O WWDC15 reforça: "CloudKit não faz nada mágico — não resolve conflitos sozinho"
  (SECUNDÁRIA [F23]).
- `CKError.partialFailure` / `batchRequestFailed` definem a semântica de lote atômico
  em zona custom [F7][F8].
- **No nosso código:**
  - Escritas usam `savePolicy: .ifServerRecordUnchanged` sempre
    (`Servico…:66`, `:209`, `:261`, `:431`; `Sincronizador…:207`) — **correto**: gera
    `serverRecordChanged` em edição concorrente em vez de sobrescrever cegamente.
  - **Mas** o handler de conflito é "refetch e sobrescrever campos inteiros":
    `registroExistente` busca o registro atual e o payload novo sobrescreve
    `conteudo/título/datas` (`Sincronizador…:160-175`) — como o blob é um JSON único
    por conversa, isso equivale a **last-writer-wins por conversa** (decisão de
    produto), **não** ao merge campo-a-campo sugerido pela Apple [F10c].
  - A fila **não usa as3 cópias** do erro; ela apenas reagenda com backoff
    (`FilaPersistenteCloudKit.swift:152-161`) — o refetch seguinte resolve.
  - Conflito local×remoto na download é resolvido por **comparação de data de revisão**
    (`PoliticaDeConflitoCloudKit.decidir`, `Sincronizador…:65-80`; consumo em
    `Biblioteca.swift:1147-1155`) — "preserva pendente local" quando a revisão local
    difere da remota. Não há merge de conteúdo: ou aplica remoto ou mantém local.
  - Escrituras do `CKShare` (permissão/participante) também são read-modify-write com
    `.ifServerRecordUnchanged` (`Servico…:219-227`, `:232-240`) — concorrência entre
    dois donos/admins editando a lista de participantes ao mesmo tempo gera
    `serverRecordChanged` e falha da segunda escrita (tratado só pelo retry genérico).

---

## 3. Recomendações oficiais de performance e configuração (WWDC/technotes)

1. **TN3162 "Understanding CloudKit throttles"** [F18] (OFICIAL, acessado 23/09/2026):
   minimizar nº de operações; evitar picos; tratar **todo** erro de operação; respeitar
   o tempo indicado (ex.: `requestRateLimited` com retry-after); entender throttles
   device-side (bateria baixa adia operações; para `NSPersistentCloudKitContainer`/
   SwiftData, olhar sysdiagnose).
2. **WWDC21 "What's new in CloudKit"** [F14] (OFICIAL,2021,URL verificada 200 em
   23/09/2026): usar variantes **async** (já usamos); blocos `Result`; **zone-wide
   share** para compartilhar zonas inteiras (modelo adotado); `encryptedValues` para
   dados sensíveis (não adotado — ver §4); apagar o `CKShare` descompartilha a zona.
3. **Tech Talk "Get the most out of CloudKit Sharing"** [F23b] (OFICIAL): no modelo de
   **root record**, `CKShare` e root **precisam ser salvos na mesma operação** (salvar
   só o share gera erro); em **zone share** isso não se aplica (nosso `modifyRecords`
   salva share+`Equipe` juntos `Servico…:63-68` — compatível com os dois modelos);
   permissões por participante; aceitação via `userDidAcceptCloudKitShareWith`
   (nosso delegate `DelegadoDeConvitesCloudKit.swift:13-34`).
4. **CKFetchRecordZoneChangesOperation** [F9]: primeira busca = completa; cachear
   token em disco; assinar `CKDatabaseSubscription` (private) / subscription de
   database changes (shared) e buscar **no push**; **não** buscar a cada launch nem
   agendar polling; no shared, zonas aparecem/desaparecem dinamicamente → primeiro
   `databaseChanges`/zones, depois mudanças por zona.
5. **CKQuerySubscription** [F15]: criar na primeira execução e persistir flag;
   escopar por zona para reduzir notificações; notificações são agrupadas → usar como
   gatilho de fetch, não como fonte de verdade.
6. **WWDC24 "Use CloudKit Console to monitor and optimize database activity"**
   [F17] (OFICIAL,2024,URL 200): configurar **alertas e telemetria** do container
   (custo/erros), ferramenta que o nosso app hoje não tem como pré-requisito operacional
   (não verifiquei se o time configurou alertas no console — **não verificável por
   código**).
7. **WWDC22 "What's new in CloudKit Console"** [F16]: zonas compartilhadas podem ser
   **públicas** ("qualquer um com o código de share entra") ou **privadas**;
   "Act As iCloud" para depurar dados de usuários reais.
8. **Sample/guide "Sharing CloudKit Data with Other iCloud Users"** [F19]: cache
   em memória da zona para navegar sem consultar o servidor; schema em **produção**
   precisa ser publicado antes (no **development** o CloudKit cria tipos
   automaticamente ao salvar — citado em §5).
9. **Core Data sharing doc** [F26]: "CloudKit tem **limite de nº de zonas** por banco"
   — sem número na página; considerar ao criar **uma zona+CKShare por equipe**
   (`Servico…:51-59`) se o nº de equipes por conta crescer (não medi o limite —
   **NÃO VERIFICADO** o número).
10. **Batch (SECUNDÁRIA [F23]):** agrupar escritas com `CKModifyRecordsOperation`,
    usar `resultsLimit`/`desiredKeys`. Não há equivalente direto no nosso fluxo de
    fila (1 arquivo por operação), e o payload já é um blob único.

---

## 4. Segurança/privacidade do banco PÚBLICO, CKShare e DCS — CRÍTICO

### 4.1 O que o banco público permite (fonte oficial)

- **"Apps can always store data in a public area that is readable by all users."**
  — CloudKit framework overview [F1].
- **"Por padrão, todos os usuários podem ler e escrever dados no banco público."**
  / "Por padrão, qualquer usuário pode ler ou escrever dados no banco público" —
  Tech Talk Apple **"GDPR & CloudKit"** [F19b] (developer.apple.com/videos/play/tech-talks/703,
  URL verificada 200 em23/09/2026). A mesma fala explica: 1 banco público por
  container; dados privados pertencem ao usuário; shared = "visão parcial do banco
  privado do dono".
- **CloudKit JS — `CloudKit.Database`** [F19c] (OFICIAL): "o **read** do banco público
  **não exige login**… por padrão seu app não pode gravar sem usuário logado; cada
  container tem um banco público **cujo dado é acessível a todos os usuários**".
  Ou seja: **leitura pública é possível sem Apple Account** (web/API), e escrita
  exige apenas *qualquer* conta logada — **sem autoria, sem ACL por usuário**.
- **Base acadêmica (SECUNDÁRIA, sistema CloudKit)** [F27]: no banco público "apenas
  usuários autenticados armazenam; security roles são usadas para controle de acesso";
  sem as roles (padrão), todos leem/escrevem.
- **Não existe isolation por usuário no público:** gravações são atribuídas ao
  "dono padrão" do container; qualquer cliente autenticado pode **atualizar e apagar**
  registros de terceiros. A Apple documenta a consequência operacional em
  `quotaExceeded`: a quota do público é **do container**, e "usuários individuais não
  podem fazer nada" [F10b].

### 4.2 O que a Apple recomenda guardar lá

Nenhuma página atual diz literalmente "guarde X"; as fontes oficiais delimitam por
propósito: público = "área legível por todos os usuários" [F1] — dados **globais do
app**, não dados de usuário. Combinações oficiais de sharing são o caminho para dados
entre pessoas: `CKShare`/zona compartilhada [F10][F23b] ou "public share" no Console
[FC2] [F16]. O próprio WWDC21 enfatiza que sharing CloudKit é protegido por
**autenticação de conta + acesso criptográfico aos dados compartilhados**
("CloudKit establishes cryptographic access to the shared data for participants, on
top of requiring account-based authentication for all requests" [F14]) — **propriedade
que o banco público não tem**.

### 4.3 No nosso app: exatamente o que vai para o banco público

Evidência (`ServicoDeEquipesCloudKit.swift`):

| Escrita/leitura pública | Linha |
|---|---|
| Salva `CodigoDeEquipe` com `codigoDeEntrada` + **`urlDoCompartilhamento`** (URL do CKShare) | `:410-415` |
| Query pública por `%K == codigoDeEntrada` para entrar | `:94-98` |
| Deleta códigos antigos (`modifyRecords(deleting:)`) | `:418-432` |
| Grava marcador `EquipeExcluida` (`equipeID`, `excluidaEm`, `estadoDaExclusao`) | `:285-301` |
| Lê marcador a cada launch (cada Mac) | `:307-317` |

**Riscos derivados do modelo oficial de confiança (§4.1) — classificação de auditoria:**

1. **CRÍTICO — marcação de exclusão forjável:** qualquer cliente autenticado pode
   **salvar/modificar** o registro `EquipeExcluida` de **qualquer** equipe (IDs
   `equipe-excluida.<equipeID>` são deriváveis — o tipo é consultável). Nosso app
   **confia nesse marcador sem nenhuma verificação de autoria** e, ao vê-lo
   `concluida`, **apaga conteúdo local** (reconciliação em
   `ContentView.swift:761-782`, `limparDadosLocais` `:784-795`). Um cliente hostil
   (ou um app malicioso no mesmo container) pode provocar **apagamento remoto da
   cópia local** de outra pessoa. Também pode **estagnar** o processo em
   `preparando` (`Servico…:35-38`, `:291`, `:300`).
2. **CRÍTICO — URL do share + código publicados em claro no público:** o registro
   `CodigoDeEquipe` entrega **a URL do `CKShare`** a qualquer leitor (`:414`), e o
   share foi criado com `publicPermission = .readWrite` "para quem tiver o link"
   (`:61`, `:383-385`, comentário de produto em `:381-382`). Pela doc do `CKShare`
   [F10]: "você pode permitir que **qualquer um com a URL** participe". Ou seja: o
   banco público é um **diretório de convites de escrita para zonas privadas** —
   leitura pública **sem login** [F19c] expõe a URL; qualquer conta que a use entra na
   equipe. Mitigações atuais do app: código6 caracteres sem ambigüidade
   (`EquipeDisponivel.swift:134-136`, ~30 bits) + rotação de código **troca o CKShare**
   (`Servico…:242-274`), o que **invalida o link antigo** — bom, mas a **nova URL volta
   a ser publicada no público**, e a rotação só protege contra quem já tinha o link
   **antes** dela.
3. **ALTO — vandalismo/DoS do fluxo de entrada:** qualquer um pode **apagar ou
   adulterar** registros `CodigoDeEquipe` (mesmo mecanismo de escrita pública), derrubando
   o join de equipes (o app responde `codigoInvalido`, `:99-103`). Não há como
   "reclamar" de exclusão: `invalidarCodigoAnterior` do dono e a destruição de um
   atacante são indistinguíveis.
4. **ALTO —枚 enumeração:** a query por campo exato (`:96`) não vaza lista, mas o
   **tipo `CodigoDeEquipe` é consultável** (queryable no Console) — sem rate-limit
   próprio além dos throttles gerais [F18], força-bruta de6 caracteres é viável em
   escala de container (e a tentativa custa quota do **nosso** container).
5. **MÉDIO — `nomesDosParticipantes`/`configuracoes`/conteúdo de conversa:** vão para
   **private/shared** (ex.: `nomesDosParticipantes` salvo no registro `Equipe`
   `Servico…:207-210`) — **correto**. Não há payload de conversa no público ✓
   (grep das linhas públicas acima é exaustivo: só código, URL e marcador).
6. **`CKShare` e permissões (OFICIAL [F10][F23b]):** participantes `readOnly`/
   `readWrite` por `publicPermission` + por participante (`Servico…:225` muda para
   `.readOnly`/`.readWrite`); dono não aparece em `participants` (defesa em `:468-469`);
   "uma vez compartilhada, a zona inteira está visível a quem aceitou" (zone share,
   [F14]) — portanto **permissão de leitura é por equipe, não por arquivo**: a
   config `visibilidadeDosArquivos` (`EquipeDisponivel.swift:29-32`) **não tem
   enforcement em CloudKit** (é só UI/local — verificado: nenhum código CK lê
   `configuracoes.visibilidadeDosArquivos`). **Próximo participante lê tudo que está
   na zona**, incl. conversas de todos.
7. **Criptografia de valores:** não usamos `encryptedValues` (grep 0) — WWDC21 [F14]
   é a opção oficial para "proteger dados sensíveis" no servidor; **não adotada**.

### 4.4 DCS — "Dynamic Content Sharing"

**NÃO VERIFICADO como termo oficial da Apple.** Buscas por frase exata em
`developer.apple.com`/web (23/09/2026) não retornaram nenhuma página Apple com o
nome "Dynamic Content Sharing"; grep no nosso repo (`DCS|Dynamic Content`) = **0**.
Os conceitos oficiais mais próximos, que a auditoria deve tratar como equivalentes
intencionais, são: **zone-wide sharing** (iOS15+/WWDC21 [F14]), **public vs private
shared zone** no Console ("A public shared zone makes every record visible to everyone
who has the share code", WWDC22 [F16]) e **`CKShare.publicPermission` + anyone-with-URL**
[F10][F23b]. Se o termo DCS veio de outro documento do projeto, este relatório não o
encontrou e **não inventa definição**.

---

## 5. Bugs/vulnerabilidades conhecidos que afetam a versão usada

Honestidade: **não localizei release notes/known issues oficiais de CloudKit
específicas para macOS 26/27** (não existe página "CloudKit release notes" atual —
**NÃO VERIFICADO** se existe). O que se tem:

1. **Armadilha operacional documentada (OFICIAL):** schema em **produção** precisa ser
   publicado; em development o servidor cria tipos automaticamente ao salvar, mas
   "para apps reais o schema deve existir antes" (guide [F19]). O nosso app já trata
   os sintomas **por substring**: `"cannot create new type conversa in production
   schema"`, `"did not find record type: equipeexcluida"`, campo
   `nomesDosParticipantes` Bytes, `"type is not marked indexable"`
   (`SincronizadorDaBibliotecaCloudKit.swift:94-111`) — evidência de que esses
   erros **já ocorreram em produção**.
2. **Quirks de plataforma conhecidos, registrados no próprio código (evidência
   interna):** `userIdentity` do `CKShare` "pode vir omitida" (`Servico…:196`);
   "O CloudKit pode **repetir o proprietário** em `participants`" (`:465-467`);
   contagem de membros podia virar0 (`EquipeDisponivel.swift:68-70`).
   Esses são workarounds para comportamentos reais do SDK.
3. **Identidade instável (bug latente nosso, níveis OFICIAL+interno):**
   `idDoParticipante` cai para **`UUID().uuidString`** quando o participante não tem
   `userRecordID` nem e-mail (`Servico…:481-485`) — cada chamada gera um ID
   **diferente**, quebrando mapeamento de nomes (`nomes[id]`, `:492`) e a checagem
   `participanteID == idAtual` (`:199`).
4. **SECUNDÁRIA (fóruns oficiais Apple, não reproduzidos por mim):** "bugs no lado da
  Apple limitaram push a ~200 subscribers" (2020) [F27b]; "Zombie CKQuerySubscription"
   (2024) [F27c]; relato2026 (iOS26.4/Xcode26) de `CKQuerySubscription` em produção
   não disparando push APNs + `BAD_REQUEST` ao criar subscription [F27d]. **Marcado
   como não verificado** — relevante porque, se adotarmos subscriptions (§3.4), é a
   classe de risco a testar.
5. **`CKError` tratado por texto (vulnerabilidade de robustez):** todo o mapeamento de
   erro de ambiente depende de `localizedDescription` em inglês minúsculo
   (`Sincronizador…:92-113`) — mudança de texto do SDK ou de idioma do sistema quebra
   os diagnósticos (os testes de localização do app já falham por idioma —
   `audit/00-mapa.md:403-412` — mesma classe de problema).
6. **Não verifiquei:** comportamento do serviço real (modo relatório), bug de quota,
   limites numéricos de zonas/assinaturas, e se há correções de CloudKit no SDK 27
   beta — **sem acesso a release notes**.

---

## 6. Deprecações

Fonte primária: **swiftinterface do SDK em uso** (`arm64e-apple-macos.swiftinterface`,
2.026 linhas; **244** linhas `@available(… deprecated …)`), lido nesta execução +
docs atuais (JSON, copyright 2026).

| API | Estado (evidência) | Usamos? |
|---|---|---|
| **Família Contacts-discovery** (`discoverAllIdentities(completionHandler:)`, `discoverUserIdentities(for…)`, `userIdentity(for…)` async, `allUserIdentitiesFromContacts()`, blocos `discover…ResultBlock`) | **Deprecado** macOS **14.0**, mensagem oficial: *"No longer supported. Please see Sharing CloudKit Data with Other iCloud Users."* (docs JSON `ckcontainer/discoverallidentities…` + swiftinterface linhas47-164) | **Não** (grep `discoverAll…` = 0). Rede de contatos para convidar = caminho morto desde macOS14. |
| **`CKShareParticipantType`/`type` antigo** | **`obsoleted: 26.0`** — *removido* no macOS 26 (swiftinterface `:1125`, `:1175`): "Use CKShare.ParticipantRole" | **Não** — usamos `participante.role != .owner` (`Servico…:468`) e `.permission` (`:225`, `:475`), os tipos aninhados atuais. |
| Typealiases antigos `CKShareParticipantPermission`/`…AcceptanceStatus`/`CKRecordReferenceAction`/`CKContainerApplicationPermission*` | deprecados "renamed to …" (swiftinterface, ocorrências `renamed to`) | Não (nomes Swift aninhados já usados). |
| **`CKContainer.default()`** | **NÃO deprecado** (docs JSON: `deprecated:false`) — correção de uma crença comum | Não usamos; usamos `init(identifier:)` (`Servico…:40`, `Sincronizador…:340`) — alinhado ao container do entitlement. |
| **`CKRecordSystemFields`/`encodeSystemFields(with:)`** | Docs atuais listam `encodeSystemFields(with:)` como tópico vigente, **sem** flag de depreciação; grep no swiftinterface local não achou `systemfields` (**inconclusivo** no nível da interface) | Não usado (grep = 0). |
| Blocos antigos de `CKFetchRecordZoneChangesOperation` | Página da operação tem seção **"Deprecated"** (`…/ckfetchrecordzonechangesoperation-deprecated-symbols`) — substituídos pelos `…ResultBlock` | **Já usamos os novos**: `recordWasChangedBlock`/`fetchRecordZoneChangesResultBlock` (`Sincronizador…:253`, `:261`). Não enumerei os símbolos antigos (**não verificado**). |
| **`NSPersistentCloudKitContainer`** | Vigente (Core Data), só não é nosso caso | grep = 0; SwiftData `cloudKitDatabase: .none` (`SwiftDataRepository.swift:33`). |
| Completion-handler variants (`save(_:completionHandler:)`, `fetch(withRecordID:completionHandler:)`…) | **Não** marcadas como deprecadas nas docs atuais (seções "Instance Methods" sem "Deprecated") | Não usamos — usamos async/await (recomendado desde WWDC21 [F14]). |

---

## 7. Onde procurar no nosso código (greps executados nesta execução)

Todos os greps: `--include=*.swift` em `Papagaio/`, `PapagaioCore/`, `PapagaioTests/`
(excluindo `.build` nos totais citados). Contagens **medidas**.

| Padrão | Ocorrências | Exemplos (`arquivo:linha`) |
|---|---:|---|
| `CKShare` | **19** | `ServicoDeEquipesCloudKit.swift:59` (criação), `:252` (rotação), `DelegadoDeConvitesCloudKit.swift:15` (aceite) |
| `CKDatabase`+`publicCloudDatabase`+`privateCloudDatabase` | **27** | `Servico…:54` (privado), `:415` (público), `Sincronizador…:244` (op de zona) |
| `publicCloudDatabase` | **7** | `Servico…:98` (query), `:292` (save EquipeExcluida), `:430` (delete) |
| `privateCloudDatabase` | **13** | `Servico…:141`, `:226`, `:295`; `Sincronizador…:290` |
| `sharedCloudDatabase` | **5** | `Servico…:120`, `:167`, `:344`; `Sincronizador…:291` |
| `fetch(withRecordID` | **0** | (usamos `record(for:)` —9×: `Servico…:139`, `:204`, `:502`; `Sincronizador…:279`) |
| `fetchAllChanges` | **1** | `Sincronizador…:249` |
| `serverChangeToken`/`previousServerChangeToken` | **0** | → **ninguém usa change token** (ver §2.2/2.3) |
| `CKQuery` | **4** (2 reais +2 comentários) | `Servico…:94`, `:420` (reais); `Sincronizador…:5`, `:192` (coment.) |
| `CKSubscription`/`CKNotification`/`CKDatabaseSubscription` | **0** | → sem subscription/push (ver §2.6) |
| `records(matching:`/`record(for:` | **9** | `Servico…:98`, `:344`, `:424`; `Sincronizador…:279` |
| `.save(` em CK | **9** | `Servico…:55`, `:415`, `:292`; `Sincronizador…:175` |
| `modifyRecords` (+`atomically`/`performAtomic`) | **5** (`performAtomic` **0**) | `Servico…:63`, `:208`, `:258`, `:430`; `Sincronizador…:204` |
| `CKError` | **3** (todos `.unknownItem`) | `Servico…:296`, `:314`; `Sincronizador…:280` → **quem trata/ignora**: só `unknownItem`; o resto é `catch` genérico `FilaPersistenteCloudKit.swift:152` |
| `CKErrorRetryAfterKey` | **0** | backoff cego, ignora retry-after do servidor (§2.5) |
| `NSPersistentCloudKitContainer` | **0** | SwiftData: `SwiftDataRepository.swift:33` (`cloudKitDatabase: .none`) |
| `ModelConfiguration`/`cloudKitDatabase` | **4** | `SwiftDataRepository.swift:29`, `:33` |
| `recordZoneID` / `CKRecordZone` / `CKRecord.ID` | **3 / 12 / 14** | `Servico…:51`, `:535`; `Sincronizador…:248`, `:303` |
| `CKContainer` | **7** | `Servico…:40` e `Sincronizador…:340` (construções reais) |
| `CKContainer.default` / `discoverAll…` / `CKRecordSystemFields` | **0 / 0 / 0** | ver §6 |
| `publicPermission` | **3** | `Servico…:61`, `:254`, `:332` (`.readWrite` — `:383-385`) |
| `CKAsset` | **3** | `Sincronizador…:167` (escrita), `:215` (leitura), `:335` (coment.) |
| `resultsLimit` / `desiredKeys` | **0 / 0** | queries sem paginação/seleção de campos (§2.7) |
| `cloudKitDatabase:` | 1 (em `ModelConfiguration`) | `SwiftDataRepository.swift:33` |

**Síntese dos achados apontados pelo prompt:**

- **Quem trata `CKError`:** só `.unknownItem` em3 pontos (§7). **Quem ignora:** a fila
  (`FilaPersistenteCloudKit.swift:152-161`), o delegate de convites
  (`DelegadoDeConvitesCloudKit.swift:25-31`), a reconciliação (`ContentView.swift:773-776`,
  com comentário deliberado "falha transitória não autoriza apagar conteúdo local") e o
  diagnóstico por **string** (`Sincronizador…:88-114`).
- **Quem não usa change tokens:** `registrosDaZona` (`Sincronizador…:242-272`) —
  token ausente + `fetchAllChanges=true` = carga total a cada sync; **nenhum** código
  do repo lê/grava token (grops 0).
- **Quem faz operações uma a uma:** a fila (`FilaPersistenteCloudKit.swift:126-147`),
  `salvar` (fetch+save, `Sincronizador…:160/175`), read-modify-writes de equipe
  (`Servico…:139-141`, `:204-210`), reconciliação por equipe (`ContentView…:762-777`),
  `participantes` (`Servico…:151-153`).
- **O que vai para o banco público:** `CodigoDeEquipe` (`codigoDeEntrada` +
  `urlDoCompartilhamento`) e `EquipeExcluida` (`equipeID`, `excluidaEm`,
  `estadoDaExclusao`) — tabelas §4.3; **mais nada** (verificado linha a linha).

---

## 8. Fontes

Todas acessadas em **23/09/2026**. "Versão" = versão da plataforma/documento
indicada pela própria página. Parafrase = ponto que sustenta este relatório.

### Oficiais (Apple)

| # | Fonte | URL | Versão/vigência | Ponto parafraseado |
|---|---|---|---|---|
| F1 | CloudKit — overview do framework | https://developer.apple.com/documentation/cloudkit | iOS8+/macOS10.10+; página servida com copyright2026 | Apps podem guardar dados numa área pública "readable by all users"; CloudKit depende de rede e (para dado de usuário) conta iCloud |
| F2 | `CKError.Code.requestRateLimited` | https://developer.apple.com/documentation/cloudkit/ckerror/code/requestratelimited | docs atuais (2026) | Rate limit; ler `CKErrorRetryAfterKey` e esperar esses segundos antes de repetir |
| F3 | `CKError.Code.zoneBusy` | https://developer.apple.com/documentation/cloudkit/ckerror/code/zonebusy | idem | Servidor ocupado na zona; repetir em segundos e **aumentar delay exponencialmente**; retry-after key |
| F4 | `CKError.Code.serviceUnavailable` | https://developer.apple.com/documentation/cloudkit/ckerror/code/serviceunavailable | idem | CloudKit indisponível |
| F5/F5b | `networkFailure` e `networkUnavailable` | https://developer.apple.com/documentation/cloudkit/ckerror/code/networkfailure · …/networkunavailable | idem | Retry imediato **com backoff**; monitorar reachability |
| F6 | `CKError.Code.limitExceeded` | https://developer.apple.com/documentation/cloudkit/ckerror/code/limitexceeded | docs atuais (JSON copyright2026) | Limites gerais: **400 itens/operação,2 MB/request (sem assets)**; servidor pode mudar; dividir a operação e reenviar |
| F7 | `CKError.Code.batchRequestFailed` | …/ckerror/code/batchrequestfailed | idem | Zona custom é atômica: falha de um item derruba o lote; ver erros por item e reenviar tudo |
| F8 | `CKError.Code.partialFailure` | …/ckerror/code/partialfailure | idem | Inspecionar falhas por item no `userInfo`; em zona custom os demais viram `batchRequestFailed` |
| F9 | `CKFetchRecordZoneChangesOperation` | https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation | idem | Token opaco por zona; token nulo = carga total; tokens cacheáveis em disco; **só private/shared**; primeiro fetch completo → cachear → **subscription + push**; "não é necessário buscar a cada launch ou agendar buscas periódicas" |
| F10 | `CKShare` | https://developer.apple.com/documentation/cloudkit/ckshare | idem | Share de zona ou de hierarquia; registros iniciais precisam existir ou irem na mesma operação; um share por registro (senão `alreadyShared`); "pode permitir que qualquer um com a URL participe" |
| F10b | `CKError.Code.quotaExceeded` | …/ckerror/code/quotaexceeded | idem | Quota do **público** é do container (só o dev resolve); do **privado** é do usuário; do **shared** é do dono da zona |
| F10c | `CKError.Code.serverRecordChanged` | …/ckerror/code/serverrecordchanged | idem | Versão do servidor mais nova; app resolve;3 cópias no `userInfo`; mesclar na `serverRecord`, senão repete conflito |
| F11 | `CKError.Code.changeTokenExpired` | …/ckerror/code/changetokenexpired | idem | Token expirou (refazer carga completa) |
| F12/F13 | `zoneNotFound` · `unknownItem` | …/ckerror/code/zonenotfound · …/unknownitem | idem | Zona não existe · registro não existe |
| F14 | WWDC21 "What's new in CloudKit" (vídeo10086) | https://developer.apple.com/videos/play/wwdc2021/10086 | WWDC2021; URL→200 em23/09/2026 | Variantes async; blocos `Result`; **zone-wide share** com `CKShare(recordZoneID:)`; apagar o share descompartilha; `encryptedValues`; acesso criptográfico + autenticação de conta no sharing |
| F15 | `CKQuerySubscription` | https://developer.apple.com/documentation/cloudkit/ckquerysubscription | docs atuais | Subscription é por usuário; só public+private; notificações **agrupadas** → usar como gatilho de `CKQueryOperation`; escopo por zona reduz notificações; criar na1ª launch e persistir flag |
| F16 | WWDC22 "What's new in CloudKit Console" (10115) | https://developer.apple.com/videos/play/wwdc2022/10115 | WWDC2022; URL→200 | Zone sharing no Console: zona **pública** = qualquer um com o código de share entra; privada tem camada extra; "Act As iCloud" |
| F17 | WWDC24 "Use CloudKit Console to monitor and optimize database activity" (10122) | https://developer.apple.com/videos/play/wwdc2024/10122 | WWDC2024; URL→200 | Alertas + telemetria do container para monitorar comportamento e custo |
| F18 | **TN3162 Understanding CloudKit throttles** | https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles | technote atual (2026) | Throttles por excesso/picos de requests; resposta traz tempo de espera; device-side throttle (bateria); **melhor estratégia: minimizar operações, tratar todo erro, respeitar retry-after**; sem API de configuração |
| F19 | Guide/sample "Sharing CloudKit Data with Other iCloud Users" | https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users | docs atuais | Fluxo completo de share + permissões; **cache local da zona p/ não consultar o servidor**; schema: development cria tipos sozinho, **produção precisa de schema publicado** |
| F19b | Tech Talk "GDPR & CloudKit" (703) | https://developer.apple.com/videos/play/tech-talks/703 | tech talk; URL→200 | **"Por padrão, qualquer usuário pode ler ou escrever dados no banco público"**; um público por container; private pertence ao usuário; shared = visão parcial do dono |
| F19c | CloudKit JS `CloudKit.Database` | https://developer.apple.com/documentation/cloudkitjs/cloudkit.database | docs atuais | **Read do público não exige login**; escrita pública exige usuário logado; público "acessível a todos os usuários" |
| F20 | CloudKit (produto) | https://developer.apple.com/icloud/cloudkit | página atual | "até1PB de armazenamento para os dados públicos do seu app"; Console substituiu o Dashboard |
| F21 | CloudKit Web Services Reference — Data Size Limits (**ARCHIVE**) | https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html | archive, "Updated:2016-06-13" |200 ops/request,200 records/response, registro1 MB, asset50 MB — **histórico, não confirmado hoje** |
| F22 | QA1917 Debugging issues with CloudKit subscriptions (**ARCHIVE**) | https://developer.apple.com/library/archive/qa/qa1917/_index.html | arquivo Apple | Subscriptions são por usuário; ver no console **daquele** usuário; push exige registro |
| F23b | Tech Talk "Get the most out of CloudKit Sharing" (10874) | https://developer.apple.com/videos/play/tech-talks/10874 | URL→200 | `CKShare`+root **na mesma operação** (modelo hierárquico); zone sharing iOS15+; permissões por participante; `CKSharingSupported` |
| F24 | `CKQueryOperation` | https://developer.apple.com/documentation/cloudkit/ckqueryoperation | docs atuais | Paginação por cursor; query restrita a **uma zona**; `resultsLimit`/`desiredKeys` |
| F26 | Core Data — "Sharing Core Data objects between iCloud users" | https://developer.apple.com/documentation/coredata/sharing-core-data-objects-between-icloud-users | docs atuais | `NSPersistentCloudKitContainer` usa zone sharing e **há limite de nº de zonas por banco** (sem número na página) |
| F27e | swiftinterface do CloudKit (**SDK local**) | `…/MacOSX.sdk/System/Library/Frameworks/CloudKit.framework/Versions/A/Modules/CloudKit.swiftmodule/arm64e-apple-macos.swiftinterface` | MacOSX27.0.sdk / Xcode-beta27.0 (medido) |244 linhas `@available(…deprecated…)`; familia Contacts-discovery deprecada em macOS14 ("No longer supported…"); `CKShareParticipantType` **obsoleted26.0**; `oneTimeURL(for:)` presente |

### Secundárias (marcadas)

| # | Fonte | URL | Data/versão | Ponto parafraseado · por que secundária |
|---|---|---|---|---|
| F23 | WWDC15 "CloudKit Tips and Tricks" (transcript) | espelhos: https://wwdcnotes.com/documentation/wwdc15-715-cloudkit-tips-and-tricks · https://nonstrict.eu/wwdcindex/wwdc2015/715 | sessão WWDC2015; **página oficial redireciona para índice** (verificado:302→/videos/wwdc2015/) | Batch com `CKOperation` p/ economizar quota de requests; `resultsLimit`/`desiredKeys`; `serverRecordChanged` sem mágica — **transcript de terceiro, sessão saiu do ar** |
| F23c | WWDC16 "CloudKit Best Practices" (transcript) | https://wwdcnotes.com/documentation/wwdc16-231-cloudkit-best-practices | WWDC2016; **página oficial redireciona** (302→/videos/wwdc2016/) | `CKDatabaseSubscription` (iOS10+) cobre o banco todo; criar subscription uma vez e setar flag; long-lived operations — **espelho de terceiro** |
| F25 | Fórum "Current CloudKit pricing?" | https://developer.apple.com/forums/thread/715649 | fórum oficial, ~2023 | Tabela de preços/limites **não está mais publicada**; uso aparente p/ público baseado em usuários ativos — **fórum, não doc** |
| F27b/c/d | Fóruns CloudKit (push200 subscribers · zombie CKQuerySubscription · push produt. iOS26.4) | https://developer.apple.com/forums/thread/129006 · /forums/tags/cloudkit-dashboard?page=2 · thread do tag cloudkit-console |2020 ·2024 ·2026 | Relatos não reproduzidos por mim sobre subscriptions/push — **fórum** |
| F28 | VLDB paper "CloudKit: Structured Storage…" (Shraer et al.) | https://www.vldb.org/pvldb/vol11/p540-shraer.pdf |2018 | Semântica de bancos e security roles do CloudKit — **acadêmico, terceiro** |

### O que NÃO foi verificado (explícito)

- Números atuais de quota diária de transações, limite de zonas por banco, limite de
  subscriptions e tamanho máximo de asset para o SDK27 — **sem fonte oficial vigente**;
- "Dynamic Content Sharing (DCS)" como termo Apple — **não encontrado** (§4.4);
- release notes/known bugs de CloudKit para macOS26/27 — **não existe página
  localizável** nesta execução;
- comportamento do serviço real (modo relatório: **zero** chamadas ao CloudKit).

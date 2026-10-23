# A7 — Arquitetura

**Data:** 2026-09-23  
**Escopo:** 232 arquivos `.swift` de produção (`Papagaio/**`: 171; `PapagaioCore/Sources/**`: 61), 45.602 linhas.  
**Método:** leitura integral do mapa e dos relatórios A1, A2, A3 e A5; leitura dos 232 fontes de produção; rastreamento de callers, guards e ciclos de vida; leitura dos contratos do SDK CloudKit instalado. Não houve acesso a CloudKit, OAuth, Granola, microfone, Process Taps, banco real ou serviço externo.

Nenhum arquivo de produção, teste, configuração, dependência, serviço ou dado real foi alterado. O único arquivo escrito por esta auditoria é `audit/02-achados/A7-arquitetura.md`.

## Legenda

- **Severidade:** `CRÍTICO`, `ALTO`, `MÉDIO`, `BAIXO`, `INFO`.
- **Confiança:** `CONFIRMADO` quando a cadeia de código e o contrato local tornam o defeito direto, sem alternativa plausível; `PROVÁVEL` quando o cenário depende de uma falha externa que não foi induzida; `HIPÓTESE` quando falta evidência suficiente.

## Resumo

Foram aceitos **7 achados arquiteturais**. Não foram contabilizados tamanho, churn, quantidade de camadas ou hotspots sem defeito concreto.

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 0 |
| ALTO | 7 |
| MÉDIO | 0 |
| BAIXO | 0 |
| INFO | 0 |
| **Total** | **7** |

| Confiança | Quantidade |
|---|---:|
| **CONFIRMADO** | 5 |
| **PROVÁVEL** | 2 |
| **HIPÓTESE** | 0 |
| **Total** | **7** |

| Prioridade | Achados |
|---|---|
| P0 — impedir dado no destino/escopo errado ou dados pessoais retidos | A7-001, A7-003, A7-004, A7-007 |
| P1 — recuperar estado, tornar operações repetíveis e unificar contratos | A7-002, A7-005, A7-006 |

---

## A7-001 — Um gravador global tem um único destino sobrescrito por cada janela

**Severidade:** ALTO  
**Confiança:** **CONFIRMADO**

**Local e trecho**

- `Papagaio/App/PapagaioApp.swift:30-33,60-62`
- `Papagaio/App/ContentView.swift:35-48,422-473,489-511`
- `Papagaio/ViewModels/GravadorViewModel.swift:25-37,191-225,369-383`

```swift
// PapagaioApp.swift
@State private var gravador = GravadorViewModel()

WindowGroup("") {
    ContentView(gravador: gravador)
}
```

```swift
// ContentView.swift — cada instância sobrescreve o mesmo closure
modelo.aoProduzirAudio = { titulo, pasta, duracao, notas, dataDeGravacao in
    // ...
    let arquivo = await nova.registrar(
        titulo: titulo,
        pastaRelativa: pasta,
        // ...
    )
}
```

```swift
// GravadorViewModel.swift — há somente um callback e ele é opcional
var aoProduzirAudio: (@MainActor (...) async -> Void)?

await aoProduzirAudio?(
    Self.tituloParaAgora(),
    resultado.pastaRelativa,
    // ...
)
```

**Cenário de reprodução**

1. Abra a janela A e selecione a equipe A.
2. Abra uma segunda janela do `WindowGroup` e selecione a equipe B.
3. Cada `ContentView.abrir()` cria sua própria `Biblioteca` e atribui `modelo.aoProduzirAudio` ao mesmo `GravadorViewModel` compartilhado. A atribuição mais recente substitui a anterior.
4. Inicie a gravação na janela A — ou pelo item da barra de menus, que também não tem destino próprio — e finalize.
5. `GravadorViewModel.parar()` chama o closure que estiver instalado naquele instante. O áudio de A é registrado na `Biblioteca`/equipe de B. Se houver uma reunião pendente na caixa da outra janela, ela também pode ser usada como destino.
6. O mesmo ocorre com `importar(_:)`, que percorre o mesmo callback nas linhas 380-383.

**Guardas buscadas para refutar**

- `guard biblioteca == nil` em `ContentView.swift:422-423` vale apenas para aquela view; não arbitra entre janelas.
- O closure não recebe `windowID`, `EspacoID` nem o destino escolhido no momento em que a gravação começou.
- `dataDeGravacao` representa a data do arquivo, não a origem/rota da captura.
- O `MenuBarExtra` usa o mesmo gravador por design, mas não instala um destino independente.
- O segundo `ContentView` do preview cria outro gravador e não protege o runtime.

**Causa**

O tempo de vida do gravador foi ampliado para toda a aplicação, mas seu contrato de saída continua sendo um callback mutável cujo proprietário deveria ser a janela. A duração do estado e a duração do destino ficaram em níveis diferentes.

**Correção sugerida**

- Se cada janela puder gravar independentemente, manter um `GravadorViewModel` por janela e separar o estado observável global mínimo da barra de menus.
- Se a gravação for realmente global, capturar no início um `DestinoDeGravacao` imutável — janela, espaço, biblioteca e reunião pendente — e devolver um evento de conclusão que carregue esse destino. Não usar um único callback sobrescrevível.
- Adicionar teste de composição com duas janelas e uma sessão falsa: iniciar pela janela A e concluir deve persistir exclusivamente em A.

---

## A7-002 — A migração dos espaços órfãos existe, mas só é chamada por teste e já não preserva equipes

**Severidade:** ALTO  
**Confiança:** **CONFIRMADO**

**Local e trecho**

- `PapagaioCore/Sources/PapagaioCore/Persistencia/ModelosSwiftData.swift:72-85`
- `PapagaioCore/Sources/PapagaioCore/Dominio.swift:11-21`
- `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:218-225,324-347,493-500`
- `Papagaio/ViewModels/Biblioteca.swift:193-204,239-256`
- `PapagaioTests/BibliotecaTests.swift:126-156`

```swift
// ModelosSwiftData.swift — relação tolerante para dados antigos
public var espaco: EspacoPersistido?
```

```swift
// SwiftDataRepository.swift
public func listar(espaco: EspacoID) async throws -> [Arquivo] {
    let alvo = espaco.rawValue
    let descritor = FetchDescriptor<ArquivoPersistido>(
        predicate: #Predicate { $0.espaco?.id == alvo && $0.apagadoEm == nil }
    )
    // ...
}
```

```swift
// A conversão torna o registro sem relação identificável de forma estável,
espaco: p.espaco.map { EspacoID(rawValue: $0.id) } ?? .legado
```

A migração disponível não trata apenas órfãos:

```swift
public func migrarTodosOsEspacos(para destino: EspacoID) throws {
    // ...
    for arquivo in arquivos where arquivo.espaco?.id != idDoDestino {
        arquivo.espaco = espacoDestino
    }
    for espaco in espacos where espaco.id != idDoDestino {
        modelContext.delete(espaco)
    }
}
```

**Cenário de reprodução**

1. Um `ArquivoPersistido` criado antes da relação de espaço é aberto após a evolução leve do schema. O código o converte para `EspacoID.legado`.
2. `Biblioteca` consulta apenas o UUID pessoal atual. O UUID fixo `00000000-0000-0000-0000-000000000000` não é o espaço aberto, portanto o arquivo não aparece nem na biblioteca nem na lixeira.
3. Não há UI, seleção ou reconciliação para `.legado` no produto inteiro.
4. Existe uma migração capaz de reunir os órfãos ao espaço pessoal, mas a busca final encontrou somente a definição e uma chamada em `PapagaioTests`; nenhum fluxo de produção a chama.
5. Chamar a função existente cegamente no startup atual seria pior: ela moveria também arquivos de equipes legítimas para o espaço pessoal e apagaria as demais relações de espaço. O método e a arquitetura atual de equipes divergiram.

**Guardas buscadas para refutar**

- `migrarTodosOsEspacos`: duas ocorrências no código — definição e teste; zero caller de produção.
- `.legado`: uma ocorrência de produto, apenas no fallback do mapper.
- `EspacoID.legado` não aparece em nenhum seletor de espaço ou tela de recuperação.
- `Biblioteca.preparar()` chama `carregar()` diretamente; não executa migração.
- O teste existente cria arquivos em espaços válidos e não cobre a relação `nil`, que é justamente o fallback legado.

**Causa**

A evolução do modelo de dados e a reintrodução de espaços de equipe não passaram por um ciclo de migração versionado. A política de recuperação ficou órfã e não é mais compatível com a topologia vigente.

**Correção sugerida**

- Criar um plano de migração versionado que mova **somente** registros com `espaco == nil` para o espaço pessoal, incluindo ativos e lixeira, sem tocar em equipes existentes.
- Executar a migração antes de qualquer `listar`, com marcador de versão, transação e idempotência.
- Manter a distinção entre “recuperar órfão” e “migrar todos os espaços”; esta última não deve voltar ao startup atual.
- Adicionar fixtures para relação nula, arquivo ativo, arquivo na lixeira e registro que já pertence a uma equipe.

---

## A7-003 — O protocolo de sync representa apenas upserts; exclusões remotas nunca alcançam os outros Macs

**Severidade:** ALTO  
**Confiança:** **CONFIRMADO**

**Local e trecho**

- `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:125-134,242-270,375-393`
- `Papagaio/ViewModels/Biblioteca.swift:467-501,1138-1171`
- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CloudKit.framework/Headers/CKFetchRecordZoneChangesOperation.h:137-147`

O transporte só sabe devolver dados presentes:

```swift
protocol TransporteDeConversasCloudKit: Sendable {
    func pagina(...) async throws -> PaginaDeConversasCloudKit
}

struct PaginaDeConversasCloudKit: Sendable {
    let registros: [Data]
    let proxima: CursorDeConversasCloudKit?
}
```

A operação de zona instala apenas o callback de registros alterados:

```swift
let operacao = CKFetchRecordZoneChangesOperation()
operacao.recordZoneIDs = [zona]
operacao.fetchAllChanges = true

operacao.recordWasChangedBlock = { _, resultado in
    // acrescenta CKRecord -> Data
}
```

O contrato do SDK define um canal diferente para exclusões:

```objc
// CKFetchRecordZoneChangesOperation.h:137-147
// The block to execute when a record no longer exists.
@property ... recordWithIDWasDeletedBlock(
    CKRecordID *recordID,
    CKRecordType recordType
);
```

**Cenário de reprodução**

1. No Mac A, uma conversa é movida para a lixeira e depois apagada definitivamente. A outbox agenda a remoção do `CKRecord` remoto e o Mac A remove banco, mídia e a cascata local registrada.
2. O Mac B já tem uma cópia local da conversa.
3. No próximo sync, a operação de zona não entrega o registro removido em `recordWasChangedBlock`; a ausência exigiria `recordWithIDWasDeletedBlock`, que não está instalado.
4. `baixarComVersoes()` apenas decodifica e salva os registros retornados. Ele não compara o conjunto completo do servidor com o local e não executa nenhuma ação para IDs ausentes.
5. A cópia do Mac B permanece. Se B estava offline durante o soft delete e o hard delete, ela pode continuar aparecendo como ativa; se viu apenas o soft delete, permanece na lixeira. Em ambos os casos, a remoção definitiva remota não converge.

**Guardas buscadas para refutar**

- `recordWithIDWasDeletedBlock`: zero ocorrências no produto.
- Também não há token de mudança persistido nem uma passagem de comparação server/local que transforme a página em diff.
- O protocolo `PaginaDeConversasCloudKit` não possui caso de exclusão/tombstone.
- A outbox persistida coordena apenas a origem da operação; ela não entrega mudanças aos outros Macs.
- `fetchAllChanges = true` retorna o estado atual, mas não transforma “ID ausente” em uma intenção de remoção local.

**Causa**

A fronteira de sync foi modelada como “lista de registros e aplica cada um”, mas o estado remoto é um conjunto de upserts **e deletes**. Sem um evento de delete, uma redução completa da zona não informa qual elemento local deve desaparecer.

**Correção sugerida**

- Modelar a página como eventos, por exemplo `.atualizar(Data)` e `.remover(recordName)`, e instalar `recordWithIDWasDeletedBlock`.
- Persistir `CKServerChangeToken` por equipe/zona somente depois de aplicar todo o lote com sucesso.
- Ao receber uma remoção remota, usar uma operação explícita do repositório que remova registro, relações e mídia local, incluindo a cascata de `LimpezaDeArquivo`.
- Testar o fake transport com um ID removido e, separadamente, o adaptador CloudKit com um schema de teste controlado. Não usar a ausência de um registro como palpite de delete.

---

## A7-004 — O modelo de acesso da equipe mistura compartilhamento público, ACL por participante e “somente administradores” sem uma fonte de autorização

**Severidade:** ALTO  
**Confiança:** **CONFIRMADO**

**Local e trecho**

- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:44-73,131-154,213-239,319-334,381-385`
- `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:3-32`
- `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:194-237,267-289,413-433`
- `PapagaioTests/EquipesCloudKitTests.swift:156-159`
- `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CloudKit.framework/Headers/CKShare.h:150-188`

Toda equipe nasce como compartilhamento público de escrita:

```swift
let compartilhamento = CKShare(recordZoneID: zonaID)
compartilhamento.publicPermission = Self.permissaoDaEntradaPorCodigo

nonisolated static var permissaoDaEntradaPorCodigo: CKShare.ParticipantPermission {
    .readWrite
}
```

Ao mesmo tempo, a UI promete administrar participantes individualmente:

```swift
Button("Alterar permissão", systemImage: "lock", action: aoEditar)
Button("Remover", systemImage: "trash", role: .destructive, action: aoRemover)
```

E o serviço tenta alterar a ACL:

```swift
participante.permission = permissao == .leitura ? .readOnly : .readWrite
compartilhamento.removeParticipant(participante)
```

O SDK instalado é explícito:

```objc
// CKShare.h:150-155
// Setting ... more permissive than none allows any user with the share's URL to join.

// CKShare.h:173-188
// To modify the list of participants, publicPermission must be none.
// You can't mix and match public and private users in the same share.
```

Por fim, há uma política local sem consumidor:

```swift
enum VisibilidadeDosArquivosDaEquipe: String, Codable {
    case todosOsMembros
    case apenasAdministrador
}
```

A tela oferece “Somente administradores” e “Aguardar revisão”, mas a busca final encontrou cada campo somente na tela e no modelo. A própria tela reconhece que revisão ainda não bloqueia envios; a visibilidade, porém, é apresentada como configuração sem aviso equivalente.

**Cenário de reprodução**

1. Ao criar a equipe, `publicPermission` é `.readWrite`; qualquer pessoa que obtenha a URL pode entrar, e o modelo não oferece participantes privados endereçáveis para a ACL.
2. A tela de gestão continua mostrando “alterar permissão” e “remover” para o proprietário. Essas operações exigem `publicPermission == .none`; o modelo atual não pode representar ao mesmo tempo acesso público e lista privada.
3. Se o proprietário salvar `visibilidadeDosArquivos = .apenasAdministrador`, o JSON é persistido e volta no `aceitar`, mas `SincronizadorDaBibliotecaCloudKit.pagina()` não recebe nem consulta a configuração. O share continua `.readWrite` para todos os participantes públicos.
4. O resultado é uma promessa de segurança sem aplicação: o item “Somente administradores” não muda a autorização de leitura/escrita.

**Guardas buscadas para refutar**

- `publicPermission`: três atribuições de produto, todas pelo mesmo `.readWrite`; zero `publicPermission = .none`.
- `visibilidadeDosArquivos`: duas ocorrências de produto — definição do modelo e picker.
- `recebimentoDeArquivos`: duas ocorrências — definição e picker; como a UI já declara que a revisão virá depois, esse item não foi contado separadamente.
- O único teste do código afirma apenas que a permissão é `.readWrite`; não cobre a combinação com ACL nem a política de visibilidade.
- `participantes()` filtra o proprietário, mas não cria uma segunda fronteira de autorização para o conteúdo.

**Causa**

Três modelos diferentes tentam representar o mesmo domínio: URL pública com código, ACL privada por participante e papel local “Administrador”. O produto não escolheu um contrato de autorização único; a UI apenas expõe os três.

**Correção sugerida**

- Escolher explicitamente um dos modelos:
  1. **capability URL rotativa:** manter público, remover/ocultar ACL por participante e administrar acesso apenas por rotação; ou
  2. **participantes privados:** usar `publicPermission = .none`, adicionar/convidar participantes e implementar a ACL real.
- Para “somente administradores”, `CKShare` sozinho só oferece leitura/escrita; pode ser necessário separar zonas/registros sensíveis ou aplicar autorização/criptografia no domínio.
- Fazer o sync receber a política efetiva e rejeitar uploads/leitura não permitidos antes de prometer a opção na UI.
- Até haver suporte, desabilitar os controles que não podem ser aplicados, em vez de persistir uma configuração sem efeito.

---

## A7-005 — A rotação do código atravessa banco privado e público sem estado intermediário recuperável

**Severidade:** ALTO  
**Confiança:** **PROVÁVEL**

**Local e trecho**

- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:242-273,410-445`
- `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:450-460`

```swift
// 1. banco privado: salva o share novo e apaga o antigo atomicamente entre si
_ = try await container.privateCloudDatabase.modifyRecords(
    saving: [novo],
    deleting: [antigo.recordID],
    savePolicy: .ifServerRecordUnchanged,
    atomically: true
)

guard let url = novo.url else {
    throw ErroDeEquipeCloudKit.conviteIndisponivel
}

// 2. banco público: apaga o código anterior
try await invalidarCodigoAnterior(equipe.codigoDeEntrada)

// 3. banco público: publica o novo
try await publicarCodigo(novoCodigo, para: url)
```

O estado local só muda depois que toda a cadeia retorna:

```swift
let atualizada = try await servicoDeEquipes.rotacionarCodigo(da: equipe)
aoAtualizarEquipe(atualizada)
```

**Cenário de reprodução**

1. A primeira transação privada termina: o share novo existe e o antigo foi removido.
2. Falha a obtenção da URL, a consulta/invalidação do código público ou a publicação do código novo. Também pode haver crash entre a publicação e `aoAtualizarEquipe`.
3. O app ainda persiste `compartilhamentoCloudKit` e `codigoDeEntrada` antigos, porque a view só atualiza o modelo após sucesso integral.
4. Uma tentativa de repetição chama `compartilhamento(da: equipe)`, que tenta carregar o ID do share antigo já removido e falha antes de criar outro. Não há estado “rotação em andamento”, URL nova salva ou fase que permita retomar.
5. Dependendo da falha, os participantes antigos perderam acesso e o novo código nunca existe, ou o código novo existe remoteamente enquanto a UI e o estado local ainda exibem o antigo.

**Guardas buscadas para refutar**

- O `atomically: true` cobre somente o `modifyRecords` privado dos dois `CKRecord`; não abrange o banco público.
- Não há marcador de rotação, novo share ID persistido antes do passo destrutivo, compensação ou reconciliação no startup.
- O método de participação volta a buscar o share pelo ID antigo; ele não procura um share novo.
- `rotacionarCodigo` aparece apenas na definição e no fluxo da UI; não há teste de falha entre as etapas.

**Causa**

Uma transação lógica de segurança foi implementada como uma sequência imperativa com efeitos irreversíveis em dois bancos independentes, sem saga, journal ou chave de idempotência.

**Correção sugerida**

- Persistir antes do passo destrutivo uma fase durável com `oldShareID`, `newShareID`, `newURL`, códigos e operação pretendida.
- Fazer cada passo idempotente e retomável na abertura e em novas tentativas; validar o novo código publicado antes de trocar o share antigo.
- Atualizar a referência local apenas após um estado remoto verificável e ativar a rotação antiga somente quando a nova estiver completa.
- Se a nova parte não puder ser publicada, restaurar o share antigo ou entrar em um estado de erro recuperável.
- Adicionar testes com falhas injetadas em `url`, invalidação, publicação e persistência local.

---

## A7-006 — O app ignora a implementação OAuth/MCP do Core e mantém uma segunda pilha divergente

**Severidade:** ALTO  
**Confiança:** **CONFIRMADO**

**Local e trecho**

- `Papagaio/Integracao/GranolaViewModel.swift:69-85`
- `Papagaio/Integracao/SessaoOAuth.swift:58-73,79-97,231-240,352-357`
- `Papagaio/Integracao/ClienteMCP.swift:25-56,129-187`
- `Papagaio/Integracao/FonteGranola.swift:20-85`
- `PapagaioCore/Sources/PapagaioCore/Integracao/SessaoOAuth.swift:14-42,58-75,161-179`
- `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:101-143,185-198`
- `PapagaioCore/Sources/PapagaioCore/Integracao/FonteGranola.swift:212-270`
- `PapagaioCore/Tests/PapagaioCoreTests/IntegracaoTests.swift:6-8,151-180`

O app não qualifica o módulo e, portanto, resolve seus próprios tipos locais:

```swift
// GranolaViewModel.swift
let sessao = SessaoOAuth(
    servidorMCP: servidorMCP,
    cofre: cofre,
    apresentador: ApresentadorDeSessaoDeAutorizacao()
)

let cliente = ClienteMCP(url: servidorMCP) { forcar in
    try await sessao.tokenDeAcesso(forcandoRenovacao: forcar)
}
let fonte = FonteGranola(cliente: cliente)
```

A divergência já é observável no código:

```swift
// app: qualquer falha de transcrição aborta a importação
if incluirTranscricao {
    transcricao = try await transcricaoDaReuniao(id: id)
}
```

```swift
// Core: a mesma tool continua opcional
do {
    // ...
} catch {
    // Plano sem transcrição ou indisponibilidade:
    // a reunião continua útil sem ela.
}
```

O cliente do app pede sempre token sem forçar renovação e transforma qualquer status fora de 200/202 em erro. O Core possui uma cadeia distinta de retry:

```swift
// Core
catch ErroMCP.naoAutenticado where tentativa == 0 {
    _ = try await fornecerToken(true)
    return try await chamarUmaVez(..., tentativa: 1)
}
```

As credenciais também têm formatos e garantias diferentes: o app engole falhas de Keychain com `try?`; o Core persiste por `try` e, ao falhar refresh, apaga o estado e refaz o fluxo.

**Cenário de reprodução**

1. O Core recebe uma correção de OAuth, MCP, parser ou persistência e seus testes passam.
2. O app continua executando as classes de `Papagaio/Integracao`, não as classes públicas de `PapagaioCore`.
3. O comportamento diverge conforme a entrada: token revogado, plano sem transcrição, Keychain indisponível ou resposta MCP ambígua.
4. Os sintomas já foram detallados em A1-004, A1-009 e A1-011; este achado não os conta novamente. A causa arquitetural é que existem duas implementações do mesmo contrato e os testes do Core não alcançam a primeira.

**Guardas buscadas para refutar**

- `SessaoOAuth(` e `ClienteMCP(` sem qualificação aparecem no app e na CLI; o `GranolaViewModel` não injeta uma implementação do Core.
- `FonteGranola` também existe como struct local no app e como actor público no Core.
- Os testes do app não mencionam `SessaoOAuth`, `ClienteMCP` ou `GranolaViewModel`; os testes Core importam `@testable PapagaioCore`. A5-008 registra essa lacuna de testabilidade; A7-006 conta a divergência na composição de produção.
- Não há typealias, adapter, factory ou teste de contrato que obrigue as duas pilhas a permanecerem iguais.
- O Core não deve ser tratado como integralmente correto: A1-003 encontrou defeito de SSE também no parser do Core. A divergência continua real; a correção exige uma implementação única e testes da classe efetivamente usada.

**Causa**

O Core foi criado como fonte única de domínio, mas integração, transporte e apresentação foram implementados novamente no app sem uma fronteira de composição. O nome do contrato deixou de indicar qual implementação é produção.

**Correção sugerida**

- Escolher uma única implementação pública — preferencialmente a do Core — e remover do app as structs/classes duplicadas.
- Manter no app apenas apresentação e estado de UI; injetar `URLSession`, cofre, apresentador e relógio.
- Definir uma migração consciente dos formatos de Keychain ou exigir reautenticação explícita; não trocar o esquema silenciosamente.
- Executar os testes de integração contra o tipo exato instanciado pelo `GranolaViewModel`, incluindo 401, refresh, SSE, plano sem transcrição e falha de Keychain.

---

## A7-007 — A exclusão de conta pode transformar a biblioteca em órfãos e ainda deixa um store pessoal sem limpeza

**Severidade:** ALTO  
**Confiança:** **PROVÁVEL**

**Local e trecho**

- `Papagaio/App/ContentView.swift:125-135,422-425,511-515,893-933`
- `Papagaio/Persistencia/LimpezaDeConta.swift:4-43`
- `Papagaio/Persistencia/FalantePreservadoParaTrecho.swift:4-47`
- `Papagaio/Funcionalidades/Perfil/PerfilPessoalView.swift:97-104`
- `PapagaioTests/BibliotecaTests.swift:405-449`

A abertura da biblioteca é opcional para a tela:

```swift
// ContentView.abrir()
do {
    let nova = try Biblioteca()
    // ...
    biblioteca = nova
} catch {
    falhaDeAbertura = "Não foi possível abrir a biblioteca: ..."
}
```

A tela de conteúdo continua renderizada mesmo com esse erro. A exclusão trata biblioteca ausente como uma lista vazia de sucesso:

```swift
let arquivosExcluidos = try await biblioteca?.excluirDadosDaConta(
    espaco: espacoPessoalExcluido
) ?? []

LimpezaDeConta.executar(arquivos: arquivosExcluidos)
LimpezaDeCredenciaisDaConta.executar()
// ...
perfil.excluirDadosDaConta()
```

A cascata é uma lista manual:

```swift
enum LimpezaDeArquivo {
    static func executar(_ id: ArquivoID, em defaults: UserDefaults = .standard) {
        TarefasDaConversa.remover(id, em: defaults)
        MidiasDaConversa.remover(id, em: defaults)
        PreferenciasVisuaisDoArquivo.remover(id, em: defaults)
        // ...
    }
}
```

Ela não inclui `FalantePreservadoParaTrecho`, cujo mapa por conversa é gravado em `UserDefaults`:

```swift
private static func chave(_ arquivo: ArquivoID) -> String {
    "falantePreservado.\(arquivo.rawValue.uuidString)"
}

static func limpar(arquivo: ArquivoID) {
    UserDefaults.standard.removeObject(forKey: chave(arquivo))
}
```

A tela promete remover os dados pessoais do Mac:

> “Seu perfil, conversas pessoais, áudios, transcrições, notas, tarefas… serão removidos deste Mac.”

**Cenário de reprodução**

Há dois caminhos de perda do mesmo contrato:

1. **Biblioteca indisponível:** se `Armazenamento.padrao()`, SwiftData ou outra dependência impedir `Biblioteca()`, a tela mostra o erro, mas o Perfil continua disponível. Ao excluir a conta, `biblioteca?.excluirDadosDaConta(...) ?? []` devolve `[]` sem lançar. `LimpezaDeConta` apaga `espacoIndividual` e o perfil é encerrado, mas os registros/mídias antigas continuam no banco sob o UUID aposentado. No relançamento, um novo UUID pessoal é criado e os dados ficam ainda mais inacessíveis — o mesmo estado de órfão tratado por A7-002.
2. **Cascata incompleta:** mesmo com abertura normal, `falantePreservado.<arquivo>` não é removido por `LimpezaDeArquivo`. `FalantePreservadoParaTrecho.limpar` existe, mas não possui caller. A exclusão definitiva de uma conversa e a exclusão do perfil deixam os nomes de falantes associados aos IDs removidos.

**Guardas buscadas para refutar**

- `FalantePreservadoParaTrecho.limpar`: zero chamadas; somente a definição.
- O prefixo `falantePreservado.` aparece somente no store que o cria/remove por entrada.
- O teste de cascata lista prefixos por arquivo em `BibliotecaTests.swift:416-421`, mas não inclui `falantePreservado.`.
- `FalhaDeAbertura` não impede `conteudoDaTela`; ela apenas mostra uma faixa e pode ser dispensada.
- `Biblioteca.excluirDadosDaConta` possui uma barreira de exclusão quando executado, mas a chamada opcional impede que essa barreira seja alcancada quando a biblioteca não existe.

**Causa**

A exclusão destrutiva é orquestrada por estado opcional de UI e depende de um catálogo manual de stores, sem um plano/manifesto que prove que todos os dados de cada arquivo foram visitados. A operação pode ser parcial sem ser representada como tal.

**Correção sugerida**

- Exigir um `CoordenadorDeExclusaoDeConta` com repositório/armazenamento obrigatórios. Se a biblioteca não abrir, abortar antes de remover identidade, equipe ou chave de espaço.
- Separar “excluir dados” de “encerrar perfil” e só marcar a conta como excluída depois que banco, disco e stores auxiliares concluírem.
- Incluir `FalantePreservadoParaTrecho` no manifesto; melhor ainda, registrar stores por protocolo com uma operação `remover(arquivo:)` e um teste de catálogo que detecte chaves desconhecidas.
- Adicionar teste de falha de abertura: a exclusão deve falhar de forma explícita e não trocar `espacoIndividual`.
- Adicionar teste de exclusão normal que seme um mapa `falantePreservado.<id>` e exige sua remoção para arquivo pessoal, arquivo de equipe preservado e exclusão definitiva.

---

## Candidatos refutados ou não contabilizados

### Corrida nos callbacks de CloudKit

Os arrays capturados em `registrosDaZona` não foram contabilizados como data race. O cabeçalho instalado diz que `recordWasChangedBlock` e os demais callbacks da operação executam serialmente (`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CloudKit.framework/Headers/CKFetchRecordZoneChangesOperation.h:118,132,183-186`). A ausência de `recordWithIDWasDeletedBlock` é um defeito de contrato de estado, não uma prova de callback concorrente.

### “Aguardar revisão” já estava documentado como não implementado

A tela informa explicitamente que a revisão de recebimento será aplicada em uma etapa futura e que não bloqueia envios (`GestaoDeEquipeView.swift:277`). Isso é uma limitação declarada, não uma regressão escondida. A opção sem aviso equivalente “Somente administradores” foi aceita em A7-004.

### Recarga completa da zona é performance, não um achado arquitetural novo

A ausência de token e a paginação em memória já é A3-004. A7-003 trata apenas a perda semântica de deletes; não repete a análise de custo.

### Múltiplas janelas não são um defeito geral sem prova

O risco de cada janela ter sua própria `Biblioteca`, outbox e ciclo de modelos continua condicional, como já qualificado em A2. A7-001 conta somente o slot de destino que é comprovadamente sobrescrito e pode enviar o áudio ao espaço errado.

### `TarefasGeraisStore` não é um store adicional esquecido

`TarefasGeraisStore` e `TarefasDaConversa` usam o mesmo prefixo `tarefasDaConversa.<id>` e o mesmo payload. O `remover` de `TarefasDaConversa` já remove a chave usada pelo store geral; não foi tratado como segunda omissão.

### O Core não foi considerado uma implementação integralmente correta

A7-006 usa o Core para provar divergência e dívida de composição, não para declarar que trocar o app por ele resolveria todos os defeitos. A1-003 encontrou problema de SSE no próprio Core. A correção proposta exige uma única implementação e testes do fluxo real.

### Tamanho, churn e número de stores não são achados

Nenhum arquivo grande, multiplicidade de stores, cor ou comentário foi listado sem uma falha observável. As 23 stores de persistência só entram no relatório quando o contrato de limpeza ou de propriedade fica demonstrado.

---

## Cobertura

A cobertura de produção foi integral no escopo solicitado:

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
| `WhisperRuntime` | 2 | 366 |
| `LlamaRuntime` | 2 | 284 |
| `OnnxApi` | 1 | 228 |
| `DiarizationRuntime` | 1 | 96 |
| `papagaio-eval` | 6 | 1.549 |
| **Produção total** | **232** | **45.602** |

Também foram abertos nesta execução os testes relevantes `PapagaioTests/BibliotecaTests.swift`, `PapagaioTests/EquipesCloudKitTests.swift` e `PapagaioCore/Tests/PapagaioCoreTests/IntegracaoTests.swift`, além dos cabeçalhos locais `CKFetchRecordZoneChangesOperation.h` e `CKShare.h`. Os relatórios A1/A2/A3/A5 foram usados para sobreposição, não como evidência substituta de arquivo/linha.

## Buscas finais

- `migrarTodosOsEspacos`: **2** ocorrências no escopo — definição em `SwiftDataRepository.swift:332` e chamada de teste em `BibliotecaTests.swift:151`; **0** caller de produção.
- `recordWithIDWasDeletedBlock`, `recordZoneChangeTokensUpdatedBlock` e `recordZoneFetchResultBlock`: **0** ocorrências no produto. O primeiro existe apenas no cabeçalho do SDK local.
- `WindowGroup`: **2** no app — o host de teste e a cena de produção; a cena de produção passa o mesmo `gravador` para cada `ContentView`.
- `aoProduzirAudio`: **1** declaração, **1** atribuição de produção e **2** chamadas de entrega; não há destino por janela.
- `publicPermission`: **3** atribuições de produto, todas `.readWrite`; `publicPermission = .none`: **0**.
- `visibilidadeDosArquivos`: **2** ocorrências de produto — modelo e picker; `recebimentoDeArquivos`: **2**, também apenas modelo e picker.
- `FalantePreservadoParaTrecho.limpar`: **0** callers. O símbolo completo aparece em usos de leitura/edição, mas a limpeza por arquivo não é chamada.
- `rotacionarCodigo`: **4** ocorrências — definição do serviço e três pontos da UI; não há teste de rotação.
- `EspacoID.legado`/`.legado`: **1** uso de produto, no fallback do mapper; não há uma tela de recuperação.
- `SessaoOAuth(` e `ClienteMCP(` sem qualificação: app e CLI; não há instanciação do Core pelo `GranolaViewModel`.
- Busca de callbacks mutáveis do CloudKit, `publicPermission`, configurações, limpeza, homônimos OAuth/MCP, `WindowGroup` e `migrarTodosOsEspacos` foi repetida em todo `Papagaio/**` e `PapagaioCore/Sources/**` antes da classificação final.

## Limitações e integridade

- Não houve chamada a CloudKit real, duas contas iCloud, OAuth Google/Granola, MCP real, microfone, Process Taps, SwiftData real do usuário ou exclusão real de conta. Os contratos de acesso e ciclo de vida foram concluídos por código e cabeçalhos do SDK; cenários dependentes de falha externa foram marcados `PROVÁVEL`.
- Não foi executado um cenário real com duas janelas, uma rotação interrompida ou uma abertura de biblioteca corrompida. A cadeia estática é direta, mas o efeito final não foi induzido em hardware/serviço.
- Não houve medição de performance nova; números de A3 não foram reutilizados como achado A7.
- A suíte de testes não foi executada nesta auditoria. Os testes foram usados para verificar callers, falsos verdes e contratos já cobertos; a baseline de execução permanece em A1/A5.
- O working tree já continha modificações e arquivos não rastreados de outros agentes/usuário. Eles foram preservados. A única gravação desta auditoria é este relatório.

## Contagens finais

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 0 |
| ALTO | 7 |
| MÉDIO | 0 |
| BAIXO | 0 |
| INFO | 0 |
| **Total** | **7** |

| Confiança | Quantidade |
|---|---:|
| **CONFIRMADO** | 5 |
| **PROVÁVEL** | 2 |
| **HIPÓTESE** | 0 |
| **Total** | **7** |

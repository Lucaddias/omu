# 01 — Pesquisa: CloudKit, OAuth e integrações

> **Documento autocontido.** Ficha técnica verificada em **2026-09-23** sobre
> CloudKit/`CKShare`, OAuth 2.0 do Google Calendar, Sign in with Apple,
> EventKit/Contacts, Keychain, MCP/Streamable HTTP e o fluxo Granola.
>
> **Modo:** leitura do repositório, consulta de documentação oficial e
> reproduções estáticas. Não houve autenticação, OAuth, chamada a CloudKit,
> push, alteração de configuração, mudança de dependência, acesso ao console
> de produção ou execução contra o Granola. Nenhum token, segredo, Client ID
> ou dado de conta é reproduzido.
>
> **Escopo de escrita:** este arquivo. O baseline `audit/00-mapa.md` e o
> relatório preliminar `audit/01-pesquisa/cloudkit.md` foram lidos
> integralmente. Este texto é uma verificação independente e não reutiliza
> como fato uma conclusão que não esteja sustentada abaixo.

## Legenda e método

- **CONFIRMADO** — está diretamente no código/configuração local, no baseline
  já medido ou em uma fonte oficial citada.
- **PROVÁVEL** — conclusão forte obtida por combinação de evidência local e
  norma/documentação, sem execução do serviço real.
- **HIPÓTESE** — explicação plausível que depende de estado externo não
  observado, como schema, funções (roles), configuração de produção ou
  resposta de um servidor.

As referências a arquivos locais usam o formato `arquivo:linha`. As fontes
externas são identificadas por `[A#]`, `[G#]`, `[M#]` e `[R#]` na seção
**Fontes oficiais consultadas**. Não se afirma performance sem medição: os
únicos números de operação abaixo são contagens estáticas, intervalos,
limites publicados ou tamanhos de página observados no código. Não houve benchmark
de CloudKit, Calendar, MCP, EventKit ou Keychain.

---

## 1. Resumo executivo

| ID | Confiança | Conclusão | Evidência local essencial |
|---|---|---|---|
| R-01 | **CONFIRMADO** | O app usa CloudKit diretamente: cada equipe tem uma zona privada do proprietário, um `CKShare` de zona inteira e registros textuais de conversa em `CKAsset`; o banco público guarda índice e marcador, não o conteúdo da conversa. O SwiftData permanece local. | `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:40-68`; `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:156-175`; `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:29-35` |
| R-02 | **CONFIRMADO** | A afirmação preliminar de que qualquer conta pode sobrescrever qualquer registro público é **falsa no modelo padrão**. A Apple diz que o público é legível por todos, mas cada usuário com conta iCloud escreve os objetos que cria; funções no developer portal podem restringir a política. | `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:91-105`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:285-301`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:410-432`; [A1] |
| R-03 | **PROVÁVEL** | O desenho deixa risco de sombreamento (shadowing), preempção e negação de serviço: não há unicidade nem verificação de autoria para o código público, e o marcador de exclusão tem ID determinístico e é consumido sem validar o criador. O efeito exato depende das funções (roles) e do estado do container. | `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:94-105`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:285-317`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:410-432`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:518-520`; `Papagaio/App/ContentView.swift:758-782`; [A1][A6] |
| R-04 | **CONFIRMADO** | O código de entrada tem alfabeto de 32 símbolos e seis posições: `32^6 = 2^30 = 1.073.741.824` possibilidades. Ele é uma chave de busca, não a fronteira de autorização: a URL pública do `CKShare` concede `.readWrite` a quem a possuir. | `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:134-137`; `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:59-73`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:381-385`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:410-415`; [A2][A3] |
| R-05 | **CONFIRMADO** | `visibilidadeDosArquivos = apenasAdministrador` é uma configuração local; o share é de zona inteira e não implementa ACL por arquivo. A opção de visibilidade não é aplicada pelo CloudKit. | `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:29-31`; `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:59-68`; [A2][A3] |
| R-06 | **CONFIRMADO** | O código tenta alterar e remover participantes com `publicPermission = .readWrite`. A documentação atual exige `publicPermission = .none` para modificar a lista e proíbe misturar usuários públicos e privados no mesmo share. | `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:213-239`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:381-385`; [A3] |
| R-07 | **CONFIRMADO** | O download refaz a carga da zona a cada chamada: `fetchAllChanges = true`, sem `CKServerChangeToken` e sem assinatura local. A paginação de 200 é feita em memória; cada envio faz uma leitura do registro e um `save`. | `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:148-149`, `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:178-197`, `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:212-239`, `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:242-282`; [A4] |
| R-08 | **CONFIRMADO** | A fila não lê `CKErrorRetryAfterKey`; o contador satura em dez e a operação continua tentando a cada 15 minutos para erros que não são classificados como ação do proprietário, incluindo quota. | `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:152-170`, `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:199-202`; `Papagaio/ViewModels/Biblioteca.swift:1095-1135`; [A5] |
| R-09 | **CONFIRMADO** | O OAuth Google Desktop segue o padrão recomendado: navegador do sistema, loopback `127.0.0.1` com porta efêmera, PKCE S256, `state`, public client sem segredo distribuível e tokens no Keychain. | `Papagaio/Integracao/SessaoOAuthGoogle.swift:124-157`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:187-218`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:221-245`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:329-337`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:367-413`; [G1][R2] |
| R-10 | **PROVÁVEL** | `prompt=none` impede telas de autenticação e consentimento. Sem consentimento prévio do mesmo cliente e usuário, o primeiro botão de conectar tende a falhar; o ideal é separar retomada de sessão de consentimento interativo. | `Papagaio/Integracao/SessaoOAuthGoogle.swift:196-211`; [G1][G7] |
| R-11 | **CONFIRMADO** | O código não persiste nem verifica o campo `scope` retornado pelo Google. A sincronização do Calendar consulta uma janela de 24 horas a cada 15 minutos, sem `syncToken` nem push. | `Papagaio/Integracao/SessaoOAuthGoogle.swift:275-309`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:395-399`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:152-166`; `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:101-150`; [G2][G5][G6] |
| R-12 | **CONFIRMADO** | O fluxo Granola usa `papagaio://oauth/callback`. Esse callback não atende à regra de redirect localhost/HTTPS da revisão MCP `2025-03-26`; além disso, o scheme não é baseado em domínio reverso, exigência da RFC 8252 para private-use URI scheme. | `Papagaio/Integracao/SessaoOAuth.swift:194-208`, `Papagaio/Integracao/SessaoOAuth.swift:238-283`; `Config/Info.plist:7-16`; [M1][R3] |
| R-13 | **CONFIRMADO** | O cliente do app implementa a era MCP `2025-03-26` (`initialize`, notificação `initialized` e `Mcp-Session-Id`). A revisão `2026-07-28` remove esses mecanismos e exige metadados, issuer/audience/resource, headers por requisição e estratégia de compatibilidade. O app não implementa as duas eras. | `Papagaio/Integracao/ClienteMCP.swift:25-35`, `Papagaio/Integracao/ClienteMCP.swift:89-125`, `Papagaio/Integracao/ClienteMCP.swift:129-187`; [M2][M3][M4][M5][M6] |
| R-14 | **CONFIRMADO** | Sign in with Apple é um perfil local. Não há servidor de autenticação; por isso a ausência de `identityToken`, `authorizationCode`, `state` e `nonce` não é, isoladamente, defeito de servidor. O identificador Apple fica no Keychain e o estado é revalidado. | `Papagaio/ViewModels/PerfilViewModel.swift:51-66`, `Papagaio/ViewModels/PerfilViewModel.swift:118-147`, `Papagaio/ViewModels/PerfilViewModel.swift:206-228`; [A11] |
| R-15 | **CONFIRMADO** | Tokens Google/Granola e o identificador Apple usam `kSecAttrAccessibleAfterFirstUnlock`; ficam acessíveis após o primeiro desbloqueio, inclusive com o Mac bloqueado, e migram em backup criptografado. `WhenUnlocked` é a recomendação para itens usados apenas em primeiro plano. | `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:14-27`; `Papagaio/ViewModels/PerfilViewModel.swift:136-146`; [A10] |
| R-16 | **CONFIRMADO** | EventKit usa `requestFullAccessToEvents()` e ainda enumera `.authorized`, que está deprecated desde macOS 14. Contatos é acessado por `requestAccess`; o prompt local usa no máximo 40 termos. | `Papagaio/Suporte/PromptDeEntidades.swift:27-38`, `Papagaio/Suporte/PromptDeEntidades.swift:42-83`; `Config/Papagaio.entitlements:33-36`; `Loro.xcodeproj/project.pbxproj:461-462`, `Loro.xcodeproj/project.pbxproj:501-502`; [A7][A8][A9] |
| R-17 | **PROVÁVEL** | macOS 27.0 e Xcode 27.0 medidos podem ser anteriores aos lançamentos de segurança de 14/09/2026. Os advisories oficiais mencionam Sign in with Apple, Authentication Services/Keychain e Xcode; o patch exato do build não foi identificado. | `audit/00-mapa.md:31-39`; [A12][A13] |

### Correção material do relatório preliminar

O texto anterior afirmava que o banco público permitia a **qualquer conta
alterar arbitrariamente registros de terceiros**. Isso não corresponde ao
modelo padrão descrito pela Apple: o público é legível por todos, mas cada
usuário com conta iCloud tem escrita nos objetos que cria, e o developer portal
permite atribuir funções (roles) [A1]. A conclusão correta é mais estreita: o app não
valida autoria nem unicidade dos registros que usa como índice e, portanto,
pode sofrer sombreamento (shadowing) e preempção, especialmente se o ID
público for previsível [A6]. Isso não transforma a URL do share em um mero
código de consulta: a URL é um convite de escrita pública `.readWrite`
[A2][A3].

---

## 2. Baseline, versões e configuração

### 2.1 Runtime e revisões aplicáveis

| Item | Valor observado ou declarado | Confiança/evidência |
|---|---|---|
| App | Produto `Ōmu`, bundle `com.papagaio.Papagaio`, marketing `1.3`, build `31` | **CONFIRMADO** — `Loro.xcodeproj/project.pbxproj:450-474`, `Loro.xcodeproj/project.pbxproj:490-514` |
| Deployment target | macOS `26.0` | **CONFIRMADO** — `Loro.xcodeproj/project.pbxproj:431-437`; `audit/00-mapa.md:41-52` |
| Linguagem | Swift `6.0`, strict concurrency `complete` | **CONFIRMADO** — `Loro.xcodeproj/project.pbxproj:431-437` |
| SDK medido | `MacOSX27.0.sdk`; Xcode `27.0 (27A5194q)` em `/Applications/Xcode-beta.app` | **CONFIRMADO** — `audit/00-mapa.md:31-39` |
| Sistema medido | macOS `27.0 (26A428)` | **CONFIRMADO** — baseline; a versão não é prova do patch de segurança |
| OAuth Google | Authorization Code + PKCE, app Desktop nativo, Calendar API `v3` | **CONFIRMADO** — `Papagaio/Integracao/SessaoOAuthGoogle.swift:68-78`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:196-245`; `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:15-20`; [G1][G3] |
| OAuth Granola | DCR RFC 7591 + Authorization Code + PKCE | **CONFIRMADO** — `Papagaio/Integracao/SessaoOAuth.swift:47-58`, `Papagaio/Integracao/SessaoOAuth.swift:180-235`; [R7] |
| MCP no app | Streamable HTTP, revisão `2025-03-26` | **CONFIRMADO** — `Papagaio/Integracao/ClienteMCP.swift:25-35`, `Papagaio/Integracao/ClienteMCP.swift:102-125`; [M1][M3] |
| MCP oficial mais recente consultado | Revisão `2026-07-28` | **CONFIRMADO** — [M4][M5][M6] |
| Norma OAuth de segurança | RFC 9700, OAuth 2.0 Security BCP, janeiro de 2025 | **CONFIRMADO** — [R6] |

A data da revisão MCP e as datas de atualização das páginas Google são as
observadas na consulta de 2026-09-23; não são promessas de que permanecerão
iguais em uma consulta futura.

### 2.2 Entitlements e `Info.plist`

| Capacidade/chave | Estado local | Uso e ressalva | Evidência |
|---|---:|---|---|
| Container iCloud | `iCloud.com.papagaio.Papagaio` + `CloudKit` | O mesmo identificador aparece no código. | `Config/Papagaio.entitlements:11-18`; `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:40-41` |
| App Sandbox | `true` | Contenção básica do processo; não substitui revisão de dados. | `Config/Papagaio.entitlements:19-20` |
| Sign in with Apple | `Default` | Solicitação local e revalidação de credencial. | `Config/Papagaio.entitlements:5-8`; `Papagaio/ViewModels/PerfilViewModel.swift:58-67` |
| APNs | `development` | A chave existe localmente, mas uso real, assinatura de produção e subscriptions no servidor não foram verificados. | `Config/Papagaio.entitlements:9-10`; busca de `CKDatabaseSubscription` no código = 0 |
| Calendário e contatos | `true` | Capacidades coherentes com o código; strings de privacidade entram pelo build. | `Config/Papagaio.entitlements:33-36`; `Loro.xcodeproj/project.pbxproj:461-462`, `Loro.xcodeproj/project.pbxproj:501-502` |
| Áudio, bookmark e arquivo selecionado | `true` | Capacidades de captura, avatar e seleção de arquivos; não alteram a análise de OAuth/CloudKit. | `Config/Papagaio.entitlements:23-28` |
| Rede cliente/servidor | ambas `true` | Saída para APIs e listener loopback; o listener do Google fica em `127.0.0.1`. | `Config/Papagaio.entitlements:29-32`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:367-413`; [A14] |
| Validação de bibliotecas | desabilitada | Exceção do hardened runtime; a justificativa para XCFrameworks locais não está documentada no repositório. | `Config/Papagaio.entitlements:21-22`; [A14] |
| CloudKit sharing | `CKSharingSupported = true` | Necessária para o fluxo de compartilhamento no bundle. | `Config/Info.plist:18-19`; [A15] |
| Callback customizado | `papagaio://` | Usado pelo Granola; não é o redirect localhost/HTTPS exigido pela revisão MCP consultada. | `Config/Info.plist:7-16`; [M1] |
| Google Client ID | `$(GOOGLE_CLIENT_ID)` | O valor effective pode existir em configuração local, mas não foi lido nem transcrito. | `Config/Info.plist:20-21`; `Config/Base.xcconfig:1-10` |

As strings de privacidade de Calendar e Contacts não estão em `Config/Info.plist`.
`GENERATE_INFOPLIST_FILE = YES` e `INFOPLIST_KEY_*` no `Loro.xcodeproj/project.pbxproj` fazem
o Xcode fundi-las no build final (`Loro.xcodeproj/project.pbxproj:455-465`, `Loro.xcodeproj/project.pbxproj:495-505`).
Isso é uma observação de configuração, não uma validação do binário
assinado.

### 2.3 Schema inferido do código — não é o schema de produção

O repositório prova o contrato lido pelo cliente. Não prova quais tipos,
campos, índices, funções, containers ou políticas estão publicados no container
real. O README exige que o tipo público `CodigoDeEquipe` tenha
`codigoDeEntrada` consultável e `urlDoCompartilhamento`, e que
`EquipeExcluida` tenha `equipeID`, `excluidaEm` e `estadoDaExclusao`
(`README.md:86-98`).

| Tipo | Banco/zona | Campos exigidos pelo cliente | Observações |
|---|---|---|---|
| `Equipe` | banco privado do proprietário; zona `equipe.<id>` | `id` String, `nome` String, `espacoID` String, `codigoDeEntrada` String opcional, `configuracoes` Data, `nomesDosParticipantes` Data | Registro fixo `equipe`; `configuracoes` e mapa de nomes são JSON em `Data`. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:393-408` |
| `CKShare` | mesma zona privada | `title`, `publicPermission`, participantes | Compartilhamento de zona inteira; não há hierarquia nem registro raiz. [A2] |
| `Conversa` | banco privado do proprietário ou banco compartilhado do participante | `conteudo` `CKAsset` com JSON, `titulo` String, `criadoEm`/`atualizadoEm` Date, `midiaDisponivelNaOrigem` numérico; `dados` legado | ID é o UUID da conversa; `dados` é apagado no caminho de escrita atual. `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:156-175`, `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:212-220` |
| `CodigoDeEquipe` | público, zona padrão | `codigoDeEntrada` String consultável, `urlDoCompartilhamento` String | O ID do registro não é escolhido pelo código; a consulta é exata por código e usa `first` sem validar o criador. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:94-105`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:410-415` |
| `EquipeExcluida` | público, zona padrão | `equipeID` String, `excluidaEm` Date, `estadoDaExclusao` String | ID determinístico `equipe-excluida.<id>`. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:285-301`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:518-520` |

`publicCloudDatabase` não oferece zonas customizadas; o código, portanto, usa a
zona padrão para os dois tipos públicos [A1][A6]. A existência dos campos no
código não prova que eles estejam indexáveis ou publicados no schema de
produção.

### 2.4 Qual implementação é realmente executada

- O app constrói `SessaoOAuth` e `ClienteMCP` da pasta
  `Papagaio/Integracao/`; esse cliente MCP é legado (`Papagaio/Integracao/GranolaViewModel.swift:69-85`).
- A CLI `papagaio-eval granola` usa a árvore separada de `PapagaioCore`.
  A implementação Core tem comentários, validações e estratégias de tentativa
  diferentes e não é evidência do runtime do app
  (`PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:101-127`, `PapagaioCore/Sources/PapagaioCore/Integracao/ClienteMCP.swift:148-198`).
- Os comentários de `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:88-92` dizem que o app usa
  `ASWebAuthenticationSession`, mas o apresentador efetivo usa `NSWorkspace` e
  callback customizado (`Papagaio/Integracao/ApresentadorDeSessaoDeAutorizacao.swift:5-49`). É
  divergência documental; não é evidência de que `ASWebAuthenticationSession` seja
  chamado.

---

## 3. CloudKit, banco público e `CKShare`

### 3.1 Modelo de dados e fronteiras

```text
dono da equipe (banco privado)
  └── zona personalizada `equipe.<id>`
      ├── registro `Equipe`
      ├── `CKShare(recordZoneID:)`, publicPermission = .readWrite
      └── registros `Conversa` (JSON em CKAsset; áudio/anexos ficam locais)

participante (banco compartilhado)
  └── cópia da zona compartilhada

banco público (zona default)
  ├── `CodigoDeEquipe` → código + URL do compartilhamento
  └── `EquipeExcluida` → marcador de exclusão
```

- `CKContainer(identifier:)` é explícito e coincide com o entitlement
  (`Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:40-41`).
- Cada equipe usa uma zona própria e salva `Equipe` e `CKShare` na mesma
  operação (`Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:51-68`).
- `CKShare(recordZoneID:)` compartilha a zona inteira; a Apple descreve a
  capacidade `zoneWideSharing` e a cópia dos registros para o banco
  compartilhado do participante [A2].
- A entrada consulta o registro público, obtém a URL, busca metadados e aceita
  o compartilhamento (`Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:90-105`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:336-370`).
- A exclusão é uma sequência de estados: grava `preparando`, invalida o
  código, apaga a zona e grava `concluida`
  (`Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:276-301`). Isso não é uma
  transação atômica entre a zona privada e o banco público.

### 3.2 O que o banco público realmente permite

A documentação atual do `publicCloudDatabase` diz que o banco está disponível
independentemente de o dispositivo ter uma conta iCloud, que o conteúdo é
legível por todos os usuários do app e que **cada usuário com conta iCloud
tem escrita nos registros e outros objetos que cria**; o developer portal
permite atribuir funções (roles) para restringir o acesso [A1]. A documentação
de `CKDatabase`
acrescenta que a escrita no banco público exige uma conta iCloud para
identificar a autoria. A documentação de `CKRecord.ID` acrescenta que a
unicidade é por banco: no público, um ID específico só pode pertencer a um
registro; no privado, o mesmo nome pode ser reutilizado por usuários
diferentes [A6].

Consequência para esta auditoria:

- **Não é correto** dizer que qualquer conta sobrescreve livremente o
  registro de outra conta no modelo padrão.
- **É correto** dizer que o índice público não é uma fonte de verdade
  autenticada: o app não consulta nem valida `creatorUserRecordID` ao
  interpretar o registro.
- **É correto** dizer que um ID público previsível pode ser preemptido por um
  criador diferente, porque a unicidade do ID no banco público não transforma o
  registro em uma declaração de autorização para o app.

### 3.3 Segurança e anti-padrões

| ID | Confiança | Achado e impacto |
|---|---|---|
| CK-01 | **CONFIRMADO** | O banco público é legível por todos e a escrita padrão é pelo criador; funções (roles) customizadas podem mudar isso. O relatório preliminar foi corrigido neste ponto. [A1] |
| CK-02 | **PROVÁVEL** | `CodigoDeEquipe` não tem unicidade nem verificação de criador. Um usuário pode criar outro registro com o mesmo `codigoDeEntrada`; `matchResults.first` não define qual duplicado vence. Se o duplicado apontar para outro share, a entrada pode receber a URL errada. Depende de indexação, funções e taxa de tentativas. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:94-105`. |
| CK-03 | **PROVÁVEL** | O marcador de exclusão usa `equipe-excluida.<id>` como ID público. No banco público, o mesmo ID é único entre os registros [A6]. Um criador diferente pode reivindicar o ID antes do proprietário; o `save` legítimo pode falhar. Se um registro preexistente já existir com `estadoDaExclusao = concluida`, `equipeFoiExcluida` não verifica o criador nem compara todos os campos antes de autorizar a limpeza local. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:285-317`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:518-520`; `Papagaio/App/ContentView.swift:761-782`. |
| CK-04 | **CONFIRMADO** | A URL do compartilhamento é gravada no registro público. Com `publicPermission = .readWrite`, quem tiver a URL pode participar; o código de seis caracteres é apenas a chave usada para encontrá-la. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:59-73`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:410-415`; [A2][A3]. |
| CK-05 | **PROVÁVEL** | O código tem 32⁶ possibilidades, mas a consulta pública por código e a URL tornam plausíveis enumeração ou vazamento do segredo de busca. Não há medição de taxa, bloqueio ou impacto; não se afirma que força bruta seja prática. `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:134-137`; `README.md:86-90`. |
| CK-06 | **CONFIRMADO** | `visibilidadeDosArquivos` e `recebimentoDeArquivos` são campos locais de `ConfiguracoesDaEquipe`; não há leitura deles para criar uma ACL por registro no CloudKit. O compartilhamento é de zona inteira. `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:29-32`; [A2]. |
| CK-07 | **CONFIRMADO** | A Apple exige `publicPermission = .none` para modificar a lista de participantes e diz que usuários públicos e privados não podem ser combinados. O app tenta mudar `participant.permission` e remover participantes enquanto o link público está habilitado; o erro real do serviço não foi executado. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:213-239`; [A3]. |
| CK-08 | **CONFIRMADO** | Participantes com escrita podem modificar ou apagar qualquer registro incluído no compartilhamento, conforme a Apple. Portanto a opção de exibir arquivos apenas a administradores não é aplicada pela ACL do compartilhamento. [A2][A3]. |
| CK-09 | **CONFIRMADO** | O recurso de reserva de `idDoParticipante` é `UUID()` quando não há ID do registro/e-mail; cada chamada pode produzir uma chave diferente. A Apple expõe `participantID` como identificador de participante, disponível no SDK alvo. `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:481-495`; [A2]. |
| CK-10 | **CONFIRMADO** | Não há uso de `encryptedValues` no código do app. Isso não permite concluir algo sobre criptografia de armazenamento do serviço Apple; apenas que o cliente não pediu esse recurso de campo. `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:156-175`. |
| CK-11 | **PROVÁVEL** | O payload compartilhado inclui transcrição, notas e resumo em `CKAsset`, enquanto áudio e anexos permanecem locais. O nível de exposição depende da ACL do share e do schema real. `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:331-368`; [A2]. |
| CK-12 | **CONFIRMADO** | Uma zona compartilhada deve ter a capability `zoneWideSharing` e pode participar de apenas um compartilhamento; o código cria a zona customizada com essa capacidade e um compartilhamento de zona inteira. [A2] |

A rotação de código troca o `CKShare`, apaga o compartilhamento anterior e publica
uma URL nova (`Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:242-273`). Isso
invalida o link anterior para novas entradas, mas a URL nova continua sendo
publicada no banco público e deve ser protegida como um convite de escrita, não
como simples metadado.

### 3.4 Sincronização, exclusões e custo estático

1. **Carga completa.** `CKFetchRecordZoneChangesOperation` recebe uma zona e
   `fetchAllChanges = true`, sem token anterior, callback de token ou
   assinatura no código (`Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:242-270`).
   A Apple orienta a primeira carga completa, cache do token, assinatura e
   busca após push; também afirma que não é necessário buscar a cada lançamento
   nem em polling regular [A4].
2. **Paginação em memória.** `registrosDaZona` acumula todos os
   `CKRecord`; `dadosDosRegistros` lê todos os assets para `Data`; só então
   `pagina` fatia 200 itens (`Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:212-239`).
   A página de 200 não reduz o download nem o pico de memória dessa rota.
3. **Envio.** `salvar` sempre faz `record(for:)`, converte `unknownItem` em
   um novo registro e depois faz `save`
   (`Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:156-175`,
   `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:274-283`). Isso
   são duas operações CloudKit por item enfileirado, sem afirmar quantas
   rodadas de rede o SDK execute internamente.
4. **Exclusões remotas.** Só há `recordWasChangedBlock`; não há
   `recordWithIDWasDeletedBlock`. O download faz upsert do que chegou e a
   biblioteca salva o resultado, mas não remove uma conversa ausente
   (`Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:247-270`,
   `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:371-393`;
   `Papagaio/ViewModels/Biblioteca.swift:1138-1171`). A permanência de uma conversa apagada por
   outro cliente é **PROVÁVEL**, não foi reproduzida contra CloudKit.
5. **Conflitos.** A fila protege uma alteração local pendente; sem pendência,
   o conteúdo remoto substitui o local (`Papagaio/ViewModels/Biblioteca.swift:1143-1171`),
   preservando apenas o caminho de mídia local quando ele existe. O `save`
   de conveniência exige que o registro seja novo ou mais recente; ao repetir
   após `serverRecordChanged`, o tratador refaz a leitura e sobrescreve campos
   do payload, sem usar as três cópias recomendadas pela Apple [A5].
6. **Sem push/assinatura no código.** Não há `CKDatabaseSubscription`,
   `CKRecordZoneSubscription`, `CKNotification` ou `fetchDatabaseChanges` no
   app. Isso não prova que o servidor de produção não tenga uma assinatura;
   prova que o cliente local não a gerencia.
7. **Tentativas.** A fila usa `min(5 * 2^(tentativa-1), 900)` segundos, mas não
   lê `CKErrorRetryAfterKey` (`Papagaio/CloudKit/FilaPersistenteCloudKit.swift:152-170`,
   `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:199-202`). A Apple
   recomenda verificar essa dica e aumentar exponencialmente o atraso em
   `zoneBusy` [A5].
8. **Erros permanentes.** Schema ausente, zona inexistente e quota chegam à
   mesma fila. A biblioteca não agenda nova tentativa quando o diagnóstico textual
   reconhece alguns erros de proprietário, mas não tem uma tabela por
   `CKError.Code` (`Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:82-122`;
   `Papagaio/ViewModels/Biblioteca.swift:1101-1113`). Um `quotaExceeded` não é
   classificado e pode continuar em tentativa; a Apple diferencia a quota do
   container público, do usuário privado e do proprietário da zona
   compartilhada [A5].
9. **Limites publicados.** A Apple informa 400 registros ou shares por
   operação e 2 MB por requisição, sem contar assets; o servidor pode mudar os
   limites [A5]. Os lotes locais têm um ou dois itens, então o limite de
   contagem não é o caminho óbvio de falha. Nenhum tamanho real de payload foi
   medido.

---

## 4. Google Calendar — OAuth e API

### 4.1 Conformidade do fluxo Desktop

| Controle | Estado | Evidência e critério |
|---|---|---|
| Public client | **CONFIRMADO / conforme** | Só envia `client_id`; não há `client_secret` no código do app. [G1][R2] |
| User agent | **CONFIRMADO / conforme** | Abre a URL com `NSWorkspace.shared.open`, fora de um WebView controlado pelo app. `Papagaio/Integracao/SessaoOAuthGoogle.swift:124-157`; [G1] |
| Redirect loopback | **CONFIRMADO / conforme para macOS** | Faz bind em `127.0.0.1`, pede porta `0` e usa a porta retornada. O Google recomenda loopback para macOS/Linux/Windows Desktop. `Papagaio/Integracao/SessaoOAuthGoogle.swift:187-193`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:367-413`; [G1] |
| Listener | **CONFIRMADO** | Aceita callback em `/oauth/callback`, valida `state` e encerra a espera depois do retorno ou timeout. `Papagaio/Integracao/SessaoOAuthGoogle.swift:423-481` |
| PKCE | **CONFIRMADO / conforme** | Verifier de 96 caracteres, alfabeto unreserved, challenge SHA-256/base64url sem padding e redemption do verifier. `Papagaio/Integracao/SessaoOAuthGoogle.swift:196-211`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:221-245`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:329-337`; [G1][R2] |
| `state` | **CONFIRMADO / conforme** | UUID por fluxo e igualdade estrita no callback. `Papagaio/Integracao/SessaoOAuthGoogle.swift:124-130`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:454-481`; [G1] |
| Tokens e revogação | **CONFIRMADO / majoritariamente conforme** | Access, expiry e refresh ficam no Keychain; refresh é tentado e logout tenta revogar. Falhas de persistência são ignoradas por `try?`. `Papagaio/Integracao/SessaoOAuthGoogle.swift:86-121`, `Papagaio/Integracao/SessaoOAuthGoogle.swift:247-309`; [G2] |
| Escopo concedido | **CONFIRMADO / lacuna** | O campo `scope` pode aparecer na resposta JSON, mas não é armazenado nem comparado com os escopos necessários. [G1][G2] |

### 4.2 Falhas de consentimento, escopo e sincronização

1. **`prompt=none` — PROVÁVEL.** A URL sempre inclui `prompt=none`
   (`Papagaio/Integracao/SessaoOAuthGoogle.swift:209-210`). O Google define `none` como não
   exibir telas de autenticação/consentimento e retornar erro quando não há
   autenticação ou consentimento prévio [G7]. Se o primeiro uso não tiver
   concessão anterior, o botão “conectar” não apresenta o consentimento
   necessário. Separar `prompt=none` para retomada e fluxo normal para novo
   consentimento elimina essa dependência.
2. **Escopo amplo — PROVÁVEL.** O código pede
   `calendar.readonly` e `userinfo.email` (`Papagaio/Integracao/SessaoOAuthGoogle.swift:78`) e
   chama `events.list`/`events.get` no calendário `primary`. O escopo
   `calendar.readonly` permite ver e baixar qualquer calendário acessível;
   `calendar.events.readonly` é mais estreito para a finalidade observada,
   mas a troca deve ser validada no console e nos testes de produto [G3][G4].
3. **Verificação de lançamento.** Ler eventos do Google Calendar é exemplo
   de dado sensível na documentação de verificação. Para um app externo
   público, verificação de marca, política de privacidade, tela de consentimento
   e possível verificação de escopo sensível são **não verificados** neste
   repositório; exceções dependem do estágio e da política do projeto [G8].
4. **Full polling — CONFIRMADO.** Depois da carga inicial, o timer espera
   15 minutos e chama `listarEventos` novamente
   (`Papagaio/Integracao/GoogleCalendarViewModel.swift:152-166`). Cada chamada usa `timeMin` até
   `timeMax` 24 horas, `maxResults=250`, pagina enquanto houver
   `nextPageToken` e `showDeleted=false` (`Papagaio/Integracao/FonteGoogleCalendarAPI.swift:101-150`).
   São quatro chamadas-base de listagem por hora enquanto o timer estiver
   ativo, mais páginas e eventualmente um `events.get` pela interface. É uma
   contagem de agenda, não uma medição de banda ou latência.
5. **Sem `syncToken`/push — CONFIRMADO.** A API não envia `syncToken` e não
   trata `410 Gone`. A documentação recomenda carga inicial, persistir
   `nextSyncToken`, sincronizar incrementalmente e fazer uma sincronização
   completa quando o token expira [G5]. O polling repetido é apontado como
   anti-padrão de uso de quota; push é a alternativa mais eficiente [G6].
6. **Sem backoff específico para 403/429 — CONFIRMADO.** A fonte transforma
   qualquer status fora de 2xx em erro local; a próxima tentativa depende do
   timer de 15 minutos (`Papagaio/Integracao/FonteGoogleCalendarAPI.swift:137-140`;
   `Papagaio/Integracao/GoogleCalendarViewModel.swift:169-181`). O Google recomenda backoff
   exponencial com jitter para limites de tempo [G6].
7. **Cancelamento local — CONFIRMADO pelo baseline.** Dois testes de OAuth
   ficaram pendurados até o limite de 300 s, e o mecanismo de shutdown do
   listener não acordou `accept()` nesta plataforma
   (`audit/00-mapa.md:396-412`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:423-451`,
   `Papagaio/Integracao/SessaoOAuthGoogle.swift:484-503`). Este item é evidência de teste local, não resultado de uma
   chamada ao Google.
8. **DPoP — PROVÁVEL como endurecimento.** O Google recomenda DPoP para
   clientes públicos e para proteger refresh tokens. O código usa Bearer e não
   cria uma chave vinculada ao remetente; isso não é uma não conformidade
   obrigatória do fluxo atual [G1][G2].

### 4.3 Dados e privacidade

- O app solicita eventos, participantes e descrição; o estado do Calendar
  persiste apenas snapshots pequenos do estado de cada reunião — ativa,
  ignorada ou convertida — em `UserDefaults`. Esses snapshots ainda podem
  conter título, data, participantes (incluindo nome/e-mail) e descrição; não são apenas IDs
  (`Papagaio/Modelos/ReuniaoPendenteCalendar.swift:4-10`;
  `PapagaioCore/Sources/PapagaioCore/Integracao/ParticipanteDaReuniao.swift:3-14`;
  `Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:3-23`,
  `Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:70-82`).
- A classe de Calendar não persiste áudio, transcrição ou token nesse estado;
  a importação de áudio é um fluxo local separado
  (`Papagaio/Integracao/GoogleCalendarViewModel.swift:169-231`).
- O log de expiração mostra apenas a duração do token, não o valor. Não
  foi encontrado token em `UserDefaults`; o Client ID efetivo não é
  transcrito.

---

## 5. Granola — OAuth, MCP e Streamable HTTP

### 5.1 OAuth implementado pelo app

| Controle | Estado | Evidência |
|---|---|---|
| Descoberta de metadata | **CONFIRMADO / conforme à revisão `2025-03-26` em estrutura** | Lê `/.well-known/oauth-authorization-server` na raiz derivada do endpoint MCP e usa `/authorize`, `/token`, `/register` e `/revoke` como fallback. `Papagaio/Integracao/SessaoOAuth.swift:117-162`; [M1] |
| DCR | **CONFIRMADO / aceito na revisão antiga; deprecated na revisão `2026-07-28`** | Registra `client_name`, redirect, grants e `token_endpoint_auth_method=none`; guarda o registro no Keychain. `Papagaio/Integracao/SessaoOAuth.swift:194-235`; [M1][M4][M6][R7] |
| PKCE e `state` | **CONFIRMADO** | S256, verifier de 96 caracteres e comparação do `state` no gerenciador de callback. `Papagaio/Integracao/SessaoOAuth.swift:238-256`; `Papagaio/Integracao/ApresentadorDeSessaoDeAutorizacao.swift:16-29`; `Papagaio/Integracao/GerenciadorDeCallbackDeAutorizacao.swift:19-52` |
| Redirect | **CONFIRMADO / incompatível com MCP** | `papagaio://oauth/callback`; a revisão MCP exige redirect localhost ou HTTPS. [M1] |
| Domínio reverso | **CONFIRMADO / não conforme** | O scheme `papagaio` não expressa um domínio sob controle em ordem reversa, exigência da RFC 8252 para private-use URI scheme. [R3] |
| Issuer e endpoints | **CONFIRMADO / lacunas** | Os metadados não validam `issuer`; os endpoints descobertos não são limitados a HTTPS; não há vínculo de `resource`/audience. `Papagaio/Integracao/SessaoOAuth.swift:120-151`, `Papagaio/Integracao/SessaoOAuth.swift:238-312`; [R4][R5][M4] |
| Refresh inválido | **CONFIRMADO / recuperação ausente** | `responderComToken` lança o erro, mas não apaga o refresh token; chamadas seguintes continuam tentando o mesmo segredo. `Papagaio/Integracao/SessaoOAuth.swift:289-312`, `Papagaio/Integracao/SessaoOAuth.swift:331-349` |

O callback genérico tem mitigação parcial: o PKCE impede que um app que capture
o código o troque sem o verifier, e o `state` liga a resposta a uma espera
ativa. Isso não transforma `papagaio://` em redirect recomendado pelo MCP,
não elimina colisão de schemes e não implementa validação de
issuer/audience/resource. A aceitação desse callback pelo servidor Granola não
foi sondada.

- **Validação do redirect — PROVÁVEL:** o gerenciador extrai `state` e `code`,
  mas não compara o scheme, host e caminho recebidos com o redirect
  registrado (`Papagaio/Integracao/GerenciadorDeCallbackDeAutorizacao.swift:31-43`).
  A RFC 8252 exige verificar o URI exato para mitigate mix-up e interceptação;
  PKCE e `state` reduzem o impacto, mas não substituem essa verificação [R3].

### 5.2 Compatibilidade MCP por revisão

| Requisito | App (`2025-03-26`) | MCP `2026-07-28` |
|---|---|---|
| Authorization Code + PKCE | **CONFIRMADO / presente** | **CONFIRMADO / presente**, mas metadata, issuer, audience/resource e discovery moderno faltam |
| Redirect | **NÃO conforme**: `papagaio://` | **NÃO conforme**: a regra localhost/HTTPS permanece |
| Metadata | AS metadata RFC 8414 e fallback | Protected Resource Metadata + AS/OIDC discovery; [M4] |
| DCR | Recomendado na revisão `2025-03-26` | Deprecated, mantido apenas para compatibilidade; [M4][M6] |
| Lifecycle | `initialize` + `notifications/initialized` | Handshake removido; `server/discover` e metadata `_meta` por request; [M5][M6] |
| Sessão | `Mcp-Session-Id` propagado quando existe | Sessões de protocolo e header removidos; [M5][M6] |
| Headers | `Content-Type`, `Accept`, Bearer e sessão | `MCP-Protocol-Version`, `Mcp-Method` e `Mcp-Name` são obrigatórios; o cliente não os envia; [M5] |
| Transporte | POST com JSON/SSE e parser legado | POST por request, sem GET stream, sem sessão e com fallback de compatibilidade; [M5] |
| Negociação de versão | Envia `2025-03-26` em `initialize`, mas não valida `result.protocolVersion` | Servidor moderno deve rejeitar versão incompatível; cliente precisa de fallback explícito; [M2][M5][M6] |
| 404 de sessão | O app trata como erro MCP comum | Não se aplica à revisão moderna |

O código pode ser um cliente plausível de um servidor que ainda suporte a
era `2025-03-26`; não é um cliente moderno `2026-07-28`. Não houve handshake
real com o Granola, portanto o suporte real a versões, ferramentas, redirect e
DCR permanece **HIPÓTESE**.

### 5.3 Dados, parser e observabilidade

- `FonteGranola` chama `get_account_info`, `list_meetings`, `get_meetings` e
  `get_meeting_transcript` (`Papagaio/Integracao/FonteGranola.swift:9-19`, `Papagaio/Integracao/FonteGranola.swift:24-85`). O schema
  real dessas ferramentas não está no repositório.
- O parser aceita XML e alguns formatos JSON legados
  (`Papagaio/Integracao/FonteGranola.swift:103-130`). Não se afirma que esses formatos ainda
  sejam o contrato de 2026.
- A importação mantém notas, resumo, participantes e transcrição no modelo
  local; o áudio convertido é tratado pela biblioteca, não é enviado por
  esse fluxo (`Papagaio/Integracao/GranolaViewModel.swift:149-199`).
- O app registra `conta.email` com `privacy: .public`
  (`Papagaio/Integracao/GranolaViewModel.swift:80-89`). Isso expõe dados pessoais em logs; deve ser
  privado ou redigido. A revisão estática não encontrou o token em log,
  mas não garante comportamento de bibliotecas ou de futuros logs.
- O cliente app usa `URLSession.data(for:)`, que aguarda o corpo completo. Em
  SSE, junta todas as linhas `data:` em um único JSON
  (`Papagaio/Integracao/ClienteMCP.swift:142-187`). Falha com mais de um evento é **PROVÁVEL**;
  a resposta real não foi observada.
- O cliente Core tenta novamente uma vez em 401/403; o cliente do app não. O
  closure do app sempre pede `forcar=false`, então um 401 pode chegar como
  erro de protocolo (`Papagaio/Integracao/GranolaViewModel.swift:80-83`; `Papagaio/Integracao/ClienteMCP.swift:129-160`).
  Não confundir as duas árvores.

---

## 6. Sign in with Apple

### 6.1 O que está realmente autenticado

- O app solicita `fullName` e `email`, mas usa `credential.user` como
  identidade do perfil local; nome e email são apenas dados de perfil
  (`Papagaio/ViewModels/PerfilViewModel.swift:58-66`, `Papagaio/ViewModels/PerfilViewModel.swift:206-228`).
- `user` é guardado no Keychain; nome e email ficam em `UserDefaults` e são
  preservados quando Apple não os fornece em uma autorização posterior
  (`Papagaio/ViewModels/PerfilViewModel.swift:89-97`, `Papagaio/ViewModels/PerfilViewModel.swift:136-175`).
- No lançamento, `getCredentialState` é consultado; `.revoked`, `.notFound` e
  `.transferred` removem a credencial local
  (`Papagaio/ViewModels/PerfilViewModel.swift:51-56`, `Papagaio/ViewModels/PerfilViewModel.swift:118-133`).
- O app também observa `credentialRevokedNotification`
  (`Papagaio/ViewModels/PerfilViewModel.swift:33-42`).

`authorizationCode`, `identityToken`, `state` e `nonce` não são usados
[CONFIRMADO]. A Apple descreve `authorizationCode` como prova de autorização
para um servidor e `nonce` como valor verificável no identity token
[A11]. Como o app não autentica uma API própria neste lançamento, a
revalidação local e o Keychain são o contrato atual. Se houver um servidor, o
`nonce` e o `identityToken` devem ser tratados e validados nele, e o
`authorizationCode` deve ser usado no fluxo apropriado; não se deve inferir
que essa implementação já é um login de servidor.

O perfil local também não é a identidade de uma equipe CloudKit. O serviço
consulta `CKContainer.accountStatus` e `userRecordID` da conta iCloud do
container (`Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:152-165`, `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:387-390`); são
domínios de identidade separados.

---

## 7. EventKit, Contacts e prompt local

### 7.1 Permissões e dados acessados

| Caminho | Estado | Dados/limite | Evidência |
|---|---|---|---|
| `requestFullAccessToEvents()` | **CONFIRMADO / atual** | API de macOS 14 para solicitar leitura e escrita de eventos; o código apenas lê, mas precisa do acesso completo antes do fetch. | `Papagaio/Suporte/PromptDeEntidades.swift:61-69`; [A7] |
| `EKAuthorizationStatus.authorized` | **CONFIRMADO / deprecated** | Apple substituiu o caso legado por `.fullAccess`/`.writeOnly`; neste fluxo de leitura, `.fullAccess` é o estado pertinente. O target é macOS 26. | `Papagaio/Suporte/PromptDeEntidades.swift:61-68`; [A8] |
| Calendário | **CONFIRMADO** | Eventos ±15 minutos em torno do áudio; título e nome de attendees. `calendars:nil` não limita a busca a um calendário escolhido. | `Papagaio/Suporte/PromptDeEntidades.swift:27-40` |
| Contatos | **CONFIRMADO / atual** | Pedido por app via `requestAccess`; lê apenas nome próprio, sobrenome e organização. | `Papagaio/Suporte/PromptDeEntidades.swift:42-58`, `Papagaio/Suporte/PromptDeEntidades.swift:72-83`; [A9] |
| Prompt Whisper | **CONFIRMADO** | Até 40 termos normalizados; é um prior local, não correção automática. | `Papagaio/Suporte/PromptDeEntidades.swift:10-24`; `Papagaio/ViewModels/Biblioteca.swift:888-914` |
| Momento do consentimento | **CONFIRMADO** | A construção do prompt é chamada no processamento do áudio, não na inicialização. | `Papagaio/ViewModels/Biblioteca.swift:873-914` |

A Apple afirma que o pedido de acesso completo é necessário antes de buscar
eventos e que a recusa deve ser tratada [A7]. O app usa `try?` e callbacks
que podem devolver lista vazia, portanto a recusa não interrompe a
transcrição (`Papagaio/Suporte/PromptDeEntidades.swift:61-83`).

O texto é passado como `initialPrompt` ao motor local. Não há chamada de rede
nessas funções; isso não é prova de que nenhum outro componente do pipeline
possa enviar dados. A string de privacidade está presente no build, mas o
`Info.plist` final assinado não foi inspecionado.

### 7.2 Privacidade e limites

- Os termos de calendário vêm de uma janela de `15 * 60` segundos para cada
  lado da gravação (`Papagaio/Suporte/PromptDeEntidades.swift:27-35`).
- A lista final é limitada a 40 após normalização (`Papagaio/Suporte/PromptDeEntidades.swift:17-24`).
- Esses são limites de entrada, não medidas de latência ou de desempenho.

---

## 8. Keychain e tratamento de segredos

### 8.1 Itens e acessibilidade

| Item | Serviço/conta | Evidência |
|---|---|---|
| Google: access/refresh/expiração/PKCE | `papagaio:google-calendar` | `Papagaio/Integracao/GoogleCalendarViewModel.swift:29-30`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:303-309` |
| Granola: access/refresh/expiração/registro do cliente/PKCE | `papagaio:granola` | `Papagaio/Integracao/GranolaViewModel.swift:37-40`; `Papagaio/Integracao/SessaoOAuth.swift:231-233`, `Papagaio/Integracao/SessaoOAuth.swift:352-357` |
| Apple user ID | `com.papagaio.Papagaio.perfil` / `apple-user-identifier` | `Papagaio/ViewModels/PerfilViewModel.swift:14-19`, `Papagaio/ViewModels/PerfilViewModel.swift:136-160` |
| Acessibilidade | `kSecAttrAccessibleAfterFirstUnlock` | `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:14-27`; `Papagaio/ViewModels/PerfilViewModel.swift:136-146`; [A10] |

A Apple descreve `AfterFirstUnlock` como acessível após o primeiro
desbloqueio, até o próximo reinício, e recomendado para operações em
segundo plano; itens com esse atributo migram para outro dispositivo em
backup criptografado. `WhenUnlocked` é recomendado para itens necessários
apenas em primeiro plano
[A10]. Assim:

- **CONFIRMADO:** os itens podem ser acessados com o Mac bloqueado depois
  de qualquer primeiro desbloqueio da sessão.
- **PROVÁVEL:** isso amplia a janela em relação a uma política mínima para
  tokens usados pela UI; não prova comprometimento.
- **PROVÁVEL:** um refresh token pode migrar em backup conforme a política do
  usuário. `ThisDeviceOnly` deve ser escolhido apenas se a semântica de não
  migrar for desejada.

### 8.2 Robustez

- `CofreDeTokens.salvar` faz `SecItemDelete` e depois `SecItemAdd`; se o
  segundo passo falha, o valor anterior já foi removido
  (`PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:14-27`).
- Google e Granola chamam `try?` ao gravar tokens; uma falha de Keychain
  pode deixar a sessão aparente em andamento sem persistência
  (`Papagaio/Integracao/SessaoOAuthGoogle.swift:303-309`; `Papagaio/Integracao/SessaoOAuth.swift:352-357`).
- `contasExistentes` consulta atributos sem `kSecReturnData`, evitando retorno
  do segredo na abertura do app (`PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:46-65`).
- Não foi encontrado token ou refresh token em `UserDefaults`; o estado do
  Calendar guarda somente metadados (`Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:3-23`).
- Logout Google/Granola tenta revogar e apaga credenciais, mas a revogação é
  melhor esforço (`Papagaio/Integracao/SessaoOAuthGoogle.swift:111-122`; `Papagaio/Integracao/SessaoOAuth.swift:100-113`).
- Nenhum valor de Client ID, token, segredo ou conta foi lido de
  `Config/Secrets.xcconfig` para esta ficha.

---

## 9. Advisories oficiais e sandbox

| Advisory | Exposição local | Leitura correta |
|---|---|---|
| macOS Golden Gate 27, CVE-2026-20683, Apple Account/Sign in with Apple | O app usa `ASAuthorizationAppleIDProvider` | **PROVÁVEL/potencialmente afetado**: lançamento de 14/09; o build local `27.0 (26A428)` não foi mapeado ao patch. [A12] |
| macOS Golden Gate 27, CVE-2026-86905, Authentication Services/Keychain | O app usa Keychain e Sign in with Apple | **PROVÁVEL/potencialmente afetado** pelo mesmo motivo. [A12] |
| Xcode 27, CVE-2026-65393, acesso do IDE a dados sensíveis | O build usa `Xcode-beta 27.0 (27A5194q)` | **PROVÁVEL/potencialmente afetado**; o build exato não foi comparado com o lançamento de segurança. [A13] |
| Página macOS consultada sem entrada específica de CloudKit/EventKit | O app usa ambos | **Não é evidência de ausência de vulnerabilidade**; é apenas o resultado negativo da fonte consultada. |

O checklist de lançamento deve confirmar a versão exata do macOS e do Xcode,
atualizar ambos e repetir build/testes. Esta auditoria não alterou o
sistema.

### Privilégio de sandbox

`com.apple.security.cs.disable-library-validation` permite carregar frameworks,
plug-ins ou bibliotecas sem exigir assinatura da Apple ou o mesmo Team ID do
executável [A14]. O entitlement está habilitado no projeto e o build declara
hardened runtime (`Config/Papagaio.entitlements:19-22`;
`Loro.xcodeproj/project.pbxproj:452`). Como existem XCFrameworks locais, a
necessidade da exceção não foi demonstrada nem removida; trata-se de uma
pergunta de privilégio mínimo, não de vulnerabilidade confirmada.

---

## 10. Deprecações e evolução até 2026-09-23

| Item | Evolução consultada | Estado no app |
|---|---|---|
| EventKit `.authorized` | Deprecated no macOS 14; usar `.fullAccess`/`.writeOnly` [A8] | **CONFIRMADO / limpeza necessária**: o caso legado ainda é enumerado. |
| Contacts `requestAccess` | Continua vigente no SDK atual [A9] | **CONFIRMADO / conforme**. |
| CloudKit APIs de descoberta de identidades | `CKDiscoverAllUserIdentitiesOperation` e `CKDiscoverUserIdentitiesOperation` terminam em macOS 14 e são marcadas como não suportadas/deprecated no SDK atual; o guia recomenda o modelo de sharing. [A16] | Busca local = 0; o app não usa essas APIs. |
| Google loopback | Deprecated para clientes mobile/Chrome; recomendado para macOS/Linux/Windows Desktop [G1] | **CONFIRMADO / não é anti-padrão neste app**. |
| Google custom scheme | Não suportado em clientes Android/Chrome [G1] | O Google app usa loopback; o callback customizado é Granola/MCP, não Google Calendar. |
| Google OOB copy/paste | Deprecated e não suportado [G1] | **Não usado**. |
| Google Calendar quota | Modelo atualizado em 2026-05-01: 10.000/min/projeto, 600/min/usuário/projeto e 1.000.000/dia como threshold diário de cobrança [G6] | Referência atual; o tier efetivo do projeto não foi consultado. |
| MCP auth | `2025-03-26`: metadata RFC 8414 + DCR SHOULD; `2026-07-28`: Protected Resource Metadata, issuer, resource e Client ID Metadata Documents; DCR deprecated [M1][M4][M6] | App permanece na primeira revisão. |
| MCP lifecycle/transport | `2026-07-28` remove `initialize`, `Mcp-Session-Id` e GET stream; exige headers e metadata por request [M5][M6] | App precisa de cliente moderno ou fallback legado explícito. |
| Sign in with Apple nonce | Necessário para ligar identity token a uma sessão/backend; não é necessário para guardar apenas `user` local [A11] | **CONFIRMADO / não aplicável ao escopo atual**. |
| Comentário `ASWebAuthenticationSession` | O presenter efetivo usa `NSWorkspace` e callback customizado | **CONFIRMADO / drift documental**. |

---

## 11. Recomendações priorizadas

As recomendações são consequências desta ficha; nenhuma alteração foi feita
no código.

### P0 — antes de produção

1. **Atualizar e confirmar o patch** de macOS e Xcode; comparar o build
   exato com [A12][A13] e repetir build/testes.
2. **Trocar o redirect Granola** por loopback `127.0.0.1` com porta efêmera
   ou por HTTPS, validar o URI exato do callback e depois implementar o
   cliente MCP moderno com fallback legado controlado por revisão [M1][M5][R3].
3. **Definir a fonte de verdade dos registros públicos.** No modelo padrão,
   validar `creatorUserRecordID` contra o proprietário esperado, evitar
   duplicidade de código e não confiar em um marcador de exclusão apenas por
   ID/estado. Para exclusão, considerar um registro privado do proprietário, uma
   prova assinada ou um canal de notificação autenticado.
4. **Escolher entre link público e gestão privada por participante.** A API
   não permite misturar os dois; se `.readWrite` por URL for mantido, a UI
   não deve prometer permissões por arquivo que o CloudKit não aplica.

### P1 — integridade e operação

5. Usar `CKShare.Participant.participantID` para identidade persistente e
   remover o fallback `UUID()` [A2].
6. Persistir `CKServerChangeToken`, tratar exclusões, adicionar subscription e
   resync em `changeTokenExpired`; substituir a paginação em memória por
   uma estratégia de rede que não materialize toda a zona [A4].
7. Ler `CKErrorRetryAfterKey`, distinguir erros reexecutáveis de permanentes,
   tratar quota/schema por código e interromper tentativas de erros que
   exigem ação do proprietário [A5].
8. Corrigir o primeiro consentimento Google, persistir/verificar `scope`,
   avaliar `calendar.events.readonly` e tratar 403/429 com backoff e jitter
   [G1][G3][G6].
9. Migrar tokens de foreground para `WhenUnlocked` (ou `ThisDeviceOnly` por
   dispositivo), propagar erro de persistência e substituir
   a exclusão antes da inclusão por atualização transacional do item do Keychain [A10].
10. Remover e-mail de log Granola (`privacy: .private`) e nunca registrar
    callback, token, metadados sensíveis ou resposta de autorização.

### P2 — manutenção

11. Remover o caso EventKit deprecated `.authorized` e manter somente
    `.fullAccess` neste fluxo de leitura [A8].
12. Atualizar comentários que ainda dizem `ASWebAuthenticationSession` e
    “MCP exige DCR” para refletir o runtime e a revisão atual [M6].
13. Documentar schema/funções de produção, IDs de proprietário, política de
    backup do Keychain, dispositivos não suportados e o estado de verificação
    do OAuth Google. Esses são insumos operacionais que não estão no
    repositório.

---

## 12. Reprodução local e limitações

### 12.1 Arquivos/linhas cobertos

- Configuração: `Config/Papagaio.entitlements:5-36`,
  `Config/Info.plist:7-21`, `Config/Base.xcconfig:1-10`,
  `Loro.xcodeproj/project.pbxproj:431-514`.
- CloudKit: `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:40-548`,
  `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:82-422`,
  `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:55-202`.
- OAuth/API: `Papagaio/Integracao/SessaoOAuthGoogle.swift:68-622`,
  `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:5-240`,
  `Papagaio/Integracao/GoogleCalendarViewModel.swift:20-307`,
  `Papagaio/Modelos/ReuniaoPendenteCalendar.swift:4-52`,
  `Papagaio/Integracao/SessaoOAuth.swift:47-415`,
  `Papagaio/Integracao/ClienteMCP.swift:25-252`.
- Apple/EventKit/Keychain: `Papagaio/ViewModels/PerfilViewModel.swift:7-249`,
  `Papagaio/Suporte/PromptDeEntidades.swift:9-86`,
  `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:7-97`,
  `PapagaioCore/Sources/PapagaioCore/Integracao/ParticipanteDaReuniao.swift:3-65`.
- Schema documentado: `README.md:86-98`.

### 12.2 Reproduções estáticas seguras

Os comandos abaixo procuram apenas em arquivos de produto e configuração
não sensíveis. Eles não devem ser ampliados para `Config/Secrets.xcconfig`:

```bash
rg -n --glob '*.swift' 'CKShare|CKContainer|CKDatabase|CKRecord|CKErrorRetryAfterKey|CKError' Papagaio PapagaioCore PapagaioTests
rg -n --glob '*.swift' '127\.0\.0\.1|code_challenge|code_verifier|prompt|state|papagaio://|Mcp-Session-Id|MCP-Protocol-Version' Papagaio PapagaioCore PapagaioTests
rg -n --glob '*.swift' 'kSecAttrAccessible|requestFullAccessToEvents|EKAuthorizationStatus|CNContactStore|ASAuthorizationAppleIDProvider' Papagaio PapagaioCore PapagaioTests
rg -n 'CKSharingSupported|icloud-container|applesignin|network\.|personal-information' Config/Papagaio.entitlements Config/Info.plist Loro.xcodeproj/project.pbxproj
rg -n --glob '*.swift' 'CKDatabaseSubscription|CKRecordZoneSubscription|CKNotification|previousServerChangeToken|serverChangeToken|recordWithIDWasDeletedBlock' Papagaio PapagaioCore
```

Resultados estáticos usados na ficha: `fetchAllChanges` = 1;
`CKDatabaseSubscription`/`previousServerChangeToken` = 0; `MCP-Protocol-Version`
= 0 no cliente app; `publicPermission = .none` = 0; `removeParticipant` = 1.
Esses são números de ocorrências no código, não métricas de runtime.

### 12.3 Limitações

1. Nenhuma requisição autenticada ou não autenticada foi feita aos serviços de
   dados do CloudKit, às APIs do Google, ao Granola ou aos serviços de
   autenticação da Apple. Não há token, consentimento, payload de resposta,
   push, consumo de quota ou schema real observados.
2. Funções, índices, schema de produção, criadores, acesso por web service,
   containers e configuração real de sharing não estão no repositório.
3. O projeto do Google Cloud, o tipo e registro do OAuth client, a tela de
   consentimento, o tier de quota, a verificação de marca/escopo sensível e as
   políticas do Workspace não foram consultados. O Client ID é
   intencionalmente omitido.
4. A resposta real do Granola, os metadados OAuth, o DCR, o redirect URI, as
   ferramentas e as revisões suportadas não foram sondados. A aceitação do
   callback customizado é **HIPÓTESE**.
5. Não houve benchmark de CloudKit, Calendar, MCP, EventKit ou Keychain.
   Só foram registrados intervalos, contagens estáticas de chamadas, tamanhos
   de página e limites publicados; performance e latência não são conclusão.
6. O build exato do sistema operacional não foi comparado ao container do
   patch de segurança. “Potencialmente afetado” não equivale a “vulnerável
   confirmado”.
7. A baseline já continha alterações do usuário fora do escopo. Esta ficha
   não alterou esses arquivos, código, configuração, dependências ou
   serviços.

---

## 13. Fontes oficiais consultadas

Todas as fontes abaixo foram acessadas em **2026-09-23**. A coluna
“Versão/schema aplicável” identifica a revisão, plataforma ou schema que deve ser
usado na leitura; pontos antigos não são combinados com o estado atual sem
sinalização.

| ID | URL | Versão/schema aplicável | Ponto parafraseado | Acesso |
|---|---|---|---|---|
| A1 | [CKContainer.publicCloudDatabase](https://developer.apple.com/documentation/cloudkit/ckcontainer/publicclouddatabase) · [CKDatabase](https://developer.apple.com/documentation/cloudkit/ckdatabase) | CloudKit docs atuais; leitura disponível no macOS 10.10+; SDK medido MacOSX27 | Banco público disponível sem conta iCloud para leitura, legível por todos; cada usuário escreve os objetos que cria, com conta iCloud necessária para autoria; o portal permite atribuir roles. | 2026-09-23 |
| A2 | [CKShare.init(recordZoneID:)](https://developer.apple.com/documentation/cloudkit/ckshare/init%28recordzoneid:%29) · [CKShare.Participant](https://developer.apple.com/documentation/cloudkit/ckshare/participant) · [participantID](https://developer.apple.com/documentation/cloudkit/ckshare/participant/participantid) | macOS 12+ para compartilhamento de zona inteira; SDK medido MacOSX27 | O compartilhamento inclui a zona e seus registros; participantes públicos aceitam a URL; escrita pode modificar/apagar registros incluídos; `participantID` fornece o identificador do participante. | 2026-09-23 |
| A3 | [CKShare.publicPermission](https://developer.apple.com/documentation/cloudkit/ckshare/publicpermission) · [removeParticipant](https://developer.apple.com/documentation/cloudkit/ckshare/removeparticipant%28_%3A%29) | macOS 10.12+; regras atuais de configuração do compartilhamento | `.readWrite` permite a entrada de quem tiver a URL; modificar a lista exige `.none` e não permite misturar usuários públicos e privados. | 2026-09-23 |
| A4 | [CKFetchRecordZoneChangesOperation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation) | macOS 10.12+; documentação CloudKit atual | Token nulo/`fetchAllChanges` refaz o histórico; tokens podem ser cacheados; a orientação é fazer a primeira carga, assinar e buscar após push, sem polling obrigatório. | 2026-09-23 |
| A5 | [CKDatabase.save](https://developer.apple.com/documentation/cloudkit/ckdatabase/save%28_%3A%29-1j6fq) · [requestRateLimited](https://developer.apple.com/documentation/cloudkit/ckerror/requestratelimited) · [zoneBusy](https://developer.apple.com/documentation/cloudkit/ckerror/zonebusy) · [quotaExceeded](https://developer.apple.com/documentation/cloudkit/ckerror/quotaexceeded) · [limitExceeded](https://developer.apple.com/documentation/cloudkit/ckerror/limitexceeded) · [serverRecordChanged](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged) · [changeTokenExpired](https://developer.apple.com/documentation/cloudkit/ckerror/changetokenexpired) | Documentação CloudKit atual; MacOSX27 SDK | `save` exige registro novo/mais recente; retry-after, backoff, quota por banco, limites de 400 itens/2 MB, resolução de conflitos e token expirado. | 2026-09-23 |
| A6 | [CKRecord.ID](https://developer.apple.com/documentation/cloudkit/ckrecord/id) · [creatorUserRecordID](https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid) | Documentação CloudKit atual; macOS 10.10+ | ID único por banco; no público só um registro usa aquele ID; o criador é o usuário que criou o registro. | 2026-09-23 |
| A7 | [requestFullAccessToEvents](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents%28completion:%29) | EventKit macOS 14+; SDK medido MacOSX27 | Solicita acesso de leitura e escrita; deve ser solicitado antes da busca; o app trata a recusa. | 2026-09-23 |
| A8 | [EKAuthorizationStatus.authorized](https://developer.apple.com/documentation/eventkit/ekauthorizationstatus/authorized) | Deprecated no macOS 14+; usar `.fullAccess`/`.writeOnly` | O caso legado não deve ser usado para decisões de acesso no SDK atual. | 2026-09-23 |
| A9 | [CNContactStore.requestAccess](https://developer.apple.com/documentation/contacts/cncontactstore/requestaccess%28for:completionhandler:%29) | Contacts macOS 10.11+; SDK atual | Pedido por app; o sistema guarda a resposta e não pergunta novamente. | 2026-09-23 |
| A10 | [kSecAttrAccessibleAfterFirstUnlock](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock) · [kSecAttrAccessibleWhenUnlocked](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked) | Security macOS 10.9+ | `AfterFirstUnlock` é indicado para segundo plano e migra em backup; `WhenUnlocked` é recomendado para primeiro plano. | 2026-09-23 |
| A11 | [Sign in with Apple sample](https://developer.apple.com/documentation/authenticationservices/implementing-user-authentication-with-sign-in-with-apple) · [authorizationCode](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential/authorizationcode) · [identityToken](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential/identitytoken) · [nonce](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce) · [entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.applesignin) | AuthenticationServices macOS 10.15+; entitlement `Default` | O identificador do usuário serve ao perfil local; authorization code é para servidor; nonce verifica o identity token; a capability habilita o serviço. | 2026-09-23 |
| A12 | [macOS Golden Gate 27 security content](https://support.apple.com/en-us/149035) | macOS Golden Gate 27, lançado em 2026-09-14 | CVE-2026-20683 em Apple Account/Sign in with Apple e CVE-2026-86905 em Authentication Services/Keychain; exige atualização. | 2026-09-23 |
| A13 | [Xcode 27 security content](https://support.apple.com/en-us/149040) | Xcode 27, lançado em 2026-09-14 | CVE-2026-65393 no Xcode IDE; a versão do build deve ser comparada ao patch. | 2026-09-23 |
| A14 | [Disable Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) · [Network Server](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server) | macOS 10.7+; hardened runtime/sandbox | Exceção de validação de bibliotecas e permissão de escutar conexões de rede; não é evidência de vulnerabilidade. | 2026-09-23 |
| A15 | [Sharing CloudKit Data with Other iCloud Users](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users) | Guia CloudKit atual; schema de desenvolvimento/produção | O schema de produção precisa ser publicado; o fluxo de sharing deve ser validado com contas reais antes da distribuição. | 2026-09-23 |
| A16 | [CKDiscoverAllUserIdentitiesOperation](https://developer.apple.com/documentation/cloudkit/ckdiscoveralluseridentitiesoperation) · [CKDiscoverUserIdentitiesOperation](https://developer.apple.com/documentation/cloudkit/ckdiscoveruseridentitiesoperation) | macOS 10.12–14; SDK MacOSX27 | As operações de descoberta de identidades terminam em macOS 14 e o SDK as marca como não suportadas/deprecated; a evolução é o modelo de sharing. | 2026-09-23 |
| G1 | [OAuth 2.0 for iOS & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) | Guia para apps nativos, atualizado em 2026-09-14 | Para desktop, recomenda loopback, navegador do sistema, PKCE S256, `state` e nenhum segredo distribuído; orienta refresh e revogação. | 2026-09-23 |
| G2 | [OAuth best practices](https://developers.google.com/identity/protocols/oauth2/resources/best-practices) | Boas práticas OAuth do Google, atualizadas em 2026-05-20 | Recomenda armazenamento seguro, DPoP como endurecimento, `state`, invalidação de refresh tokens e tratamento dos escopos concedidos. | 2026-09-23 |
| G3 | [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth) | Google Calendar API v3, atualizado em 2026-09-03 | Compara `calendar.readonly` e `calendar.events.readonly`, recomenda menor privilégio e registra a observação sobre escopo sensível. | 2026-09-23 |
| G4 | [Events.list](https://developers.google.com/workspace/calendar/api/v3/reference/events/list) | Google Calendar API v3 | O endpoint aceita intervalo de tempo, paginação e parâmetros de sincronização; a resposta inclui eventos e metadados da página. | 2026-09-23 |
| G5 | [Calendar incremental synchronization](https://developers.google.com/workspace/calendar/api/guides/sync) | Google Calendar API v3, atualizado em 2026-09-11 | Recomenda carga inicial, persistir `nextSyncToken`, sincronização incremental, entradas excluídas e nova carga completa em 410. | 2026-09-23 |
| G6 | [Calendar quotas](https://developers.google.com/workspace/calendar/api/guides/quota) · [errors](https://developers.google.com/workspace/calendar/api/guides/errors) | Calendar API v3; quotas alteradas em 2026-05-01; documentação atualizada em 2026-09-11 | 10.000/min/projeto, 600/min/usuário/projeto e 1.000.000/dia como threshold diário de cobrança; orienta backoff exponencial e o tratamento de 403/429 e 410. | 2026-09-23 |
| G7 | [Google OAuth/OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect) | OAuth/OIDC do Google atual; tabela de parâmetros | `prompt=none` não exibe telas de autenticação/consentimento e retorna erro sem autenticação ou consentimento prévios; `state` e campos da resposta de token são documentados. | 2026-09-23 |
| G8 | [Sensitive scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) · [OAuth app state](https://developers.google.com/identity/protocols/oauth2/production-readiness/overview) · [OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies) | OAuth do Google atual; página de escopo sensível atualizada em 2026-08-19 e políticas modificadas em 2026-08-05 | A leitura de eventos do Calendar é citada como dado sensível; apps externos públicos podem exigir verificação; estado e controles administrativos são externos ao repositório. | 2026-09-23 |
| M1 | [MCP Authorization 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization) | Revisão MCP 2025-03-26 | OAuth 2.1, PKCE, metadata RFC 8414, SHOULD para DCR, Bearer token e regra de redirect localhost/HTTPS. | 2026-09-23 |
| M2 | [MCP Lifecycle 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle) | Revisão MCP 2025-03-26 | `initialize` primeiro, versão negociada, notificação `initialized` e desconexão em versão incompatível. | 2026-09-23 |
| M3 | [MCP Transports 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports) | Revisão MCP 2025-03-26 | Streamable HTTP com POST/Accept, ID de sessão, GET SSE e comportamento de reinicialização após 404. | 2026-09-23 |
| M4 | [MCP Authorization 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization) | Revisão MCP 2026-07-28 | Protected Resource Metadata, descoberta AS/OIDC, validação de issuer, indicadores de recurso/audience, preferência por Client ID Metadata e depreciação de DCR. | 2026-09-23 |
| M5 | [MCP Streamable HTTP 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http) | Revisão MCP 2026-07-28 | Remove GET stream e sessões de protocolo; exige headers de metadata da requisição e `_meta`; define fallback moderno/legacy. | 2026-09-23 |
| M6 | [MCP changelog 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/changelog) | Mudanças desde 2025-11-25 | Remove sessões/`initialize`/GET; adiciona discovery e metadata por requisição; deprecia DCR. | 2026-09-23 |
| R1 | [RFC 6749 — OAuth 2.0](https://www.rfc-editor.org/rfc/rfc6749.html) | OAuth 2.0, outubro de 2012 | Authorization Code, refresh, `state`/CSRF e codificação de parâmetros como base. | 2026-09-23 |
| R2 | [RFC 7636 — PKCE](https://www.rfc-editor.org/rfc/rfc7636.html) | PKCE, setembro de 2015 | Verificador unreserved de 43–128 caracteres, S256 e verifier no endpoint de token. | 2026-09-23 |
| R3 | [RFC 8252 — OAuth Native Apps](https://www.rfc-editor.org/rfc/rfc8252.html) | BCP 212, outubro de 2017 | Navegador externo, PKCE, private-use URI scheme em domínio reverso, loopback e exigência de `state` no callback. | 2026-09-23 |
| R4 | [RFC 8414 — AS Metadata](https://www.rfc-editor.org/rfc/rfc8414.html) | Metadata OAuth, junho de 2018 | Metadata well-known via HTTPS, validação de issuer/endpoints e validação do certificado TLS. | 2026-09-23 |
| R5 | [RFC 8707 — Resource Indicators](https://www.rfc-editor.org/rfc/rfc8707.html) | Resource Indicators, fevereiro de 2020 | `resource` vincula o token solicitado ao recurso protegido/audience pretendido. | 2026-09-23 |
| R6 | [RFC 9700 — OAuth Security BCP](https://www.rfc-editor.org/rfc/rfc9700.html) | BCP 240, janeiro de 2025 | PKCE, redirects exatos, CSRF, audience/tokens vinculados ao remetente e proteção de refresh tokens. | 2026-09-23 |
| R7 | [RFC 7591 — Dynamic Client Registration](https://www.rfc-editor.org/rfc/rfc7591.html) | DCR, julho de 2015 | Metadata de registro, cliente público `none`, resposta com ID/segredo e segurança de transporte. | 2026-09-23 |

**Fim da ficha.** Nenhum serviço de dados ou autenticação de produto foi
executado, nenhum segredo foi transcrito e somente este arquivo foi escrito por
esta revisão.

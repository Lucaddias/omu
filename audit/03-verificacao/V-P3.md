# V-P3 — Verificação independente de `cloudkit-integracoes.md`

> **Data da verificação:** 2026-09-23  
> **Alvo:** `audit/01-pesquisa/cloudkit-integracoes.md:1-769`  
> **Escopo de escrita:** somente `audit/03-verificacao/V-P3.md`  
> **Modo:** leitura integral do alvo e do código/configuração relevante, busca
> estática, consulta de documentação oficial e inspeção local de assinatura de
> binários. Não houve OAuth, CloudKit, push, chamada autenticada aos serviços de
> produto, leitura de `Config/Secrets.xcconfig`, alteração de dependência,
> build ou mudança de código/configuração.

## 1. Resultado executivo

**Veredito global: CONFIRMADO COM AJUSTE.** A ficha é tecnicamente forte, cita
fontes oficiais alcançáveis e evita afirmar que o app está vulnerável apenas por
usar APIs relevantes. Porém, ela chama controles OAuth de plenamente conformes
sem provar a fonte criptográfica dos verificadores PKCE, afirma que lotes locais
de CloudKit têm um ou dois itens quando um caminho pode acumular IDs ilimitados
e trata a rotação do share como uma operação bem-sucedida apesar do ID fixo do
`CKRecordNameZoneWideShare`. O cliente MCP também não segue integralmente a
sequência de autorização da revisão que a própria ficha diz implementar.

### Contagens

| Métrica | Resultado |
|---|---:|
| Claims atômicos verificados | **59** |
| `CONFIRMADO` | **44** |
| `CONFIRMADO COM AJUSTE` | **10** |
| `REFUTADO` | **2** |
| `INCONCLUSIVO` | **3** |
| URLs do autor | **58** |
| URLs do autor com HTTP 200 e sem redirect | **58/58** |
| URLs suplementares oficiais | **6/6** com HTTP 200 e sem redirect |
| Divergências materiais | **9** |
| Omissões materiais | **13** |
| Correções de texto proposals | **7** |

As três inconclusivas são exclusivamente estados externos: configuração real do
OAuth Client do Google e políticas do Workspace; schema, índices, roles e
containers de produção do CloudKit; e suporte real do Granola às revisões,
metadados, redirect, DCR e tools.

## 2. Método e critérios

### 2.1 Vereditos

- **CONFIRMADO** — a afirmação é sustentada diretamente por código,
  configuração, baseline ou texto oficial aplicável.
- **CONFIRMADO COM AJUSTE** — o núcleo factual existe, mas a redação, o nível de
  conformidade ou a omissão de uma dependência precisa ser corrigida.
- **REFUTADO** — a evidência local/oficial contradiz a afirmação específica.
- **INCONCLUSIVO** — o fato depende de estado externo não observado e não pode ser
  confirmado só pelo repositório.

### 2.2 Reprodução de evidência

1. As referências `arquivo:linha` abaixo foram relidas no worktree em
   2026-09-23; não são cópias das referências da P3.
2. As **58 URLs distintas** da seção de fontes da P3 foram extraídas e
   verificadas sem seguir redirects. Todas responderam HTTP 200 e
   `num_redirects=0`.
3. Páginas Apple HTML que servem apenas como shell foram verificadas nos
   endpoints JSON DocC oficiais equivalentes
   (`/tutorials/data/documentation/...json`), usando o conteúdo de
   `primaryContentSections`, `deprecationSummary` e metadados.
4. Foram reinspecionados os comandos seguros de presença/ausência, inclusive
   `CKDatabaseSubscription`, tokens, headers MCP, delete callbacks e
   `encryptedValues`; eles contam ocorrências no código, não uso em runtime.
5. Os três XCFrameworks locais foram inspecionados com `codesign -d/-dv` e
   `codesign --verify --strict --verbose=2`, sem reassinatura ou escrita.

### 2.3 Fronteiras

- HTTP 200 comprova reachability, não autenticidade do servidor, configuração
  do produto ou permanência futura do conteúdo.
- O modelo padrão público do CloudKit não substitui as roles e políticas reais
  do container de produção.
- A existência de um callback `papagaio://` no código não prova que o Granola o
  aceite, nem que o servidor real suporte a revisão MCP alegada.
- Assinaturas inspecionadas são as dos artefatos locais atuais; não são o
  Release distribuído e assinado da Apple.

---

## 3. Matriz de claims — CloudKit, ACL e estabilidade

| Claim | Veredito | Evidência reproduzida e decisão V-P3 |
|---|---|---|
| **CK-01** — Cada equipe usa zona privada do proprietário, share de zona inteira, `Conversa` em `CKAsset`; índice e marcador públicos não transportam a conversa. | **CONFIRMADO** | `ServicoDeEquipesCloudKit.swift:40-68`, `:90-105`, `:410-415`; `SincronizadorDaBibliotecaCloudKit.swift:156-175`, `:331-368`; [A2]. |
| **CK-02** — No modelo padrão, cada usuário escreve os objetos públicos que cria; a alegação anterior de que qualquer conta sobrescreve livremente qualquer registro é falsa. | **CONFIRMADO** | [A1] diz “users have write access to the records … they create”; [A6] confirma unicidade do ID no banco público. A correção da P3 é correta. Roles customizadas continuam externas. |
| **CK-03** — O índice por código não valida `creatorUserRecordID` nem impõe unicidade do valor `codigoDeEntrada`; duplicados podem produzir sombreamento e `first` não define vencedor. | **CONFIRMADO** | A consulta e o consumo de somente `first` estão em `ServicoDeEquipesCloudKit.swift:94-105`; o save não fornece ID derivado do código em `:410-415`. A exploração depende de o campo estar consultável e de roles/taxas reais. |
| **CK-04** — O marcador público de exclusão não vincula estado a um proprietário esperado; um registro prévio com `estadoDaExclusao == "concluida"` é aceito para limpeza local. | **CONFIRMADO COM AJUSTE** | `ServicoDeEquipesCloudKit.swift:285-317`, `:518-520`; `ContentView.swift:758-782`; [A1][A6]. A ausência de vínculo é fato; a preempção por terceiro e o efeito real dependem do estado do ID, índice e roles. |
| **CK-05** — O código tem alfabeto 32 e seis posições (`32^6 = 2^30`); ele localiza uma URL de share `.readWrite` e não é a fronteira de autorização do share. | **CONFIRMADO** | `EquipeDisponivel.swift:134-137`; `ServicoDeEquipesCloudKit.swift:59-73`, `:381-385`, `:410-415`; [A2][A3]. |
| **CK-06** — `visibilidadeDosArquivos` é estado local; não existe ACL por registro. Participantes com escrita podem alterar/apagar qualquer registro incluído no share. | **CONFIRMADO** | `EquipeDisponivel.swift:29-32`; `ServicoDeEquipesCloudKit.swift:59-68`; [A2]. Isso torna inadequate prometer “somente administradores” no nível CloudKit. |
| **CK-07** — O código altera/remove participantes enquanto `publicPermission` continua público; a Apple exige `.none` para modificar a lista e proíbe misturar usuários públicos e privados. | **CONFIRMADO** | `ServicoDeEquipesCloudKit.swift:213-239`, `:381-385`; [A3] contém literalmente as duas regras. O erro real do serviço não foi executado. |
| **CK-08** — `idDoParticipante` cai para `UUID()` quando record ID/e-mail não estão disponíveis, produzindo identificadores não persistentes. | **CONFIRMADO** | `ServicoDeEquipesCloudKit.swift:481-495`; [A2] documenta `participantID`. |
| **CK-09** — O download usa `fetchAllChanges = true`, não mantém token e materializa todos os registros/assets antes de paginar 200 em memória. | **CONFIRMADO** | `SincronizadorDaBibliotecaCloudKit.swift:178-197`, `:212-270`; [A4]. |
| **CK-10** — Cada envio faz uma leitura e um `save`; o tratamento de conflito não usa as três cópias do `serverRecordChanged` fornecidas pela Apple. | **CONFIRMADO** | `SincronizadorDaBibliotecaCloudKit.swift:156-175`, `:274-283`; `Biblioteca.swift:1143-1171`; [A5]. |
| **CK-11** — Não há callback de exclusão no download e não há subscriptions/change tokens no cliente; portanto um registro remoto ausente não é removido por essa rota. | **CONFIRMADO** | `SincronizadorDaBibliotecaCloudKit.swift:247-270`, `:371-393`; `Biblioteca.swift:1138-1171`; busca local dos símbolos citados na P3 retornou zero. A permanência em produção é condicional ao comportamento real, mas a falta de tratamento é direta. |
| **CK-12** — A fila não lê `CKErrorRetryAfterKey`, satura em dez tentativas e continua agendando a cada 15 minutos para quota/erros não classificados. | **CONFIRMADO** | `FilaPersistenteCloudKit.swift:152-170`, `:199-202`; `Biblioteca.swift:1095-1135`; [A5]. |
| **CK-13** — A Apple publica 400 itens/2 MB, mas a afirmação “os lotes locais têm um ou dois itens” torna o limite de contagem pouco relevante. | **REFUTADO** | O limite está corretamente em [A5]. Porém `invalidarCodigoAnterior` acumula todos os IDs encontrados e os deleta atomicamente, sem chunk: `ServicoDeEquipesCloudKit.swift:418-432`. Esse lote não tem limite local de 1–2. |
| **CK-14** — A rotação troca o share, invalida o antigo e publica URL nova. | **CONFIRMADO COM AJUSTE** | A intenção e a sequência aparecem em `ServicoDeEquipesCloudKit.swift:242-273`, mas todo share de zona recebe o ID fixo `CKRecordNameZoneWideShare` [S2]. O código salva `novo` e deleta `antigo.recordID` no mesmo lote atômico (`:251-263`), embora ambos tenham o mesmo record ID. Isso é forte indício de operação inválida/conflito; o erro exato requer teste real. |
| **CK-15** — O banco público não permite zonas customizadas; os dois registros públicos sem `zoneID` usam a zona default. | **CONFIRMADO** | `ServicoDeEquipesCloudKit.swift:410-415`, `:518-520`; [S1] diz “You can’t create custom zones in a public database”. A P3 chegou ao fato, mas [A1][A6] não são a fonte textual direta desse trecho. |
| **CK-16** — Tipos, campos, índice consultável, ambiente, containers, roles de produção e web services estão corretos. | **INCONCLUSIVO** | `README.md:86-98` e o cliente provam apenas o contrato requerido. O console/container real não foi consultado. A própria P3 admite essa limitação em `:117-137` e `:695-704`. |
| **CK-17** — O cliente não solicita `encryptedValues`; o payload compartilhado inclui metadados, transcrição, notas e resumo, enquanto mídia local é removida do payload. | **CONFIRMADO** | `SincronizadorDaBibliotecaCloudKit.swift:156-175`, `:331-368`; busca por `encryptedValues` = 0. Isso não prova nem refuta criptografia em repouso do serviço Apple. |

### ACL/roles — leitura consolidada

- **Share privado/compartilhado:** `.readWrite` é aplicado à zona inteira. A
  Apple confirma que participantes com escrita podem modificar/apagar qualquer
  registro incluído [A2]. Controles de proprietário, configuração e nomes no
  cliente não são ACL do CloudKit.
- **Banco público:** leitura global e escrita pelos criadores no modelo padrão
  [A1]. Duplicados de índice e marcadores não autenticados continuam
  integridade/anti-abuso do cliente, não autorização garantida pelo serviço.
- **Roles:** podem mudar o comportamento real [A1], mas não estavam no
  repositório. Nenhuma conclusão sobre a política de produção foi feita.
- **Fonte insuficiente:** A15 sustenta sharing/schema/CKSharingSupported de forma
  geral, mas não declara explicitamente “publicar em produção” no trecho
  consultado. `README.md:86-98` e [S3] são evidência mais direta para as
  afirmações locais.

---

## 4. Matriz de claims — Google Calendar/OAuth

| Claim | Veredito | Evidência reproduzida e decisão V-P3 |
|---|---|---|
| **G-01** — O app nativo usa navegador do sistema, loopback `127.0.0.1` em porta efêmera, public client sem segredo distribuível e guarda tokens no Keychain. | **CONFIRMADO** | `SessaoOAuthGoogle.swift:73-78`, `:124-157`, `:187-193`, `:221-245`, `:303-309`, `:367-413`; [G1][G2]. Isso confirma o padrão implementado, não o tipo registrado no console. |
| **G-02** — O OAuth Client configurado no Google Cloud é do tipo `Desktop app`. | **INCONCLUSIVO** | [G1] diz para configurar `Desktop app`, mas o console não foi consultado. O bundle/projeto local prova apenas que o software alvo é macOS nativo. A P3 deveria marcar o tipo efetivo como externo, não confirmado. |
| **G-03** — O PKCE tem 96 caracteres, alfabeto unreserved, S256 base64url sem padding e o verifier é enviado no token exchange. | **CONFIRMADO** | `SessaoOAuthGoogle.swift:196-211`, `:221-245`, `:329-337`; [G1][R2]. |
| **G-04** — O PKCE Google é plenamente conforme, inclusive entropia criptográfica. | **CONFIRMADO COM AJUSTE** | O formato está correto, mas o verificador é produzido por 96 chamadas a `alfabeto.randomElement()` (`SessaoOAuthGoogle.swift:329-337`). [G1] exige “high-entropy cryptographic random string”; [R2] exige string criptograficamente aleatória. O código não demonstra esse contrato. Isso não prova RNG fraca; impede a afirmação de conformidade plena. |
| **G-05** — `state` é UUID por fluxo, o callback exige `/oauth/callback`, compara o state e o listener fica no loopback. | **CONFIRMADO** | `SessaoOAuthGoogle.swift:124-130`, `:187-193`, `:367-481`; [G1]. O baseline confirma o travamento de shutdown já citado pela P3 em `audit/00-mapa.md:396-412`. |
| **G-06** — `prompt=none` é enviado sempre; sem autenticação/consentimento prévio para os scopes, o primeiro botão não consegue concedê-los. | **CONFIRMADO** | `SessaoOAuthGoogle.swift:196-211`; [G7] define `none` e o erro quando não há autenticação/consentimento prévios. “Tende a falhar” pode ser reforçado para “falha nesses casos”. |
| **G-07** — `calendar.readonly` concede leitura de qualquer calendário acessível; `calendar.events.readonly` é mais estreito para os endpoints observados, mas a troca final é externa ao produto. | **CONFIRMADO** | Scope em `SessaoOAuthGoogle.swift:78`; [G3][G4]. A P3 corretamente evita chamar a troca de correção obrigatória sem validar o produto. |
| **G-08** — O cliente não persiste/compara o `scope` retornado; usa Keychain, mas engole falhas de persistência com `try?`. | **CONFIRMADO** | `SessaoOAuthGoogle.swift:275-309`, `:395-399`; [G1][G2]. Google exige verificar os scopes efetivamente concedidos. |
| **G-09** — Após a carga inicial, a UI consulta 24 horas a cada 15 minutos; são quatro listagens-base/hora, mais páginas e `events.get` sob demanda. | **CONFIRMADO** | `GoogleCalendarViewModel.swift:152-181`; `FonteGoogleCalendarAPI.swift:101-150`. A contagem é agenda estática, não medição de latência. |
| **G-10** — A API não usa `syncToken` nem trata 410. | **CONFIRMADO COM AJUSTE** | `FonteGoogleCalendarAPI.swift:101-150` confirma a ausência. A correção recomendada precisa manter a mesma query entre sincronizações: [G4] proíbe combinar `syncToken` com `timeMin`, `timeMax`, `orderBy` e proíbe `showDeleted=false`; [G5] exige limpeza e sincronização completa em 410. Portanto não basta acrescentar `syncToken` ao request atual. |
| **G-11** — Push é alternativa mais eficiente que polling. | **CONFIRMADO** | [G6] chama polling repetido de anti-pattern e push de alternativa dramaticamente mais eficiente. |
| **G-12** — Push pode substituir diretamente o timer neste app desktop local. | **CONFIRMADO COM AJUSTE** | [G6] sustenta a eficiência, mas [S5] exige receptor HTTPS com certificado válido e canal `watch` por recurso. Não há backend no repositório; falta um endpoint HTTPS alcançável, que é dependência de implantação. |
| **G-13** — Não há backoff/jitter específico para 403/429; a próxima tentativa depende do timer. | **CONFIRMADO** | `FonteGoogleCalendarAPI.swift:137-140`; `GoogleCalendarViewModel.swift:169-181`; [G6]. |
| **G-14** — Os limites publicados são 10.000/min/projeto, 600/min/usuário/projeto e 1.000.000/dia como threshold; o polling descrito não é, por si só, prova de violação. | **CONFIRMADO** | [G6]. A ressalva correta é que projeto, tier e Workspace policy reais não foram consultados. |
| **G-15** — O estado de Calendar persiste snapshots com título, horário, participantes e descrição em `UserDefaults`, não apenas IDs. | **CONFIRMADO** | `ReuniaoPendenteCalendar.swift:4-10`; `ParticipanteDaReuniao.swift:3-14`; `EstadoDasReunioesCalendar.swift:3-23`, `:70-82`. |

---

## 5. Matriz de claims — Granola, OAuth e MCP

| Claim | Veredito | Evidência reproduzida e decisão V-P3 |
|---|---|---|
| **M-01** — O app executa `Papagaio/Integracao/ClienteMCP.swift`; o cliente de `PapagaioCore` é outra árvore e não prova o runtime do app. | **CONFIRMADO** | `GranolaViewModel.swift:69-85`; clientes em `Papagaio/Integracao/ClienteMCP.swift:25-252` e `PapagaioCore/.../ClienteMCP.swift:101-316`. |
| **M-02** — O cliente app envia `initialize`, `notifications/initialized` e `Mcp-Session-Id` na revisão `2025-03-26`. | **CONFIRMADO** | `Papagaio/Integracao/ClienteMCP.swift:25-35`, `:89-125`, `:129-149`; [M2][M3]. |
| **M-03** — O cliente implementa a sequência de autorização da revisão `2025-03-26`. | **CONFIRMADO COM AJUSTE** | A revisão antiga determina request MCP sem token → 401 → iniciar OAuth [M1]. O app chama `obterToken(false)` antes de montar/enviar o primeiro POST (`Papagaio/Integracao/ClienteMCP.swift:129-140`), o que pode disparar OAuth preemptivamente. Portanto “cliente plausível legado” precisa ser “subconjunto legacy com divergência de sequência”. |
| **M-04** — A revisão `2026-07-28` remove lifecycle handshake, sessão e GET stream e exige headers/metadata por request. | **CONFIRMADO** | [M5][M6] e o changelog descrevem exatamente essas mudanças. O app não implementa a era moderna. |
| **M-05** — `papagaio://oauth/callback` viola a regra de redirect localhost/HTTPS tanto em `2025-03-26` quanto em `2026-07-28`. | **CONFIRMADO** | `Info.plist:7-16`; `SessaoOAuth.swift:194-208`, `:238-283`; [M1][S6]. A P3 acertou a permanência da regra na revisão moderna. |
| **M-06** — O scheme `papagaio` não é domínio reverso e não satisfaz RFC 8252 §7.1. | **CONFIRMADO** | `Info.plist:10-15`; `SessaoOAuth.swift:204-245`; [R3]. `CFBundleURLName = br.com.papagaio.oauth` não transforma o scheme em reverse-DNS. |
| **M-07** — A descoberta de metadados AS e DCR são estruturalmente compatíveis com `2025-03-26`. | **CONFIRMADO COM AJUSTE** | URL base, metadados e fallback: `SessaoOAuth.swift:117-162`; request DCR: `:194-235`; [M1][R7]. “Estruturalmente” está correto; não significa metadados/registro validados nem conformidade completa. |
| **M-08** — O cliente não valida issuer, não limita endpoints descobertos a HTTPS e não envia `resource`/audience. | **CONFIRMADO** | `SessaoOAuth.swift:120-151`, `:238-312`; [R4][R5][M4]. [R4] exige issuer idêntico; [R5] vincula audience; [M4] torna `resource` obrigatório na era moderna. |
| **M-09** — PKCE S256 do Granola está plenamente conforme. | **CONFIRMADO COM AJUSTE** | Formato correto em `SessaoOAuth.swift:238-256`, `:371-381`; a mesma limitação de `randomElement()` impede comprovar entropia criptográfica [R2][M4][S6]. |
| **M-10** — O state é comparado, mas o callback não valida scheme/host/path exatos. | **CONFIRMADO** | `ApresentadorDeSessaoDeAutorizacao.swift:16-29`; `GerenciadorDeCallbackDeAutorizacao.swift:19-52`; [R3][R6]. PKCE/state reduzem impacto, mas não cumprem a proteção mix-up completa. |
| **M-11** — Refresh token inválido continua sendo retido e reutilizado. | **CONFIRMADO** | `SessaoOAuth.swift:289-312`, `:331-349` não apagam o segredo no erro. |
| **M-12** — O pedido DCR declara corretamente `none`, mas resposta e revogação exigem ajuste para o cliente público. | **CONFIRMADO COM AJUSTE** | O request pede `none` (`SessaoOAuth.swift:202-230`), mas a resposta não é validada; se omitir auth method, o default RFC é `client_secret_basic`, não `none` [R7]. A revogação monta Basic `id:` mesmo quando o cliente é público [SessaoOAuth.swift:314-328]. A P3 não registra esse desvio. |
| **M-13** — O cliente app não trata 401/403 com refresh, não reinicializa em 404 de sessão, não valida a versão retornada e faz parser SSE por concatenação de linhas `data:`. | **CONFIRMADO** | `Papagaio/Integracao/ClienteMCP.swift:102-124`, `:129-187`; [M2][M3]. O closure do app sempre chama `forcar=false` (`GranolaViewModel.swift:80-83`). |
| **M-14** — Log de Granola publica `conta.email` e o cliente usa `URLSession.data(for:)` para SSE. | **CONFIRMADO** | `GranolaViewModel.swift:80-95`; `Papagaio/Integracao/ClienteMCP.swift:142-187`. A P3 não encontrou token em log; isso não exclui biblioteca/futuro. |
| **M-15** | Granola aceita o callback, Metadata, DCR, redirect e versões MCP alegados e entrega os quatro tools com os schemas atuais. | **INCONCLUSIVO** | Nenhuma chamada autenticada ou endpoint real do Granola foi exercitado. `FonteGranola.swift:9-130` prova apenas o schema que o cliente espera, não o servidor. |

---

## 6. Matriz de claims — Apple local, EventKit, Contacts, Keychain, advisories e supply chain

| Claim | Veredito | Evidência reproduzida e decisão V-P3 |
|---|---|---|
| **O-01** | Sign in with Apple cria um perfil local; `user` é a identidade e é revalidado. | **CONFIRMADO** | `PerfilViewModel.swift:51-66`, `:118-147`, `:206-228`; [A11]. A identidade Apple é separada de `CKContainer.userRecordID()` em `ServicoDeEquipesCloudKit.swift:152-165`, `:387-390`. |
| **O-02** | A ausência de `authorizationCode`, `identityToken`, `nonce` e `state` não é, isoladamente, defeito no app local. | **CONFIRMADO** | `PerfilViewModel.swift:58-67`, `:206-228`; [A11]. Se um backend for adicionado, nonce/token/code passam a ser dependências desse contrato. |
| **O-03** | Tokens Google/Granola e Apple user ID usam `kSecAttrAccessibleAfterFirstUnlock`, permanecem acessíveis após first unlock e migram em backup criptografado. | **CONFIRMADO** | `CofreDeTokens.swift:14-27`; `PerfilViewModel.swift:136-146`; [A10]. `WhenUnlocked` é a recomendação Apple para foreground. |
| **O-04** | A cofre faz delete-before-add e os callers OAuth ignoram erro de persistência. | **CONFIRMADO** | `CofreDeTokens.swift:14-27`; `SessaoOAuthGoogle.swift:303-309`; `SessaoOAuth.swift:352-357`. Falha no add pode perder o valor anterior. |
| **O-05** | EventKit pede full access e ainda enumera `.authorized`, deprecated no macOS 14. | **CONFIRMADO** | `PromptDeEntidades.swift:61-69`; [A7][A8]. O estado de leitura pertinente é `.fullAccess`. |
| **O-06** | Contacts usa `requestAccess`, lê only given/family/organization e o prompt final tem no máximo 40 termos. | **CONFIRMADO** | `PromptDeEntidades.swift:10-24`, `:42-58`; [A9]. |
| **O-07** | Sandbox, iCloud/CloudKit, APNs, Calendar, Contacts, network client/server, library validation, `CKSharingSupported` e privacy strings estão presentes na configuração declarada. | **CONFIRMADO** | `Papagaio.entitlements:5-36`; `Info.plist:7-21`; `project.pbxproj:450-465`, `:490-505`. Isso não valida o binário final assinado. |
| **O-08** | Os três advisories tornam o build/local potencialmente afetado, mas não confirmam vulnerabilidade. | **CONFIRMADO** | [A12][A13]; `audit/00-mapa.md:31-39`. A P3 preserva corretamente “potencialmente afetado”. |
| **O-09** | A exceção de library validation é apenas uma pergunta de privilégio mínimo. | **CONFIRMADO COM AJUSTE** | Entitlement e hardened runtime: `Papagaio.entitlements:19-22`; `project.pbxproj:447-452`; [A14]. `Package.swift:18-27` usa três binários locais. `codesign --verify --strict` rejeitou os três objetos; whisper/llama reportaram metadata ad-hoc, ONNX unsigned. Isso não prova comprometimento, mas torna a necessidade da exceção concreta e deve constar da revisão. |
| **O-10** | O inventário de segurança/configuração da P3 está completo. | **REFUTADO** | A lista de arquivos cobertos (`cloudkit-integracoes.md:653-673`) não inclui `PapagaioCore/Package.swift`, `Package.resolved` ou `Scripts/bootstrap-runtimes.sh`, apesar de três XCFrameworks locais e disable-library-validation. |
| **O-11** | As 58 URLs citadas pela P3 estão reachables e sem redirect em 2026-09-23. | **CONFIRMADO** | Extração distinta + GET sem seguir redirect: 58/58 HTTP 200, `num_redirects=0`. A matriz completa está na §9. |
| **O-12** | Produto, deployment, Swift, SDK e versões declaradas foram transcritos corretamente. | **CONFIRMADO** | `project.pbxproj:431-474`, `:490-514`; `Package.swift:1-6`; `audit/00-mapa.md:31-57`. |

---

## 7. Divergências materiais

| ID | Divergência | Impacto e correção necessária |
|---|---|---|
| **DV-01** | P3 trata PKCE Google e Granola como plenamente conforme, mas ambos usam `String.randomElement()` sem garantia criptográfica explícita. | **Alto.** O formato S256 está correto; a conformidade de entropia não está demonstrada. Usar API claramente CSPRNG (`SecRandomCopyBytes`/framework auditado) e testar unicidade/formato. |
| **DV-02** | A ficha mistura “app macOS nativo” com “OAuth Client `Desktop` confirmado”. | **Médio.** O tipo no Google Cloud é externo. Separar o padrão implementado do credential real. |
| **DV-03** | “Lotes locais têm um ou dois itens” é falso para `invalidarCodigoAnterior`. | **Médio.** O lote pode ter qualquer número de matches; o limite de 400 continua aplicável e deve guide chunking. |
| **DV-04** | Rotacionar share é descrita como troca bem-sucedida, apesar do ID fixo e save/delete do mesmo ID no mesmo batch. | **Alto.** Tratar como defeito potencial até testar em container real; não afirmar invalidação旧 URL concluída. |
| **DV-05** | A P3 não destaca que duplicates externos podem bloquear `invalidarCodigoAnterior`: no modelo creator-only, um único ID de terceiro no lote atômico pode impedir a invalidação. | **Alto.** Filtrar autor/creator, dividir lotes e tornar a rotação/exclusão resiliente a duplicatas. |
| **DV-06** | O cliente MCP é chamado “plausível 2025-03-26”, mas obtém token antes de qualquer request/401. | **Alto.** Não afirmar conformidade legacy completa; implementar probe 401→OAuth e fallback explícito. |
| **DV-07** | DCR response e revogação não são validados; Basic é montado para cliente público `none`. | **Médio.** Validar metadata retornada, auth method/default e construir revogação conforme metadata. |
| **DV-08** | A recomendação Calendar omite restrições do `syncToken` e a infraestrutura HTTPS necessária para push desktop. | **Médio.** Preservar query compatível, tratar 410 e não prescrever push local sem backend alcançável. |
| **DV-09** | Supply chain e assinatura dos três XCFrameworks não entram no inventário, embora o app desabilite library validation. | **Médio/alto.** Incluir pins, script, assinatura/release artifact e justificativa da exception. |

## 8. Omissões e correções proposals

### 8.1 Omissões materiais (13)

| ID | Omissão | Evidência a acrescentar |
|---|---|---|
| **OM-01** | ID fixo do share de zona. | `ServicoDeEquipesCloudKit.swift:59`, `:251-263`; [S2]. |
| **OM-02** | Banco público não aceita custom zones. | `ServicoDeEquipesCloudKit.swift:410-415`; [S1]. |
| **OM-03** | Fonte exata de `CKSharingSupported`. | `Info.plist:18-19`; [S3]. |
| **OM-04** | `novoCodigoDeEntrada` também usa `randomElement()`. | `EquipeDisponivel.swift:134-137`; [R2] como critério, sem extrapolar que o RNG real é fraco. |
| **OM-05** | Duplicatas estrangeiras podem fazer o delete atômico de código falhar. | `ServicoDeEquipesCloudKit.swift:418-432`; [A1][S4]. |
| **OM-06** | `syncToken` não pode conviver com `timeMin/timeMax/orderBy`; `showDeleted` não pode ser false. | `FonteGoogleCalendarAPI.swift:119-126`; [G4]. |
| **OM-07** | Push exige webhook HTTPS e certificado válido. | [S5]. |
| **OM-08** | Sequência MCP legada requer request sem token e 401 antes do OAuth. | `Papagaio/Integracao/ClienteMCP.swift:129-140`; [M1]. |
| **OM-09** | DCR response deve devolver metadata registrada; auth method omitido tem default Basic. | `SessaoOAuth.swift:214-233`; [R7]. |
| **OM-10** | Revogação usa Basic mesmo para registro público `none`. | `SessaoOAuth.swift:314-328`; [R7]. |
| **OM-11** | Cliente app não valida `Content-Type`, JSON-RPC response `id` nem event framing SSE. | `Papagaio/Integracao/ClienteMCP.swift:129-187`; [M3]. |
| **OM-12** | Três XCFrameworks, dependência FluidAudio pinada e bootstrap com SHA. | `Package.swift:11-27`; `Package.resolved:3-12`; `bootstrap-runtimes.sh:47-58`, `:104-149`, `:282-299`. |
| **OM-13** | Estado de assinatura local e relação com `disable-library-validation`. | `Papagaio.entitlements:19-22`; `Package.swift:18-27`; inspeção `codesign` descrita em O-09. |

### 8.2 Correções de texto proposals (7)

1. **OAuth Google:** “O app implementa o padrão Desktop recomendado; o tipo do
   OAuth Client e a configuração efetiva no Cloud Console são externos.”
2. **PKCE:** “Formato S256 e verifier de 96 caracteres confirmados; a garantia
   de entropia criptográfica não é estabelecida pelo uso de
   `randomElement()`.”
3. **Limite CloudKit:** “`invalidarCodigoAnterior` pode enviar todos os matches
   em um único batch; o guideline de 400 itens continua relevante.”
4. **Rotação:** “A sequência intends replace o share, mas nuevo e antigo
   compartilham `CKRecordNameZoneWideShare`; o resultado deve permanecer
   inconclusivo até teste real.”
5. **MCP legado:** “O cliente implementa parte da era `2025-03-26`, mas inicia
   OAuth antes do 401 e não cumpre a sequência de authorization.”
6. **Calendar:** “Para incremental, manter a mesma query sem `timeMin/timeMax`,
   tratar 410 e full wipe; push exige backend HTTPS.”
7. **Supply chain:** “Três XCFrameworks locais são fixados por SHA no bootstrap,
   mas os objetos atuais não passam validação estrita de assinatura; a
   necessidade da exception de library validation deve ser verificada no
   artefato Release.”

---

## 9. Matriz de reachability e conteúdo por URL do autor

**Legenda de status:** `200/0` = HTTP 200, zero redirects. Todas as 58 URLs
abaixo foram abertas em 2026-09-23. Para Apple, “conteúdo” foi conferido no
DocC JSON oficial equivalente; para as demaisdomínios, no HTML/Markdown
servido. A coluna “conferência” registra se o texto realmente sustenta o uso
que a P3 faz dele.

| ID | URL(s) | Status | Conferência de conteúdo |
|---|---|---:|---|
| A1 | <https://developer.apple.com/documentation/cloudkit/ckcontainer/publicclouddatabase><br><https://developer.apple.com/documentation/cloudkit/ckdatabase> | 200/0 (2/2) | Suporta leitura pública, escrita dos próprios objetos e roles no developer portal. |
| A2 | <https://developer.apple.com/documentation/cloudkit/ckshare/init%28recordzoneid:%29><br><https://developer.apple.com/documentation/cloudkit/ckshare/participant><br><https://developer.apple.com/documentation/cloudkit/ckshare/participant/participantid> | 200/0 (3/3) | Suporta zona inteira, cópia para shared DB, escrita sobre qualquer registro e participant ID. |
| A3 | <https://developer.apple.com/documentation/cloudkit/ckshare/publicpermission><br><https://developer.apple.com/documentation/cloudkit/ckshare/removeparticipant%28_%3A%29> | 200/0 (2/2) | Suporta URL pública e a exigência `.none`/sem mistura para lista de participantes. |
| A4 | <https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation> | 200/0 | Suporta token nil/histórico, cache, push e ausência de polling regular. |
| A5 | <https://developer.apple.com/documentation/cloudkit/ckdatabase/save%28_%3A%29-1j6fq><br><https://developer.apple.com/documentation/cloudkit/ckerror/requestratelimited><br><https://developer.apple.com/documentation/cloudkit/ckerror/zonebusy><br><https://developer.apple.com/documentation/cloudkit/ckerror/quotaexceeded><br><https://developer.apple.com/documentation/cloudkit/ckerror/limitexceeded><br><https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged><br><https://developer.apple.com/documentation/cloudkit/ckerror/changetokenexpired> | 200/0 (7/7) | Suporta retry-after, backoff, quotas por DB, 400/2 MB, conflito em três cópias e token expirado. |
| A6 | <https://developer.apple.com/documentation/cloudkit/ckrecord/id><br><https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid> | 200/0 (2/2) | Suporta unicidade de record ID no público e creator ID. |
| A7 | <https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents%28completion:%29> | 200/0 | Suporta full read/write access antes de fetch e tratamento de denial. |
| A8 | <https://developer.apple.com/documentation/eventkit/ekauthorizationstatus/authorized> | 200/0 | Suporta deprecation no macOS 14 e uso de `.fullAccess/.writeOnly`. |
| A9 | <https://developer.apple.com/documentation/contacts/cncontactstore/requestaccess%28for:completionhandler:%29> | 200/0 | Suporta request per-app e persistência da resposta. |
| A10 | <https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock><br><https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked> | 200/0 (2/2) | Suporta AfterFirstUnlock/background, foreground/WhenUnlocked e migração em backup criptografado. |
| A11 | <https://developer.apple.com/documentation/authenticationservices/implementing-user-authentication-with-sign-in-with-apple><br><https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential/authorizationcode><br><https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential/identitytoken><br><https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce><br><https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.applesignin> | 200/0 (5/5) | Suporta perfil local com `user`, entitlement, e uso server-side de code/token/nonce. |
| A12 | <https://support.apple.com/en-us/149035> | 200/0 | Suporta release de 2026-09-14 e CVEs 20683/86905. |
| A13 | <https://support.apple.com/en-us/149040> | 200/0 | Suporta release de 2026-09-14 e CVE 65393. |
| A14 | <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation><br><https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server> | 200/0 (2/2) | Suporta efeito de library validation e permissão de incoming connections. |
| A15 | <https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users> | 200/0 | Suporta sharing/schema e `CKSharingSupported`; **não sustenta sozinho** o paraphrase específico “schema de produção publicado”. |
| A16 | <https://developer.apple.com/documentation/cloudkit/ckdiscoveralluseridentitiesoperation><br><https://developer.apple.com/documentation/cloudkit/ckdiscoveruseridentitiesoperation> | 200/0 (2/2) | Suporta “no longer supported”, deprecation no macOS 14 e referência ao sharing. |
| G1 | <https://developers.google.com/identity/protocols/oauth2/native-app> | 200/0 | Suporta system browser, loopback desktop, public client, S256, state, refresh/revoke e scope verification; última atualização 2026-09-14. |
| G2 | <https://developers.google.com/identity/protocols/oauth2/resources/best-practices> | 200/0 | Suporta Keychain/secure storage, state, token invalidation, DPoP opcional e refresh handling; 2026-05-20. |
| G3 | <https://developers.google.com/workspace/calendar/api/auth> | 200/0 | Suporta diferença entre `calendar.readonly` e `calendar.events.readonly`; 2026-09-03. |
| G4 | <https://developers.google.com/workspace/calendar/api/v3/reference/events/list> | 200/0 | Suporta query, paginação e restrições de `syncToken`; 2026-07-29. |
| G5 | <https://developers.google.com/workspace/calendar/api/guides/sync> | 200/0 | Suporta full/incremental sync, query constante, 410 e nextSyncToken; 2026-09-11. |
| G6 | <https://developers.google.com/workspace/calendar/api/guides/quota><br><https://developers.google.com/workspace/calendar/api/guides/errors> | 200/0 (2/2) | Suporta quotas 10k/600/1M, polling anti-pattern, push, 403/429 e backoff; 2026-09-11. |
| G7 | <https://developers.google.com/identity/openid-connect/openid-connect> | 200/0 | Suporta `prompt=none`, state, scope e token response fields. |
| G8 | <https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification><br><https://developers.google.com/identity/protocols/oauth2/production-readiness/overview><br><https://developers.google.com/identity/protocols/oauth2/policies> | 200/0 (3/3) | Suporta Calendar como sensitive, verificação condicional e Workspace admin controls; datas 2026-08-19, 2026-05-22 e 2026-08-05. |
| M1 | <https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization> | 200/0 | Suporta metadata, DCR SHOULD, PKCE, 401-first e redirect localhost/HTTPS. |
| M2 | <https://modelcontextprotocol.io/specification/2025-03-26/basic/lifecycle> | 200/0 | Suporta initialize, version negotiation e initialized. |
| M3 | <https://modelcontextprotocol.io/specification/2025-03-26/basic/transports> | 200/0 | Suporta Streamable HTTP, sessão e reset em 404. |
| M4 | <https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization> | 200/0 | Suporta Protected Resource Metadata, issuer, resource, Client ID Metadata e DCR deprecated. |
| M5 | <https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http> | 200/0 | Suporta remoção de GET/sessão, headers por request, `_meta` e fallback. |
| M6 | <https://modelcontextprotocol.io/specification/2026-07-28/changelog> | 200/0 | Suporta remove handshake/session, metadata e deprecation de DCR. |
| R1 | <https://www.rfc-editor.org/rfc/rfc6749.html> | 200/0 | Suporta OAuth 2.0 base. |
| R2 | <https://www.rfc-editor.org/rfc/rfc7636.html> | 200/0 | Suporta PKCE 43–128, high-entropy cryptographic random, S256 e verifier. |
| R3 | <https://www.rfc-editor.org/rfc/rfc8252.html> | 200/0 | Suporta browser externo, reverse-DNS, loopback e state/exact callback. |
| R4 | <https://www.rfc-editor.org/rfc/rfc8414.html> | 200/0 | Suporta issuer obrigatório e validação idêntica; defaults de auth method. |
| R5 | <https://www.rfc-editor.org/rfc/rfc8707.html> | 200/0 | Suporta resource/audience binding. |
| R6 | <https://www.rfc-editor.org/rfc/rfc9700.html> | 200/0 | BCP 240, janeiro de 2025; PKCE, redirect exato, CSRF, mix-up, audience e refresh-token protection. |
| R7 | <https://www.rfc-editor.org/rfc/rfc7591.html> | 200/0 | Suporta DCR metadata, public `none`, default Basic se omitido e response 201. |

### 9.1 Suplementares usados por esta V-P3

| ID | URL | Status | Uso |
|---|---|---:|---|
| S1 | <https://developer.apple.com/documentation/cloudkit/ckrecordzone> | 200/0 | Prova que public DB não aceita custom zones. |
| S2 | <https://developer.apple.com/documentation/cloudkit/ckrecordnamezonewideshare> | 200/0 | Prova ID fixo do share de zona. |
| S3 | <https://developer.apple.com/documentation/bundleresources/information-property-list/cksharingsupported> | 200/0 | Fonte exata da declaração de suporte a sharing. |
| S4 | <https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)> | 200/0 | Semântica atômica de modifyRecords. |
| S5 | <https://developers.google.com/workspace/calendar/api/guides/push> | 200/0 | Webhook HTTPS/certificado e canais push. |
| S6 | <https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/security-considerations> | 200/0 | Redirect localhost/HTTPS e PKCE na revisão moderna. |

**Total de reachability:** 58/58 URLs do autor e 6/6 URLs suplementares
responderam HTTP 200 sem redirect.

---

## 10. Recomendações de correção para a P3

1. Rebaixar “Desktop Client” e “PKCE plenamente conforme”分别 para
   “implementação local observada” e “formato confirmado, entropia não
   comprovada”.
2. Corrigir a afirmação de lotes 1–2 e highlightar o delete atômico sem
   chunk/filter de creator.
3. Tratar rotação de share como potentially broken até resolver/testar o ID
   fixo `CKRecordNameZoneWideShare`.
4. Acrescentar a sequência 401-first e a lacuna de reset 404/versionamento ao
   parecer MCP legado.
5. Validar metadata/DCR e auth method de revogação; não usar Basic para
   cliente público `none`.
6. Reescrever a receita de Calendar incremental e push com as restrições
   oficiais.
7. Incorporar `PapagaioCore`/bootstrap/assinatura ao escopo de segurança e
   verificar a exception de library validation no Release.

## 11. Limitações

1. Nenhuma requisição autenticada, consentimento, token, push, quota,
   notificação push ou resposta real de CloudKit/Google/Granola foi obtido.
2. Estado de CloudKit production, roles, índices, web services, schema
   unpublished/published e containers并不 foram observados.
3. Google Cloud OAuth Client, consent screen, verification, quotas efetivas e
   Workspace policies não foram consultados.
4. Metadata/DCR/tools/redirects/revisões do Granola não foram sondados.
5. Não houve build, benchmark ou teste de integração; o baseline de testes foi
   usado apenas onde a P3 o invoca.
6. As três bibliotecas foram verificadas no worktree; um build Release pode
   reassinatá-las e produzir entitlements/assinatura diferentes.
7. Mudanças preexistentes do usuário permaneceram intocadas. O único arquivo
   criado por esta revisão é `audit/03-verificacao/V-P3.md`.

**Fim da V-P3.**

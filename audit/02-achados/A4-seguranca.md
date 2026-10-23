# A4 — Segurança

> **Data:** 23/09/2026  
> **Projeto:** Ōmu / Papagaio-Loro  
> **HEAD observado:** `6138e1d` (`main`, `origin/main`)  
> **Modo:** auditoria somente-leitura; nenhum código, configuração, dependência, serviço, banco ou histórico foi alterado. Este é o único arquivo de relatório que esta execução pretendia escrever.  
> **Regra de segredo:** valores de token, client secret, refresh token, Client ID efetivo, URL de compartilhamento e credenciais não são transcritos. Quando necessário, aparecem como `[REDACTED]`.

## 1. Escopo, método e convenções

Foram lidos integralmente os quatro documentos de entrada (`audit/00-mapa.md` e os três arquivos em `audit/01-pesquisa/`), reabertos os fontes oficiais relevantes e relidos os caminhos de produção, configuração, CI, bootstrap, histórico Git e testes. Foram feitas buscas de reachability, buscas por callbacks de exclusão, schemas de CloudKit, OAuth/MCP, flags de CI, manipulação de paths, logs e segredos. Não houve autenticação nem chamada a CloudKit, Google, Granola, GitHub Actions remoto ou Apple Services.

- **Severidade** mede o impacto potencial no produto, não a certeza de exploração.
- **Confiança `CONFIRMADO`** significa que o controle, a ausência do controle ou o defeito foi observado diretamente no código, em um teste local ou em uma probe benigna.
- **Confiança `PROVÁVEL`** significa que a cadeia de código e a documentação são fortes, mas depende de schema/roles/serviço real ou de um payload que não foi executado.
- **Confiança `HIPÓTESE`** é reservada para itens não promovidos a Finding.
- Referências `arquivo:linha` são evidência local. Saídas de probes ficam em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a4/`, fora do repositório.

## 2. Resumo executivo

| ID | Achado | Severidade | Confiança |
|---|---|---|---|
| A4-001 | Segredo OAuth historicamente versionado | **ALTA, condicional** | CONFIRMADO (exposição); PROVÁVEL (impacto) |
| A4-002 | Índice público de códigos enumerável e sem fonte única de verdade | **ALTA** | PROVÁVEL |
| A4-003 | Marcador público de exclusão pode ordenar apagamento local | **ALTA** | PROVÁVEL |
| A4-004 | `CKShare` concede escrita à zona inteira e não implementa as permissões prometidas | **ALTA** | CONFIRMADO no código; impacto de serviço PROVÁVEL |
| A4-005 | Exclusão remota de conversa não é aplicada localmente | **MÉDIA** | CONFIRMADO estaticamente; impacto PROVÁVEL |
| A4-006 | Pasta de modelos do usuário chega a parsers nativos sem checksum obrigatório | **ALTA** | PROVÁVEL |
| A4-007 | `whisper.cpp` está antes de correções oficiais de memória | **MÉDIA** | CONFIRMADO na comparação de releases |
| A4-008 | XCFrameworks não autenticados, aceitos por `Info.plist`, com library validation desativada | **MÉDIA** | CONFIRMADO |
| A4-009 | Google Calendar pede escopo amplo e persiste descrição não divulgada | **MÉDIA** | CONFIRMADO |
| A4-010 | Redirect Granola usa scheme customizado sem URI exato | **MÉDIA** | PROVÁVEL |
| A4-011 | Metadata OAuth/MCP não valida issuer, HTTPS, audience/resource | **MÉDIA** | PROVÁVEL |
| A4-012 | Keychain usa acessibilidade mais forte e substituição não atômica | **BAIXA** | CONFIRMADO no código |
| A4-013 | Actions usa tag mutável e token sem privilégio mínimo explícito | **MÉDIA** | CONFIRMADO |
| A4-014 | Nome de pasta `..` escapa do pacote temporário e pode atingir o pai do destino | **MÉDIA** | CONFIRMADO por probe |
| A4-015 | Timeout/cancelamento do loopback não desperta `accept()` | **ALTA** | CONFIRMADO por probe |
| A4-016 | E-mail e mensagens de erro são registrados como públicos | **BAIXA** | CONFIRMADO |

### Contagens

| Severidade | Quantidade |
|---|---:|
| CRÍTICA | 0 |
| ALTA | 6 |
| MÉDIA | 8 |
| BAIXA | 2 |
| **Total** | **16** |

Não há RCE remota ou exclusão remota de dados de produção confirmada nesta auditoria. As findings de maior prioridade são A4-001, A4-002, A4-003, A4-004, A4-006 e A4-015. As de prioridade seguinte são A4-005, A4-007, A4-008, A4-009, A4-010, A4-011, A4-013 e A4-014.

## 3. Achados

### A4-001 — Segredo OAuth historicamente versionado

**Severidade:** **ALTA, condicional à validade e ao uso do valor**  
**Confiança:** **CONFIRMADO** para a exposição; **PROVÁVEL** para impacto  
**Alcance:** histórico Git, forks, clones e logs de repositório; não é um segredo lido pelo app em runtime.

**Evidência**

- `Config/SETUP-GOOGLE.md:43-47` documenta que o app desktop não deve embutir `client_secret`.
- `.gitignore:29-30` e `Config/Base.xcconfig:3-10` mantêm `Config/Secrets.xcconfig` local e ignorado.
- `git log --all -S'GOOGLE_CLIENT_SECRET' -- Config/SETUP-GOOGLE.md` encontra `41c48eb6cb1eb9ec7a035d468840593bb6096228` (26/08/2026, inclusão) e `e2eceb38199806fd2a9a919db9f4fa1cf95fb64a` (27/08/2026, remoção).
- O arquivo local `Config/Secrets.xcconfig` existe, está ignorado e não está versionado; o valor não foi lido, editado ou transcrito.

Trecho histórico mascarado:

```text
Config/SETUP-GOOGLE.md (histórico)
GOOGLE_CLIENT_SECRET = [REDACTED]
```

**Cenário**

Um valor de client secret entrou em um commit e pode ter sido copiado para remote, fork, backup ou log de CI antes da remoção. Se ainda for válido e aceito pelo provedor, um terceiro pode tentar usá-lo contra o cliente. O valor atual local não prova que o valor histórico foi revogado.

**Reprodução benigna**

```bash
git log --all --format='%H %cI %s' -S'GOOGLE_CLIENT_SECRET' -- Config/SETUP-GOOGLE.md
git check-ignore -v Config/Secrets.xcconfig
git ls-files --error-unmatch Config/Secrets.xcconfig
```

O comando de histórico exibe somente hashes, datas e assunto; o conteúdo do segredo não foi impresso. Não foi feita tentativa de uso do valor.

**Refutação buscada**

- O valor não está no `HEAD` nem no índice atual.
- O fluxo atual do Google é public client e não envia `client_secret` no código do app (`SessaoOAuthGoogle.swift:229-235`).
- Isso não refuta a exposição histórica: remoção do working tree não remove o objeto Git nem cópias já feitas.
- Não foi consultado o Google Cloud Console; validade, revogação, escopos e clientes associados são **não verificados**.

**Causa**

Um valor sensível foi colocado em documentação versionada em vez de um mecanismo de segredo; a remoção posterior não trata cópias históricas.

**Correção sugerida**

1. Revogar/rotacionar o valor no Google Cloud Console antes de qualquer limpeza.
2. Auditar access logs, runners, forks e clones que possam ter recebido o commit.
3. Só depois avaliar `git filter-repo`/BFG e force-push coordenado; purged history quebra clones e não substitui revogação.
4. Manter o app como public client, usando somente PKCE e sem segredo distribuível.

**Referência oficial**

- [Google OAuth 2.0 for iOS & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) — apps instalados não conseguem manter segredos; recomenda PKCE e navegador do sistema.
- [RFC 7636 — PKCE](https://www.rfc-editor.org/rfc/rfc7636.html).

---

### A4-002 — Índice público de códigos enumerável e sem fonte única de verdade

**Severidade:** **ALTA**  
**Confiança:** **PROVÁVEL** — a consulta e a configuração são confirmadas; enumerabilidade, roles e taxa de tentativas dependem do container real.

**Evidência**

- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:90-105` consulta `CodigoDeEquipe` por `codigoDeEntrada` e usa o primeiro resultado.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:410-415` grava `codigoDeEntrada` e `urlDoCompartilhamento` em registro público.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:418-432` apaga registros pelo predicado, sem autoral ou assinatura.
- `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:134-137` gera seis caracteres de um alfabeto de 32 símbolos (`32^6 = 2^30`).
- `README.md:86-94` manda publicar `codigoDeEntrada` como campo consultável.

```swift
let consulta = CKQuery(
    recordType: TipoDeRegistro.codigoDeEquipe,
    predicate: NSPredicate(format: "%K == %@", Campo.codigoDeEntrada, codigoNormalizado)
)
let resultado = try await container.publicCloudDatabase.records(matching: consulta)
guard let registro = try resultado.matchResults.first?.1.get() else { ... }
```

**Cenário**

A documentação de implantação torna o campo elegível para consulta. O banco público do CloudKit é legível pelo modelo padrão; um cliente autorizado a consultar o tipo pode usar um predicado amplo para obter o índice, em vez de acertar um código de 30 bits. O registro contém também a URL do `CKShare`, cuja permissão é `.readWrite`. Duplicatas não são resolvidas: um registro criado por outra conta com o mesmo código pode ser o primeiro resultado e levar a pessoa para outro share.

**Reprodução benigna**

Foi feita uma conferência estática, sem autenticação:

```bash
rg -n 'CKQuery|codigoDeEntrada|urlDoCompartilhamento|matchResults.first' \
  Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift README.md
```

A reprodução de serviço sería criar duas contas de teste, publicar o schema exatamente como o README descreve e pedir uma consulta ampla ao banco público. Ela não foi executada para não tocar em CloudKit real. O teste seguro de duplicidade pode ser feito com um transporte fake que devolva dois registros para o mesmo código e registre qual foi escolhido; o código atual não tem teste adversarial.

**Refutação buscada**

- O modelo padrão não permite que qualquer conta sobrescreva arbitrariamente o registro de outra; a criação é do usuário que escreve. Isso limita a variante de overwrite, não a leitura nem a preempção de duplicata.
- `32^6` não é uma força bruta trivial; não se afirma que um atacante online va exhausting codes sem custo.
- A consulta depende de `QUERYABLE`, de schema publicado e de roles do container, que não foram observados.
- A correção histórica `b35d01f` remove a consulta e deriva o record name por hash, mas `git merge-base --is-ancestor b35d01f HEAD` retornou `1`; o commit está apenas em `claude/fix-auditoria-regressoes-3358d3`, não no `main` atual.

**Causa**

Um segredo de entrada de baixa entropia foi armazenado como índice público pesquisável e tratado como se `first` fosse uma fonte confiável. A consulta, o URL público e a capacidade de escrita do share não formam uma fronteira de autorização robusta.

**Correção sugerida**

- Migrar para um token de convite aleatório com entropia suficiente e uma busca por identificador não enumerável; hash determinístico sem trocar a entropia não basta.
- Validar tipo/criador/owner esperado e tratar duplicatas explicitamente; nunca aceitar `first` como verdade.
- Se o índice precisar ser público, publicar somente o mínimo e impedir que o URL de escrita seja retornado a clientes não autorizados.
- Revisar as roles de produção e a premissa de escrita; testar com duas contas e rotação do código.
- Reavaliar a correção `b35d01f` em vez de aplicá-la às cegas, pois ela também altera a migração dos registros antigos.

**Referência oficial**

- [Apple `CKDatabase`](https://developer.apple.com/documentation/cloudkit/ckdatabase) — banco público acessível a todos para leitura; escrita exige iCloud e identifica o autor.
- [Apple `CKRecord.ID`](https://developer.apple.com/documentation/cloudkit/ckrecord/id) — IDs são únicos no banco público.
- [Apple `CKShare.publicPermission`](https://developer.apple.com/documentation/cloudkit/ckshare/publicpermission) — URL pública permite entrada quando a permissão é mais permissiva que `.none`.

---

### A4-003 — Marcador público de exclusão pode ordenar apagamento local

**Severidade:** **ALTA**  
**Confiança:** **PROVÁVEL** — o gatilho e a cascata de limpeza são confirmados; a criação do registro por outra conta depende de roles e do conhecimento do ID.

**Evidência**

- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:276-301` publica `EquipeExcluida` em `preparando`, apaga a zona e publica `concluida`.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:307-317` considera a equipe excluída somente pelo estado do registro.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:518-520` deriva o ID público de `equipe.id`.
- `Papagaio/App/ContentView.swift:758-795` transforma `true` em `limparDadosLocais`, removendo SwiftData, mídia, lixeiras e vínculos.

```swift
let marcador = CKRecord(
    recordType: TipoDeRegistro.equipeExcluida,
    recordID: Self.idDoMarcadorDeExclusao(para: equipe.id)
)
marcador[Campo.estadoDaExclusao] = EstadoDoMarcadorDeExclusao.concluida.rawValue as NSString
// ...
return (marcador[Campo.estadoDaExclusao] as? String)
    == EstadoDoMarcadorDeExclusao.concluida.rawValue
```

**Cenário**

No modelo padrão, um participante ou outra conta iCloud que conheça o `id` da equipe pode criar antecipadamente o record name público com `estadoDaExclusao = concluida`. O proprietário pode colidir com esse ID; outros Macs leem o mesmo estado e limpam a cópia local como se a exclusão legítima tivesse terminado. O resultado inclui perda de dados locais, inclusive mídia e itens na lixeira.

**Reprodução benigna**

Experimento seguro, sem CloudKit real: com um fake de `CKDatabase`, devolver um `EquipeExcluida` com o mesmo record name e estado `concluida`, sem `creatorUserRecordID`, e chamar `equipeFoiExcluida`; a implementação atual retorna `true`. A reprodução decisiva em duas contas deve usar o container de teste, roles controladas e nenhum dado real; não foi executada.

**Refutação buscada**

- A exclusão legítima tem dois estados e só marca `concluida` depois de apagar a zona; isso não protege contra um registro previamente criado por outro criador.
- A Apple oferece `creatorUserRecordID`, mas a busca por ele no código retorna zero.
- Roles customizadas podem impedir a preempção; por isso a confiança do impacto permanece provável, não confirmada.
- A limpeza de dados é tentada e falhas transitórias não apagam localmente; isso reduz falso positivo de rede, mas não valida a autoria do marcador.

**Causa**

Um registro público determinístico funciona como comando destrutivo sem vínculo com o proprietário da zona.

**Correção sugerida**

- Migrar a sinalização para registro privado do proprietário, subscription autenticada ou prova assinada.
- Enquanto o marcador legado existir, validar `creatorUserRecordID`, owner, `equipeID`, nonce e uma versão de esquema; rejeitar registros não autorizados.
- Executar uma migração coordenada e um ensaio de duas contas antes de remover o marcador antigo.
- Tratar a limpeza local como operação recuperável até que a exclusão remota e a autorização do sinal tenham sido confirmadas.

**Referência oficial**

- [Apple `CKRecord.creatorUserRecordID`](https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid).
- [Apple `CKRecord.ID`](https://developer.apple.com/documentation/cloudkit/ckrecord/id).
- [Apple `CKDatabase`](https://developer.apple.com/documentation/cloudkit/ckdatabase).

---

### A4-004 — `CKShare` concede escrita à zona inteira e não implementa as permissões prometidas

**Severidade:** **ALTA**  
**Confiança:** **CONFIRMADO** para o modelo implementado; impacto de serviço **PROVÁVEL** porque não houve duas contas reais.

**Evidência**

- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:59-68` cria `CKShare(recordZoneID:)` para a zona inteira e define `publicPermission` pela propriedade da entrada por código.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:381-385` fixa `.readWrite`.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:213-239` tenta alterar permissões e remover participantes.
- `Papagaio/Modelos/Equipes/EquipeDisponivel.swift:29-32` contém `visibilidadeDosArquivos` e `recebimentoDeArquivos`, mas esses campos não são aplicados à ACL.
- `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:267-289` diz que a política de revisão será aplicada em etapa futura.
- `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:242-267` rotaciona o share inteiro, removendo participantes existentes e recriando a URL.

```swift
let compartilhamento = CKShare(recordZoneID: zonaID)
compartilhamento.publicPermission = .readWrite
```

**Cenário**

Qualquer pessoa que possua a URL do share pode participar e, com `.readWrite`, alterar ou apagar registros da zona compartilhada. A opção “Somente administradores” e a revisão de recebimento não criam ACL por registro; são apenas configuração local. Além disso, a Apple documenta que modificar a lista de participantes exige `publicPermission = .none` e proíbe misturar usuários públicos e privados. O código tenta remover/alterar participantes enquanto o link público continua habilitado, portanto a revogação pode falhar ou não produzir o efeito prometido.

**Reprodução benigna**

```bash
rg -n 'CKShare\(recordZoneID|publicPermission|removeParticipant|visibilidadeDosArquivos' \
  Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift \
  Papagaio/Modelos/Equipes/EquipeDisponivel.swift \
  Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift
```

O teste existente `PapagaioTests/EquipesCloudKitTests.swift:156-159` confirma que a permissão implementada é `.readWrite`. Um teste de integração com duas contas deve verificar leitura, escrita, remoção e as duas opções da UI; não foi executado contra CloudKit.

**Refutação buscada**

- O acesso por código é intencional para convidar parceiros e a UI declara leitura/escrita; isso não elimina a divergência com “somente administradores”.
- Trocar simplesmente para `.none` não é uma correção: o app não tem caminho `addParticipant` para adicionar usuários privados.
- A documentação da Apple é uma pré-condição de protocolo; não se afirma que o servidor real aceitou ou recusou uma operação específica.
- A，苹果 `CKShare` de zona não possui, por si só, ACL por arquivo; o problema é o código vender uma restrição que não cria.

**Causa**

O produto usa um único share de zona como se fosse uma hierarquia com ACL por registro e administra participantes por uma API incompatível com a participação pública.

**Correção sugerida**

- Escolher explicitamente um modelo: share privado com `addParticipant`/remoção, ou link público de escrita sem opções de UI que prometam administrations.
- Aplicar permissões por registro/role no schema e no backend quando “somente administradores” for requisito real.
- Fazer a rotação de código invalidar o URL antigo de forma verificável e testar a revogação com duas contas.
- Até a migração, remover ou marcar como não implementada a opção de visibilidade para não criar falsa sensação de controle.

**Referência oficial**

- [Apple `CKShare.init(recordZoneID:)`](https://developer.apple.com/documentation/cloudkit/ckshare/init%28recordzoneid:%29).
- [Apple `CKShare.publicPermission`](https://developer.apple.com/documentation/cloudkit/ckshare/publicpermission).
- [Apple `removeParticipant(_:)`](https://developer.apple.com/documentation/cloudkit/ckshare/removeparticipant%28_%3A%29).
- [Sharing CloudKit Data with Other iCloud Users](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users).

### A4-005 — Exclusão remota de conversa não é aplicada localmente

**Severidade:** **MÉDIA**  
**Confiança:** **CONFIRMADO** no código; impacto de serviço **PROVÁVEL**.

**Evidência**

- `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:242-271` instala `recordWasChangedBlock`, mas não instala `recordWithIDWasDeletedBlock`.
- `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:371-393` decodifica e devolve apenas os registros recebidos.
- `Papagaio/ViewModels/Biblioteca.swift:1138-1173` faz upsert do resultado e salva a biblioteca; não há remoção por ID ausente.
- O caminho local em `Papagaio/ViewModels/Biblioteca.swift:467-505` remove o arquivo e agenda a remoção, mas não implementa a operação inversa para uma exclusão vinda de outro Mac.

```swift
operacao.recordWasChangedBlock = { _, resultado in
    // apenas registra/appende o CKRecord Success
}
operacao.fetchRecordZoneChangesResultBlock = { resultado in
    // concludes with registros mudados
}
// não há recordWithIDWasDeletedBlock
```

**Cenário**

Uma conta apaga definitivamente uma conversa no CloudKit. A conta participante recebe a mudança de zona, mas o callback de exclusão é ignorado; a próxima carga só atualiza os registros presentes. A conversa apagada continua no SwiftData, na busca e possivelmente em índices auxiliares até uma ação local separate. Isso é retenção e inconsistência, não exclusão remota comprovada.

**Reprodução benigna**

Com um transporte fake, devolver uma página sem o ID que foi removido e uma lista local com esse ID; `baixarComVersoes` retorna a lista vazia, mas o consumidor apenas salva os itens recebidos. Um teste de integração precisaria de duas contas e um ID descartável. Nenhum dado real foi apagado.

**Refutação buscada**

- A remoção local agenda corretamente a operação CloudKit; o defeito é a direção inversa.
- A exclusão global de equipe usa `EquipeExcluida` e tem uma limpeza separada; ela não cobre a exclusão de uma conversa individual.
- A ausência de subscriptions/token explica custo e latência, mas não substitui o callback de exclusão.

**Causa**

O transporte foi modeling apenas mutações de registros, não o conjunto de IDs apagados que a operação de mudanças pode retornar.

**Correção sugerida**

- Implementar `recordWithIDWasDeletedBlock`, coletar IDs e removê-los do repositório local de forma idempotente.
- Persistir `CKServerChangeToken`, usar subscription/push e tratar `changeTokenExpired` com resync.
- Cobrir a rotina com fake que entregue somente deleções e com teste de duas contas.

**Referência oficial**

- [Apple `CKFetchRecordZoneChangesOperation`](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation) — tokens, mudanças e回调 de exclusão.

---

### A4-006 — Pasta de modelos do usuário chega a parsers nativos sem checksum obrigatório

**Severidade:** **ALTA**  
**Confiança:** **PROVÁVEL** — o caminho até `whisper_init_from_file_with_params`/`llama_model_load_from_file` é confirmado; um modelo malicioso não foi carregado.

**Evidência**

- `PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift:99-140` usa `verificarChecksum: Bool = false`; sem o parâmetro, apenas存在 e tamanho são conferidos.
- `Papagaio/ViewModels/ModelosViewModel.swift:39-55` é o fluxo normal da escolha de pasta.
- `PapagaioCore/Sources/PapagaioCore/Runtime/PastaDeModelosDoUsuario.swift:17-50` aceita bookmark de qualquer pasta escolhida.
- `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:29-65` usa os arquivos chosen diretamente.
- `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:108-121` e `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:71-99` passam o caminho para parsers C/C++ in-process.

```swift
public func avaliar(..., verificarChecksum: Bool = false) -> ResultadoPreflight
// ...
guard verificarChecksum, !peso.sha256.isEmpty else { return true }
```

**Cenário**

Uma pasta indicada pela pessoa, ou um modelo baixado de uma fonte não confiável, contém um arquivo com o tamanho exato esperado, mas bytes malformados. O preflight passa; o arquivo chega ao parser GGML/whisper. Uma falha de memória pode derrubar o app e, conforme a superfície nativa, overflowing pode llegar a execução de código no processo. O usuário precisa escolher a pasta e iniciar o processamento.

**Reprodução benigna**

O teste existente em `PapagaioCore/Tests/PapagaioCoreTests/RuntimeTests.swift:101-105` fixa o comportamento: arquivo com tamanho correto e conteúdo errado retorna verdadeiro quando `verificarChecksum` é falso. Uma prova segura adicional seria criar um arquivo do tamanho esperado em pasta temporária e chamar somente `Preflight.pesoValido`; não se deve passar esse arquivo a um parser nativo.

**Refutação buscada**

- Downloads do próprio app verificam tamanho e SHA-256 (`DownloadDeModelos.swift:184-194`).
- O tamanho exato torna corrupção aleatória menos provável, mas não transforma entrada escolhida pelo usuário em confiável.
- Um advisory específico do llama pode atingir outro caminho (`no_alloc=true`); não se afirma que o CVEGHSA-3p4r é exatamente o loader principal deste app.
- Não foi executado PoC de modelo malicioso nem，足以 provar RCE.

**Causa**

O SHA existe no modelo de dados, mas foi tratado como opção de UX/performance em vez de condição de segurança para uma fronteira que entra em C/C++.

**Correção sugerida**

- Exigir SHA-256 para toda pasta externa, inclusive a escolhida;谁是 allow-list de hashes而不是 tamanho.
- Validar arquivo regular, tamanho, hash e ausência de symlink inesperado; registrar a origem.
- Considerar executar o parser em processo separado, com资源和 memória limitados, para conter crash/RCE.
- Atualizar os runtimes e adicionar testes com arquivos malformados sem feed nativo em produção.

**Referência oficial**

- [llama.cpp GHSA-3p4r-fq3f-q74v](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v) — exemplo oficial de integer overflow em parser GGUF; a aplicabilidade exacta depende do caminho.
- [llama.cpp security policy](https://github.com/ggml-org/llama.cpp/security).

---

### A4-007 — `whisper.cpp` está antes de correções oficiais de memória

**Severidade:** **MÉDIA**  
**Confiança:** **CONFIRMADO** na comparação de releases; reachability do payload não foi medida.

**Evidência**

- `Scripts/bootstrap-runtimes.sh:49-58` fixa `WHISPER_TAG="v1.9.1"`.
- `Scripts/bootstrap-runtimes.sh:282-289` baixa esse XCFramework e confere o hash do ZIP.
- `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:108-121` carrega o modelo no processo; `WhisperEngine.swift:119-123` envia áudio decodificado ao mesmo wrapper.
- O release oficial `v1.9.3` lista OOB read em áudio muito curto e recusa de `n_dims` inválido para impedir stack-buffer-overflow em modelo malformado; `v1.9.4` lista correção de leitura não inicializada.

**Cenário**

Um arquivo de áudio muito curto ou um modelo malformado, keduanya entradas que o app pode receber por importação/pasta de modelos, encontra a versão anterior às correções. O resultado pode ser crash ou leitura fora dos limites. Não há GHSA/CVE publicado para whisper.cpp; a finding é baseada em notas oficiais de release, não em advisory atribuído.

**Reprodução benigna**

A reprodução segura é a comparação de tags e changelog, sem PoC:

```bash
git grep -n 'WHISPER_TAG\|v1.9.1' -- Scripts/bootstrap-runtimes.sh
```

A reprodução de impacto exigiria um corpus descartável e ASan/instrumentação; não foi feita para não executar entrada maliciosa no processo do produto.

**Refutação buscada**

- A página de advisories do mantenedor não mostrava advisory publicado.
- O app pode rejeitar alguns arquivos antes do wrapper; não foi medido quais.
- O hash do ZIP protege a acquisition, não a memória do pin.

**Causa**

A tag de runtime foi escolhida sem uma política de atualização de correções de segurança nem um gate de fuzz/áudio curto.

**Correção sugerida**

- Avaliar e testar `whisper.cpp >= v1.9.4`, atualizando tag e SHA do XCFramework.
- Adicionar testes de regressão para áudio curto, header de modelo inválido e leitura não inicializada.
- Manter o pin accompanied por data de revisão e advisories; não atualizar às cegas sem compilar os dois wrappers.

**Referência oficial**

- [whisper.cpp v1.9.3](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.3).
- [whisper.cpp v1.9.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4).
- [whisper.cpp security advisories](https://github.com/ggml-org/whisper.cpp/security/advisories).

---

### A4-008 — XCFrameworks não autenticados, aceitos por `Info.plist`, com library validation desativada

**Severidade:** **MÉDIA**  
**Confiança:** **CONFIRMADO** — estado local, entitlement e CI foram medidos; não é prova de app final não assinado.

**Evidência**

- `Scripts/bootstrap-runtimes.sh:107-116` pula um diretório existente quando há `Info.plist` e ele não é ponteiro LFS.
- `Scripts/bootstrap-runtimes.sh:135-149` copia com `cp -R` diretamente para o destino e pod afterward.
- `Config/Papagaio.entitlements:19-22` habilita sandbox e `com.apple.security.cs.disable-library-validation`.
- `.github/workflows/ci.yml:39-42,50-51` usa `CODE_SIGNING_ALLOWED=NO` e não faz gate de archive Release.
- Probe local: `codesign --verify --deep --strict --verbose=2` retornou `code object is not signed at all` para os três XCFrameworks; o resultado foi salvo em `audit-a4/xcf-codesign.txt`. Binários Mach-O individuais podem aparecer como linker-signed, mas o wrapper XCFramework não tem assinatura de código confiável.

**Cenário**

Uma pasta de framework previamente alterada, parcial ou preparada por outro processo é aceita pelo próximo bootstrap. Um app com a exceção de library validation pode carregar bibliotecas sem a assinatura Apple/mesmo Team ID. A CI não valida a cadeia de assinatura que seria usada em uma distribuição.

**Reprodução benigna**

```bash
for p in PapagaioCore/Frameworks/*.xcframework; do
  codesign --verify --deep --strict --verbose=2 "$p" || true
done
```

Um fixture temporário com diretório e `Info.plist` válidos, sem binário alterado, reproduz o branch de “já presente”; não foiplaced no repositório nem executado código.

**Refutação buscada**

- O diretório é gitignored e a CI usa runner hospedado novo, o que limita persistência e acesso remoto.
- O entitlement, sozinho, não prova uma vulnerabilidade; a Apple o descreve como exceção de hardening.
- Não foi criado um binário malicioso nem foi feita notarização; portanto não se afirma comprometimento de produção.

**Causa**

O download de ZIP é verificado, mas o artefato final podado não recebe manifest de integridade; a exceção de runtime é ampla e a CI não exige assinatura.

**Correção sugerida**

- Gerar manifest determinístico do XCFramework final, preparar em diretório temporário no mesmo volume e promover com `mv` atômico.
- Assinar os frameworks no archive e remover `disable-library-validation` se o design permitir.
- Criar job Release separado com `Archive/Export`, `codesign --verify --deep --strict`, inspeção de entitlements, `spctl` e notarização.
- Registrar provenance dos artefatos e não aceitar diretório apenas por `Info.plist`.

**Referência oficial**

- [Apple Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
- [Apple sample de sharing/validação de schema](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users) — referência de validação antes de distribuição.

---

### A4-009 — Google Calendar pede escopo amplo e persiste descrição não divulgada

**Severidade:** **MÉDIA**  
**Confiança:** **CONFIRMADO**.

**Evidência**

- `Papagaio/Integracao/SessaoOAuthGoogle.swift:68-78` solicita `calendar.readonly` e `userinfo.email`.
- `Papagaio/Integracao/FonteGoogleCalendarAPI.swift:48-59,176-218` lê `description`, títulos e participantes.
- `Papagaio/Integracao/GoogleCalendarViewModel.swift:273-282` coloca a descrição no `ReuniaoPendenteCalendar`.
- `Papagaio/Persistencia/EstadoDasReunioesCalendar.swift:19-23,42-63,70-82` serializa o objeto inteiro em `UserDefaults`.
- `Configuracoes/ConfiguracoesView.swift:300` promete apenas título, data e participantes.

```swift
private let escopos =
  "https://www.googleapis.com/auth/calendar.readonly " +
  "https://www.googleapis.com/auth/userinfo.email"
// ...
descricao: evento.descricao
```

**Cenário**

O token concede acesso de leitura a qualquer calendário acessível, embora o código use apenas `primary`. A descrição pode conterconfidential links, agenda, nomes ou decisões; ela é persistida localmente em um snapshot que o texto da interface não menciona. Um processo do mesmo usuário, backup ou diagnóstico com acesso ao container pode ler esse snapshot. Não foi observada envio da descrição para um servidor do Papagaio.

**Reprodução benigna**

Um fixture local pode criar `EventoCalendarSimples` com descrição e passar por `GoogleCalendarViewModel.aplicar`; depois `EstadoDasReunioesCalendar` serializa o snapshot. Isso não chama Google nem altera serviço. O teste real deve revisar tela de consentimento, política de privacidade e o escopo efetivo concedido.

**Refutação buscada**

- `UserDefaults` não é um canal remoto público; a finding é de minimização/retenção local, não de vazamento comprovado.
- O endpoint chamado é `primary`, e a descrição pode ser necessária para a decisão de produto.
- O código não registra tokens; apenas a descrição e os metadados são persistidos.

**Causa**

A implementação pede o escopo mais próximo de “ler calendários” e copia o objeto de evento inteiro para um store de estado, sem um contrato de dados mínimo.

**Correção sugerida**

- Avaliar `calendar.events.readonly` para a finalidade observada e verificar o `scope` realmente concedido.
- Pedir consentimento explícito para descrição e limitar o que é persistido; remover description de `ReuniaoPendenteCalendar` se não for indispensável.
- Adicionar política de retenção/limpeza para estados ignorados e cópias de backup.
- Manter sincronização incremental com `nextSyncToken` para reduzir exposição repetida e quota.

**Referência oficial**

- [Google Calendar scopes](https://developers.google.com/workspace/calendar/api/auth) — `calendar.readonly` versus `calendar.events.readonly`.
- [Google OAuth native apps](https://developers.google.com/identity/protocols/oauth2/native-app).
- [Google Calendar incremental synchronization](https://developers.google.com/workspace/calendar/api/guides/sync).

### A4-010 — Redirect Granola usa scheme customizado sem URI exato

**Severidade:** **MÉDIA**  
**Confiança:** **PROVÁVEL** — a configuração e a ausencia da comparação são confirmadas; a colisão de apps e a aceitação do servidor não foram testadas.

**Evidência**

- `Config/Info.plist:7-16` registra `CFBundleURLSchemes = papagaio`.
- `Papagaio/Integracao/SessaoOAuth.swift:194-208,238-283` usa `papagaio://oauth/callback` no DCR, na autorização e na troca.
- `Papagaio/Integracao/ApresentadorDeSessaoDeAutorizacao.swift:16-49` deriva o `state` da URL e abre `NSWorkspace`.
- `Papagaio/Integracao/GerenciadorDeCallbackDeAutorizacao.swift:31-43` extrai `state` e `code`, mas não compara scheme, host e caminho com um redirect esperado.

**Cenário**

Outro aplicativo local registra o mesmo scheme e pode capturar o callback. O PKCE e o `state` reduzem a chance de troca do código, mas não impedem negação de serviço, interceptação do redirect ou mix-up de fluxo. O callback private-use também não expressa domínio reverso, como recomendado para native apps.

**Reprodução benigna**

```bash
plutil -p Config/Info.plist | grep -A5 -B2 CFBundleURLSchemes
rg -n 'papagaio://oauth/callback|entregar\(|primeiro.*state' \
  Papagaio/Integracao Config/Info.plist
```

Um teste seguro pode entregar ao manager um URL `papagaio://outro-host/oauth/callback` com o `state` correto e registrar que o código é aceito; o teste não precisa abrir navegador nem usar conta real. A execução desse teste não foi necessária para provar a ausência do guard.

**Refutação buscada**

- `state` e PKCE S256 estão presentes e reduzem o impacto de roubo direto do código.
- O fluxo Google não usa esse scheme; usa loopback `127.0.0.1`, que é apropriado para desktop.
- A configuração real do Granola pode rejeitar o redirect; essa resposta não foi consultada.

**Causa**

O redirect foi escolhido como string genérica e o handler trata o callback como um bearer de `state`, não como um URI de transação validado.

**Correção sugerida**

- Preferir loopback com porta efêmera ou HTTPS universal/claimed link; usar `ASWebAuthenticationSession` quando aplicável.
- Comparar scheme, host, porta e path exatos antes de entregar o código.
- Associar `state`, verifier, cliente e transação a um registro único; limpar tudo em timeout/cancelamento.
- Migrar o DCR e validar a lista de redirect no servidor.

**Referência oficial**

- [RFC 8252 — OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252.html) — private-use URI scheme em reverse-domain e loopback.
- [MCP Authorization 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization) e [MCP Authorization 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization) — redirect e descoberta.

---

### A4-011 — Metadata OAuth/MCP não valida issuer, HTTPS, audience/resource

**Severidade:** **MÉDIA**  
**Confiança:** **PROVÁVEL** — o código aceita endpoints sem validação; o impacto depende de metadata maliciosa, comprometimento do servidor ou mix-up.

**Evidência**

- `Papagaio/Integracao/SessaoOAuth.swift:117-151` substitui os endpoints por qualquer `URL(string:)` retornado no JSON.
- `Papagaio/Integracao/SessaoOAuth.swift:238-256` monta a autorização sem `resource` e sem issuer esperado.
- `Papagaio/Integracao/SessaoOAuth.swift:259-312` envia o código/verifier ao `token` descoberto; se o DCR exigir `client_secret_basic`, também envia o segredo ao endpoint escolhido.
- `Papagaio/Integracao/SessaoOAuth.swift:331-349` não valida `iss` na resposta.
- `Papagaio/Integracao/ClienteMCP.swift:102-124` anuncia a revisão antiga `2025-03-26` e não negotiate headers modernos.

```swift
if let rota = json["token_endpoint"] as? String,
   let url = URL(string: rota) {
    configuracao.token = url
}
```

**Cenário**

Uma resposta de metadata comprometida ou um endpoint de autorização configurado incorretamente pode apontar `token_endpoint` para HTTP ou para outro host. O cliente então envia o authorization code, o verifier PKCE e possivelmente o client secret para esse destino. A ausência de issuer e resource também impede vínculo inequívoco entre token e servidor MCP.

**Reprodução benigna**

Um duble local pode responder metadata JSON com `token_endpoint`controlled pelo teste e registrar apenas esquema/host, nunca token. O teste pode afirmar que o código atual aceita o URL; não foi feita chamada ao Granola. O mesmo teste deve ser repetido com `iss` ausente, `resource` ausente e endpoint HTTP.

**Refutação buscada**

- A base inicial é `https://mcp.granola.ai/mcp`, o transporte usa HTTPS por padrão e PKCE/state estão presentes.
- Um atacante de rede sem controle do TLS não consegue alterar a metadata; o cenário exige resposta maliciosa, servidor comprometido ou configuração insegura.
- A revisão MCP de 2026 pode não ser a deployed; não se afirma que o servidor real aceite callbacks ou metadata.

**Causa**

Metadata foi tratada como configuração convenience, não como entrada de segurança que precisa de validação de issuer, origin, TLS e audience.

**Correção sugerida**

- Implementar Protected Resource Metadata e validar `issuer` por string exata, HTTPS e allowlist de origin.
- Enviar `resource` canônico no authorization e token requests; validar `iss` conforme a revisão MCP adotada.
- Rejeitar endpoints fora do servidor autorizado e não enviar client secret a destinos não verificados.
- Adicionar cliente moderno ou fallback de versão explicitamente negociado, sem misturar headers de revisões diferentes.

**Referência oficial**

- [MCP Authorization 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization) — issuer, resource, validação de response e HTTPS.
- [RFC 8414 — OAuth Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414.html).
- [RFC 8707 — Resource Indicators](https://www.rfc-editor.org/rfc/rfc8707.html).
- [RFC 9700 — OAuth Security BCP](https://www.rfc-editor.org/rfc/rfc9700.html).

---

### A4-012 — Keychain usa acessibilidade mais forte e substituição não atômica

**Severidade:** **BAIXA** como hardening; **MÉDIA** se o objetivo incluipu robustness de credenciais  
**Confiança:** **CONFIRMADO** no código.

**Evidência**

- `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:14-27` executa `SecItemDelete` e depois `SecItemAdd` com `kSecAttrAccessibleAfterFirstUnlock`.
- `Papagaio/ViewModels/PerfilViewModel.swift:136-146` repete delete-before-add para o identificador Apple.
- `Papagaio/Integracao/SessaoOAuth.swift:231-240,352-357` engole falhas de Keychain com `try?` ao salvar cliente/PKCE/tokens.
- A Apple documenta que `AfterFirstUnlock` permanece acessível até o próximo restart e é indicado para background; `WhenUnlocked` é recomendado para foreground.

**Cenário**

Tokens e identificadores ficam acessíveis depois do primeiro desbloqueio, inclusive com o Mac bloqueado, para qualquer código que consiga executar no contexto do usuário. Além disso, uma falha no `SecItemAdd` após o delete apaga a credencial anterior; erros de persistência podem ser silenciosos e deixar a próxima sessão sem PKCE/token.

**Reprodução benigna**

A leitura estática e um teste com `CofreDeTokens` em container de teste podem forçar `errSec` e verificar ausência/estado após delete. Nenhum item real foi criado, alterado ou lido; o teste não deve usar as contas de produção.

**Refutação buscada**

- O app tem sincronização em background legitimately, portanto `AfterFirstUnlock` não é automaticamente incorreto.
- Keychain continua criptografado e não há evidência de extração por outro usuário.
- A falha de delete-before-add é disponibilidade/integridade de credencial, não exposição direta.

**Causa**

Uma política de background foi aplicada indistintamente a todos os itens e a API de substituição foi usada como operação best-effort, sem rollback ou erro obrigatório.

**Correção sugerida**

- Separar itens foreground (`WhenUnlocked`/`ThisDeviceOnly`) de itens realmente necessários em background.
- Preferir `SecItemUpdate` transacional; se for necessário delete/add, manter backup seguro e tratar erro.
- Propagar falha de PKCE, cliente e token; nunca continuar o fluxo como se o verifier tivesse sido persistido.
- Definir política de backup e migração de dispositivos em documentação de segurança.

**Referência oficial**

- [Apple `kSecAttrAccessibleAfterFirstUnlock`](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock).
- [Apple `kSecAttrAccessibleWhenUnlocked`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked).

---

### A4-013 — Actions usa tag mutável e token sem privilégio mínimo explícito

**Severidade:** **MÉDIA**  
**Confiança:** **CONFIRMADO**.

**Evidência**

- `.github/workflows/ci.yml:3-7` usa `pull_request` e `push` para `main`; não há `pull_request_target` nem `workflow_run`.
- `.github/workflows/ci.yml:14,26` usa `actions/checkout@v4` duas vezes.
- `.github/workflows/ci.yml:16-20,28-42` executa scripts e `xcodebuild` sobre o código do PR.
- O workflow não declara `permissions:`; a permissão efetiva depende da configuração do repositório/organização.

**Cenário**

Uma tag movida ou uma futura alteração da action pode executar código no runner. O conteúdo do PR também executa scripts de bootstrap e testes; se o token receber escrita ou se segredos forem adicionados ao job, o impacto cresce. O trigger atual evita o padrão mais perigoso deprivileged `pull_request_target`, mas não expressa o mínimo de privilégio.

**Reprodução benigna**

```bash
rg -n 'uses:|permissions:|pull_request_target|workflow_run|run:' .github/workflows/ci.yml
```

A consulta retornou duas referências `actions/checkout@v4`, zero `permissions:`, zero `pull_request_target` e zero `workflow_run`. Nenhuma execução remota foi feita.

**Refutação buscada**

- `actions/checkout` não tinha advisory publicado na página do mantenedor consultada.
- O repositório não usa secrets no workflow visível e o runner é GitHub-hosted.
- O grafo atual não possui targets de plugin SwiftPM; portanto `-skipPackagePluginValidation` é risco futuro, não execução atual comprovada.
- Não se afirma tomada de conta do repositório; a finding é hardening e preparação contra segredo/token futuros.

**Causa**

O workflow prioriza simplicidade e não fixa a política desupply chain nem declara o escopo do token.

**Correção sugerida**

- Pinar `actions/checkout` por SHA completo, mantendo a tag em comentário.
- Declarar `permissions: contents: read` no nível do workflow e elevar somente o necessário.
- Manter `pull_request`, evitarsegredos em jobs de fork, usar runners efêmeros e revisar actionsXN.
- Adicionar Dependabot para actions, `-disableAutomaticPackageResolution` e um job Release separado com assinatura/notarização.

**Referência oficial**

- [GitHub Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use) — SHA completo, least privilege e risco de conteúdo não confiável.
- [Apple CI para Swift packages](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows) — lockfile e resolução determinística.

---

### A4-014 — Nome de pasta `..` escapa do pacote temporário e pode atingir o pai do destino

**Severidade:** **MÉDIA**  
**Confiança:** **CONFIRMADO** por probe.

**Evidência**

- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:1039-1051` aceita qualquer pasta não vazia, sem rejeitar `.`/`..`.
- `Papagaio/Suporte/NomeDeArquivoSeguro.swift:10-15` troca `/`, `:` e `\\`, mas deixa `..` intacto.
- `Papagaio/Suporte/DossieDaConversa.swift:137-146` anexa o nome sanitizado a uma raiz temporária.
- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:581-588` calcula o destino com `pacote.lastPathComponent` e remove o alvo antes de copiar.

```swift
let nomeSeguro = NomeDeArquivoSeguro.gerar(de: nome) // ".." permanece ".."
let raiz = fm.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
    .appendingPathComponent(nomeSeguro, isDirectory: true)
```

**Cenário**

Uma pasta chamada `..` faz o URL do pacote apontar para a pasta temporária pai. Ao baixar, `lastPathComponent` continua `..`; o destino escolhido pelo usuário pode resolver para o diretório pai, e o código tenta removê-lo antes da cópia. O sandbox e a permissão da pasta selecionada limitam o alcance, mas a operação pode apagar dados fora do diretório que a pessoa pretendia substituir.

**Reprodução benigna**

Probe Swift sob `audit-a4/path_probe2.swift`, sem tocar no repositório:

```text
package.lastPathComponent=..
target.standardized=/.../a4-probe-<uuid>
target==selected.parent? true
```

A probe criou e removeu apenas um diretório temporário. Ela não executou `DossieDaConversa` nem removeu uma pasta do usuário.

**Refutação buscada**

- O nome é entrada local criada pela pessoa; não foi encontrado caminho remoto que injete automaticamente `..` no label.
- Barras são convertidas pelo sanitizer, então a probe não demonstra traversal arbitrário com múltiplos níveis.
- A severidade foi reduzida porque o usuário precisa iniciar a exportação e o sandbox limita o sistema de arquivos.

**Causa**

`standardizedFileURL`/containment foi aplicado em caminhos de mídia, mas o nome do pacote de pasta e o destino de exportação não receberam a mesma validação.

**Correção sugerida**

- Rejeitar `.`, `..`, componentes vazios, controles e separadores antes de persistir o label.
- Criar sempre um diretório com UUID e usar um nome de folha seguro gerado pelo app, nunca o label como componente de sistema.
- Canonicalizar e provar que o destino final está dentro do diretório selecionado antes de qualquer `removeItem` ou `copyItem`.
- Adicionar teste de `..`, `.`, sibling prefix e symlink para as duas APIs de exportação.

**Referência oficial**

- [Apple `URL.standardizedFileURL`](https://developer.apple.com/documentation/foundation/url/standardizedfileurl).
- [Apple `URL.appendingPathComponent`](https://developer.apple.com/documentation/foundation/url/appendingpathcomponent%28_%3Aisdirectory:%29) — o componente é aceito literalmente; a validação de containment é responsabilidade da aplicação.

### A4-015 — Timeout/cancelamento do loopback não desperta `accept()`

**Severidade:** **ALTA**  
**Confiança:** **CONFIRMADO** por código, teste baseline e probe de sistema.

**Evidência**

- `Papagaio/Integracao/SessaoOAuthGoogle.swift:160-185` usa `withThrowingTaskGroup`; o timeout/cancelamento cancela o filho, mas o grupo estruturado espera o worker bloqueante.
- `Papagaio/Integracao/SessaoOAuthGoogle.swift:423-451` chama `shutdown` no descriptor do socket de escuta.
- `Papagaio/Integracao/SessaoOAuthGoogle.swift:484-497` fica bloqueado em `Darwin.accept` quando não existe cliente.
- `PapagaioTests/OAuthGoogleTests.swift:47-83` contém os testes de cancelamento e timeout; a baseline registrou que ambos penduram.
- Probe local `audit-a4/listener-probe.out`, executado em 23/09/2026:

```text
shutdown_result=-1 errno=57
accept_completed_within_2s=false
RESULT=still blocked in accept
```

**Cenário**

A pessoa inicia a conexão Google e fecha o navegador, ou o callback não chega. O temporizador de 180 segundos dispara `cancelAll()` e `parar()`, mas `shutdown()` no socket que só está escutando retorna `ENOTCONN` e não acorda `accept()`. A continuation nunca é retomada, `conectar()` fica pendurado e tentativas posteriores são bloqueadas pelo guard de `tarefaDeConexao`. O mesmo mecanismo pode prender a suíte de testes.

**Reprodução benigna**

A probe minima em `audit-a4/shutdown_accept_probe.swift` cria um socket em `127.0.0.1`, chama `listen`, inicia `accept` em uma fila e aplica `shutdown` sem cliente. Ela não abre navegador, não usa token e encerra após 2 segundos. O resultado está em `audit-a4/listener-probe.out`; a execução Baseline também deixou os dois testes pendurados.

**Refutação buscada**

- O caminho com cliente já conectado (`OAuthGoogleTests.swift:169-194`) passa, confirming que `conexao.cancelar()` funciona para o socket aceito.
- O listener é corretamente ligado a `127.0.0.1` e a porta é efêmera; o problema não é exposição da porta.
- `Darwin.shutdown` é documentado para parte de uma conexão full-duplex, não como um cancelador de `accept` em socket de escuta; o probe no macOS confirma `ENOTCONN`.

**Causa**

Uma syscall POSIX bloqueante foi tratada como operação cancelável por Swift, e o mecanismo de interrupção foi aplicado no descriptor errado.

**Correção sugerida**

- Usar `DispatchSource` cancelável para o listener ou uma conexão loopback de despertar com estado de geração.
- Manter um único dono do descriptor para evitar close/reuse races.
- Garantir que timeout, cancelamento e callback Always retomem a continuation exatamente uma vez.
- Manter os testes de cancelamento com timeout explícito no gate.

**Referência oficial**

- [Apple `shutdown(2)` manual page](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/shutdown.2.html) — a operação é para parte de uma conexão full-duplex e retorna `ENOTCONN` quando não há conexão.
- Evidência local corroborante: `audit/02-achados/A2.md:36-80` e `audit/00-mapa.md:396-412`.

---

### A4-016 — E-mail e mensagens de erro são registrados como públicos

**Severidade:** **BAIXA**  
**Confiança:** **CONFIRMADO**.

**Evidência**

- `Papagaio/Integracao/GranolaViewModel.swift:80-89` registra `conta.email` com `privacy: .public`.
- `Papagaio/Integracao/GoogleCalendarViewModel.swift:94-99,177-181` registra descrições de erro com `privacy: .public`.
- `Papagaio/Integracao/SessaoOAuth.swift:148-150` registra endpoints de metadata como públicos.
- A busca local não encontrou token, Authorization header ou callback em log; a finding não afirma exposição de token.

```swift
registro.info("Conectado: \\(conta.email, privacy: .public)")
```

**Cenário**

Logs unificados podem ser coletados por diagnóstico, suporte, MDM/observabilidade ou por um processo com acesso ao sistema. O endereço de conta e mensagens de servidor podem carregar PII ou detalhes de endpoint. A visibilidade explícita anula a proteção padrão que o próprio `Logger` aplicaria.

**Reprodução benigna**

```bash
rg -n 'privacy:\s*\.public|registro\.(info|error|fault)' Papagaio/Integracao
```

A reprodução real deve gerar apenas uma conexão de teste e revisar `log show`/`log stream`; nenhum serviço real foi chamado e nenhum valor de e-mail foi extraído.

**Refutação buscada**

- A maior parte das strings não tem interpolação pública; tokens não foram encontrados.
- A Apple privacy protects logs against casual viewing but not a principal with log access; o risco é local/operacional, não vazamento remoto comprovado.

**Causa**

O código escolheu `.public` para conveniência de diagnóstico em vez de usar privacidade padrão ou identificadores não sensíveis.

**Correção sugerida**

- Remover `privacy: .public` de e-mail, títulos, erros e URLs; usar `.private`/`.redacted`.
- Registrar códigos de erro estáveis, status HTTP e um identificador de correlação não reversível.
- Criar uma política de retenção de logs e testar com uma conta sintética.

**Referência oficial**

- [Apple `Logger`](https://developer.apple.com/documentation/os/logger) — strings interpoladas são redigidas por padrão; `.public` torna o valor visível.

## 4. Reachability e cobertura

| Superfície | Entrada/gatilho | Caminho alcançado | Limite da validação |
|---|---|---|---|
| CloudKit público | criar equipe, girar código, abrir/conectar equipe | `ServicoDeEquipesCloudKit` → public DB/query/share e `ContentView` → limpeza local | roles, schema e duas contas não foram acessados |
| Conversas CloudKit | processar, baixar, excluir, reconciliar | `SincronizadorDaBibliotecaCloudKit` → `Biblioteca` → SwiftData/mídia | callback de exclusão não foi exercitado contra serviço real |
| Google Calendar | conectar e timer de 15 minutos | OAuth → `FonteGoogleCalendarAPI` → `UserDefaults`/biblioteca | nenhum consentimento ou API real foi chamado |
| Granola/MCP | conectar e importar | `SessaoOAuth` → `ClienteMCP` → `FonteGranola` | metadata, redirect e ferramentas do servidor não foram consultados |
| Modelos | escolher pasta e processar áudio | `Preflight` → `MotoresLocais` → Whisper/llama C/C++ | nenhum modelo malicioso foi executado |
| Exportação | criar/renomear pasta e baixar/compartilhar | UI → `NomeDeArquivoSeguro` → `DossieDaConversa`/Finder | probe local confirmou only o cálculo de path, não a cópia real |
| OAuth listener | iniciar conexão e cancelar/timeout | `ServidorOAuthLocal` → `accept` em fila | teste real do Google não foi executado; probe de socket reproduziu o defeito |
| CI | PR/push para `main` | checkout → scripts → build/testes | GitHub-hosted runner e configuração remota não foram inspecionados |
| Logs/Keychain | conectar, IMPORTar perfil ou erro | `Logger`, `CofreDeTokens`, `PerfilViewModel` | nenhum segredo real foi lido ou escrito |

### Contagens e buscas finais

A contagem de baseline do mapa é **266 arquivos Swift / 53.437 linhas** no escopo focado (`Papagaio`, `PapagaioCore/Sources`, `PapagaioCore/Tests`, `PapagaioTests` e `Package.swift`). A pasta de auditoria também registrou uma varredura ampla de 301 arquivos de texto; os números não são misturados porque a definição de inclusão difere. Foram percorridos **346 commits** no histórico local.

Resultados de buscas estáticas安全 relevantes:

| Padrão | Ocorrências no escopo de produto/configuração |
|---|---:|
| `CKQuery` | 4 |
| `recordWithIDWasDeletedBlock` | 0 |
| `CKDatabaseSubscription` | 0 |
| `CKRecordZoneSubscription` | 0 |
| `previousServerChangeToken`/`serverChangeToken` | 0 |
| `creatorUserRecordID` | 0 |
| `MCP-Protocol-Version` | 0 |
| `publicPermission = .none` | 0 |
| `removeParticipant` | 1 |
| `actions/checkout@v4` | 2 |
| `pull_request_target` | 0 |
| `workflow_run` | 0 |

Também foram relidos os testes de OAuth, CloudKit, Runtime e exportação, os manifests/lockfiles, entitlements, Info.plist, scripts de bootstrap e o commit histórico `b35d01f`. Não há ferramenta de cobertura ou Análise estática configurada; portanto não se afirma percentual de linhas cobertas.

## 5. Segredos e mascaramento

- Nenhum valor de `GOOGLE_CLIENT_SECRET`, token, refresh token, Authorization header, Client ID efetivo ou URL de share foi impresso, copiado para o relatório ou usado em requisição.
- O relatório usa apenas `[REDACTED]` noTrecho histórico.
- `Config/Secrets.xcconfig` foi tratado como arquivo local ignorado; `git check-ignore` confirmou a regra e `git ls-files` confirmou que não está versionado.
- A busca atual por `GOOGLE_CLIENT_SECRET` no código versionado não encontrou o valor; a pesquisa histórica encontrou somente os dois commits de inclusão/remoção descritos em A4-001.
- Tokens de Google/Granola são guardados no Keychain; não há token em `UserDefaults` ou no log encontrado por esta busca.

## 6. Dependências, advisories e proveniência

| Componente/versão observada | Evidência/estado oficial | Conclusão de segurança |
|---|---|---|
| FluidAudio `0.15.5`, pin exato e revisão nos três `Package.resolved` | Releases posteriores `0.15.6–0.16.1`; página de advisories sem advisory publicado | Sem CVE confirmado no pin; atualização exige adaptar wrapper, não é alteração cega |
| llama.cpp `b9222` | 13 advisories oficiais; nenhum intervalo publicado contém `b9222`; advisories de GGUF continuam relevantes para entrada não confiável | Ausência de advisory não atesta parser seguro; RPC não é exposto pelo wrapper |
| whisper.cpp `v1.9.1` | Releases `v1.9.3`/`v1.9.4` listam correções de memória; página de advisories sem advisory | A4-007: atualizar após testes; não se atribui CVE inexistente |
| ONNX Runtime `1.24.2` | Releases posteriores `1.24.3+` e `1.29/1.30` traz hardening; advisories oficial sem entrada publicada | Sem advisory confirmado; pin deve ser revisited periodicamente |
| Silero VAD `76e3dc4` | Modelo pinned por commit e SHA no bootstrap | Sem advisory publicado; origem é reproduzível, mas o artefato continua sendo dado de parser |
| XCFrameworks whisper/llama/ONNX | `codesign --verify` local: wrappers sem assinatura; ZIPs têm SHA | A4-008: hash de aquisição não substitui assinatura do artefato final |
| `actions/checkout@v4` | Tag móvel, sem advisory publicado na página do mantenedor | A4-013: hardening; não foi alegado comprometimento da action |
| URLs `resolve/main` de pesos/Core ML | Hashes locais detectam troca de bytes | Mutabilidade afeta disponibilidade/proveniência; não foi classificada como bypass de checksum |

Fontes reabertas/confirmadas em 23/09/2026 incluem Apple CloudKit/Keychain/URL/entitlements/shutdown, Google OAuth e Calendar, RFCs 7636/8252/8414/8707/9700, MCP 2025 e 2026, GitHub Secure Use, releases/advisories de whisper e llama, além dos releases de FluidAudio, ONNX Runtime e Silero indicados nas documentos de pesquisa. Links diretos aparecem em cada finding e na lista abaixo.

## 7. Divergências de histórico e estado do repositório

- `HEAD` está em `main`/`origin_main` no commit `6138e1d`; as modificações e untracked já existentes foram preservadas e não foram atribuídas a esta auditoria.
- O commit `41c48eb6cb1eb9ec7a035d468840593bb6096228` introduziu a chave de segredo em `Config/SETUP-GOOGLE.md`; `e2eceb38199806fd2a9a919db9f4fa1cf95fb64a` removeu o valor. A rotação não foi verificada.
- O commit `b35d01fa2e760bdfad57b20d25ff8adae03f80bb` contém uma correção de entrada por código e remoção do `CKQuery`, mas não é ancestral do `HEAD`; ele está na branch `claude/fix-auditoria-regressoes-3358d3`. O `main` atual mantém a consulta pública e o README ainda exige campo consultável.
- A suíte de testes do app não forneceu resultado final confiável na baseline: 107 testes iniciados, 99 aprovados, 6 falhos e 2 pendurados; o travamento do listener foi confirmado separadamente. Não se usa esse estado para afirmar qualquerFinding além de A4-015.

## 8. Limitações e riscos não verificados

1. Não houve acessoAllowed a CloudKit real, Google OAuth/Calendar, Granola/MCP, GitHub Actions remoto, Apple Services ou Xcode Cloud. Roles, schema de produção, índices, creators, tokens, payloads, push e quotas reais não foram vistos.
2. Não foi possível confirmar rotação do segredo, estado de assinatura de um archive Release, notarização, permissões efetivas do `GITHUB_TOKEN` ou configuração da organização.
3. Não se executou PoC destrutivo, modelo GGUF malicioso, exploit de CloudKit, callback OAuth real ou scan de terceiros. As probes foram locais, reversíveis e sem dados de produção.
4. A versão exata do patch de macOS/Xcode não foi comparada ao build de segurança; potenciais advisories de sistema são **não verificados**, não findings confirmados.
5. Não houve benchmark de CloudKit, Calendar, MCP, Keychain ou inferência; números de performance não foram usados.
6. O teste de app foi interrompido pelo problema de OAuth e pelo limite de execução; a suíte não é um gate verde desta auditoria.
7. O estado de WIP pré-existente impede atribuir a mudanças em `DetectorDeAtividadeDeVoz.swift`, `SileroVAD.swift`, `papagaio-eval` e `Scripts/testa-papagaio-core.sh` qualquer intenção ou correção de segurança.

## 9. Candidatas refutadas ou não promovidas

- **PCM malformado:** a probe `pcm_probe.swift` com 3 bytes retornou `bytes=3 floats=0`, sem crash; `processarPCMCru` já rejeita comprimentos não múltiplos de `MemoryLayout<Float>.size`. Não foi promovido a Finding.
- **`-skipPackagePluginValidation`:** o grafo atual tem zero targets de plugin; é risco futuro/hardening, não execução atual comprovada.
- **`pull_request_target`:** não existe no workflow; não se aplica o rótulo de “pwn request” a este checkout.
- **Overwrite arbitrário no banco público:** o modelo padrão impede que qualquer conta sobrescreva diretamente o registro de outra; A4-002 e A4-003 ficam restritos a leitura, duplicata/preempção e criação de registro, não a essa afirmação mais ampla.
- **Segredo no `HEAD`:** não há valor de client secret no código atual; A4-001 é exposição histórica, com rotação pendente.
- **`disable-library-validation` isoladamente:** é uma exceção de hardening, não uma vulnerabilidade autônoma; foi reportada apenas junto da cadeia de XCFrameworks não assinados e da falta de gate de release.

## 10. Ordem de correção recomendada

### P0 — antes de distribuição

1. Revogar/rotacionar o segredo histórico e só então limpar cópias/histórico.
2. Corrigir o índice público de `CodigoDeEquipe`, o marcador `EquipeExcluida` e o modelo de `CKShare`; validar a correção `b35d01f` e o schema com duas contas.
3. Corrigir o cancelamento do listener loopback e colocar timeout explícito no gate.
4. Exigir hash para modelos externos ou retirar essa opção; atualizar `whisper.cpp` e revisar todos os parsers nativos.

### P1 — antes de publicar integração confiável

5. Assinar/verificar XCFrameworks, remover a exceção de library validation se possível e criar gate Release/notarização.
6. Reduzir escopo do Calendar, não persistir descrição sem necessidade e verificar o escopo efetivamente concedido.
7. Migrar OAuth/MCP para metadata moderna com issuer/resource/redirect exato; revisar claims e responses.
8. Corrigir o marker de exclusão e path traversal; aplicar contenção de path em toda exportação.
9. Endurecer Keychain e GitHub Actions conforme A4-012/A4-013.

### P2 — hygiene e privacidade

10. Remover logs públicos, substituir IDs frágeis e completar o handling de deleções/tokens CloudKit.
11. ManterSBOM, provenance, advisories e revisão periódica dos pins nativos.

## 11. Fontes oficiais e referências primárias

- [Apple CKDatabase](https://developer.apple.com/documentation/cloudkit/ckdatabase), [CKShare publicPermission](https://developer.apple.com/documentation/cloudkit/ckshare/publicpermission), [removeParticipant](https://developer.apple.com/documentation/cloudkit/ckshare/removeparticipant%28_%3A%29), [CKFetchRecordZoneChangesOperation](https://developer.apple.com/documentation/cloudkit/ckfetchrecordzonechangesoperation), [creatorUserRecordID](https://developer.apple.com/documentation/cloudkit/ckrecord/creatoruserrecordid).
- [Apple Keychain AfterFirstUnlock](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlock), [WhenUnlocked](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlocked), [Disable Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation), [URL.standardizedFileURL](https://developer.apple.com/documentation/foundation/url/standardizedfileurl), [shutdown(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/shutdown.2.html).
- [Google OAuth native apps](https://developers.google.com/identity/protocols/oauth2/native-app), [Calendar scopes](https://developers.google.com/workspace/calendar/api/auth), [Calendar sync](https://developers.google.com/workspace/calendar/api/guides/sync), [OAuth best practices](https://developers.google.com/identity/protocols/oauth2/resources/best-practices).
- [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636.html), [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html), [RFC 8414](https://www.rfc-editor.org/rfc/rfc8414.html), [RFC 8707](https://www.rfc-editor.org/rfc/rfc8707.html), [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html).
- [MCP Authorization 2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization), [MCP Authorization 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization), [MCP Streamable HTTP 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http).
- [GitHub Secure use](https://docs.github.com/en/actions/reference/security/secure-use), [llama.cpp GHSA-3p4r-fq3f-q74v](https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v), [llama.cpp security](https://github.com/ggml-org/llama.cpp/security), [whisper v1.9.3](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.3), [whisper v1.9.4](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.4), [whisper advisories](https://github.com/ggml-org/whisper.cpp/security/advisories).
- [Apple Logger](https://developer.apple.com/documentation/os/logger), [Apple sample de CloudKit sharing](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users), [Apple CI para Swift packages](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows).

### Fechamento

Nenhuma correção foi aplicada durante a produção deste relatório. O único artefato intencional desta auditoria de segurança é `audit/02-achados/A4-seguranca.md`; probes e saídas permanecem no diretório temporário aprovado.

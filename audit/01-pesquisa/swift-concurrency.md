# Ficha técnica independente — Swift 6.4, SwiftUI/Observation/SwiftData, AVFoundation/Core Audio e Apple Concurrency

**Projeto:** Ōmu (Papagaio/Loro), aplicativo macOS<br>
**Data de corte e acesso:** 23/09/2026<br>
**Escopo:** comparação entre a configuração efetivamente declarada no repositório e as versões estáveis da Apple disponíveis na data de corte.
**Modo:** pesquisa somente leitura; nenhum arquivo de produção, manifesto, arquivo de resolução, dependência, serviço ou banco foi alterado.

> Esta ficha substitui integralmente o texto preliminar anterior. A síntese operacional é: **o projeto já está no modo de linguagem Swift 6 com verificação completa, mas o alvo de implantação continua sendo macOS 26.0; APIs novas do SDK 27 precisam de barreiras de disponibilidade, e os pontos de concorrência/áudio encontrados são condições de auditoria, não achados de defeito de domínio.** [CONFIRMADO]

## Legenda e método

- **CONFIRMADO** — arquivo, comando local ou fonte primária foram lidos/medidos nesta auditoria.
- **PROVÁVEL** — inferência forte a partir da evidência, sem reprodução no ambiente real.
- **HIPÓTESE** — possibilidade plausível que ainda não foi verificada.

Para as afirmações sobre o código, este documento traz referência `arquivo:linha`; os trechos exibidos foram abertos nesta auditoria. Comentários como `// demais propriedades` ou `// trecho intermediário omitido` marcam linhas deixadas de fora apenas para manter o excerto legível. Contagens de `rg` são resultados de comando, não conclusões de defeito. Números de desempenho do mapa de auditoria não foram reutilizados como medição: **esta ficha não mede desempenho**.

### Evidência de configuração e ferramentas

| Fato | Evidência |
|---|---|
| Swift local | `swift-driver version: 1.167 Apple Swift version 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)`; alvo `arm64-apple-macosx27.0.0` — comando `swift --version` [CONFIRMADO] |
| Xcode local | `Xcode 27.0`, compilação `27A5194q` — comando `xcodebuild -version` [CONFIRMADO] |
| macOS local | `macOS 27.0`, compilação `26A428` — comando `sw_vers` [CONFIRMADO] |
| SDK local | `macOS 27.0`, `-sdk macosx27.0` — comando `xcodebuild -showsdks` [CONFIRMADO] |
| SDK local exato | `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk`; `xcrun --sdk macosx --show-sdk-build-version` retorna `26A5353p` [CONFIRMADO] |

A compilação local é uma **versão beta do Xcode 27**. A comparação estável usa os números publicados pela Apple: **Swift 6.4**, **Xcode 27.0 `27A266a`** e **macOS 27.0 `26A428`**, todos publicados em 14–15/09/2026. [CONFIRMADO — F1, F2, F10, F11]

O SDK `MacOSX27.0.sdk` local é evidência beta de disponibilidade/depreciação; ele não é tratado como se fosse o SDK estável. O Xcode estável `27A266a` não está instalado nesta máquina; portanto, não houve compilação, execução nem medições estáveis com Instruments. [CONFIRMADO]

### Escopo de leitura

- `audit/00-mapa.md` foi lido integralmente antes desta pesquisa, conforme o mapa de auditoria. Os resultados abaixo não dependem apenas dele: manifestos, arquivos de resolução, projeto e código foram reabertos para esta ficha. [CONFIRMADO]
- Foram lidos `Package.swift`, os três `Package.resolved`, `project.pbxproj`, os modelos de visualização de gravação/reprodução, o tap de Core Audio, os adaptadores C, SwiftData, os retornos de chamada do AppKit e os trechos de SwiftUI citados. [CONFIRMADO]
- Não se executou serviço real, teste de áudio em dispositivo físico, teste real de SwiftData contra o banco do usuário, TSan, análise de binários/SDK para CVEs, alteração de dependências ou atualização automática de opções. [CONFIRMADO]

---

## 1. Configuração exata do projeto

### 1.1 Manifesto SwiftPM

**CONFIRMADO — trechos efetivamente abertos:**

`PapagaioCore/Package.swift:1,6,15,42,47,52,64,82,87,92`

```swift
// swift-tools-version: 6.0
// trecho intermediário omitido
platforms: [.macOS("26.0")],
// trecho intermediário omitido
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
// trecho intermediário omitido
swiftSettings: [.swiftLanguageMode(.v6)]
```

Todos os alvos Swift relevantes usam `.swiftLanguageMode(.v6)`. Isso é diferente da versão do compilador: `swift-tools-version: 6.0` declara a versão da API de manifesto; o compilador observado é Swift 6.4. [CONFIRMADO]

A dependência SwiftPM está fixada exatamente em `0.15.5`. Os três arquivos de resolução confirmam a mesma revisão `19600a485baa4998812e4654b70d2bab8f2c9949`, embora os `originHash` sejam diferentes:

- `PapagaioCore/Package.resolved:5,9-10`
- `Loro.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:5,9-10`
- `Loro.xcworkspace/xcshareddata/swiftpm/Package.resolved:5,9-10`

**CONFIRMADO:** não há inconsistência de fixação entre os três arquivos. A comparação das versões no repositório de origem do FluidAudio e dos componentes C não é usada para sugerir atualização automática; fica fora da conclusão desta ficha.

### 1.2 Projeto Xcode

**CONFIRMADO — trechos efetivamente abertos:**

`Loro.xcodeproj/project.pbxproj:353,376,407,431`

```text
MACOSX_DEPLOYMENT_TARGET = 26.0;
```

`Loro.xcodeproj/project.pbxproj:414-415,436-437`

```text
SWIFT_STRICT_CONCURRENCY = complete;
SWIFT_VERSION = 6.0;
```

As duas configurações de compilação do app mostram `SWIFT_STRICT_CONCURRENCY = complete` e `SWIFT_VERSION = 6.0`; o alvo de implantação aparece em `353`, `376`, `407` e `431`. [CONFIRMADO]

Portanto, a combinação efetiva é:

| Item | Valor | Consequência |
|---|---|---|
| Alvo de implantação | macOS 26.0 | APIs marcadas macOS 27 não podem ser assumidas em tempo de execução |
| Linguagem | Swift 6.0 | o compilador 6.4 executa o código no modo 6 |
| Verificação | `complete` | o projeto já está no nível de verificação que o objetivo de migração Swift 6 busca; não há uma garantia de que uma opção de migração futura seja ativada |
| Xcode local | 27.0 beta `27A5194q` | evidência local, não compilação estável |

A configuração explícita de `complete` é consistente com o modo de linguagem Swift 6 e não deve ser tratada como uma prova de que `NonisolatedNonsendingByDefault` ou `default-isolation MainActor` esteja habilitado. A busca de opções foi feita somente em código/configuração de produto, com o padrão:

```text
NonisolatedNonsending|DefaultIsolation|defaultIsolation|SWIFT_UPCOMING_FEATURE|default-isolation|NonisolatedNonsendingByDefault
```

e não encontrou ocorrência em `Papagaio`, `PapagaioCore/Sources`, `Loro.xcodeproj` ou `Config`. [CONFIRMADO — comando `rg` executado nesta auditoria]

**Não houve alteração de opções, `Package.swift` ou `project.pbxproj`.** [CONFIRMADO]

---

## 2. Swift 6.0 → 6.4: mudanças e aplicabilidade

A comparação abaixo separa mudanças de linguagem, APIs de biblioteca e disponibilidade no sistema operacional. Uma novidade do compilador não implica que uma API esteja disponível no alvo de implantação do app.

| Versão | Mudança relevante para esta auditoria | Estado no projeto |
|---|---|---|
| **6.0** | Modo de linguagem Swift 6 e verificação completa de segurança contra corridas de dados como base da migração. A documentação de migração recomenda habilitar a verificação antes de entrar no modo 6. [F5] | O projeto já está em modo 6 e `complete`; não há migração de modo pendente nesta ficha. |
| **6.1** | Não atribuí uma mudança específica de concorrência à 6.1 sem uma fonte primária lida nesta rodada. A ausência de análise não significa que o lançamento não tenha mudanças. | Nenhuma ação específica recomendada. |
| **6.2** | “Approachable concurrency”: opção de adesão para isolar no MainActor por padrão; recurso experimental `nonisolated(nonsending)` para executar `async` no contexto do chamador; `@concurrent` para trabalho explicitamente paralelo; `Observations`; `NotificationCenter` tipado; ferramentas de migração. [F3] | Os sinalizadores do recurso experimental não foram encontrados. `Observations` é uma possibilidade para macOS 26, mas não foi adotado. `@concurrent` não foi ativado automaticamente. |
| **6.2** | SE-0463 importa manipuladores de conclusão Objective-C como `@Sendable` por padrão quando a API é não isolada; é uma mudança de inferência importante para fechamentos AppKit. [F9] | Há três usos de `MainActor.assumeIsolated` em retornos de chamada; são condições de auditoria, não prova de erro. |
| **6.3** | Seletores de módulo, inclusive `Swift::Task`, para desambiguar APIs. [F4] | Não foi encontrada necessidade no código; não é motivo para refatoração automática. |
| **6.4** | `await` em `defer` (SE-0493), `withTaskCancellationShield` (SE-0504) e rastreamento avançado de Observation (SE-0506). [F2, F6, F7, F8] | `async defer` compila no alvo macOS 26; o escudo e o rastreamento avançado são condicionais ao SDK/sistema 27 no SDK local. |

### 2.1 `async` em `defer` — adotável, aditivo

SE-0493 é explicitamente aditivo: um `defer` pode conter `await` quando o contexto já é assíncrono, e o corpo assíncrono é aguardado antes da saída do escopo. [CONFIRMADO — F6]

O experimento temporário, sem arquivo no repositório, usou o compilador local:

```text
printf 'func f() async { defer { await Task.yield() } }\n' |
  swiftc -typecheck -target arm64-apple-macosx26.0 \
  -sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk -
```

com:

```swift
func f() async {
  defer { await Task.yield() }
}
```

Resultado: compilou; houve apenas o aviso de que um `defer` no fim do escopo executa imediatamente. [CONFIRMADO — comando de typecheck]

Isso torna `async defer` uma opção real para a limpeza no alvo atual, mas não há uma mudança de código automática: é preciso primeiro decidir quais partes da limpeza devem ser aguardadas e quais devem observar cancelamento. A proposta SE-0493 também deixa claro que o `defer` não deixa de observar cancelamento; o escudo é uma decisão separada. [F6, F7]

### 2.2 `withTaskCancellationShield` — mecanismo de Swift 6.4, mas não é retrocompatível com macOS 26

A proposta SE-0504 diz que a API permite que uma região observe a tarefa como não cancelada, sem “descancelar” a tarefa; também alerta que a mudança exige suporte do tempo de execução e **não é retrocompatível por implantação**. [CONFIRMADO — F7]

No SDK local, a assinatura é:

`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface:3090-3123`

```swift
@available(anyAppleOS 27.0, *)
@_alwaysEmitIntoClient nonisolated(nonsending)
public func withTaskCancellationShield<Value, Failure>(
    operation: nonisolated(nonsending) () async throws(Failure) -> Value
) async throws(Failure) -> Value where Failure: Swift.Error
```

O typecheck temporário com `-target arm64-apple-macosx26.0` produziu:

```text
'withTaskCancellationShield(operation:)' is only available in macOS 27.0 or newer
```

[CONFIRMADO — L6 e comando de typecheck]

Portanto:

- **CONFIRMADO:** a API não pode ser chamada sem disponibilidade no alvo macOS 26 do projeto.
- **PROVÁVEL:** o Xcode 27 na versão geral deve expor a mesma restrição de SDK/sistema operacional; ainda deve ser confirmado no SDK estável instalado, pois a máquina só tem o SDK beta.
- **CONFIRMADO:** não há uso de `withTaskCancellationShield` no produto; a busca retornou zero ocorrências.
- **Não se deve** trocar o alvo de implantação ou introduzir `#available` sem uma decisão de compatibilidade e teste de limpeza.

### 2.3 `nonisolated(nonsending)`, `@concurrent` e default MainActor

Swift 6.2 apresenta `nonisolated(nonsending)` como recurso experimental e `@concurrent` como ativação explícita. [F3] O projeto está no modo Swift 6, mas não habilitou esses recursos por meio de sinalizadores de projeto. [CONFIRMADO]

Isso importa porque a execução de uma função `async` não isolada pode mudar quando o recurso experimental é ativado; não basta atualizar o compilador para presumir o novo modelo de executor. O problema #88731 registrou uma falha de isolamento que exigia `NonisolatedNonsendingByDefault`; como a opção não existe no repositório, ela não explica o código atual. [F25]

O problema #88173 descreve uma falha do compilador com `-default-isolation MainActor` em uma compilação otimizada; ele permanece aberto na consulta e exige essa opção, que também não foi encontrada. [F27] É uma razão para **não** ativar a opção como remédio automático.

### 2.4 SE-0463 e retornos de chamada Objective-C

SE-0463 muda a importação de manipuladores de conclusão Objective-C para `@Sendable`; a própria proposta explica que, em código Swift 6, fechamentos não isolados podem perder a inferência implícita de `@MainActor` e gerar avisos. [F9]

O problema #82127 documenta um caso em que `addCompletion:` deixou de importar como `@MainActor`; o problema aparece como **Closed** na consulta, portanto não o classifico como defeito aberto do Swift 6.4. [F24]

No projeto, os três pontos de `assumeIsolated` são:

1. `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:126-131` — timer adicionado ao run loop principal.
2. `Papagaio/ViewModels/PerfilViewModel.swift:240-247` — protocolo de apresentação do AuthenticationServices.
3. `Papagaio/Funcionalidades/Gravacao/JanelaFlutuanteDeGravacao.swift:182-191` — retorno de chamada de `NSAnimationContext`.

**CONFIRMADO — trechos:**

```swift
// ReprodutorDeArquivo.swift:126-131
let timer = Timer(timeInterval: intervaloDeObservacao, repeats: true) { [weak self] _ in
    MainActor.assumeIsolated { self?.atualizarTempo() }
}
temporizador = timer
RunLoop.main.add(timer, forMode: .common)
```

```swift
// PerfilViewModel.swift:240-247
nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    MainActor.assumeIsolated {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}
```

```swift
// JanelaFlutuanteDeGravacao.swift:182-191
NSAnimationContext.runAnimationGroup { contexto in
    contexto.duration = 0.26
    contexto.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    painel.animator().setFrame(origem, display: true)
} completionHandler: {
    MainActor.assumeIsolated {
        painel.close()
    }
}
```

A documentação da Apple define `assumeIsolated` como uma verificação síncrona: se o contexto não estiver no executor serial do MainActor, o programa termina com erro fatal. [F19] **PROVÁVEL:** os retornos de chamada são entregues nos contextos indicados pelo código, mas essa premissa não é verificada pelo compilador e precisa de teste de ciclo de vida real. Não há teste de AppKit com NIB, execução de áudio nem reprodução executados nesta ficha para provar todos os caminhos.

---

## 3. SwiftUI e Observation

### 3.1 Matriz de APIs

| API | Disponibilidade/estado em 23/09/2026 | Evidência no projeto | Avaliação |
|---|---|---|---|
| `@MainActor` | Recomendado para trabalho de interface; a documentação da Apple recomenda manter a UI na thread principal. [F20, F21] | `Papagaio/ViewModels/GravadorViewModel.swift:9-11`; `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:21-23`; `Papagaio/ViewModels/Biblioteca.swift:19-21` | **CONFIRMADO:** o padrão dos modelos de visualização da interface é explícito. |
| `@Observable` | Disponível desde macOS 14; a busca em `Papagaio`/`PapagaioCore/Sources` encontrou 14 anotações em 13 arquivos, incluindo `Papagaio/ViewModels/GravadorViewModel.swift:10,492`. [CONFIRMADO — `rg`; L4] | `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:21-23`; `Papagaio/ViewModels/Biblioteca.swift:19-21`; `Papagaio/ViewModels/MidiasDaConversaViewModel.swift:13-15` | Adequado ao alvo 26; não substitui automaticamente `@State`. |
| `Observations` | Apple documenta macOS 26.0+. [F14] | Não há uso no escopo de produto lido. | Opção para um consumidor externo; não altera SwiftUI automaticamente. |
| `withObservationTracking(options:_:onChange:)` e rastreamento contínuo | Apple documenta macOS 27.0+. [F15] | Não há uso no escopo de produto lido. | **Não adotar sem `if #available` e caminho alternativo** enquanto a implantação for 26. |
| `@State` | Xcode 27 muda a implementação para macro; as notas de versão descrevem retroimplantação em sistemas alinhados e compatibilidade de fonte com exceções. [F11] | `Papagaio/App/ContentView.swift:56-58,71`; `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:54-65,113-119` | **CONFIRMADO:** compilar e testar a compatibilidade no Xcode na versão geral; não há defeito confirmado. |
| `FileDocument` | As notas de versão estáveis do macOS 27 marcam o protocolo como obsoleto e apontam `ReadableDocument`/`Document`; o SDK beta local ainda o expõe sem anotação de depreciação. [F11] | `Papagaio/Suporte/DocumentoMarkdown.swift:5-23` e `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:521-529` | Preservar a compatibilidade atual do alvo 26; confirmar a depreciação no SDK na versão geral antes de planejar a migração. |
| `ReadableDocument`/`WritableDocument`/`Document` | APIs novas de macOS 27, com entrada/saída assíncrona, progresso e URL. [F11, L5] | Não são usadas no projeto. | Não introduzir uma reescrita de documentos como parte de uma atualização de Swift. |

### 3.2 `@State` no código

**CONFIRMADO — `Papagaio/App/ContentView.swift:48-71`:**

```swift
@State private var biblioteca: Biblioteca?
@State private var modelos: ModelosViewModel?
// demais propriedades
@State private var perfil = PerfilViewModel()
@State private var notificacoes = NotificacoesViewModel()
@State private var equipes = EquipesDoUsuario.carregar()
// demais propriedades
@State private var ficha = FichaDaEntrevista()
```

**CONFIRMADO — `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:54-65,113-119`:**

```swift
@State private var favorito: Bool
@State private var pasta: String?
// demais propriedades
@State private var metadados: MetadadosVisuaisDoArquivo
// inicialização explícita no init
_favorito = State(initialValue: PreferenciasVisuaisDoArquivo.favorito(arquivo.id))
// demais inicializações
_metadados = State(initialValue: PreferenciasVisuaisDoArquivo.metadados(arquivo.id))
```

**CONFIRMADO — `Papagaio/Funcionalidades/Equipes/GestaoDeEquipeView.swift:480-490,516-527`:**

```swift
@State private var permissao: ParticipanteDaEquipe.Permissao
// inicialização explícita no init
_permissao = State(initialValue: participante.permissao)
// demais propriedades
@State private var nome: String
// inicialização explícita no init
_nome = State(initialValue: nomeInicial)
```

As notas de versão do macOS 27 dizem que a implementação nova é uma macro e que o caso mais problemático é combinar um valor inicial na declaração com uma atribuição no inicializador; também apontam a composição com outros invólucros de propriedade ou macros como não suportada. [F11]

**PROVÁVEL:** os padrões explícitos `_propriedade = State(initialValue:)` são diferentes do exemplo de inicialização duplicada e não constituem falha por si só. **CONFIRMADO:** o repositório usa muitos `@State` com expressões iniciais e alguns inicializadores explícitos; portanto a compilação na versão geral precisa verificar avisos, compatibilidade de fonte e inicialização efetiva. Não houve alteração de código nem teste de visualizações prévias nesta pesquisa.

Também é importante não confundir:

- `@State` guarda o estado de apresentação/identidade local de uma tela;
- `@Observable` representa um modelo observável;
- `@StateObject` continua sendo usado no ponto de referência de `Papagaio/App/ContentView.swift:63-67` para uma caixa `ObservableObject`, e não é uma migração automática para `@Observable`. [CONFIRMADO]

### 3.3 Observação avançada: `Observations` não é `withContinuousObservation`

A API `Observations` é uma `AsyncSequence` que observa mudanças transacionais de tipos `@Observable`; sua disponibilidade documentada começa no macOS 26. [F14] O rastreamento com `options`, `willSet`/`didSet`/`deinit` e a forma contínua são APIs do macOS 27. [F15, L4]

O projeto tem `@Observable` em `Papagaio/ViewModels/GravadorViewModel.swift` e `Papagaio/ViewModels/Biblioteca.swift`, mas não consome `Observations` nem `withObservationTracking` no escopo de produto pesquisado. [CONFIRMADO — `rg` sem ocorrências e os trechos de código acima] Portanto:

- não há defeito observado por “falta de `Observations`”;
- `Observations` é uma opção de desenho para um consumidor que precise de instantâneos transacionais;
- o rastreamento avançado não pode ser uma adoção simples sem caminho alternativo para o macOS 26.

### 3.4 `FileDocument` e documentos

**CONFIRMADO — `Papagaio/Suporte/DocumentoMarkdown.swift:5-23`:**

```swift
struct DocumentoMarkdown: FileDocument {
    static let tipo = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [tipo] }
    let conteudo: String
    // inicializadores e propriedades intermediárias
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(conteudo.utf8))
    }
}
```

**CONFIRMADO — `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:521-529`:**

```swift
.fileExporter(
    isPresented: $mostrandoExportador,
    document: DocumentoMarkdown(conteudo: DossieDaConversa.gerar(arquivo: arquivo)),
    contentType: DocumentoMarkdown.tipo,
    defaultFilename: DossieDaConversa.nomeDeArquivo(para: arquivo)
) { _ in }
```

As notas de versão estáveis do macOS 27 marcam `FileDocument` como obsoleto e apontam `ReadableDocument`/`Document`. Elas também registram que `DocumentReader` e `DocumentWriter` passaram a usar `@concurrent` e que `URLDocumentConfiguration` passou a ser `@MainActor` e não conforma `Sendable`. [F11]

Há uma divergência entre o SDK beta local e as notas de versão estáveis: a interface SwiftUI do beta mostra `FileDocument` com disponibilidade desde macOS 11, mas sem anotação de depreciação (`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:23862-23872`); ainda declara `URLDocumentConfiguration : Sendable` (`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:1854-1874`) e mantém `read`/`write` como `nonisolated` (`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:1789-1800`), enquanto as notas estáveis descrevem `@concurrent`. Portanto, a conclusão estável é a da Apple, mas as anotações observadas no beta devem ser comparadas com o SDK na versão geral. [CONFIRMADO — F11, L5]

**Conclusão [PROVÁVEL]:** a exportação atual deve continuar até que o alvo de implantação e o desenho de documentos sejam planejados. A depreciação anunciada nas notas de versão do macOS 27 é uma tarefa futura, não uma justificativa para trocar `FileDocument` agora. O código de exportação não foi executado contra um sandbox real nesta pesquisa.

---

## 4. SwiftData

### 4.1 Ator, container e rollback

A documentação da Apple define `ModelActor` como `Actor` e diz que o `modelContext` serializa o código executado no ator de modelo. [F16]

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:7-35`:**

```swift
/// `@ModelActor` porque `ModelContext` não é `Sendable`: o ator garante que
/// todo acesso ao contexto acontece numa mesma fila.
@ModelActor
public actor SwiftDataRepository: ArquivoRepository {
    public static func containerLocal(
        nome: String = "Papagaio",
        emMemoria: Bool = false
    ) throws -> ModelContainer {
        let schema = Schema([
            ArquivoPersistido.self,
            TrechoPersistido.self,
            InsightPersistido.self,
            NotaPersistida.self,
            EspacoPersistido.self,
        ])
        let configuracao = ModelConfiguration(
            nome,
            schema: schema,
            isStoredInMemoryOnly: emMemoria,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuracao])
    }
}
```

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:349-362`:**

```swift
private func salvarContexto() throws {
    do {
        try modelContext.save()
    } catch {
        modelContext.rollback()
        throw error
    }
}
```

Esse helper é chamado, entre outros pontos, no caminho de `salvar` (`PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:120`) e após operações de lixeira/migração (`PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:245-259,266-292,297-346`). [CONFIRMADO — trechos abertos]

**CONFIRMADO:** o código separa structs de domínio `Sendable` de classes `@Model` não-`Sendable` (`PapagaioCore/Sources/PapagaioCore/Persistencia/ModelosSwiftData.swift:4-7,12-29,91-143`) e usa `ModelActor` como fronteira. Isso é uma aplicação coerente do modelo de isolamento do SwiftData; não prova que todos os usos futuros serão seguros. [CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Persistencia/ModelosSwiftData.swift:4-7` e `PapagaioCore/Sources/PapagaioCore/Persistencia/SwiftDataRepository.swift:7-12`]

### 4.2 Correção de SwiftData no macOS 27

As notas de versão do macOS 27 registram uma correção para um interbloqueio envolvendo `@Query`, salvar um `ModelContext` em um ator de segundo plano e agendar novas tarefas assíncronas para um `ModelActor`. [F11]

A aplicabilidade direta não está demonstrada: a busca no escopo de produto não encontrou `@Query`. [CONFIRMADO — comando `rg` em `Papagaio`/`PapagaioCore/Sources`]

**Conclusão [PROVÁVEL]:** o projeto usa `ModelContext` e `@ModelActor`, mas o cenário específico do aviso exige `@Query` e uma sequência de tarefas agendadas. Deve ser testado com o banco real ou um caso de teste que reproduza o padrão; não é um defeito do SwiftData confirmado no Ōmu apenas por usar `@ModelActor`.

A documentação de `ModelContext.save()` recomenda verificar `hasChanges` antes de salvar para evitar trabalho desnecessário. [F17] **CONFIRMADO:** o helper `salvarContexto` sempre chama `save()` nos caminhos que encapsulou. **PROVÁVEL:** essa é uma observação de design, não um defeito funcional; a alteração não foi sugerida como automática.

---

## 5. AVFoundation e Core Audio

### 5.1 Matriz de APIs e disponibilidade

Nos cabeçalhos abreviados nesta seção, `AVAudioNode.h`, `AVAudioPlayer.h`, `AVAudioRecorder.h`, `AudioHardwareTapping.h` e `NSTimer.h` correspondem, respectivamente, aos arquivos SDK listados em L1–L3.

| API | Evidência de SDK/documentação | Uso no Ōmu | Conclusão |
|---|---|---|---|
| `AVAudioRecorder` | `AVAudioRecorder.h:22-33,46-91`; disponibilidade antiga, sem `API_DEPRECATED` nos métodos usados. | `PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift:92-120` cria, configura e inicia o gravador. | **CONFIRMADO:** continua sendo uma API disponível; o comportamento do hardware/TCC não foi testado. |
| `AVAudioPlayer` | `AVAudioPlayer.h:22-38,43-58,81-90`; `stop` pode bloquear ao liberar o hardware. | `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:89-104,205-225`. | **PROVÁVEL:** `stop()` ocorre em uma classe `@MainActor`; medir em dispositivo/áudio real antes de chamar de travamento. |
| `AVAudioNode.installTap` antigo | `AVAudioNode.h:23-32` alerta que o retorno de chamada pode ocorrer fora da thread principal; `AVAudioNode.h:117` marca depreciação no macOS 27; `AVAudioNode.h:160` declara a variante com `error` no macOS 27. | `Papagaio/ViewModels/GravadorViewModel.swift:404-456`. | **CONFIRMADO no SDK beta:** o retorno de chamada pode ocorrer fora da thread principal e o código não altera estado do MainActor ali. **PROVÁVEL:** a variante substituta deve ser adotada apenas quando o alvo e a disponibilidade permitirem. |
| Tap de processo | `AudioHardwareTapping.h:42-54` marca criação/destruição desde macOS 14.2. O exemplo da Apple requer macOS 14.2. [F13, L2] | `PapagaioCore/Sources/PapagaioCore/Captura/SystemAudioTap.swift:69-90,116-172`. | **CONFIRMADO:** a guarda do produto é macOS 14.4, mais restritiva que 14.2; isso é uma condição de compatibilidade, não um defeito. |
| Timer em contexto assíncrono | `NSTimer.h:30-40,67,93`; as sobrecargas por alvo/invocação são `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`. [L3] | `PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift:128-143` e `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:116-131` usam bloco de timer + `RunLoop.main.add`. | **CONFIRMADO:** o código evita a sobrecarga oficialmente marcada; não é uma depreciação geral de `Timer`. |

### 5.2 Gravação de microfone e timer

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift:128-145`:**

```swift
// `Timer.scheduledTimer` é indisponível de contexto async no Swift 6.2
// (pode nunca disparar); criar o timer e anexá-lo ao RunLoop da main
// foge disso e garante o modo `.common`.
let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.atualizarMedicao()
    }
}
self.timer = timer
RunLoop.main.add(timer, forMode: .common)
```

O cabeçalho local confirma que a sobrecarga agendada por invocação/alvo tem a anotação de indisponibilidade em contexto assíncrono (`/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSTimer.h:67,93`). [L3] A sobrecarga com bloco, usada para criar o timer sem agendá-lo, é a que o código aproveita; portanto não se deve generalizar a anotação para todos os métodos de `Timer`. [CONFIRMADO]

**CONFIRMADO:** o ciclo de vida invalida o timer no encerramento. `PapagaioCore/Sources/PapagaioCore/Captura/SessaoGravacao.swift:341-350` mostra `timer?.invalidate()`, `timer = nil` e `recorder?.stop()` no helper `encerrarCaptura`. **PROVÁVEL:** a intenção de limpeza é explícita, mas o caminho de erro e a retenção devem ser testados com uma sessão real.

### 5.3 Ditado e retorno de chamada de áudio

**CONFIRMADO — `Papagaio/ViewModels/GravadorViewModel.swift:404-456`:**

```swift
/// `installTap` entrega buffers na thread de áudio em tempo real.
// demais propriedades e métodos
final class CapturaDeDitado: @unchecked Sendable {
    // demais propriedades
    entrada.installTap(onBus: 0, bufferSize: 2_048, format: formato) { buffer, _ in
        pedidoDoTap.append(buffer)
        try? arquivo.write(from: buffer)
    }
```

O cabeçalho da Apple confirma que o retorno de chamada pode ser chamado em outra thread (`AVAudioNode.h:23-32`). [F12, L1] O comentário do projeto registra uma falha anterior ao tocar estado do MainActor na thread de áudio (`Papagaio/ViewModels/GravadorViewModel.swift:404-414`). [CONFIRMADO]

**Avaliação [PROVÁVEL]:** a separação de `CapturaDeDitado` e o `@unchecked Sendable` parecem coerentes com a fronteira do retorno de chamada, mas o compilador não verifica a exclusão entre reconhecimento de voz, encerramento e escrita. É uma invariante de execução; não é prova de corrida de dados nem de correção completa. É necessário testar com retorno de chamada real, interrupção do microfone e encerramento concorrente.

O `installTap` usado aqui é a sobrecarga antiga. O SDK beta a marca como obsoleta para macOS 27, mas o projeto tem alvo 26; a depreciação deve aparecer como aviso, não como mudança de disponibilidade para esse alvo. **[PROVÁVEL — L1; confirmar no Xcode na versão geral]**

### 5.4 Reprodução

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:21-26,89-104`:**

```swift
@MainActor
@Observable
public final class ReprodutorDeArquivo {
    // demais propriedades
    public init(
        audio: URL,
        trechos: [Trecho],
        secundario urlSecundario: URL? = nil,
        intervalo: TimeInterval = ReprodutorDeArquivo.intervaloDeObservacao
    ) {
        self.trechos = trechos
        self.primario = try? AVAudioPlayer(contentsOf: audio)
        self.secundario = urlSecundario.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        self.intervaloDeObservacao = intervalo
    }
```

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:205-225`:**

```swift
public func encerrar() {
    temporizador?.invalidate()
    temporizador = nil
    primario?.stop()
    secundario?.stop()
    tocando = false
}
// demais métodos
isolated deinit {
    encerrar()
}
```

O cabeçalho de `AVAudioPlayer` diz que `stop` bloqueia enquanto libera o hardware de áudio (`AVAudioPlayer.h:55-58`). [L1] Como `encerrar()` é método de um tipo `@MainActor`, a chamada é um candidato a trabalho síncrono no ator principal. **PROVÁVEL:** isso merece Instruments com um arquivo real, mas não há medição de latência nesta ficha e não se transforma em achado de defeito.

A desmontagem do timer é feita em `.onDisappear` (`Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:513-520`); o reprodutor é criado na `.task` da mesma tela (`Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:484-505`) e seus trechos são atualizados em `.onChange` (`Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:506-511`). [CONFIRMADO — trechos abertos] Isso é uma boa condição de ciclo de vida para testar, não prova de vazamento.

### 5.5 Tap de processo e retorno de chamada de IOProc

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Captura/SystemAudioTap.swift:1,69-90,147-172`:**

```swift
@preconcurrency import AudioToolbox
// configuração e criação do tap
guard #available(macOS 14.4, *) else { throw SystemAudioTapError.apiUnavailable }
// criação do tap
status = AudioHardwareCreateProcessTap(description, &newTapID)
// criação do IOProc
status = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil) { _, inputData, _, _, _ in
    // conversão do buffer
    state.consume(buffer: buffer, frames: frames)
}
// início do dispositivo
status = AudioDeviceStart(aggregateDeviceID, ioProcID)
```

O cabeçalho do Core Audio marca `AudioHardwareCreateProcessTap` e `AudioHardwareDestroyProcessTap` como macOS 14.2+ (`AudioHardwareTapping.h:42-54`). [L2] O exemplo da Apple diz que o tap deve ser usado em um dispositivo agregado e requer macOS 14.2+ e `NSAudioCaptureUsageDescription`. [F13]

O projeto tem a chave de permissão:

`Config/Info.plist:22-23`

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>O Ōmu grava o áudio da reunião para transcrever a fala do seu interlocutor.</string>
```

[CONFIRMADO]

O escritor evita `AVAudioFile` e usa `ExtAudioFileWriteAsync` no retorno de chamada (`PapagaioCore/Sources/PapagaioCore/Captura/SystemAudioTap.swift:350-403,451-471`). [CONFIRMADO] A intenção é reduzir conversões e alocações explícitas no caminho de tempo real, mas o código não mede perdas de áudio, CPU, quedas ou qualidade. **PROVÁVEL:** o desenho é compatível com a preocupação de tempo real; somente um teste com uma rota de saída real pode confirmar.

### 5.6 Correção de AVFAudio no macOS 27

As notas de versão do macOS 27 registram uma correção de uma possível falha de AudioDSP quando as propriedades do dispositivo de áudio mudam. [F11] É uma correção de sistema pertinente ao domínio, mas não há teste que atribua qualquer falha do Ōmu a ela. [PROVÁVEL]

---

## 6. Apple Concurrency: padrões e anti-padrões

### 6.1 Isolamento de UI

**CONFIRMADO — `Papagaio/ViewModels/GravadorViewModel.swift:7-11`:**

```swift
/// Estado de gravação para a UI.
@MainActor
@Observable
final class GravadorViewModel {
```

**CONFIRMADO — `Papagaio/ViewModels/Biblioteca.swift:13-21`:**

```swift
@MainActor
@Observable
final class Biblioteca {
```

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:19-23`:**

```swift
@MainActor
@Observable
public final class ReprodutorDeArquivo {
```

A Apple recomenda usar a thread principal para a interface e mover o trabalho que não é de UI para segundo plano. [F20, F21, F22] Isso NÃO foi medido nem transforma todo `@MainActor` em problema. As evidências mostram apenas uma fronteira explícita e coerente nos modelos de visualização principais.

### 6.2 Trabalho C síncrono dentro de atores

**CONFIRMADO — `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:73-88,137-178`:**

```swift
/// `whisper_context` não é thread-safe.
public actor ContextoWhisper {
    private final class Caixa: @unchecked Sendable {
        // ponteiro e liberação
    }
    public func transcrever(
        amostras: [Float],
        // demais parâmetros
    ) throws -> [SegmentoWhisper] {
        // carregar e preparar parâmetros
        return amostras.withUnsafeBufferPointer { buffer in
            whisper_full(contexto, params, buffer.baseAddress, Int32(buffer.count))
        }
```

**CONFIRMADO — `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:136-155,178-210`:**

```swift
public func completar(
    prompt: String,
    // demais parâmetros
) throws -> String {
    try Task.checkCancellation()
    // carregar contexto e tokenizar
    while offset < tokens.count {
        try Task.checkCancellation()
        let codigo: Int32 = tokens.withUnsafeMutableBufferPointer { buffer in
            let fatia = buffer.baseAddress! + offset
            return llama_decode(contexto, llama_batch_get_one(fatia, Int32(fim - offset)))
        }
        guard codigo == 0 else { throw ErroLlama.falhaNoDecode(codigo) }
        offset = fim
    }
    while gerados < maxTokens {
        try Task.checkCancellation()
        // decodificar token
```

**CONFIRMADO — `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:24-34,106-129`:**

```swift
/// `OrtSession` não é thread-safe.
public actor SessaoOnnx {
    // ponteiros e libertação
    public func rodar(
        entradas: [String: DadosTensorOnnx],
        saidas: [String]
    ) throws -> [String: DadosTensorOnnx] {
        try carregar()
        // preparar buffers
```

A documentação da Apple/WWDC21 explica que o pool cooperativo presume que as threads podem avançar; trabalho bloqueante ou esperas fora do modelo podem causar queda de progresso, inanição ou interbloqueio. [F22] A documentação de travamentos também distingue trabalho síncrono na thread principal de uma tarefa que apenas posterga trabalho pesado para ela. [F20, F21]

**PROVÁVEL:** chamadas C síncronas dentro desses atores podem ocupar um executor cooperativo por longos intervalos. **CONFIRMADO:** `ContextoWhisper` não tem `Task.checkCancellation` dentro de `whisper_full`; `ContextoLlama` verifica antes de lotes e antes de tokens; `SessaoOnnx` não tem um ponto de cancelamento no trecho lido. Essa diferença de granularidade está comprovada no código, mas não é uma medição de atraso.

A ação correta é medir com Instruments Swift Concurrency/Time Profiler e testar cancelamento durante inferência real. Não é automaticamente “mover tudo para `Task.detached`”.

### 6.3 `Task.detached`

A documentação da Apple define `Task.detached` como uma tarefa de nível superior não estruturada, recomenda concorrência estruturada quando possível e diz que o cancelamento da tarefa pai não cancela automaticamente uma tarefa desacoplada; é preciso manter uma referência explícita para cancelá-la. [F18]

A busca em `Papagaio` e `PapagaioCore/Sources` encontrou **6 ocorrências** de produto:

| Local | Forma observada | Leitura de auditoria |
|---|---|---|
| `Papagaio/ViewModels/Biblioteca.swift:1435-1442` | `await Task.detached { /* operação */ }.value` para `AVURLAsset.load(.duration)` | Tarefa desacoplada aguardada para ler a duração; o valor é aguardado. |
| `Papagaio/Suporte/OpcoesDeCompartilhamento.swift:38-58` | `Task.detached` sem referência explícita; o erro volta por `MainActor.run` | Cópia de dossiê fora da thread principal; cancelamento e ciclo de vida precisam de teste. |
| `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:571-594` | `Task.detached` sem referência explícita no retorno de `NSOpenPanel` | Cópia de pasta; o fechamento referencia estado da tela via `MainActor.run` em `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:590-592`. |
| `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:608-614` | `await Task.detached { zip }.value` | Tarefa desacoplada aguardada para compactar; o valor é aguardado. |
| `Papagaio/Funcionalidades/Biblioteca/PastasDaBiblioteca.swift:97-105` | `await Task.detached { pastaComTudo }.value` | Tarefa desacoplada aguardada para montar o dossiê; o valor é aguardado. |
| `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1222-1233` | `await Task.detached { pacoteComAudio }.value` | Tarefa desacoplada aguardada para montar o pacote de áudio; o valor é aguardado. |

**CONFIRMADO:** quatro são aguardadas com `.value` e duas são descartadas sem espera (sem referência explícita). Isso é uma contagem estática, não um achado de domínio. [CONFIRMADO — listagem `rg` e trechos abertos]

**PROVÁVEL:** as duas tarefas descartadas sem espera são as mais sensíveis a cancelamento e ao ciclo de vida da tela. Não há medição de retenção, CPU ou travamento; não as classifico como defeito. A recomendação é criar testes de cancelamento e decidir se o trabalho deve ser modelado como tarefa estruturada quando o fluxo permitir.

### 6.4 Tarefas, cancelamento e retenção

Há uso positivo de `Task.isCancelled` e `Task.checkCancellation` em produção. Exemplos:

- `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:179-193` verifica cancelamento depois de entrar na fila e libera a fila em `do/catch`.
- `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:107-140,160-189` verifica entre fases e antes dos dois salvamentos.
- `PapagaioCore/Sources/PapagaioCore/Transcricao/WhisperEngine.swift:82-124` verifica por janela de VAD/Whisper.
- `Papagaio/ViewModels/GravadorViewModel.swift:131-142,237-256` cancela tarefas de avisos e nível e faz consultas periódicas de forma cooperativa.
- `Papagaio/Integracao/GoogleCalendarViewModel.swift:152-166` mantém uma tarefa de sincronização e trata o cancelamento durante a suspensão.

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Runtime/MotoresLocais.swift:179-193`:**

```swift
private func comExclusividade<T: Sendable>(
    _ operacao: () async throws -> T
) async throws -> T {
    await fila.entrar()
    do {
        try Task.checkCancellation()
        let resultado = try await operacao()
        await fila.sair()
        return resultado
    } catch {
        await fila.sair()
        throw error
    }
}
```

**CONFIRMADO:** o `do/catch` libera a fila mesmo quando a operação falha. **PROVÁVEL:** o código C síncrono dentro de `operacao` não pode ser interrompido por uma simples verificação.

`PapagaioCore/Sources/PapagaioCore/Transcricao/FilaEstrita.swift:3-37` documenta e implementa uma fila explícita porque um ator comum é reentrante durante `await`; a escolha é local e não é um defeito. [CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Transcricao/FilaEstrita.swift:3-16,18-37`]

### 6.5 `async let`, grupos de tarefas e fluxos

Há um uso de `async let` em produto:

`Papagaio/Suporte/PromptDeEntidades.swift:9-24`

```swift
async let termosDoCalendario = termosDoCalendario(
    inicio: arquivo.criadoEm,
    fim: arquivo.criadoEm.addingTimeInterval(max(arquivo.duracao, 1))
)
async let termosDosContatos = termosDosContatos()
let termos = (await termosDoCalendario + termosDosContatos)
```

[CONFIRMADO]

No mesmo escopo de produto, a busca não encontrou `withTaskGroup`, `for await`, `AsyncStream` ou `AsyncThrowingStream`. Isso é uma **observação de estilo**, não um achado: o app usa consultas periódicas, `Task` e continuações em pontos diferentes. [CONFIRMADO — `rg` em `Papagaio`/`PapagaioCore/Sources`]

Não se deve concluir que a ausência de grupo de tarefas ou fluxo seja um problema de desempenho sem medir. Se houver fases realmente independentes, a auditoria futura pode comparar `async let`/grupo de tarefas com o pipeline atual, preservando a exclusividade de modelos.

### 6.6 `MainActor.assumeIsolated`

A documentação da Apple é explícita: `assumeIsolated` deve ser usado apenas quando o contexto atual já está no executor serial do MainActor; caso contrário, há erro fatal. [F19]

Há três usos, com as justificativas locais citadas na §2.4. [CONFIRMADO]

| Uso | Evidência | Classificação |
|---|---|---|
| Timer do reprodutor | `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:126-131` adiciona ao `RunLoop.main` e usa bloco fraco | **PROVÁVEL:** consistente com a documentação, mas a garantia depende do caminho de entrega do timer. |
| AuthenticationServices | `Papagaio/ViewModels/PerfilViewModel.swift:240-247` usa protocolo nonisolated | **PROVÁVEL:** a API de apresentação deve ser consultada na thread principal; testar o fluxo real. |
| `NSAnimationContext` | `Papagaio/Funcionalidades/Gravacao/JanelaFlutuanteDeGravacao.swift:182-191` | **PROVÁVEL:** o comentário afirma thread principal, mas o retorno de chamada importado é a área sensível de SE-0463. |

Não substituir globalmente por `MainActor.run`: a semântica síncrona e a garantia de executor são diferentes. [F19]

### 6.7 Travas, semáforos e E/S síncrona

**CONFIRMADO — `Papagaio/Integracao/ClienteMCP.swift:32-43,77-86`:**

```swift
final class ClienteMCP: @unchecked Sendable {
    // demais propriedades
    private let trava = NSLock()
    // demais métodos
    private func garantirInicializacao() async throws {
        let tarefa: Task<Void, Error>? = trava.withLock {
            // verificar estado e reutilizar/criar a tarefa
            let nova = Task { try await self.inicializar() }
            inicializacao = nova
            return nova
        }
        try await tarefa?.value
```

O `await` ocorre fora da trava; isso é diferente de manter uma trava atravessando uma suspensão. [CONFIRMADO]

**CONFIRMADO — `PapagaioCore/Sources/PapagaioCore/Runtime/CicloDeVidaDeModelos.swift:91-114`:**

```swift
observadorDeSaida = NotificationCenter.default.addObserver(
    // nome e objeto
    queue: .main
) { [weak self] _ in
    // guardar a referência
    let espera = DispatchSemaphore(value: 0)
    Task {
        await self.descarregarTudo()
        espera.signal()
    }
    _ = espera.wait(timeout: .now() + 2)
}
```

A WWDC21 desaconselha semáforos e variáveis de condição que escondem dependências entre tarefas; a Apple também explica que uma thread principal bloqueada é um caminho clássico de travamento. [F22, F20] [PROVÁVEL] Este código está na saída do app, tem um tempo limite explícito de 2 segundos e comenta a decisão, portanto é uma condição controlada a medir, não um defeito confirmado. O número é um tempo limite codificado, não uma medição de desempenho.

Também existem operações de E/S síncronas no initializer e em métodos de atores. Por exemplo, `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:38-52` lê `Data(contentsOf:)` e `Papagaio/CloudKit/FilaPersistenteCloudKit.swift:211-220` escreve JSON atomicamente. [CONFIRMADO — trechos abertos] Isso pode bloquear o executor do ator, mas o código não demonstra que a thread principal está esperando essa fila. [PROVÁVEL]

### 6.8 Escapes de verificação

A busca em código de produto/core encontrou 13 usos de `@unchecked Sendable` e um uso efetivo de `nonisolated(unsafe)` (mais uma ocorrência em comentário). [CONFIRMADO — `rg`]

Casos relevantes:

- `PapagaioCore/Sources/WhisperRuntime/ContextoWhisper.swift:82-92`, `PapagaioCore/Sources/LlamaRuntime/ContextoLlama.swift:36-46` e `PapagaioCore/Sources/OnnxApi/SessaoOnnx.swift:31-55`: caixas de ponteiros C com `deinit`; o acesso é protegido pelo ator, mas a prova é uma convenção de código. [CONFIRMADO]
- `PapagaioCore/Sources/PapagaioCore/Captura/NivelAudio.swift:10-25`: `@unchecked Sendable` combinado com `Atomic<UInt32>`; é o caso com uma primitiva de sincronização explícita. [CONFIRMADO]
- `Papagaio/ViewModels/GravadorViewModel.swift:404-421`: retorno de ditado fora do MainActor, com estado manual e comentário de falha anterior. [CONFIRMADO]
- `Papagaio/Integracao/ClienteMCP.swift:32-43` e `Papagaio/Integracao/GerenciadorDeCallbackDeAutorizacao.swift:13-52`: travas e invariantes manuais. [CONFIRMADO]
- `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:7,321`: invólucros `@unchecked Sendable` para valores opacos do CloudKit; a validade do contrato depende do uso e do isolamento manuais. [CONFIRMADO]
- `PapagaioCore/Sources/DiarizationRuntime/DiarizadorFluidoOffline.swift:39-58`: `nonisolated(unsafe) let gerente` dentro de um ator, com comentário de que a exclusividade é do ator. [CONFIRMADO]

Esses pontos devem ser tratados como **invariantes a revisar**, não como `@unchecked Sendable` incorreto. O compilador não prova o contrato que o comentário promete. [PROVÁVEL]

---

## 7. Mudanças incompatíveis, correções, depreciações e ganhos

### 7.1 Mudanças incompatíveis e compatibilidade

| Item | Tipo | Impacto potencial no Ōmu | Decisão |
|---|---|---|---|
| Modo de linguagem Swift 6 | mudança incompatível de compilação já incorporada | O projeto está em `SWIFT_VERSION=6.0` e `.v6`. [CONFIRMADO] | Não migrar novamente. |
| `default-isolation MainActor` | recurso experimental opcional | Pode mudar o executor de código não isolado e gerar diagnósticos. [#88173 é reproduzível apenas com a opção e compilação otimizada. F27] | Manter desligado até uma migração medida. |
| `NonisolatedNonsendingByDefault` | recurso experimental opcional | Alteraria a semântica de funções e fechamentos e teve problemas de isolamento. [#88731/#87097. F25] | Não ativar automaticamente. |
| SE-0463 | mudança de importação Objective-C | Manipuladores de conclusão podem deixar de inferir MainActor; explica os usos de `assumeIsolated`. [F9, F24] | Auditar cada retorno de chamada; não é defeito confirmado. |
| Nova macro de `@State` | mudança de implementação/compatibilidade de fonte | Inicializadores e expressões de inicialização precisam de uma verificação de compilação. [F11] | Compilar e testar no Xcode na versão geral. |
| `DocumentReader`/`DocumentWriter` | APIs do macOS 27; `URLDocumentConfiguration` muda o isolamento | Só afetaria uma futura migração de documentos. [F11, L5] | Não reescrever `FileDocument` agora. |
| `installTap` antigo | depreciação no macOS 27 | O uso atual continua compatível com o alvo 26; a substituta exige macOS 27. [L1] | Manter até revisar a implantação. |

### 7.2 Correções

- **SwiftData:** correção de interbloqueio `@Query`/`ModelContext` em ator de segundo plano/`ModelActor` aparece nas notas de versão do macOS 27. [F11] Aplicabilidade não confirmada no Ōmu.
- **AVFAudio:** correção de possível falha de AudioDSP ao mudar propriedades do dispositivo. [F11] Atribuição ao app não confirmada.
- **SwiftUI `@State`:** a nova implementação deixa de reavaliar continuamente uma expressão inicial; a própria Apple lista correções de compilação em `@State` e `#Preview`. [F10, F11]
- **Execução/compilador do Swift 6.3:** o problema #88259 foi fechado por uma correção do otimizador no PR #88285; o relato era específico de Swift 6.3/Xcode 26.4 e não prova que Swift 6.4 reproduza o problema. [F26]
- **SE-0463:** o problema #82127 está fechado; trata-se de registro de compatibilidade de migração, não de uma regressão aberta comprovada no 6.4. [F24]

### 7.3 Depreciações e anotações de disponibilidade

1. **`AVAudioNode.installTap(onBus:bufferSize:format:block:)`** é marcado como obsoleto no macOS 27 no cabeçalho local; a variante com `error`/resultado é `API_AVAILABLE(macos(27.0))`. [CONFIRMADO — `AVAudioNode.h:117,160`]
2. **`FileDocument`** é marcado como obsoleto nas notas de versão estáveis do macOS 27; Apple aponta `ReadableDocument` para leitura e `Document` para leitura/escrita. A interface do SDK beta local ainda não contém essa anotação. [F11, L5]
3. **`Timer.scheduledTimer` em contexto assíncrono** não é uma depreciação geral: as sobrecargas relevantes são marcadas `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`. O código já usa o caminho manual. [L3]
4. **APIs de Swift 6.2/6.4** não estão obsoletas; algumas são opcionais ou condicionais. Não confundir “novo” com “obrigatório”.

### 7.4 Ganhos aplicáveis

Os seguintes são recursos documentados, não medições deste projeto:

- **Swift 6.4:** limpeza assíncrona em `defer`; [F2, F6]
- **Swift 6.4:** escudo de cancelamento para a limpeza, com a restrição de sistema operacional deste projeto; [F2, F7, L6]
- **Swift 6.4:** rastreamento fino e continuável de Observation, com API do macOS 27; [F2, F8, F15]
- **Swift 6.2:** `Observations` no macOS 26, `@concurrent` e o recurso experimental `nonisolated(nonsending)`; [F3, F14]
- **Swift 6.2:** `NotificationCenter` tipado; [F3]
- **Xcode 27:** Instruments ganhou ferramentas de perfilamento de tarefas, executores e atores, e o SwiftUI `@State` foi reimplementado; [F10, F11]
- **SwiftUI 27:** documentos assíncronos com progresso e URLs; [F11]

**Não há número de ganho de desempenho medido para o Ōmu nesta pesquisa.** Expressões como “evita reavaliação” ou “permite trabalho fora da thread principal” descrevem a fonte, não um resultado observado no app. [CONFIRMADO]

---

## 8. Defeitos conhecidos e questões abertas

### 8.1 Problemas conhecidos do Swift

| Problema | Estado observado em 23/09/2026 | Relação com o projeto |
|---|---|---|
| [#82127](https://github.com/swiftlang/swift/issues/82127) | Fechado; aberto em 09/06/2025; caso SE-0463 no Swift 6.2. [F24] | Ajuda a explicar por que retornos de chamada do AppKit exigem `assumeIsolated`; não é prova de falha no código atual. |
| [#88731](https://github.com/swiftlang/swift/issues/88731) | Fechado como duplicata de [#87097](https://github.com/swiftlang/swift/issues/87097); o relato exigia `NonisolatedNonsendingByDefault`. [F25] | A opção não foi encontrada; não atribuir a falha ao projeto. |
| [#87097](https://github.com/swiftlang/swift/issues/87097) | Fechado; isolamento perdido com lista de captura em `nonisolated(nonsending)`. [F25] | Só importa se o recurso experimental for ativado; não está no estado atual. |
| [#88259](https://github.com/swiftlang/swift/issues/88259) | Fechado; o PR [#88285](https://github.com/swiftlang/swift/pull/88285) foi mesclado em 16/04/2026; erro do otimizador no Swift 6.3. [F26] | Correção histórica; não reproduzido nem atribuído ao 6.4. |
| [#88173](https://github.com/swiftlang/swift/issues/88173) | Aberto; falha do compilador com `-default-isolation MainActor` e otimização. [F27] | Não se aplica enquanto a opção não estiver no projeto; não ativar para “resolver” sem teste. |

Um relato em um tópico do fórum Swift afirma que `MainActor.assumeIsolated` podia falhar até na thread principal durante o carregamento de NIB no Swift 6.2. [F28] O fórum é hospedado pela Apple, mas o conteúdo é de usuário; classifiquei como **PROVÁVEL**, não como aviso oficial nem como reprodução do Ōmu. Não encontrei uma página oficial de problemas conhecidos específica de concorrência do Swift 6.4 que resolva esse ponto. [CONFIRMADO — consulta às fontes]

### 8.2 O que não foi verificado

- Correção dos problemas acima especificamente na compilação estável `27A266a`.
- Problemas conhecidos de concorrência do Swift 6.4 no macOS 26/27.
- Reprodução de `assumeIsolated` nos retornos de chamada de Timer, AuthenticationServices e `NSAnimationContext` em uma sessão real.
- Correlacionar falha de AudioDSP ou de SwiftData com este app.
- Comportamento de `@State` em todas as configurações e inferência de tipos genéricos com o Xcode 27 na versão geral.

---

## 9. Segurança e avisos de segurança

### 9.1 Avisos de segurança oficiais consultados

| Aviso | Versão/data | CVEs representativas e descrição | Relação correta com o projeto |
|---|---|---|---|
| Xcode 27 | 14/09/2026 | `CVE-2026-65393`: um app poderia acessar dados sensíveis por falha de validação de permissões no Xcode IDE. [F30] | É risco da ferramenta de desenvolvimento, não prova de app distribuível vulnerável. |
| macOS Golden Gate 27 | 14/09/2026 | AppKit `CVE-2026-84587`; Foundation `CVE-2026-65409`/`86911`; Authentication Services `CVE-2026-86905`; TCC `CVE-2026-84527`, entre outros. [F29] | O app usa AppKit/Foundation/Authentication Services, mas alcance, entrada maliciosa e exposição não foram testados. |
| macOS Tahoe 26.7 | 14/09/2026 | inclui CVEs de Foundation, AppKit, Sign in with Apple/Apple Account, TCC, CoreMedia e outros. [F31] | O alvo de implantação é macOS 26; a versão de patch do sistema operacional deve ser verificada separadamente do SDK usado para compilar. |

O projeto usa Keychain, por exemplo `PapagaioCore/Sources/PapagaioCore/Integracao/CofreDeTokens.swift:4-7,14-25,30-43`; isso torna a categoria Authentication Services/Keychain relevante para acompanhamento, mas **não** demonstra que `CVE-2026-86905` afete a aplicação. [CONFIRMADO — código aberto; exposição não verificada]

A página de segurança do Swift lista avisos antigos do ecossistema, principalmente de Linux/NIO; a página de avisos do repositório `swiftlang/swift` exibe “There aren't any published security advisories” (“Não há avisos de segurança publicados”), enquanto a política descreve o procedimento oficial de relato. [F32, F34, F35] Isso é o resultado da consulta, não prova de ausência absoluta de vulnerabilidades no compilador, no SDK ou nos binários.

### 9.2 Limites de análise

Não foi feita nesta ficha:

- análise de CVEs dos XCFrameworks whisper/llama/ONNX ou dos modelos;
- verificação de assinaturas, permissões efetivas de cada binário ou superfície de exploração;
- TSan/Thread Sanitizer;
- execução com serviço real, OAuth real, CloudKit real ou sistema de áudio real;
- teste de patch do macOS 26/27 em hardware de usuário;
- auditoria de SBOM ou de dependências transitivas.

A presença de um CVE na página de um produto Apple não é convertida em achado de código do Ōmu. [CONFIRMADO]

---

## 10. Recomendações de validação, sem alteração automática

1. **Fixar uma matriz de ferramentas:** repetir compilações Debug/Release com Xcode 27.0 `27A266a`, Swift 6.4 e SDK estável 27, mantendo `MACOSX_DEPLOYMENT_TARGET=26.0`. Registrar compilador, vinculador, SDK e sistema operacional separadamente.
2. **Testar disponibilidade em duas linhas:** compilar e executar no macOS 26 e no macOS 27. Para `withTaskCancellationShield` e o rastreamento avançado, confirmar o caminho alternativo; para `Observations`, testar no alvo 26.
3. **Auditar `@State`:** compilar todas as configurações com o Xcode na versão geral e exercitar inicializadores, `onDisappear`, visualizações prévias e reconstruções de tela. Não assumir que a mudança de implementação preserva toda a semântica de inicialização.
4. **Medir concorrência:** usar Instruments Swift Concurrency/Executors e Time Profiler durante transcrição, resumo e VAD. Registrar apenas tempos observados; esta ficha não fornece uma linha de base de desempenho.
5. **Testar cancelamento e ciclo de vida:** testar uma a uma as seis ocorrências de `Task.detached`, com foco nas duas sem referência explícita, e os três `assumeIsolated`; testar primeiro plano/segundo plano, cancelamento durante a inferência e saída da tela.
6. **Testar áudio real:** microfone, tap de processo, rota de saída, pausa/retomada, alterações de propriedades do dispositivo e limpeza. Usar as permissões reais; não inferir qualidade de gravação ou congelamento por leitura estática.
7. **Testar SwiftData:** criar um caso de teste com `@Query` apenas se a arquitetura realmente precisar dele; exercitar `ModelActor`, `save`/`rollback`, migrações e operações concorrentes. A nota de interbloqueio do macOS 27 não deve ser tratada como reprodução deste defeito sem reprodução.
8. **Manter sinalizadores experimentais desligados:** não adicionar `DefaultIsolation`, `NonisolatedNonsendingByDefault` ou `SWIFT_UPCOMING_FEATURE` por causa de uma nota de lançamento. Qualquer adoção deve ter um problema rastreado, matriz de compilação e teste de execução.
9. **Planejar `FileDocument` para uma mudança de implantação:** não migrar o exportador para `Document` enquanto o app precisa do caminho macOS 26; quando migrar, testar `DocumentReader`/`DocumentWriter`, `@concurrent` e `URLDocumentConfiguration` no MainActor, confirmando também a divergência entre o SDK beta e as notas de versão estáveis.
10. **Revisar avisos de segurança no fluxo de lançamento:** aplicar correções de Xcode/macOS e manter a etapa de segurança separada da afirmação de compatibilidade com Swift.

Essas são condições de verificação. Nenhuma delas autoriza mudança automática de código, dependência, sinalizador ou alvo de implantação.

---

## 11. Conclusão

**CONFIRMADO:** o manifesto e o projeto declaram o modo de linguagem Swift 6 e a verificação completa; o arquivo de resolução da dependência SwiftPM é coerente; Swift 6.4 é a versão estável da data; e o SDK local é de um Xcode beta. [F1, F2, F10]

**CONFIRMADO:** a implantação no macOS 26 é a restrição mais importante para a comparação. `withTaskCancellationShield` e o rastreamento avançado de Observation aparecem no SDK beta local como macOS 27; `Observations` aparece como macOS 26. [F14, F15, L4, L6]

**CONFIRMADO:** o código demonstra bons padrões em vários pontos — `@MainActor` para modelos de visualização, atores para contextos C/SwiftData, `Task.checkCancellation` em pontos de fase, fila explícita e retornos de chamada de áudio fora do MainActor. [Arquivos e linhas citados nas §§3–6]

**PROVÁVEL:** os riscos de pesquisa a investigar são trabalho C síncrono em atores, duas `Task.detached` sem referência explícita, retornos de chamada com `assumeIsolated`, E/S síncrona em ator e o possível `AVAudioPlayer.stop` no MainActor. São pontos de teste, não defeitos declarados. Nenhuma medição de desempenho ou reprodução de execução foi feita para provar impacto.

**CONFIRMADO:** a comparação com SwiftUI do macOS 27, SwiftData, AVFAudio e avisos de segurança revela APIs e obsoletações que exigem planejamento, mas não autoriza trocar o alvo de implantação, ativar recursos experimentais, migrar `FileDocument` ou reescrever produção nesta ficha.

---

## 12. Registro de fontes

Todas as fontes abaixo foram acessadas em **23/09/2026**. `HTTP 200` indica a resposta verificada no acesso. Nas páginas da Apple renderizadas dinamicamente, a variante `.md` também foi consultada quando disponível. Quando a página não informa data de publicação, o registro identifica a versão ou o SDK e mantém a data de acesso. `L1`–`L6` são evidências locais do SDK e não URLs.

### Fontes primárias — Apple, Swift e Swift Evolution

- **F1 — https://developer.apple.com/news/releases** — *Releases*, Apple Developer; 14/09/2026; Xcode 27.0 (`27A266a`) e macOS 27.0 (`26A428`); **HTTP 200**; ponto: números de compilação e datas da plataforma estável 27.
- **F2 — https://www.swift.org/blog/swift-6.4-released/** — *Swift 6.4 Released*, Swift.org; 15/09/2026; Swift 6.4; **HTTP 200**; ponto: `async defer`, `withTaskCancellationShield`, Observation avançado e melhorias de ferramentas.
- **F3 — https://www.swift.org/blog/swift-6.2-released/** — *Swift 6.2 Released*, Swift.org; 15/09/2025; Swift 6.2; **HTTP 200**; ponto: concorrência acessível, isolamento padrão opcional, `nonisolated(nonsending)`, `@concurrent`, `Observations`, `NotificationCenter` e ferramentas de migração.
- **F4 — https://www.swift.org/blog/swift-6.3-released/** — *Swift 6.3 Released*, Swift.org; 24/03/2026; Swift 6.3; **HTTP 200**; ponto: seletores de módulo, inclusive `Swift::Task`, e mudanças do lançamento.
- **F5 — https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/** — *Swift 6 Concurrency Migration Guide — Enable data-race safety*, Swift.org; Swift 6; **HTTP 200**; ponto: a verificação de segurança de dados deve ser ativada progressivamente e a verificação completa é o destino do modo Swift 6.
- **F6 — https://github.com/swiftlang/swift-evolution/blob/main/proposals/0493-defer-async.md** — *SE-0493 Support async calls in defer bodies*, Swift Evolution; status Implementado no Swift 6.4; **HTTP 200**; ponto: `async defer` é aditivo, a saída do escopo é aguardada e o cancelamento continua observável.
- **F7 — https://github.com/swiftlang/swift-evolution/blob/main/proposals/0504-task-cancellation-shields.md** — *SE-0504 Task Cancellation Shields*, Swift Evolution; status Implementado no Swift 6.4; **HTTP 200**; ponto: o escudo oculta o cancelamento recebido no escopo e nas tarefas filhas, sem implantação retroativa.
- **F8 — https://github.com/swiftlang/swift-evolution/blob/main/proposals/0506-advanced-observation-tracking.md** — *SE-0506 Advanced Observation Tracking*, Swift Evolution; status Implementado no Swift 6.4; **HTTP 200**; ponto: `options`, tipos de evento e observação contínua são APIs especializadas.
- **F9 — https://github.com/swiftlang/swift-evolution/blob/main/proposals/0463-sendable-completion-handlers.md** — *SE-0463 Import Objective-C completion handler parameters as @Sendable*, Swift Evolution; status Implementado no Swift 6.2; **HTTP 200**; ponto: importação de manipuladores de conclusão Objective-C e diagnósticos de isolamento.
- **F10 — https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes.md** — *Xcode 27 Release Notes*, Apple Developer; Xcode 27, Swift 6.4 e SDK 27; 14/09/2026; **HTTP 200**; ponto: Xcode 27 inclui Swift 6.4, SDK 27, melhorias de concorrência no Instruments e mudanças de ferramentas.
- **F11 — https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes.md** — *macOS 27 Golden Gate Release Notes*, Apple Developer; SDK do macOS 27; 14/09/2026; **HTTP 200**; ponto: correção de AVFAudio, interbloqueio de SwiftData, nova implementação de `@State`, APIs de documentos, depreciação de `FileDocument` e orientação de migração.
- **F12 — <https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)>** — *installTap(onBus:bufferSize:format:block:)*, Apple Developer documentation; AVFAudio, página da versão macOS 27; **HTTP 200**; ponto: identifica a API; o cabeçalho local L1 documenta que o retorno de chamada pode ocorrer fora da thread principal.
- **F13 — https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps.md** — *Capturing system audio with Core Audio taps*, exemplo da Apple; Core Audio, corpo do exemplo exige macOS 14.2+; **HTTP 200**; ponto: tap de processo, dispositivo agregado, chave de permissão e versão mínima.
- **F14 — https://developer.apple.com/documentation/observation/observations.md** — *Observations*, Apple Developer documentation; Observation/Swift, disponibilidade macOS 26+; **HTTP 200**; ponto: `AsyncSequence` de mudanças transacionais de tipos `@Observable`.
- **F15 — <https://developer.apple.com/documentation/observation/withobservationtracking(options:_:onchange:).md>** — *withObservationTracking(options:_:onChange:)*, Apple Developer documentation; Observation/Swift, disponibilidade macOS 27+; **HTTP 200**; ponto: disponibilidade da API avançada com `options`.
- **F16 — https://developer.apple.com/documentation/swiftdata/modelactor.md** — *ModelActor*, Apple Developer documentation; SwiftData/Swift 5.9+, macOS 14+; **HTTP 200**; ponto: `ModelActor` é um `Actor` e seu `ModelContext` serializa o código executado no ator.
- **F17 — https://developer.apple.com/documentation/swiftdata/modelcontext/save().md** — *ModelContext.save()*, Apple Developer documentation; SwiftData/Swift 5.9+, macOS 14+; **HTTP 200**; ponto: `save()` grava alterações pendentes e a Apple recomenda verificar `hasChanges`.
- **F18 — https://developer.apple.com/documentation/swift/task/detached(name:priority:operation:)-795w1.md** — *Task.detached(name:priority:operation:)*, Apple Developer documentation; Swift Concurrency, macOS 10.15+; **HTTP 200**; ponto: tarefa não estruturada, preferência por concorrência estruturada, cancelamento manual e necessidade de manter uma referência explícita.
- **F19 — https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:).md** — *MainActor.assumeIsolated(_:file:line:)*, Apple Developer documentation; Swift Concurrency, macOS 10.15+; **HTTP 200**; ponto: verifica o executor serial do MainActor e encerra o processo quando a premissa não é satisfeita.
- **F20 — https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app.md** — *Understanding hangs in your app*, Apple Developer documentation; Xcode 27; **HTTP 200**; ponto: trabalho na thread principal, funcionamento do run loop e distinção entre thread ocupada e bloqueada.
- **F21 — https://developer.apple.com/documentation/xcode/improving-app-responsiveness.md** — *Improving app responsiveness*, Apple Developer documentation; Xcode 27; **HTTP 200**; ponto: manter o trabalho de UI na thread principal e mover o restante para segundo plano; a orientação da Apple não é uma medição deste projeto.
- **F22 — https://developer.apple.com/videos/play/wwdc2021/10254** — *Swift concurrency: Behind the scenes*, WWDC21; tempo de execução de Swift Concurrency; 2021; **HTTP 200**; ponto: pool cooperativo, continuações, bloqueio, travas e contrato de progresso.
- **F23 — https://developer.apple.com/videos/play/wwdc2023/10248** — *Analyze hangs with Instruments*, WWDC23; Swift Concurrency/SwiftUI; 2023; **HTTP 200**; ponto: herança de tarefas, MainActor, cancelamento de `Task.detached` e análise com Instruments.

### Problemas, relatos e segurança

- **F24 — https://github.com/swiftlang/swift/issues/82127** — *SE-0463 completion handler loses inferred MainActor*, problema no Swift; aberto em 09/06/2025, observado como fechado; Swift 6.2/Xcode 26; **HTTP 200**; ponto: reprodução da perda de inferência de MainActor em um manipulador importado.
- **F25 — https://github.com/swiftlang/swift/issues/88731 e https://github.com/swiftlang/swift/issues/87097** — problemas de isolamento `MainActor`/`nonisolated(nonsending)`, Swift; abertos em 29/04/2026 e 09/02/2026, observados como fechados/duplicados; Swift 6.2–6.3; **HTTP 200**; ponto: só se aplicam quando `NonisolatedNonsendingByDefault` está ativado.
- **F26 — https://github.com/swiftlang/swift/issues/88259 e https://github.com/swiftlang/swift/pull/88285** — problema e correção do otimizador relacionados a cancelamento/troca de thread, Swift; problema aberto em 01/04/2026 e PR mesclado em 16/04/2026; Swift 6.3; **HTTP 200**; ponto: correção histórica, não reprodução no Swift 6.4 atual.
- **F27 — https://github.com/swiftlang/swift/issues/88173** — *Compiler crash with approachable concurrency and -O*, problema no Swift; aberto em 28/03/2026, observado como aberto; Swift 6.2; **HTTP 200**; ponto: requer `-default-isolation MainActor` e compilação otimizada.
- **F28 — https://forums.swift.org/t/mainactor-assumeisolated-crashes-on-main-thread/80624** — *MainActor.assumeIsolated crashes on main thread*, relato de usuário no Swift Forums; contexto de 2025; **HTTP 200**; ponto: relato não oficial, não aviso da Apple nem reprodução do Ōmu.
- **F29 — https://support.apple.com/en-us/149035** — *About the security content of macOS Golden Gate 27*, Apple Support; 14/09/2026; macOS 27; **HTTP 200**; ponto: CVEs representativas de AppKit, Foundation, Authentication Services, TCC e outros componentes.
- **F30 — https://support.apple.com/en-us/149040** — *About the security content of Xcode 27*, Apple Support; 14/09/2026; Xcode 27; **HTTP 200**; ponto: `CVE-2026-65393` no Xcode IDE.
- **F31 — https://support.apple.com/en-us/149042** — *About the security content of macOS Tahoe 26.7*, Apple Support; 14/09/2026; macOS Tahoe 26.7; **HTTP 200**; ponto: CVEs representativas da linha do sistema operacional alvo.
- **F32 — https://swift.org/security/** — *Swift.org security*, projeto Swift; página atual, acesso em 23/09/2026; **HTTP 200**; ponto: política de relato e avisos antigos do ecossistema.
- **F33 — https://github.com/swiftlang/swift-evolution** — *Swift Evolution*, projeto Swift; propostas e status dos lançamentos até a versão 6.4; **HTTP 200**; ponto: cronologia e status das propostas.
- **F34 — https://github.com/swiftlang/swift/security/policy** — *Security policy*, repositório `swiftlang/swift`; página atual, acesso em 23/09/2026; **HTTP 200**; ponto: procedimento oficial para relatar vulnerabilidades no compilador.
- **F35 — https://github.com/swiftlang/swift/security/advisories** — *Security Advisories*, repositório `swiftlang/swift`; página atual, acesso em 23/09/2026; **HTTP 200**; ponto: a página exibe “There aren't any published security advisories”; ausência não prova inexistência de problemas.

### Evidência local do SDK beta

- **L1 — `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/AVFAudio.framework/Headers/AVAudioNode.h:23-32,117-160`**, `AVAudioPlayer.h:22-58,81-90`, `AVAudioRecorder.h:22-33,46-91` — SDK beta local; acesso em 23/09/2026; **HTTP N/A**; ponto: retorno de chamada, depreciação, disponibilidade e a observação de bloqueio de `stop`.
- **L2 — `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/CoreAudio.framework/Versions/A/Headers/AudioHardwareTapping.h:42-54` e `CATapDescription.h:40-45,85-111`** — SDK beta local; acesso em 23/09/2026; **HTTP N/A**; ponto: disponibilidade do tap de processo e descrição do tap.
- **L3 — `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/Foundation.framework/Headers/NSTimer.h:30-40,67,93,100-106`** — SDK beta local; acesso em 23/09/2026; **HTTP N/A**; ponto: funcionamento do run loop e anotações `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`.
- **L4 — `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/usr/lib/swift/Observation.swiftmodule/arm64e-apple-macos.swiftinterface:10-18,52-100,135-160`** — SDK beta local; interface do compilador 6.4.0.19.103, alvo macOS 27; acesso em 23/09/2026; **HTTP N/A**; ponto: `Observations` no macOS 26 e rastreamento avançado no macOS 27.
- **L5 — `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:1786-1820,1854-1875,23862-23872`** — SDK beta local; acesso em 23/09/2026; **HTTP N/A**; ponto: protocolos de documentos do macOS 27; no beta, `FileDocument` aparece sem anotação de depreciação, `URLDocumentConfiguration` aparece como `Sendable` e `read`/`write` aparecem como `nonisolated`, divergências que exigem comparação com o SDK na versão geral.
- **L6 — `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/usr/lib/swift/_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface:3090-3123`** — SDK beta local; acesso em 23/09/2026; **HTTP N/A**; ponto: `withTaskCancellationShield` está anotada como `anyAppleOS 27.0`.

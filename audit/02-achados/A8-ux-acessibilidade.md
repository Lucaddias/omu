# A8 — UX e acessibilidade

> **Data:** 2026-09-23  
> **Escopo:** `Papagaio/App/**`, `Papagaio/Funcionalidades/**`, `Papagaio/DesignSystem/**`, `Papagaio/Suporte/**`, `Papagaio/ViewModels/**` e os testes de interface relacionados.  
> **Método:** auditoria estática com busca de modificadores de acessibilidade, foco, teclado, gestures, descarte, estados e localização; leitura de `audit/00-mapa.md` integral; cálculo WCAG direto dos tokens sRGB. Não houve execução do app, VoiceOver, teclado ou hardware.  
> **Escrita:** este é o único arquivo do repositório criado/editado por este agente. Nenhum fonte, teste, configuração, dependência ou serviço real foi alterado.

## Correção do caminho solicitado

- O prefixo solicitado `/Users/lucadias/Documents/Challenges/Academy/Challenge 3` não existe: verificação local retornou `REQUESTED_PATH_MISSING`.
- A auditoria foi feita no repositório existente `/Users/lucadias/Documents/Academy/Challenges/Challenge 3/Projeto principal/Papagaio`: a verificação retornou `FALLBACK_PATH_EXISTS`.
- Todas as referências abaixo são relativas a esse fallback. Nenhuma conclusão foi atribuída ao caminho inexistente.

## Legenda

- **Severidade:** `CRÍTICO`, `ALTO`, `MÉDIO`, `BAIXO`, `INFO`.
- **Confiança:** `CONFIRMADO` = ausência/efeito demonstrável no código ou cálculo verificável; `PROVÁVEL` = estrutura concreta que depende da árvore AX/teclado em execução; `HIPÓTESE` = evidência insuficiente. Não há HIPÓTESE aberta.

## Resumo

| Severidade | Quantidade |
|---|---:|
| CRÍTICO | 0 |
| ALTO | 3 |
| MÉDIO | 12 |
| BAIXO | 2 |
| **Total** | **17** |

| Confiança | Quantidade |
|---|---:|
| CONFIRMADO | 11 |
| PROVÁVEL | 6 |
| HIPÓTESE | 0 |
| **Total** | **17** |

**Highlights:** o contraste padrão da faixa coral mede **2,33:1**; cancelamento de gravação e quatro tipos de exclusão definitiva não compartilham a confirmação já existente em outras superfícies; o detalhe ignora o estado tipado de falha; mudar status no quadro depende de arraste; ajuda depende exclusivamente de hover; títulos longos de tarefas são truncados; há controles por gesture sem foco de teclado, labels vazios, estado selecionado não exposto e tempo/ditado fixos em português.

---

## A8-001 — `textoLegivel` escolhe branco sobre o coral padrão e reprova contraste

- **Severidade:** ALTO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/DesignSystem/PapagaioTheme.swift:54-60`

```swift
/// Coral da identidade. Só para superfícies e traços — **nunca** atrás de
/// texto branco: a razão de contraste dá 2,3:1, abaixo do mínimo de 4,5:1.
static let destaque = corAdaptativa(
    claro: (1.000, 0.537, 0.392),
    escuro: (1.000, 0.576, 0.435)
)
```

- `Papagaio/Persistencia/AparenciaDoCartao.swift:187-210`

```swift
var textoLegivel: Color {
    // ...
    let luminancia = 0.2126 * linear(sRGB.redComponent)
        + 0.7152 * linear(sRGB.greenComponent)
        + 0.0722 * linear(sRGB.blueComponent)

    return luminancia > 0.45 ? Color(red: 0.12, green: 0.11, blue: 0.10) : .white
}
```

- `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:986-1000,1064-1075`

```swift
guard let pasta else { return PapagaioTema.destaque }
// ...
return corDaFaixa.textoLegivel
```

**Cenário concreto**

Uma conversa sem cor/pasta própria, no modelo com capa, usa `PapagaioTema.destaque`. O cálculo WCAG com gama sRGB dos valores de `PapagaioTheme.swift:58` deu luminância `0,400522`; como `0,400522 <= 0,45`, a função escolhe branco. A razão resultante é **2,33:1**. O título regular de 20 pt e a descrição de 15 pt ficam abaixo de 4,5:1. O mesmo auxiliar é usado em `GradeDePastas.swift:115-136`, que também pode receber cores livres.

**Guardas e refutação**

- `PapagaioTema.preenchimentoPrimario`/`textoSobrePrimario` (`PapagaioTheme.swift:98-112`) estão corretos para botões principais; o defeito fica em `textoLegivel`, não no tema inteiro.
- O próprio comentário do DesignSystem reconhece a razão 2,3:1, mas a função de escolha de cor contradiz essa regra.
- `PapagaioTests/InterfaceTests.swift:139-186` só compara a ordem de luminância entre texto/fundo e calcula a luminância como média simples dos canais; não verifica `textoLegivel` nem razão de contraste.

**Causa**

O limiar fixo `0,45` não escolhe a alternativa de maior razão de contraste. Para o coral, ele escolhe justamente a pior das duas.

**Correção sugerida**

Escolher branco ou a tinta escura comparando as duas razões WCAG, e adicionar testes com gamma real para o coral, aviso, amarelo, laranja e cores fornecidas pelo usuário. Manter o par `preenchimentoPrimario` como mitigação dos botões principais.

---

## A8-002 — Cancelar uma gravação inteira é imediato em três superfícies, mas confirmado apenas no selo

- **Severidade:** ALTO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/Funcionalidades/Gravacao/PainelDeGravacao.swift:120-129`

```swift
Button("Finalizar".localized, systemImage: "stop.fill") {
    Task { await aoFinalizar() }
}
// ...
Button("Cancelar".localized, systemImage: "xmark") {
    Task { await aoCancelar() }
}
```

- `Papagaio/Funcionalidades/Gravacao/PainelFlutuanteDeGravacao.swift:102-108`

```swift
BotaoDoSelo(simbolo: "xmark", ajuda: "Cancelar gravação".localized, perigo: true) {
    Task { await gravador.cancelar() }
}
```

- `Papagaio/App/PapagaioApp.swift:117-123`

```swift
Button("Finalizar gravação".localized) { ... }
Button("Cancelar gravação".localized) {
    Task { await gravador.cancelar() }
}
```

- `Papagaio/App/ContentView.swift:1013-1035` já possui a confirmação que falta às três superfícies acima:

```swift
BotaoDoSelo(simbolo: "xmark", ajuda: "Cancelar gravação".localized, perigo: true) {
    confirmandoCancelamentoDaGravacao = true
}
// ...
Button("Cancelar gravação".localized, role: .destructive) {
    Task { await aoCancelarGravacao() }
}
```

- `Papagaio/ViewModels/GravadorViewModel.swift:109-126` descarta a sessão e seus dados sem undo.

**Cenário concreto**

Um clique/Enter em “Cancelar” no painel principal, no painel flutuante ou no menu bar descarta todo o áudio capturado. A mesma intenção no selo da raiz abre um diálogo que informa que o áudio capturado será descartado.

**Guardas e refutação**

O selo tem `role: .destructive`, mensagem explícita e ação de cancelar. Os painéis têm rótulo “Cancelar” e, no flutuante, `perigo: true`; esses sinais não são alternativa à confirmação.

**Causa**

A política de confirmação mora no componente local do selo, enquanto três chamadores acessam o ViewModel diretamente.

**Correção sugerida**

Centralizar o pedido de cancelamento/confirmação antes de `GravadorViewModel.cancelar()`, ou fazer todas as superfícies rotearem pelo mesmo confirmador. O menu bar pode abrir a confirmação na janela principal antes de descartar.

---

## A8-003 — Quatro tipos de item da lixeira são apagados definitivamente em um clique

- **Severidade:** ALTO
- **Confiança:** CONFIRMADO

**Evidência**

A conversa comum percorre confirmação:

- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:970-986,1195-1201`

```swift
.confirmationDialog("Apagar definitivamente?", ...)
// ...
aoPedirExclusaoDefinitiva: {
    arquivoParaExclusaoDefinitiva = arquivo
}
```

Os demais itens chamam a eliminação diretamente:

- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:1168-1173,1207-1224,1229-1255`

```swift
aoApagarDefinitivamente: {
    googleCalendar.apagarPendenteDefinitivamente(pendente)
}
// ...
try LixeiraDeMidia.remover(item)
// ...
LixeiraDePastas.remover(item)
// ...
LixeiraDeTarefas.remover(item)
```

- O caso de mídia é fisicamente destrutivo: `Papagaio/Persistencia/LixeiraDeMidia.swift:152-162,219-227`

```swift
try apagarArquivo(do: item, armazenamento: armazenamento)
descartarRegistro(item, em: defaults)
// ...
try fm.removeItem(at: caminho)
```

**Cenário concreto**

Reunião ignorada, anexo, pasta ou tarefa na lixeira podem ser removidos em uma única ativação, sem `confirmationDialog` e sem undo. Para mídia, o arquivo sai do disco.

**Guardas e refutação**

Os botões de mídia, pasta e tarefa têm `role: .destructive`, ícone de lixeira e `.accessibilityLabel`; o botão de reunião usa `tint` de perigo. A conversa comum também tem confirmação. Essas guardas não protegem os outros quatro tipos.

**Causa**

Foi aplicado um fluxo comum à conversa, mas os callbacks dos demais itens não passam por um estado intermediário de “pedir exclusão definitiva”.

**Correção sugerida**

Criar um pedido tipado (item + operação) e um diálogo comum para todos os tipos. Se confirmação for removida deliberadamente, oferecer undo com prazo explícito; para mídia, manter a barra de erro apenas para falha, não para a decisão destrutiva.

---

## A8-004 — Falha ao iniciar a gravação desaparece da tela e fica sem ação de recuperação

- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/ViewModels/GravadorViewModel.swift:169-177`

```swift
do {
    try await sessao.iniciar()
} catch {
    self.sessao = nil
    estado = .falhou("\(error)")
    return
}
```

- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:279-282,455-458`

```swift
private var emCaptura: Bool {
    gravador.gravando && focoNaGravacao
}

private var falhaDaGravacao: String? {
    guard case let .falhou(motivo) = gravador.estado else { return nil }
    return motivo
}
```

- `Papagaio/Funcionalidades/Biblioteca/BibliotecaHomeView.swift:900-943`

```swift
} else if !emCaptura {
    cabecalhoDaLixeira
}

if emCaptura || secaoSelecionada != .todos {
    // ...
    if let falhaDaGravacao {
        FalhaDaGravacao(mensagem: falhaDaGravacao)
    }
}
```

- `Papagaio/Funcionalidades/Gravacao/PainelDeGravacao.swift:159-177` mostra que o componente de erro combina o conteúdo para acessibilidade, mas só recebe a mensagem quando é montado.

**Cenário concreto**

Ao falhar a permissão/reconhecimento/início, `gravando` fica falso. Logo, `emCaptura` fica falso e o ramo que monta `FalhaDaGravacao` não é alcançado. A pessoa vê a biblioteca normal e não recebe o motivo nem um botão “Tentar novamente”.

**Guardas e refutação**

O estado `.falhou` permanece no ViewModel e a tela de captura tem o componente acessível. O problema é a condição de montagem; não é perda do estado no modelo.

**Causa**

A visibilidade da falha foi vinculada à tela ativa de captura, que é justamente abandonada quando a captura falha.

**Correção sugerida**

Renderizar a falha fora de `emCaptura`, com foco/anúncio à transição, e adicionar “Tentar novamente”/“Abrir ajustes” conforme o erro.

---

## A8-005 — O detalhe recebe `EstadoDoArquivo`, mas falha e posição na fila não chegam ao conteúdo

- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/App/ContentView.swift:561-570` entrega o estado tipado:

```swift
estado: biblioteca.estado(de: arquivo),
processando: biblioteca.estaProcessando(arquivo),
naFila: biblioteca.estaNaFila(arquivo)
```

- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:25-29,100,116`

```swift
let estado: EstadoDoArquivo
let processando: Bool
let naFila: Bool
// ...
self.estado = estado
```

A busca de `estado` no restante do arquivo mostra somente essa inicialização; os ramos de conteúdo usam `processando` e `naFila`, nunca `estado.descricao` ou `case .falhou`.

- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:1125-1131,1403-1414`

```swift
CartaoDeEstadoVazio(
    simbolo: "text.alignleft",
    titulo: "Resumo indisponível".localized,
    mensagem: "O resumo aparecerá depois do processamento.".localized
)
// ...
CartaoDeEstadoVazio(
    simbolo: "text.quote",
    titulo: "Transcrição em preparação".localized,
    mensagem: "A transcrição aparecerá depois do processamento.".localized
)
```

- `Papagaio/ViewModels/Biblioteca.swift:1291-1300` distingue corretamente `.falhou`, `.naFila` e `.processando`.

**Cenário concreto**

Se o pipeline falhar sem transcrição, `processando` e `naFila` ficam falsos; como `podeIniciarTranscricao` só depende desses dois e de `trechos.isEmpty` (`ArquivoDetalheView.swift:348-351`), a tela mostra “Pronto para transcrever”. Se só o resumo falhou depois da transcrição, mostra “Resumo indisponível”. O motivo real fica fora da tela. Há um botão de nova tentativa, mas ele é apresentado como ação inicial, não como recuperação do erro.

**Guardas e refutação**

`EstadoDoArquivo` é tipado, localizado e testado; o cartão da biblioteca também o consome. `InterfaceTests.swift:24-75` prova o enum, não a propagação/renderização no detalhe.

**Causa**

A view foi preparada para depender de flags paralelas e ficou sem uma projeção do estado tipado para cada estado vazio.

**Correção sugerida**

Derivar todas as flags do `estado`; criar ramos específicos para `.falhou(motivo)` e `.naFila(posicao)`, com ação “Tentar novamente” e anúncio de conclusão/falha.

---

## A8-006 — Mudar status no quadro depende de arraste; um callback de conclusão chega sem uso

- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/Funcionalidades/Tarefas/ColunaDeTarefasGerais.swift:97-107,146-169`

```swift
CartaoDeTarefaGeral(...)
    .draggable(tarefa.id)
// ...
content.dropDestination(for: String.self) { ids, _ in
    aoMover(id, destino)
}
```

- `Papagaio/Funcionalidades/Tarefas/CartaoDeTarefaGeral.swift:141-148` deixa apenas editar, ocultar e excluir no menu e declara que a ação de conclusão foi removida porque o destino é o arraste:

```swift
// "Marcar concluída" saiu daqui...
Button("Excluir".localized, ...)
```

- O componente ainda recebe `aoAlternarConclusao` em `CartaoDeTarefaGeral.swift:3-16`, mas não há botão nem chamada na sua árvore.
- `Papagaio/Funcionalidades/Detalhe/Tarefas/SecaoDeTarefas.swift:86-110` também usa `.draggable` + `dropDestination`.
- `Papagaio/Funcionalidades/Detalhe/Tarefas/CartaoDeTarefaDaConversa.swift:123-132` oferece apenas alternar concluída; os demais status continuam no arraste.
- Os sheets aceitam `@Binding status` (`EditorDeTarefaGeralSheet.swift:10-18`; `NovaTarefaDaConversaSheet.swift:30-35`), mas não renderizam um controle de status.

**Cenário concreto**

No quadro geral, uma tarefa de “Não iniciado” só passa a “Em andamento/Concluída” quando arrastada para outra coluna. No detalhe, o botão alterna apenas entre “Concluída” e “Em andamento”; não há controle alternativo para escolher “Não iniciado” ou outro status sem usar o destino físico de uma seção. Não há ação AX explícita de “mover para status”.

**Guardas e refutação**

O botão de conclusão no detalhe remove parte da exclusividade. Colunas recolhidas ampliam a área de drop (`ColunaDeTarefasGerais.swift:71-86`), mas não criam uma operação de teclado/VoiceOver.

**Causa**

A interação de arrastar e soltar foi escolhida como único modelo de edição de status, apesar de existir callback e binding para edição.

**Correção sugerida**

Adicionar um menu “Mover para” por tarefa, com `Button` para cada status e `accessibilityAction`/atalhos quando necessário. O arraste pode continuar como acelerador visual.

---

## A8-007 — A ajuda compartilhada só abre por hover

- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/DesignSystem/Componentes/BotaoDeAjudaPapagaio.swift:34-54`

```swift
Image(systemName: "info.circle")
    .frame(width: 22, height: 22)
    .onHover { pairando = $0 }
    .popover(isPresented: $pairando, arrowEdge: .bottom) { ... }
    .accessibilityLabel(ajuda.localized)
    .accessibilityHint(texto.localized)
```

Não há `Button`, `accessibilityAddTraits(.isButton)` nem `accessibilityAction`.

A busca encontrou **9 pontos de uso** do componente: Configurações, Tarefas, gravação, Mídias, Biblioteca (dois), Notas, nomes de voz e Mídia da conversa. A definição do componente e um comentário em `CartaoDeConversa.swift` também apareceram na busca, mas não são usos.

**Cenário concreto**

Teclado e VoiceOver encontram um rótulo/hint, mas não existe ação sem mouse para abrir o texto. Nas telas afetadas, a única explicação inicial fica inacessível.

**Guardas e refutação**

Label, hint, tooltip e popover foram implementados. Eles resolvem descoberta e texto, mas `.onHover` não é um disparador de foco/ativação.

**Causa**

O componente foi projetado como um rótulo de mouse, apesar de estar em telas de tarefas.

**Correção sugerida**

Envolver em `Button` e alternar um estado de popover no clique/ativação AX; manter hover apenas como feedback e disparo opcional, com foco visível.

---

## A8-008 — Filtros e “Adicionar mídia” são gestures, não controles focáveis

- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL

**Evidência**

- `Papagaio/Funcionalidades/Biblioteca/FiltroDeConversas.swift:33-64`

```swift
PastilhaDeFiltro(...)
    .onTapGesture {
        selecionado = filtro
    }
    .accessibilityAddTraits(.isButton)
```

- `Papagaio/Funcionalidades/Detalhe/Midia/MidiaDaConversaView.swift:66-113`

```swift
VStack { /* ... */ }
    .contentShape(Rectangle())
    .onTapGesture(perform: aoAdicionar)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel("Adicionar mídia".localized)
```

Nenhum dos dois tem `Button`, `FocusState`, atalho de teclado ou `accessibilityAction`.

**Cenário provável**

Com Full Keyboard Access, os controles não entram na ordem de foco como botões. A trait e o label podem melhorar a navegação por VoiceOver, mas não há no código uma ação personalizada que garanta ativação por teclado.

**Guardas e refutação**

O filtro adiciona `.isButton` e `.isSelected`; o cartão de mídia adiciona label e hint. Esses mitigantes cobrem descoberta/estado, mas não o mecanismo nativo de foco/ativação.

**Causa**

`.onTapGesture` foi usado para controlar exatamente a área do shape, sem o `Button` plain-style que permitiria o mesmo desenho.

**Correção sugerida**

Usar `Button` + `.buttonStyle(.plain)` + `.contentShape`, preservando a área total; se o gesture for mantido por integração de drop, adicionar `accessibilityAction` e um botão alternativo.

---

## A8-009 — Interruptor e seletores de cor têm label vazio ou nenhum nome semântico

- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL

**Evidência**

- `Papagaio/Funcionalidades/Configuracoes/PersonalizacaoDosCartoes.swift:55-84`

```swift
VStack {
    Text(titulo.localized)
    Text(detalhe.localized)
}
Toggle("", isOn: $ligado)
    .labelsHidden()
```

Os textos são irmãos, não um label combinado com o `Toggle`.

- `Papagaio/Funcionalidades/Biblioteca/EditorDeAparenciaDoCartao.swift:59-67`

```swift
ColorPicker("", selection: Binding(...))
    .labelsHidden()
```

- `Papagaio/Funcionalidades/Biblioteca/GradeDePastas.swift:613-618` repete `ColorPicker("")`.
- Os botões de paleta em `EditorDeAparenciaDoCartao.swift:37-56` e `GradeDePastas.swift:585-607` têm como label apenas um `Circle`; em `EditorDeAparenciaDoCartao.swift:40-56` nem há `.help`, enquanto `BotaoSemCor` usa apenas tooltip.

**Cenário provável**

A árvore AX pode expor um interruptor sem o nome “Participantes”/“Data” etc. e um seletor sem “Cor”; os botões de cor podem ser lidos como elementos genéricos. O impacto depende de reprodução VoiceOver.

**Guardas e refutação**

O título visível da fileira, o heading “Cor” e `.help` em parte das swatches dão contexto visual/pointer. Eles não são automaticamente associado ao nó do controle.

**Causa**

O layout customizado permite que label e conteúdo visual sejam separados sem um `accessibilityElement`/label explícito.

**Correção sugerida**

Passar o texto real ao `Toggle`/`ColorPicker`, ainda que visualmente oculto; nomear cada swatch com `opcao.titulo`, adicionar `accessibilityValue` com a cor atual e `isSelected` à escolha ativa.

---

## A8-010 — Vários seletores anunciam labels, mas não o valor selecionado

- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL

**Evidência**

- `Papagaio/DesignSystem/Componentes/ControleSegmentadoPapagaio.swift:29-56`: a seleção muda apenas cor/fundo; não há `.isSelected` ou `accessibilityValue`.
- `Papagaio/Funcionalidades/Biblioteca/AtalhosDaBiblioteca.swift:21-43`: “Recentes”/“Favoritos” não recebem `isSelected`; o estado é desenhado dentro do label.
- `Papagaio/Funcionalidades/Detalhe/NotasDaConversa.swift:217-235`: chips de filtro usam cor para estado, sem `isSelected`.
- `Papagaio/Funcionalidades/Equipes/SeletorDeEquipeView.swift:33-70`: a equipe ativa tem checkmark e fundo, mas nenhum trait/valor de seleção.

**Cenário provável**

VoiceOver pode ler “Prioridade”/“Recentes”/“Todas” sem descobrir qual opção está ativa; trocar a seleção não produz uma mudança semântica explícita.

**Guardas e refutação**

O problema não é universal: `FiltroDeConversas.swift:60-63`, `BarraDeSecoesDaConversa.swift:103-105`, `PersonalizacaoDosCartoes.swift:477-480` e `ConfiguracoesView.swift:663-665` adicionam `isSelected`. Os cartões de filtro de Tarefas/Mídias usam label “Marcar/Desmarcar” (`CartaoFiltroDeConversaTarefa.swift:95-96`; `CartaoFiltroDeConversaMidia.swift:77-78`). Isso confirma que a lacuna é de consistência entre componentes.

**Causa**

Componentes de seleção foram construídos como `Button` + estilo visual, sem um contrato comum de acessibilidade para “opção selecionada”.

**Correção sugerida**

Criar um primitivo único (`Picker` segmentado quando possível) ou aplicar `accessibilityAddTraits(.isSelected)` e `accessibilityValue` em toda família equivalente.

---

## A8-011 — Vários alvos interativos violam o mínimo de 44 pt declarado pelo próprio DesignSystem

- **Severidade:** BAIXO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/DesignSystem/PapagaioTheme.swift:136-143` declara 44 pt como “alvo mínimo de toque”.
- Alvos realmente declarados:
  - `BotaoDeAjudaPapagaio.swift:35-43`: **22×22**;
  - `BotoesDaBarra.swift:155-169` (`BotaoDoSelo`): **24×24**;
  - `ArquivoDetalheView.swift:275-305`: anterior/próxima/fechar da busca, **26×26**;
  - `BarraDeAudioDaConversa.swift:293-308`: voltar/avançar, **34×34**;
  - `NotasDaConversa.swift:430-458`: editar/apagar, **28×28**.

**Cenário concreto**

A área sensível é menor que o mínimo do projeto em controles frequentes, especialmente nos painéis compactos e no player.

**Guardas e refutação**

`BotaoPrincipalPapagaio` usa 44 pt, `BotaoCircularPapagaio` usa 36 pt e alguns menus/áreas têm padding externo. O achado é especificamente para os cinco casos cujo frame visível/role não recebe área externa de 44 pt.

**Causa**

O comentário de “botão pequeno” e as otimizações de densidade prevaleceram sobre o token de alvo mínimo.

**Correção sugerida**

Separar frame visual e hit target: manter o glifo menor, mas aplicar `contentShape`/frame transparente de 44 pt ou aumentar o espaçamento real.

---

## A8-012 — Progresso e estados transitórios não têm semântica de valor/anúncio

- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL

**Evidência**

- `Papagaio/Funcionalidades/Biblioteca/CartaoDeConversa.swift:1804-1840`

```swift
TimelineView(.periodic(from: inicio, by: 1)) { contexto in
    corpo(fracao: Self.fracao(...))
}
// ...
Text("\(Int((fracao * 100).rounded()))%")
    .foregroundStyle(PapagaioTema.textoSecundario)
```

Não há `accessibilityElement`, label “andamento do processamento”, value/frase ou anúncio de marco. O cartão pai usa um label textual do estado em `:362-363`, não o valor da barra.

- `Papagaio/Funcionalidades/Detalhe/NotasDaConversa.swift:191-196` mostra “Salvando...”/“Salvo” como `Label`, mas sem estado vivo explícito.
- Não há `AccessibilityNotification`, `accessibilityLiveRegion` ou equivalente de anúncio no app.

**Cenário provável**

Uma pessoa com visão vê 42% subindo; uma pessoa de VoiceOver recebe no máximo um texto estático sem contexto, e não uma mudança de valor/estado ao entrar em “processando”, “concluído” ou “falhou”. A reprodução AX não foi executada.

**Guardas e refutação**

O card tem `estado.descricao` no label e há `ProgressView` visível no detalhe (`ArquivoDetalheView.swift:1101-1107`). Isso anuncia a fase inicial, mas não garante atualização nem valor percentual.

**Causa**

O desenho trata progresso como atualização visual frequentíssima, sem um canal semântico separado.

**Correção sugerida**

Expor label contextual + value nos elementos focados e anunciar apenas marcos (início, 25/50/75/100, conclusão, erro), evitando anunciar 60 ticks por minuto.

---

## A8-013 — O valor de tempo para VoiceOver está fixo em português

- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/DesignSystem/FormatacaoDeTempo.swift:22-28`

```swift
var faladoPorExtenso: String {
    // ...
    return minutos > 0 ? "\(minutos) min \(segundos) s" : "\(segundos) s"
}
```

- Esse valor é usado como `accessibilityValue` do player em `BarraDeAudioDaConversa.swift:121-135` e em hints de fala/trecho (`LinhaDeFala.swift:105-110`; `LinhaDeTranscricao.swift:133-138`).
- `PapagaioTests/InterfaceTests.swift:104-108` fixa literalmente:

```swift
#expect(TimeInterval(187).faladoPorExtenso == "3 min 7 s")
#expect(TimeInterval(42).faladoPorExtenso == "42 s")
```

- A camada de localização usa `Locale.autoupdatingCurrent` (`Papagaio/Suporte/Localizacao.swift:4-8,27-37`), mas esse valor não passa por ela.

**Cenário concreto**

Em locale inglês, o slider pode anunciar uma frase inglesa contendo “3 min 7 s”; o usuário recebe uma unidade de outro idioma em uma propriedade semântica.

**Guardas e refutação**

O texto visível do player é numérico e o invólucro da propriedade AX usa `.localized`. O teste existente confirma apenas o contrato PT e não protege o locale EN.

**Causa**

A função foi criada como “fala” e recebeu strings literais em vez de um formatter regionalizado.

**Correção sugerida**

Gerar a unidade com formatter/`DateComponentsFormatter` ligado ao locale atual ou a um locale de ditado explícito; adicionar expectations EN e PT-BR.

---

## A8-014 — Ditado de notas força o reconhecedor para `pt_BR`

- **Severidade:** MÉDIO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/ViewModels/GravadorViewModel.swift:509-529`

```swift
guard let reconhecedor = SFSpeechRecognizer(locale: Locale(identifier: "pt_BR"))
    ?? SFSpeechRecognizer(),
      reconhecedor.isAvailable
else { ... }
```

- O idioma atual do app é documentado como `.autoupdatingCurrent` em `Papagaio/Suporte/Localizacao.swift:4-8`, mas não é usado nessa seleção.
- O mapa registra execução baseline com locale `en-BR` (`audit/00-mapa.md:413-430,716-722`); isso é contexto, não prova de áudio real nesta auditoria.

**Cenário concreto**

Um usuário em EN/ES/PT-PT recebe um reconhecedor primário pt_BR. O refinamento Whisper pode corrigir o resultado final, mas o texto parcial ao vivo — justamente a confirmação de que o ditado está funcionando — pode sair no idioma errado.

**Guardas e refutação**

Existe fallback `SFSpeechRecognizer()` quando a construção pt_BR retorna `nil`, e o Whisper refina o áudio. O fallback não escolhe o idioma desejado quando pt_BR existe e está disponível; não há seletor de idioma.

**Causa**

O reconhecedor foi fixado para o idioma do produto inicial em vez do idioma de entrada escolhido pelo sistema/usuário.

**Correção sugerida**

Usar `Locale.autoupdatingCurrent` por padrão, oferecer seletor de idioma de ditado e validar `supportsOnDeviceRecognition`/disponibilidade antes de iniciar. Manter o texto parcial localizado e indicar o idioma usado.

---

## A8-015 — `CartaoDePasta` contém um `Button` dentro do `Button` externo

- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL

**Evidência**

- `Papagaio/Funcionalidades/Biblioteca/GradeDePastas.swift:152-195`

```swift
Button(action: acao) {
    HStack {
        // ...
        menuDaPasta
    }
}
```

- `GradeDePastas.swift:292-305` define `menuDaPasta` como outro `Button` dentro do label do primeiro.
- O context menu externo (`GradeDePastas.swift:248-255`) cobre apenas editar/apagar; o popover interno tem favoritar, baixar, editar, compartilhar e lixeira (`:307-348`).

**Cenário provável**

A árvore de foco pode tratar o botão interno como parte do label externo, sem oferecer uma parada independente no teclado; VoiceOver pode achatar/ler apenas uma ação ou anunciar botões aninhados em ordem imprevisível.

**Guardas e refutação**

O context menu dá alternativas parciais e o botão interno possui `.help`; nenhum desses guards remove a nesting nem cobre todas as ações do popover.

**Causa**

O botão de menu foi colocado dentro do label para preservar o desenho visual, em vez de ser um irmão sobreposto à linha.

**Correção sugerida**

Tornar a linha um container não interativo com um `Button` “Abrir pasta” explícito e um `Menu` irmão, ou usar `onTapGesture` no container mais `accessibilityAction` para a abertura.

---

## A8-016 — Busca na transcrição rola a visão, mas não move o foco de acessibilidade

- **Severidade:** MÉDIO
- **Confiança:** PROVÁVEL

**Evidência**

- `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:197-253` usa apenas `@FocusState` para o `TextField`:

```swift
@FocusState private var focoBuscaTranscricao: Bool
// ...
DispatchQueue.main.async { focoBuscaTranscricao = true }
```

- `ArquivoDetalheView.swift:242-247,315-325` atualiza `alvoDaBusca` e o índice, e `:1509-1513,1594-1597` chama apenas `rolagem.scrollTo`.
- Não há `AccessibilityFocusState`, `accessibilityFocused`, `AccessibilityNotification` ou equivalente no restante do app.

**Cenário provável**

VoiceOver abre a busca e aciona “próxima ocorrência”; a lista rola visualmente, mas o foco continua no campo/resultado anterior e a ocorrência não é anunciada como novo contexto. A pessoa precisa navegar manualmente para descobrir onde a busca parou.

**Guardas e refutação**

O campo recebe foco real, a contagem é atualizada e há atalhos anterior/próximo (`ArquivoDetalheView.swift:275-306`). Esses recursos atendem teclado e visão, mas não transferem o foco AX nemmulticolam um `accessibilityValue` da ocorrência.

**Causa**

A busca trata a posição visual como estado de revisão, mas não modela posição e foco semântico.

**Correção sugerida**

Adicionar foco AX ancorado à ocorrência atual e um valor anunciado como “ocorrência X de Y”; ao navegar, opcionalmente devolver o foco ao campo de busca com a posição preservada, sem perder a ordem de leitura.

---

## A8-017 — Títulos longos de tarefas são truncados sem uma forma de recuperar o texto completo

- **Severidade:** BAIXO
- **Confiança:** CONFIRMADO

**Evidência**

- `Papagaio/Funcionalidades/Tarefas/CartaoDeTarefaGeral.swift:70-77`

```swift
Text(tarefa.tarefa.titulo)
    .lineLimit(2)
    .truncationMode(.tail)
    .minimumScaleFactor(0.75)
```

- `Papagaio/Funcionalidades/Detalhe/Tarefas/CartaoDeTarefaDaConversa.swift:45-52` repete `lineLimit(3)` + `truncationMode(.tail)` sem `.help`.
- `Papagaio/Funcionalidades/Detalhe/Tarefas/LinhaDeTarefaDaConversa.swift:207-220` usa `lineLimit(2)` sem `.help` nem valor alternativo.

**Cenário concreto**

Um título de tarefa com muitas palavras é cortado com reticências em cartões de largura fixa. A pessoa precisa abrir a edição para saber qual é o título; em uma lista compacta, o nome truncado também pode tornar duas tarefas difíceis de distinguir.

**Guardas e refutação**

O VoiceOver pode ler o conteúdo completo do `Text` mesmo quando a apresentação visual corta; este achado é de layout/revisão visual, não uma afirmação de perda do texto na árvore AX. Os títulos de conversas e de alguns cartões têm `.help(titulo)` (`CartaoDeConversa.swift:541-552,594-607`), o que é uma mitigação parcial e não cobre as três telas de tarefas citadas.

**Causa**

A altura fixa dos cartões foi preservada para alinhar a grade, mas não foi adicionado um caminho de leitura do valor completo quando a linha precisa ser truncada.

**Correção sugerida**

Adicionar `.help(título)`/inspector acessível aos cartões de tarefas e, em vez de truncar silenciosamente, permitir quebra em painel maior ou exibir o título completo em um popover/sheet. Manter o texto completo na semântica AX.

---

## Refutações, mitigantes e controles já corretos

Os pontos abaixo foram procurados para não transformar as proteções já existentes em falsos achados:

- `FiltroDeConversas.swift:60-63` expõe `.isButton` e `.isSelected`; portanto A8-008 é especificamente sobre foco/ativação, não ausência total de semântica.
- `BarraDeSecoesDaConversa.swift:103-105`, `PersonalizacaoDosCartoes.swift:477-480` e `ConfiguracoesView.swift:663-665` já anunciam seleção.
- `FalhaDaGravacao.swift:162-176` combina a mensagem para AX quando o componente existe; o defeito é ele não ser montado.
- `CartaoDaLixeira.swift:61-84` e a confirmação de `BibliotecaHomeView.swift:970-986` protegem a exclusão definitiva de conversa; A8-003 cobre apenas os demais tipos sem a mesma etapa.
- `ArquivoDetalheView.swift:367-369,430-453` respeita `accessibilityReduceMotion` para o player; não há garantia global de que todo o app respeita Reduce Motion.
- `BotaoPrincipalPapagaio.swift:490-507` usa 44 pt; A8-011 é específico dos alvos compactos que não chegam a esse token.
- `Papagaio/DesignSystem/PapagaioTheme.swift:98-112` tem um par primário/texto primário legível; o problema de contraste está em `textoLegivel`, não em todos os botões.
- As falhas de locale da baseline (`audit/00-mapa.md:413-430,716-732`) foram tratadas como contexto de ambiente, não como prova de que o produto retorna sempre português.
- Não há teste de UI/AX, VoiceOver, teclado ou captura real no material lido. `InterfaceTests` cobre alguns tokens, atalhos e strings, mas não fecha as lacunas acima.

## Cobertura e buscas realizadas

- Inventário estático: **115 arquivos `.swift`, 26.666 linhas** — App 5/1.296; Funcionalidades 64/17.400; DesignSystem 22/2.623; Suporte 14/2.015; ViewModels 10/3.332.
- Leitura integral de `audit/00-mapa.md` (948 linhas) e dos pontos de UI/ViewModel relacionados aos fluxos de captura, biblioteca, detalhe, tarefas, mídia, lixeira, player, perfil/equipes e configurações.
- Buscas por `accessibility*`, `Button`, `keyboardShortcut`, `FocusState`, `AccessibilityFocus`, `onTapGesture`, `highPriorityGesture`, `draggable`, `dropDestination`, `onDrop`, `ProgressView`, `lineLimit`, `frame`, `localized`, `pt_BR`, `faladoPorExtenso` e `SFSpeechRecognizer`.
- Cálculo de contraste executado com a fórmula WCAG e correção de gama sobre os valores RGB do tema; nenhum serviço, OAuth, CloudKit, microfone, Process Tap ou arquivo de usuário foi acessado.
- Não houve reprodução real de VoiceOver, Tab/Full Keyboard Access, Locale EN/PT, layout com fonte ampliada ou desempenho de animação. Por isso os seis itens marcados `PROVÁVEL` precisam de uma passagem de UI/AX antes do patch final.
- Nenhum problema de tremor/jitter foi classificado como achado: as animações foram inspecionadas estaticamente, mas não houve medição ou reprodução suficiente para atribuir um defeito perceptível.

## Contagens finais

- **Achados A8:** 17.
- **Severidade:** 0 CRÍTICO; 3 ALTO; 12 MÉDIO; 2 BAIXO.
- **Confiança:** 11 CONFIRMADO; 6 PROVÁVEL; 0 HIPÓTESE.
- **Código/testes/configurações alterados:** 0.
- **Arquivo desta auditoria:** `audit/02-achados/A8-ux-acessibilidade.md`.

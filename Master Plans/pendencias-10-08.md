# Papagaio — o que ficou para a próxima

Sessão de 10/08, branch `testes-e-correcoes`.

## Bloqueia o uso

**Tap de áudio do sistema não captura nada.** O `sistema.m4a` sai com 1 KB — só
cabeçalho. O app agora descarta esse arquivo ao finalizar e segue com o
microfone, então não quebra mais a transcrição, mas numa chamada online a voz do
outro lado se perde. Suspeita: permissão de gravação de áudio do sistema no
macOS. Precisa de investigação no `SystemAudioTap`.

**Assinatura.** Antônio não está no time `8CTC75M93B` do Apple Developer. Para
rodar localmente, `project.pbxproj` e `Config/Papagaio.entitlements` estão
alterados **no disco dele** com assinatura ad hoc e sem Sign in with Apple /
push. Esses dois arquivos **não podem entrar em commit**. Solução real: adicionar
a conta dele ao time.

## Vale fazer

**Progresso real da transcrição.** Hoje a barra no cartão é estimativa por tempo
decorrido, calculada sobre a duração do áudio. O whisper.cpp expõe
`progress_callback` com o percentual verdadeiro; ligar isso exige mexer no
`ContextoWhisper` (callback em C atravessando um ator) — combinar com o Felipe
antes.

**Download não retoma sozinho.** Se o download do Qwen for interrompido, o
`.parcial` fica parado até alguém clicar em "Baixar modelos" de novo na
biblioteca. O `DownloadDeModelos` já sabe retomar por `Range:` HTTP; falta só
disparar automaticamente quando existe um `.parcial` na abertura.

**Ícone do app nas notificações.** As notificações do sistema mostram o ícone
antigo. Conferir se os PNGs em `Assets.xcassets/AppIcon.appiconset` estão
atualizados; se estiverem, é cache do macOS.

**Bundle identifier.** Está `com.papagaio.Papagaioos` no projeto. Se não for
intencional, o app usa outro container — biblioteca e modelos separados.

## Notas — pergunta de produto em aberto

As notas são para **reler** depois ou para **virar entregável**? A resposta muda
o que vem a seguir: busca e leitura lado a lado com a transcrição, no primeiro
caso; exportar seleção e transformar nota em tarefa, no segundo.

## Feito nesta sessão

Interface: barra superior alinhada e responsiva, busca centralizada com recuo em
janela estreita, filtros clicáveis como pastilhas, cartões de altura igual,
cabeçalhos enxutos com ajuda em "i" no hover, ficha da conversa em popover
editável, player com volume estilo YouTube, arrastar do Finder para importar,
lixeira de mídia dentro da própria aba, origem (gravado/importado) no cartão.

Correções: componentes perdidos no porte MVVM restaurados, crash ao fechar o app
(ggml abortando no `exit`), mensagens de erro legíveis (`LocalizedError`),
`sistema.m4a` órfão derrubando a transcrição inteira, ficha da importação
gravando participantes sempre como 1.

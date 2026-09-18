import PapagaioCore
import SwiftUI

/// A mídia de todas as conversas reunida num só lugar — mesma ideia do
/// Painel de Tarefas (`TarefasView`), só que para fotos, vídeos, áudios e
/// outros anexos em vez de tarefas. Sem conversa nenhuma selecionada,
/// mostra tudo, com o cartão dizendo de qual conversa cada arquivo veio
/// (ver `origem` em `CartaoDeAnexoDeMidia`); selecionando uma ou mais
/// conversas na fileira do topo, filtra só as delas.
struct MidiasView: View {
    let biblioteca: Biblioteca?
    let consulta: String

    @State private var conversasSelecionadas: Set<ArquivoID> = []
    @State private var tipoSelecionado: String?
    @State private var versaoDasMidias = 0
    @State private var erro: String?

    /// Os tipos possíveis vêm direto de `AnexoDeMidiaDaConversa.tipoVisual`
    /// — não existe um enum próprio no modelo, então a lista aqui precisa
    /// bater exatamente com o que aquele computed property pode devolver.
    private static let tipos: [(nome: String, simbolo: String)] = [
        ("Imagem", "photo"),
        ("Vídeo", "film"),
        ("Áudio", "waveform"),
        ("PDF", "doc.richtext"),
        ("Arquivo", "doc"),
    ]

    private var conversas: [Arquivo] {
        biblioteca?.arquivos.sorted { $0.entradaNaBiblioteca > $1.entradaNaBiblioteca } ?? []
    }

    /// Sem filtro nenhum — só para decidir se a página está mesmo vazia
    /// (nada de mídia ativa, nada na lixeira) ou se só a seleção/busca atual
    /// não bateu com nada. Uma conversa com todos os anexos apagados some de
    /// `midiasPorConversa` (ela só lista quem tem anexo ativo), mas os itens
    /// dela continuam na lixeira — sem esta conta à parte, a página mostraria
    /// "Nenhuma mídia ainda" com itens recuperáveis escondidos logo abaixo.
    private var naLixeiraGeral: [MidiaNaLixeira] {
        _ = versaoDasMidias
        return LixeiraDeMidia.itens().filter { !$0.daGravacao }
    }

    private var midiasPorConversa: [MidiasDaConversaGeral] {
        _ = versaoDasMidias
        guard let biblioteca else { return [] }
        return conversas.compactMap { arquivo -> MidiasDaConversaGeral? in
            let anexos = MidiasDaConversa.carregar(arquivo.id)
            guard !anexos.isEmpty else { return nil }
            let pasta = biblioteca.audio(de: arquivo).deletingLastPathComponent()
            return MidiasDaConversaGeral(
                arquivo: arquivo,
                titulo: arquivo.resumo?.titulo ?? arquivo.titulo,
                pastaDaConversa: pasta,
                anexos: anexos
            )
        }
    }

    private var conversasVisiveis: [MidiasDaConversaGeral] {
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = midiasPorConversa
        let filtradasPorSelecao = conversasSelecionadas.isEmpty
            ? base
            : base.filter { conversasSelecionadas.contains($0.id) }

        guard !termo.isEmpty else { return filtradasPorSelecao }
        return filtradasPorSelecao.compactMap { conversa in
            let anexos = conversa.anexos.filter {
                conversa.titulo.casaComBusca(termo) || $0.nome.casaComBusca(termo)
            }
            guard !anexos.isEmpty else { return nil }
            return MidiasDaConversaGeral(
                arquivo: conversa.arquivo,
                titulo: conversa.titulo,
                pastaDaConversa: conversa.pastaDaConversa,
                anexos: anexos
            )
        }
    }

    /// Mostrar de qual conversa cada anexo veio só faz sentido quando a
    /// grade reúne mais de uma — dentro de uma única conversa selecionada,
    /// repetir o nome dela em todo cartão seria repetir o título da própria
    /// página (mesmo raciocínio de `CartaoDeTarefaDaConversa`).
    private var mostrandoVariasConversas: Bool {
        conversasSelecionadas.count != 1
    }

    private var midiasVisiveis: [MidiaGeral] {
        let todas = conversasVisiveis.flatMap { conversa in
            conversa.anexos.map { MidiaGeral(conversa: conversa, anexo: $0) }
        }
        let filtradas = tipoSelecionado.map { tipo in
            todas.filter { $0.anexo.tipoVisual == tipo }
        } ?? todas

        return filtradas.sorted { $0.anexo.data > $1.anexo.data }
    }

    /// Removido continua na grade, igual à aba Mídia de dentro de uma
    /// conversa (ver `CartaoDeMidiaRemovida`) — sumir de vista obrigaria a
    /// pessoa a abrir a conversa específica e procurar a lixeira de lá só
    /// para desfazer um clique de segundos atrás. Os mesmos filtros da
    /// grade (conversa, tipo, busca) valem aqui: um item apagado de uma
    /// conversa fora da seleção não deveria aparecer.
    ///
    /// Sem áudio da própria gravação: esta tela lida só com os anexos que a
    /// pessoa escolheu (`MidiasDaConversa`), não com `microfone.wav`/
    /// `sistema.caf` — o mesmo recorte de `midiasPorConversa`.
    private var naLixeiraVisivel: [MidiaNaLixeira] {
        let termo = consulta.trimmingCharacters(in: .whitespacesAndNewlines)
        var itens = naLixeiraGeral

        if !conversasSelecionadas.isEmpty {
            itens = itens.filter { conversasSelecionadas.contains($0.arquivoID) }
        }
        if let tipoSelecionado {
            itens = itens.filter { $0.tipo == tipoSelecionado }
        }
        guard !termo.isEmpty else { return itens }
        return itens.filter { $0.nome.casaComBusca(termo) || $0.conversaTitulo.casaComBusca(termo) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.pagina) {
                cabecalhoDaPagina

                if !midiasPorConversa.isEmpty {
                    seletorDeConversas
                }

                if midiasPorConversa.isEmpty && naLixeiraGeral.isEmpty {
                    CartaoDeEstadoVazio(
                        simbolo: "photo.on.rectangle",
                        titulo: "Nenhuma mídia ainda".localized,
                        mensagem: "Fotos, vídeos, áudios e outros anexos salvos em qualquer conversa aparecerão reunidos aqui.".localized
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .cartaoPapagaio()
                } else {
                    conteudo
                }
            }
            .larguraDeConteudoPapagaio()
            .padding(.horizontal, PapagaioTema.espacamentoDePagina)
            .padding(.vertical, PapagaioTema.espacamentoDePagina)
        }
        .background(PapagaioTema.fundo)
        .alert("Atenção".localized, isPresented: Binding(get: { erro != nil }, set: { if !$0 { erro = nil } })) {
            Button("OK".localized) { erro = nil }
        } message: {
            Text((erro ?? "").localized)
        }
    }

    private var cabecalhoDaPagina: some View {
        HStack(alignment: .center, spacing: PapagaioTema.Espaco.curto) {
            Text("Painel de Mídias".localized)
                .font(PapagaioTema.Tipo.tituloDePagina)
                .foregroundStyle(PapagaioTema.texto)

            // Nudge de +3pt: mesmo ajuste de
            // `BibliotecaHomeView.cabecalhoDaBiblioteca` e
            // `TarefasView.cabecalhoDoPainel` — o círculo do "i" ficava
            // acima do centro óptico da letra bold de 30pt mesmo com
            // `alignment: .center`.
            BotaoDeAjudaPapagaio(
                texto: "Fotos, vídeos, áudios e outros anexos de todas as conversas, reunidos num só lugar.".localized,
                ajuda: "Sobre a página de mídias".localized,
                largura: 280
            )
            .offset(y: 3)

            Spacer(minLength: 0)
        }
        .padding(PapagaioTema.Espaco.secao)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            PapagaioTema.superficie,
            in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var seletorDeConversas: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack {
                Text("Todas as conversas".localized)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(PapagaioTema.textoSecundario)

                Text("\(midiasPorConversa.count) \(midiasPorConversa.count == 1 ? "Conversa".localized : "Conversas".localized)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .padding(.vertical, PapagaioTema.Espaco.minimo)
                    .background(PapagaioTema.superficieSuave, in: Capsule())

                if !conversasSelecionadas.isEmpty {
                    Button("Limpar seleção".localized) {
                        withAnimation(.snappy(duration: 0.18)) {
                            conversasSelecionadas.removeAll()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.destaqueEscuro)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: PapagaioTema.Espaco.medio) {
                    ForEach(midiasPorConversa) { conversa in
                        CartaoFiltroDeConversaMidia(
                            conversa: conversa,
                            selecionado: conversasSelecionadas.contains(conversa.id)
                        ) {
                            alternarSelecao(conversa.id)
                        }
                    }
                }
                .padding(.vertical, PapagaioTema.Espaco.minimo)
            }
            .desvanecerNasBordasHorizontais()
        }
    }

    private var conteudo: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.largo) {
            resumoEFiltros

            if midiasVisiveis.isEmpty && naLixeiraVisivel.isEmpty {
                CartaoDeEstadoVazio(
                    simbolo: "magnifyingglass",
                    titulo: "Nenhuma mídia encontrada".localized,
                    mensagem: "Tente limpar a seleção, trocar o tipo de arquivo ou buscar por outra conversa.".localized
                )
                .frame(maxWidth: .infinity, minHeight: 240)
                .cartaoPapagaio()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 270), spacing: PapagaioTema.Espaco.largo, alignment: .top)],
                    spacing: PapagaioTema.Espaco.largo
                ) {
                    ForEach(midiasVisiveis) { midia in
                        CartaoDeAnexoDeMidia(
                            anexo: midia.anexo,
                            aoAbrir: { AberturaDeMidia.abrir(midia.anexo.url) },
                            aoRemover: { removerAnexo(midia) },
                            origem: mostrandoVariasConversas ? midia.conversa.titulo : nil
                        )
                    }

                    ForEach(naLixeiraVisivel) { item in
                        CartaoDeMidiaRemovida(
                            item: item,
                            aoRestaurar: { restaurarItem(item) },
                            aoApagarDeVez: { apagarDeVezItem(item) }
                        )
                    }
                }
                .animation(.snappy(duration: 0.22), value: naLixeiraVisivel)
            }
        }
    }

    private var resumoEFiltros: some View {
        HStack(alignment: .firstTextBaseline, spacing: PapagaioTema.Espaco.medio) {
            Label(tituloDaGrade, systemImage: "photo.on.rectangle")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(PapagaioTema.texto)
                .layoutPriority(1)

            Text("\(midiasVisiveis.count) \(midiasVisiveis.count == 1 ? "Arquivo".localized : "Arquivos".localized)")
                .font(.callout.weight(.bold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .padding(.horizontal, PapagaioTema.Espaco.medio)
                .padding(.vertical, PapagaioTema.Espaco.minimo)
                .background(PapagaioTema.superficieSuave, in: Capsule())
                .fixedSize()

            Spacer(minLength: PapagaioTema.Espaco.medio)

            Menu {
                Button("Todos os tipos".localized) { tipoSelecionado = nil }
                Divider()
                ForEach(Self.tipos, id: \.nome) { tipo in
                    Button(tipo.nome.localized, systemImage: tipo.simbolo) { tipoSelecionado = tipo.nome }
                }
            } label: {
                Label(tipoSelecionado?.localized ?? "Tipo de arquivo".localized, systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(BotaoDeFiltroDeTarefaGeral(ativo: tipoSelecionado != nil))
        }
    }

    private var tituloDaGrade: String {
        if conversasSelecionadas.count == 1, let selecionada = conversasVisiveis.first {
            return selecionada.titulo
        }
        return conversasSelecionadas.isEmpty ? "Todas as mídias".localized : "%d conversas selecionadas".localized(conversasSelecionadas.count)
    }

    private func alternarSelecao(_ id: ArquivoID) {
        withAnimation(.snappy(duration: 0.18)) {
            if conversasSelecionadas.contains(id) {
                conversasSelecionadas.remove(id)
            } else {
                conversasSelecionadas.insert(id)
            }
        }
    }

    /// Vai para a lixeira de mídia — mesmo destino de "Remover" dentro da
    /// aba Mídia de uma conversa (ver `MidiasDaConversaViewModel.remover`),
    /// só que sem passar por um view model específico de uma conversa: aqui
    /// a tela cobre várias ao mesmo tempo, então a remoção acontece direto
    /// contra a conversa dona do anexo clicado.
    private func removerAnexo(_ midia: MidiaGeral) {
        let anexo = midia.anexo
        let conversa = midia.conversa
        do {
            try LixeiraDeMidia.mover(
                url: anexo.url,
                nome: anexo.nome,
                tamanho: anexo.tamanho,
                tipo: anexo.tipoVisual,
                daGravacao: false,
                arquivoID: conversa.id,
                conversaTitulo: conversa.titulo,
                pastaDaConversa: conversa.pastaDaConversa
            )
            let atualizados = MidiasDaConversa.carregar(conversa.id).filter { $0.id != anexo.id }
            try MidiasDaConversa.salvar(atualizados, para: conversa.id)
            versaoDasMidias += 1
        } catch {
            self.erro = "Não foi possível remover \"%@\": %@".localized(anexo.nome, error.localizedDescription)
        }
    }

    /// Devolve o arquivo para a conversa de origem — mesma lógica de
    /// `MidiasDaConversaViewModel.restaurar`, sem depender de um view model
    /// de uma conversa específica.
    private func restaurarItem(_ item: MidiaNaLixeira) {
        if !LixeiraDeMidia.restaurar(item) {
            erro = "Não foi possível restaurar \"%@\".".localized(item.nome)
        }
        versaoDasMidias += 1
    }

    private func apagarDeVezItem(_ item: MidiaNaLixeira) {
        do {
            try LixeiraDeMidia.remover(item)
            versaoDasMidias += 1
        } catch {
            erro = "Não foi possível apagar definitivamente \"%@\": %@".localized(item.nome, error.localizedDescription)
        }
    }
}

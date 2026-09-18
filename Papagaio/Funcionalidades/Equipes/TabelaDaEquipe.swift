import SwiftUI

struct TabelaDaEquipe: View {
    static let itensPorPagina = 4

    let membros: [ParticipanteDaEquipe]
    let pagina: Int
    let podeGerenciar: Bool
    let aoEditarNome: (ParticipanteDaEquipe) -> Void
    let aoEditar: (ParticipanteDaEquipe) -> Void
    let aoRemover: (ParticipanteDaEquipe) -> Void
    let aoAlternarPagina: (Int) -> Void

    private var membrosDaPagina: [ParticipanteDaEquipe] {
        let inicio = min(pagina * Self.itensPorPagina, membros.count)
        let fim = min(inicio + Self.itensPorPagina, membros.count)
        return Array(membros[inicio..<fim])
    }

    private var ultimaPagina: Int {
        max(0, (membros.count - 1) / Self.itensPorPagina)
    }

    private var intervaloAtual: String {
        guard !membros.isEmpty else { return "Nenhum membro".localized }
        let fim = min((pagina + 1) * Self.itensPorPagina, membros.count)
        return "%d de %d membros".localized(fim, membros.count)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                HStack {
                    CabecalhoDeColuna("MEMBRO".localized, largura: 300)
                    CabecalhoDeColuna("IDENTIDADE".localized, largura: 330)
                    CabecalhoDeColuna("ACESSO".localized, largura: 210)
                    CabecalhoDeColuna("AÇÕES".localized, alinhamento: .trailing)
                }
                .padding(.horizontal, PapagaioTema.Espaco.secao)
                .frame(height: 64)

                SeparadorPapagaio()

                ForEach(membrosDaPagina) { membro in
                    LinhaDeMembroDaEquipe(
                        membro: membro,
                        podeGerenciar: podeGerenciar,
                        aoEditarNome: { aoEditarNome(membro) },
                        aoEditar: { aoEditar(membro) },
                        aoRemover: { aoRemover(membro) }
                    )

                    if membro.id != membrosDaPagina.last?.id {
                        SeparadorPapagaio()
                    }
                }

                SeparadorPapagaio()

                HStack {
                    Text(intervaloAtual)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)

                    Spacer()

                    HStack(spacing: PapagaioTema.Espaco.curto) {
                        Button {
                            aoAlternarPagina(-1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(pagina == 0 ? PapagaioTema.textoSecundario.opacity(0.3) : PapagaioTema.textoSecundario)
                        .disabled(pagina == 0)

                        Button {
                            aoAlternarPagina(1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(pagina >= ultimaPagina ? PapagaioTema.textoSecundario.opacity(0.3) : PapagaioTema.texto)
                        .disabled(pagina >= ultimaPagina)
                    }
                }
                .padding(.horizontal, PapagaioTema.Espaco.secao)
                .frame(height: 72)
            }
            .frame(minWidth: 940)
        }
        .cartaoPapagaio()
    }
}

struct CabecalhoDeColuna: View {
    let texto: String
    let largura: CGFloat?
    let alinhamento: Alignment

    init(_ texto: String, largura: CGFloat? = nil, alinhamento: Alignment = .leading) {
        self.texto = texto
        self.largura = largura
        self.alinhamento = alinhamento
    }

    var body: some View {
        Text(texto.localized)
            .font(.callout.weight(.bold))
            .foregroundStyle(PapagaioTema.textoSecundario)
            .lineLimit(1)
                    .minimumScaleFactor(0.82)
            .frame(width: largura, alignment: alinhamento)
            .frame(maxWidth: largura == nil ? .infinity : nil, alignment: alinhamento)
    }
}

struct LinhaDeMembroDaEquipe: View {
    let membro: ParticipanteDaEquipe
    let podeGerenciar: Bool
    let aoEditarNome: () -> Void
    let aoEditar: () -> Void
    let aoRemover: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: PapagaioTema.Espaco.largo) {
                AvatarDeMembro(iniciais: Papagaio.iniciais(de: membro.nome, vazio: "M"))

                VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
                    Text(membro.nome)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(PapagaioTema.texto)
                    Text(membro.eProprietario ? "Conta proprietária".localized : "Participante aceito".localized)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.textoSecundario)
                }
            }
            .frame(width: 300, alignment: .leading)

            Text("Apple Account compartilhada".localized)
                .font(.title3)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .frame(width: 330, alignment: .leading)

            Text(membro.descricaoDaPermissao.localized)
                .font(.callout.weight(.medium))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .padding(.horizontal, PapagaioTema.Espaco.largo)
                .frame(height: PapagaioTema.Altura.compacta)
                .background(PapagaioTema.destaque.opacity(0.24), in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                .frame(width: 210, alignment: .leading)

            Spacer()

            if podeGerenciar || membro.eAtual {
                Menu {
                    Button("Editar nome".localized, systemImage: "pencil", action: aoEditarNome)
                    if podeGerenciar && !membro.eProprietario {
                        Button("Alterar permissão".localized, systemImage: "lock", action: aoEditar)
                        Button("Remover".localized, systemImage: "trash", role: .destructive, action: aoRemover)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .foregroundStyle(PapagaioTema.textoSecundario)
                .help("Ações".localized)
            } else {
                Text("—")
                    .foregroundStyle(PapagaioTema.textoSecundario)
            }
        }
        .padding(.horizontal, PapagaioTema.Espaco.pagina)
        .frame(height: 96)
    }
}

struct AvatarDeMembro: View {
    let iniciais: String

    var body: some View {
        Text(iniciais)
            .font(.callout.weight(.bold))
            .foregroundStyle(PapagaioTema.texto)
            .frame(width: 50, height: 50)
            .background(
                LinearGradient(
                    colors: [PapagaioTema.destaqueSuave, PapagaioTema.superficieSuave],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
    }
}

import PapagaioCore
import SwiftUI


/// Seções reais disponíveis para uma conversa. Mantê-las fora da view de
/// composição permite reutilizar a barra de navegação sem criar telas que o
/// produto ainda não oferece.
enum SecaoDoDetalhe: String, CaseIterable, Identifiable {
    case resumo = "Resumo"
    case transcricao = "Transcrição"
    case notas = "Notas"
    case midia = "Mídia"
    case tarefas = "Tarefas"

    var id: Self { self }

    var simbolo: String {
        switch self {
        case .resumo: "text.alignleft"
        case .transcricao: "text.quote"
        case .notas: "note.text"
        case .midia: "photo.on.rectangle"
        case .tarefas: "list.clipboard"
        }
    }
}


/// Navegação horizontal entre os conteúdos que já existem no domínio de uma
/// conversa. A mudança de estado fica no container para preservar a regra de
/// abrir o player ao entrar na aba de áudio.
struct BarraDeSecoesDaConversa<Acessorio: View>: View {
    let secaoSelecionada: SecaoDoDetalhe
    let aoSelecionar: (SecaoDoDetalhe) -> Void
    /// Conteúdo encostado na ponta direita da mesma barra — a ficha da
    /// conversa. Fica aqui dentro para dividir a linha de base e o filete
    /// inferior com as abas, em vez de formar uma segunda faixa.
    @ViewBuilder let acessorio: Acessorio

    init(
        secaoSelecionada: SecaoDoDetalhe,
        aoSelecionar: @escaping (SecaoDoDetalhe) -> Void,
        @ViewBuilder acessorio: () -> Acessorio = { EmptyView() }
    ) {
        self.secaoSelecionada = secaoSelecionada
        self.aoSelecionar = aoSelecionar
        self.acessorio = acessorio()
    }

    /// As abas dividiam a largura inteira da janela: em tela cheia sobravam
    /// ~250pt entre "Resumo" e "Transcrição", e a barra deixava de ler como um
    /// grupo. Agora cada aba tem a largura do seu rótulo e o conjunto fica
    /// ancorado à esquerda, alinhado com o título da página.
    var body: some View {
        // Uma única régua rolável evita que abas sumam/cortem e elimina a
        // segunda barra horizontal que aparecia em janelas compactas.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: PapagaioTema.Espaco.secao) {
                abas
                acessorio
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(.top, PapagaioTema.Espaco.minimo)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PapagaioTema.borda.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var abas: some View {
        HStack(spacing: PapagaioTema.Espaco.secao) {
            ForEach(SecaoDoDetalhe.allCases) { secao in
                let estaSelecionada = secaoSelecionada == secao

                Button {
                    aoSelecionar(secao)
                } label: {
                    VStack(spacing: PapagaioTema.Espaco.curto) {
                        Label(secao.rawValue.localized, systemImage: secao.simbolo)
                            .labelStyle(.titleAndIcon)
                            .font(PapagaioTema.Tipo.apoio.weight(estaSelecionada ? .semibold : .regular))
                            .lineLimit(1)
                    .minimumScaleFactor(0.82)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(
                                estaSelecionada
                                    ? PapagaioTema.destaqueEscuro
                                    : PapagaioTema.textoSecundario
                            )

                        Rectangle()
                            .fill(estaSelecionada ? PapagaioTema.destaque : .clear)
                            .frame(height: 3)
                    }
                    // `Rectangle` é guloso: sem fixar o eixo horizontal ele
                    // esticava a aba inteira e as cinco voltavam a se espalhar
                    // pela janela, mesmo com o rótulo já dimensionado.
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(estaSelecionada ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

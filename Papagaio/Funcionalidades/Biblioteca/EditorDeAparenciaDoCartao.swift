import AppKit
import PapagaioCore
import SwiftUI

/// Cor e imagem da faixa de uma conversa, num popover ancorado ao cartão.
///
/// Três caminhos para a mesma decisão, porque são três públicos: a paleta
/// pronta resolve em um clique, a roda do sistema serve para quem está
/// escolhendo no olho, e o campo hexadecimal é como se casa a faixa com a cor
/// exata de uma marca. Só a roda seria caça ao pixel; só o hex exigiria saber
/// o código de cor de antemão.
struct EditorDeAparenciaDoCartao: View {
    let arquivoID: ArquivoID
    /// A cor que a faixa usaria sem escolha manual — a da pasta, ou a da marca.
    let corPadrao: Color
    @Binding var cor: Color?
    @Binding var semCor: Bool
    @Binding var banner: URL?
    @Binding var ajuste: AjusteDeImagem
    /// O modelo compacto não tem faixa — só a tarja de cor lateral — então
    /// não existe onde a imagem apareceria. Mostrar "Escolher imagem…"
    /// nesse modelo prometia um efeito que a pessoa nunca veria acontecer.
    var mostrarImagem = true

    @State private var hexDigitado = ""
    @FocusState private var editandoHex: Bool

    private let sugeridas: [Color] = AparenciaDasPastas.Cor.allCases.map(\.cor)
    private let colunas = [GridItem(.adaptive(minimum: 30), spacing: PapagaioTema.Espaco.curto)]

    private var corAtual: Color { cor ?? corPadrao }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            secao("Cor".localized)

            LazyVGrid(columns: colunas, spacing: PapagaioTema.Espaco.curto) {
                BotaoSemCor(ativo: semCor, acao: aplicarSemCor)

                ForEach(Array(sugeridas.enumerated()), id: \.offset) { _, opcao in
                    Button {
                        aplicar(opcao)
                    } label: {
                        Circle()
                            .fill(opcao)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().stroke(
                                    !semCor && cor == opcao ? PapagaioTema.texto : PapagaioTema.borda,
                                    lineWidth: !semCor && cor == opcao ? 2 : 1
                                )
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: PapagaioTema.Espaco.curto) {
                // A roda de cores do próprio macOS: além do círculo cromático,
                // ela traz o conta-gotas, que é como se copia uma cor de outra
                // janela sem saber o código dela.
                ColorPicker("", selection: Binding(
                    get: { semCor ? PapagaioTema.superficieSuave : corAtual },
                    set: { aplicar($0) }
                ), supportsOpacity: false)
                .labelsHidden()

                TextField("#RRGGBB", text: $hexDigitado)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .focused($editandoHex)
                    .onSubmit(aplicarHexDigitado)
                    .padding(.horizontal, PapagaioTema.Espaco.curto)
                    .frame(height: PapagaioTema.Altura.compacta)
                    .background(PapagaioTema.superficieSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                            .stroke(editandoHex ? PapagaioTema.destaque.opacity(0.6) : PapagaioTema.borda, lineWidth: 1)
                    }

            }

            if mostrarImagem {
                SeparadorPapagaio()

                secao("Imagem".localized)

                HStack(spacing: PapagaioTema.Espaco.curto) {
                    Button((banner == nil ? "Escolher imagem…" : "Trocar imagem…").localized, action: escolherImagem)
                        .buttonStyle(BotaoDeContornoPapagaio())

                    if banner != nil {
                        Button("Remover".localized, systemImage: "trash") {
                            AparenciaDoCartao.removerBanner(arquivoID)
                            banner = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.perigo)
                    }
                }

                if banner != nil {
                    SeletorDeAjusteDeImagem(ajuste: Binding(
                        get: { ajuste },
                        set: {
                            ajuste = $0
                            AparenciaDoCartao.definirAjuste($0, para: arquivoID)
                        }
                    ))
                }

                Text("A imagem cobre a cor. O texto do cartão ganha um véu escuro por cima dela para continuar legível.".localized)
                    .font(.caption)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(width: 280)
        .onAppear { hexDigitado = corAtual.hexadecimal ?? "" }
    }

    private func secao(_ titulo: String) -> some View {
        Text(titulo)
            .font(.caption.weight(.bold))
            .foregroundStyle(PapagaioTema.textoSecundario)
            .textCase(.uppercase)
    }

    /// Sem cor não é "cor nenhuma gravada" — é uma escolha própria.
    ///
    /// Por isso ela não limpa a cor guardada junto: quem volta atrás e escolhe
    /// "Padrão" reencontra a cor da pasta, e quem tinha uma cor manual antes
    /// não a perde por experimentar o cinza.
    private func aplicarSemCor() {
        semCor = true
        AparenciaDoCartao.definirSemCor(true, para: arquivoID)
    }

    private func aplicar(_ nova: Color) {
        semCor = false
        AparenciaDoCartao.definirSemCor(false, para: arquivoID)
        cor = nova
        AparenciaDoCartao.definirCor(nova, para: arquivoID)
        hexDigitado = nova.hexadecimal ?? ""
    }

    /// Texto inválido não apaga a cor: volta a mostrar a atual.
    ///
    /// Aplicar `nil` no meio da digitação faria a faixa piscar para o padrão a
    /// cada caractere incompleto.
    private func aplicarHexDigitado() {
        guard let nova = Color(hexadecimal: hexDigitado) else {
            hexDigitado = corAtual.hexadecimal ?? ""
            return
        }
        aplicar(nova)
    }

    private func escolherImagem() {
        let painel = NSOpenPanel()
        painel.title = "Escolha uma imagem para a faixa".localized
        painel.prompt = "Usar imagem".localized
        painel.canChooseFiles = true
        painel.canChooseDirectories = false
        painel.allowsMultipleSelection = false
        painel.allowedContentTypes = [.image]

        guard painel.runModal() == .OK,
              let url = painel.url,
              url.startAccessingSecurityScopedResource()
        else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        try? AparenciaDoCartao.definirBanner(url, para: arquivoID)
        banner = AparenciaDoCartao.banner(arquivoID)
    }
}

/// A opção "sem cor": um círculo vazio com a barra diagonal que o Figma, o
/// Finder e as etiquetas do macOS usam para dizer "nada aqui".
///
/// Precisa ser um botão na paleta, e não um interruptor à parte: é uma
/// alternativa às cores, e o lugar onde a pessoa procura por ela é entre elas.
struct BotaoSemCor: View {
    let ativo: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Circle()
                .fill(PapagaioTema.superficie)
                .frame(width: 26, height: 26)
                .overlay {
                    Path { caminho in
                        caminho.move(to: CGPoint(x: 5, y: 21))
                        caminho.addLine(to: CGPoint(x: 21, y: 5))
                    }
                    .stroke(PapagaioTema.perigo.opacity(0.7), lineWidth: 1.5)
                }
                .overlay {
                    Circle().stroke(
                        ativo ? PapagaioTema.texto : PapagaioTema.borda,
                        lineWidth: ativo ? 2 : 1
                    )
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Sem cor".localized)
    }
}

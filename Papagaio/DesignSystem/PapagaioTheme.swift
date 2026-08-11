import AppKit
import SwiftUI

/// Cor que troca sozinha entre claro e escuro.
///
/// O app inteiro era travado em `.preferredColorScheme(.light)` porque as cores
/// eram valores RGB fixos. Resolvendo na `NSColor` cada superfície passa a ter
/// as duas versões, e o modo escuro deixa de exigir uma segunda paleta paralela.
private func corAdaptativa(
    claro: (Double, Double, Double),
    escuro: (Double, Double, Double)
) -> Color {
    Color(nsColor: NSColor(name: nil) { aparencia in
        let ehEscuro = aparencia.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (r, g, b) = ehEscuro ? escuro : claro
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    })
}

/// Tokens visuais compartilhados por todas as telas.
///
/// Antes cada tela inventava a sua própria medida: cinco tamanhos de título de
/// página (30/32/34/36/42), seis raios de canto e vinte e dois espaçamentos
/// diferentes. Os valores abaixo são a única fonte — quem precisar de um número
/// novo acrescenta aqui em vez de escrever o literal na view.
enum PapagaioTema {
    // MARK: - Cores

    static let fundo = corAdaptativa(
        claro: (0.980, 0.976, 0.969),
        escuro: (0.086, 0.080, 0.075)
    )
    static let superficie = corAdaptativa(
        claro: (1.000, 1.000, 1.000),
        escuro: (0.137, 0.129, 0.122)
    )
    static let superficieSuave = corAdaptativa(
        claro: (0.949, 0.945, 0.937),
        escuro: (0.196, 0.184, 0.176)
    )
    static let texto = corAdaptativa(
        claro: (0.125, 0.118, 0.114),
        escuro: (0.960, 0.953, 0.945)
    )
    static let textoSecundario = corAdaptativa(
        claro: (0.385, 0.331, 0.306),
        escuro: (0.706, 0.671, 0.647)
    )
    static let borda = corAdaptativa(
        claro: (0.910, 0.796, 0.761),
        escuro: (0.286, 0.247, 0.227)
    )

    /// Coral da identidade. Só para superfícies e traços — **nunca** atrás de
    /// texto branco: a razão de contraste dá 2,3:1, abaixo do mínimo de 4,5:1.
    /// Texto sobre destaque usa `destaqueEscuro`.
    static let destaque = corAdaptativa(
        claro: (1.000, 0.537, 0.392),
        escuro: (1.000, 0.576, 0.435)
    )
    /// Variante legível: passa em 5,8:1 com branco por cima e em 4,7:1 sobre
    /// `destaqueSuave`. É a cor de texto e de botão preenchido.
    static let destaqueEscuro = corAdaptativa(
        claro: (0.663, 0.278, 0.161),
        escuro: (1.000, 0.678, 0.549)
    )
    static let destaqueSuave = corAdaptativa(
        claro: (0.992, 0.882, 0.847),
        escuro: (0.247, 0.169, 0.137)
    )

    static let sucesso = corAdaptativa(
        claro: (0.207, 0.485, 0.329),
        escuro: (0.400, 0.749, 0.545)
    )
    static let aviso = corAdaptativa(
        claro: (0.733, 0.435, 0.078),
        escuro: (0.925, 0.667, 0.286)
    )
    static let perigo = corAdaptativa(
        claro: (0.730, 0.176, 0.176),
        escuro: (0.902, 0.412, 0.396)
    )

    /// Preenchimento de botão principal, com o par de texto que o acompanha.
    ///
    /// Não dá para usar `destaqueEscuro` e branco nos dois temas: no escuro
    /// `destaqueEscuro` é um pêssego claro, e branco por cima dele volta a
    /// reprovar. Então o preenchimento inverte junto com o tema — fundo escuro
    /// com texto branco no claro, fundo coral com texto quase preto no escuro.
    /// Ambos passam folgado (5,8:1 e 8,4:1).
    static let preenchimentoPrimario = corAdaptativa(
        claro: (0.663, 0.278, 0.161),
        escuro: (1.000, 0.576, 0.435)
    )
    static let textoSobrePrimario = corAdaptativa(
        claro: (1.000, 1.000, 1.000),
        escuro: (0.086, 0.080, 0.075)
    )

    // MARK: - Espaçamento

    /// Escala de 4 em 4. Todo `spacing:` e `padding:` sai daqui.
    enum Espaco {
        /// 4 — separação entre rótulo e valor.
        static let minimo: CGFloat = 4
        /// 8 — itens muito ligados.
        static let curto: CGFloat = 8
        /// 12 — dentro de um controle ou linha.
        static let medio: CGFloat = 12
        /// 16 — padding interno de card.
        static let largo: CGFloat = 16
        /// 24 — entre blocos de uma seção.
        static let secao: CGFloat = 24
        /// 32 — entre seções da página.
        static let pagina: CGFloat = 32
    }

    // MARK: - Altura de controles

    /// Antes existiam catorze alturas (24, 28, 30, 32, 34, 36, 38, 40, 42, 46…).
    /// Três bastam, e é o que mantém botão, campo e menu alinhados numa linha.
    enum Altura {
        /// 28 — selo, chip, contador.
        static let compacta: CGFloat = 28
        /// 36 — botão, campo de texto, menu. O padrão.
        static let padrao: CGFloat = 36
        /// 44 — ação principal; também é o alvo mínimo de toque.
        static let destaque: CGFloat = 44
    }

    // MARK: - Tipografia

    /// Uma escala só. `tituloDePagina` substitui os cinco tamanhos de H1 que
    /// existiam espalhados pelas telas.
    enum Tipo {
        static let tituloDePagina = Font.system(size: 30, weight: .bold)
        static let tituloDeSecao = Font.system(size: 20, weight: .semibold)
        static let tituloDeCard = Font.system(size: 17, weight: .semibold)
        static let corpo = Font.body
        static let apoio = Font.callout
        static let legenda = Font.caption
        static let rotulo = Font.caption.weight(.semibold)
    }

    // MARK: - Formas

    /// Dois raios. Card usa 16, qualquer controle usa 8; selos são cápsulas.
    static let raioDeCard: CGFloat = 16
    static let raioDeControle: CGFloat = 8

    // MARK: - Larguras

    static let espacamentoDePagina: CGFloat = Espaco.secao
    /// Grades e tabelas podem ocupar a janela toda até este limite.
    static let larguraMaximaDeConteudo: CGFloat = 1_420
    /// Texto corrido para em 720pt (~70 caracteres). Acima disso o olho perde a
    /// volta da linha — era o que acontecia no resumo em tela cheia.
    static let larguraDeLeitura: CGFloat = 720
}

extension View {
    /// Superfície com a borda discreta e quente da identidade visual.
    func cartaoPapagaio(raio: CGFloat = PapagaioTema.raioDeCard) -> some View {
        background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: raio, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: raio, style: .continuous)
                    .stroke(PapagaioTema.borda, lineWidth: 1)
            }
    }

    /// Dá às páginas largura legível em janelas grandes, sem prejudicar
    /// redimensionamento ou Split View.
    ///
    /// O bloco é centralizado na janela: quando o limite de largura entra em
    /// ação, a sobra se divide igual dos dois lados. Ancorado à esquerda, toda
    /// a folga ia parar na direita e a página ficava visivelmente torta.
    func larguraDeConteudoPapagaio(alinhamento: Alignment = .leading) -> some View {
        frame(maxWidth: PapagaioTema.larguraMaximaDeConteudo, alignment: alinhamento)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Limita a largura de texto corrido à faixa confortável de leitura.
    func larguraDeLeituraPapagaio(alinhamento: Alignment = .leading) -> some View {
        frame(maxWidth: PapagaioTema.larguraDeLeitura, alignment: alinhamento)
    }

    /// Moldura padrão de campo de texto e de menu — mesma altura e mesmo raio
    /// dos botões, para que uma linha de controles fique alinhada.
    func molduraDeControlePapagaio(altura: CGFloat = PapagaioTema.Altura.padrao) -> some View {
        padding(.horizontal, PapagaioTema.Espaco.medio)
            .frame(height: altura)
            .background(
                PapagaioTema.superficie,
                in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                    .stroke(PapagaioTema.borda, lineWidth: 1)
            }
    }
}

/// Leitura de data digitada, compartilhada por todo campo que aceita texto.
///
/// Aceita o que a pessoa costuma escrever: 15/08/2026, 15-08-2026, 15082026,
/// 15/08/26 e 15/08 (assume o ano corrente).
enum DataDigitada {
    private static let formatos = ["dd/MM/yyyy", "dd-MM-yyyy", "ddMMyyyy", "dd/MM/yy", "dd/MM"]

    static func lendo(_ texto: String) -> Date? {
        let limpo = texto.trimmingCharacters(in: .whitespaces)
        guard !limpo.isEmpty else { return nil }

        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "pt_BR")
        formatador.calendar = Calendar.current

        for formato in formatos {
            formatador.dateFormat = formato
            guard let lida = formatador.date(from: limpo) else { continue }

            // "dd/MM" cai no ano de referência do formatador; joga para o ano
            // corrente, que é o que a pessoa quis dizer ao omitir o ano.
            if formato == "dd/MM" {
                let anoAtual = Calendar.current.component(.year, from: Date())
                var partes = Calendar.current.dateComponents([.day, .month], from: lida)
                partes.year = anoAtual
                return Calendar.current.date(from: partes)
            }

            return lida
        }

        return nil
    }

    static func texto(de data: Date) -> String {
        data.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year())
    }
}

/// Botão redondo de cromo — voltar, fechar, dispensar.
///
/// Existia copiado em quatro lugares com tamanhos e molduras diferentes: uns
/// com círculo e borda, outros só com o glifo solto, que não parecia clicável.
struct BotaoCircularPapagaio: View {
    let simbolo: String
    let ajuda: String
    var destaque: Bool = false
    /// Opcional: quem passar um binding ganha a mesma legenda flutuante da
    /// barra superior. Sem ele o botão continua contando só com o `help`,
    /// que é o tooltip lento do sistema.
    var legendaAtiva: Binding<LegendaDaBarra?>? = nil
    let acao: () -> Void

    /// Sem resposta ao mouse, o botão parecia um ícone decorativo: nada
    /// mudava até o clique. Ícone e borda acendem no coral da identidade,
    /// como já acontece nos botões da barra.
    @State private var pairando = false

    var body: some View {
        GeometryReader { geometria in
            Button(action: acao) {
                Image(systemName: simbolo)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        destaque || pairando
                            ? PapagaioTema.destaqueEscuro
                            : PapagaioTema.textoSecundario
                    )
                    .frame(width: PapagaioTema.Altura.padrao, height: PapagaioTema.Altura.padrao)
                    .background(PapagaioTema.superficie, in: Circle())
                    .overlay {
                        Circle().stroke(
                            pairando ? PapagaioTema.destaque.opacity(0.58) : PapagaioTema.borda,
                            lineWidth: 1
                        )
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(ajuda)
            .accessibilityLabel(ajuda)
            .onHover { ativo in
                pairando = ativo
                guard let legendaAtiva else { return }
                if ativo {
                    let area = geometria.frame(in: .global)
                    legendaAtiva.wrappedValue = LegendaDaBarra(
                        texto: ajuda,
                        x: area.midX,
                        baseDoIcone: area.maxY
                    )
                } else if legendaAtiva.wrappedValue?.texto == ajuda {
                    legendaAtiva.wrappedValue = nil
                }
            }
            .animation(.easeOut(duration: 0.14), value: pairando)
        }
        .frame(width: PapagaioTema.Altura.padrao, height: PapagaioTema.Altura.padrao)
    }
}

/// Campo de data na identidade visual do app: mesma moldura dos menus e campos
/// de texto, com calendário em popover e entrada por digitação.
///
/// O `DatePicker` nativo do macOS traz stepper e moldura próprios, que destoam
/// de tudo em volta — por isso o controle é montado aqui.
struct CampoDeDataPapagaio: View {
    @Binding var data: Date
    var rotuloAcessivel: String = "Data"

    @State private var mostrandoCalendario = false
    @State private var textoDigitado = ""
    @State private var textoInvalido = false

    private var dataPorExtenso: String {
        data.formatted(.dateTime.day(.twoDigits).month(.wide).year())
    }

    var body: some View {
        Button {
            mostrandoCalendario.toggle()
        } label: {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Image(systemName: "calendar")
                Text(dataPorExtenso)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(PapagaioTema.texto)
            .molduraDeControlePapagaio()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rotuloAcessivel)
        .accessibilityValue(dataPorExtenso)
        .popover(isPresented: $mostrandoCalendario, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: PapagaioTema.Espaco.curto) {
                Text("Digite a data")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PapagaioTema.textoSecundario)

                HStack(spacing: PapagaioTema.Espaco.curto) {
                    TextField("dd/mm/aaaa", text: $textoDigitado)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .padding(.horizontal, PapagaioTema.Espaco.medio)
                        .frame(height: PapagaioTema.Altura.padrao)
                        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                                .stroke(textoInvalido ? PapagaioTema.perigo : PapagaioTema.borda, lineWidth: 1)
                        }
                        .onSubmit(aplicarTextoDigitado)
                        .onChange(of: textoDigitado) { _, _ in textoInvalido = false }

                    Button("Usar", action: aplicarTextoDigitado)
                        .buttonStyle(BotaoDeContornoPapagaio())
                }

                if textoInvalido {
                    Text("Data não reconhecida. Use dd/mm/aaaa.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PapagaioTema.perigo)
                }

                Divider()
                    .padding(.vertical, PapagaioTema.Espaco.minimo)

                DatePicker(rotuloAcessivel, selection: $data, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
            }
            .padding(PapagaioTema.Espaco.medio)
            .frame(minWidth: 300)
            .onAppear {
                textoDigitado = DataDigitada.texto(de: data)
                textoInvalido = false
            }
        }
    }

    private func aplicarTextoDigitado() {
        guard let lida = dataLendo(textoDigitado) else {
            textoInvalido = true
            return
        }

        textoInvalido = false
        data = lida
        mostrandoCalendario = false
    }

    private func dataLendo(_ texto: String) -> Date? {
        DataDigitada.lendo(texto)
    }
}

struct BotaoPrincipalPapagaio: ButtonStyle {
    @Environment(\.isEnabled) private var habilitado

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(PapagaioTema.textoSobrePrimario)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            .frame(minHeight: PapagaioTema.Altura.destaque)
            .background(
                habilitado ? PapagaioTema.preenchimentoPrimario : PapagaioTema.preenchimentoPrimario.opacity(0.42),
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct BotaoDeContornoPapagaio: ButtonStyle {
    @Environment(\.isEnabled) private var habilitado

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(habilitado ? PapagaioTema.destaqueEscuro : PapagaioTema.textoSecundario)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PapagaioTema.Espaco.largo)
            .frame(minHeight: PapagaioTema.Altura.destaque)
            .background(PapagaioTema.superficie, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(PapagaioTema.borda.opacity(habilitado ? 1 : 0.5), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

enum EstiloDoStatus {
    case destaque
    case sucesso
    case aviso
    case erro
    case neutro

    var cor: Color {
        switch self {
        case .destaque: PapagaioTema.destaqueEscuro
        case .sucesso: PapagaioTema.sucesso
        case .aviso: PapagaioTema.aviso
        case .erro: PapagaioTema.perigo
        case .neutro: PapagaioTema.textoSecundario
        }
    }

    var fundo: Color {
        switch self {
        case .destaque: PapagaioTema.destaqueSuave
        case .sucesso: PapagaioTema.sucesso.opacity(0.14)
        case .aviso: PapagaioTema.aviso.opacity(0.15)
        case .erro: PapagaioTema.perigo.opacity(0.12)
        case .neutro: PapagaioTema.superficieSuave
        }
    }
}

struct SeloDeStatus: View {
    let texto: String
    let simbolo: String
    let estilo: EstiloDoStatus

    var body: some View {
        Label(texto, systemImage: simbolo)
            .font(PapagaioTema.Tipo.rotulo)
            .foregroundStyle(estilo.cor)
            .lineLimit(1)
            // Sem isto o selo era espremido pelo irmão ao lado e virava
            // "transcrito e resu…" — o estado do arquivo é justamente o que o
            // cartão precisa comunicar.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PapagaioTema.Espaco.medio)
            .frame(height: PapagaioTema.Altura.compacta)
            .background(estilo.fundo, in: Capsule())
    }
}

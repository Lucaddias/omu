import AppKit
import Foundation
import PapagaioCore
import SwiftUI
import Testing
@testable import Papagaio

// MARK: - Atalhos e foco

@Test("Space do player não captura um editor de texto")
@MainActor
func atalhoDoPlayerRespeitaFocoDeTexto() {
    #expect(!ArquivoDetalheView.atalhoDeReproducaoEstaDisponivel(
        primeiroRespondedor: NSTextView()
    ))
    #expect(!ArquivoDetalheView.atalhoDeReproducaoEstaDisponivel(
        primeiroRespondedor: NSTextField()
    ))
    #expect(ArquivoDetalheView.atalhoDeReproducaoEstaDisponivel(
        primeiroRespondedor: nil
    ))
}

// MARK: - Estado tipado

// `EstadoDoArquivo` nasceu para acabar com duas classificações incompatíveis da
// mesma string: o cartão decidia a cor por lista negativa de literais, e o
// detalhe por `contains("erro")`. O mesmo arquivo aparecia vermelho num lugar e
// neutro no outro.

@Test("Cada estado tem exatamente um estilo, sem depender do texto")
func estiloPorEstado() {
    #expect(EstadoDoArquivo.prontoParaTranscrever.estilo == .neutro)
    #expect(EstadoDoArquivo.transcrito.estilo == .neutro)
    #expect(EstadoDoArquivo.transcritoEResumido.estilo == .sucesso)
    #expect(EstadoDoArquivo.naFila(posicao: 1).estilo == .aviso)
    #expect(EstadoDoArquivo.processando(.transcrevendo).estilo == .destaque)
    #expect(EstadoDoArquivo.falhou("qualquer coisa").estilo == .erro)
}

@Test("Uma falha sem a palavra erro continua sendo tratada como falha")
func falhaSemAPalavraErro() {
    // Este era o caso que quebrava: "Nenhuma fala reconhecida neste áudio."
    // não contém "erro" nem "falhou", então o detalhe pintava de neutro
    // enquanto o cartão pintava de vermelho.
    let estado = EstadoDoArquivo.falhou("Nenhuma fala reconhecida neste áudio.")

    #expect(estado.estilo == .erro)
    #expect(estado.simbolo == "exclamationmark.triangle")
    #expect(estado.descricao == "Nenhuma fala reconhecida neste áudio.")
}

@Test("Só fila e processamento bloqueiam ações destrutivas")
func estadosOcupados() {
    #expect(EstadoDoArquivo.processando(.resumindo).ocupado)
    #expect(EstadoDoArquivo.naFila(posicao: 3).ocupado)
    #expect(!EstadoDoArquivo.prontoParaTranscrever.ocupado)
    #expect(!EstadoDoArquivo.transcritoEResumido.ocupado)
    #expect(!EstadoDoArquivo.falhou("x").ocupado)
}

@Test("A posição na fila aparece na descrição")
func descricaoDaFila() {
    #expect(EstadoDoArquivo.naFila(posicao: 2).descricao == "na fila (posição %d)".localized(2))
}

@Test("Os estados de processamento usam as chaves localizáveis do card")
func descricoesDasFasesDeProcessamento() {
    #expect(EstadoDoArquivo.processando(.transcrevendo).descricao == "transcrevendo…".localized)
    #expect(EstadoDoArquivo.processando(.diarizando).descricao == "distinguindo falantes…".localized)
    #expect(EstadoDoArquivo.processando(.resolvendoFalantes).descricao == "resolvendo falantes pelo contexto…".localized)
    #expect(EstadoDoArquivo.processando(.traduzindo).descricao == "traduzindo…".localized)
    #expect(EstadoDoArquivo.processando(.resumindo).descricao == "resumindo…".localized)
    #expect(EstadoDoArquivo.processando(.salvando).descricao == "salvando…".localized)
}

@Test("O editor sugere um e-mail pessoal válido para membros da equipe")
func emailSugeridoNoEditorDeInformacoes() {
    #expect(EditorDeInformacoesDoCard.emailSugeridoDaEquipe == "joao.santos@email.com")
}

// MARK: - Formatação de tempo

// Existiam catorze cópias disto em seis arquivos, metade com `%d:%02d` e metade
// com `%02d:%02d` — inconsistência visível na tela, não só duplicação.

@Test("Relógio e cronômetro formatam o mesmo instante de formas previsíveis")
func formatosDeTempo() {
    #expect(TimeInterval(187).comoRelogio == "3:07")
    #expect(TimeInterval(187).comoCronometro == "03:07")
    #expect(TimeInterval(59).comoRelogio == "0:59")
    #expect(TimeInterval(3_600).comoRelogio == "60:00")
}

@Test("Valores inválidos viram zero em vez de derrubar o processo")
func tempoInvalido() {
    // `AVPlayer` devolve NaN antes de carregar a duração, e `Int(NaN)` crasha.
    #expect(TimeInterval.nan.comoRelogio == "0:00")
    #expect(TimeInterval.infinity.comoRelogio == "0:00")
    #expect(TimeInterval(-30).comoRelogio == "0:00")
    #expect(TimeInterval.nan.faladoPorExtenso == "0 s")
}

@Test("VoiceOver recebe tempo por extenso, não 3:07")
func tempoPorExtenso() {
    #expect(TimeInterval(187).faladoPorExtenso == "3 min 7 s")
    #expect(TimeInterval(42).faladoPorExtenso == "42 s")
}

@Test("Canal confiável permanece na identidade visual e acessível da fala")
func identidadeDaFalaPreservaCanal() {
    let fala = FalaDeFalante(
        id: UUID(),
        falanteAcustico: "S1",
        inicio: 42,
        fim: 45,
        palavras: [],
        texto: "Vamos começar",
        speaker: Speaker.eu,
        trechoIds: []
    )

    #expect(LinhaDeFala.rotuloDoCanal(Speaker.eu) == "Eu · microfone".localized)
    #expect(
        LinhaDeFala.rotuloDoCanal(Speaker.interlocutor)
            == "Interlocutor · áudio do sistema".localized
    )
    #expect(
        LinhaDeFala.identidadeAcessivel(
            fala,
            falantePreservado: nil,
            nomesDeVoz: ["S1": "Luca"]
        ) == "\(LinhaDeFala.rotuloDoCanal(Speaker.eu)), Luca"
    )
}

// MARK: - Tema

@Test("Os tokens de cor mudam entre claro e escuro")
func temaTemDuasAparencias() {
    // Antes eram cores fixas claras e a `ContentView` forçava
    // `.preferredColorScheme(.light)`: quem usa o Mac no escuro recebia uma
    // janela branca no meio do sistema.
    let claro = NSAppearance(named: .aqua)
    let escuro = NSAppearance(named: .darkAqua)

    func componentes(_ cor: Color, _ aparencia: NSAppearance?) -> [CGFloat] {
        var resultado: [CGFloat] = []
        (aparencia ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            guard let convertida = NSColor(cor).usingColorSpace(.sRGB) else { return }
            resultado = [convertida.redComponent, convertida.greenComponent, convertida.blueComponent]
        }
        return resultado
    }

    for (nome, cor) in [
        ("fundo", PapagaioTema.fundo),
        ("superficie", PapagaioTema.superficie),
        ("texto", PapagaioTema.texto),
        ("destaqueEscuro", PapagaioTema.destaqueEscuro),
    ] {
        let noClaro = componentes(cor, claro)
        let noEscuro = componentes(cor, escuro)
        #expect(noClaro != noEscuro, "\(nome) não muda entre as aparências")
    }
}

@Test("O texto principal inverte de claridade entre as aparências")
func contrasteInverte() throws {
    func luminancia(_ cor: Color, _ aparencia: NSAppearance?) -> CGFloat {
        var valor: CGFloat = 0
        (aparencia ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(cor).usingColorSpace(.sRGB) else { return }
            valor = 0.2126 * srgb.redComponent
                + 0.7152 * srgb.greenComponent
                + 0.0722 * srgb.blueComponent
        }
        return valor
    }

    let claro = NSAppearance(named: .aqua)
    let escuro = NSAppearance(named: .darkAqua)

    // No claro: texto escuro sobre fundo claro. No escuro: o inverso.
    #expect(luminancia(PapagaioTema.texto, claro) < luminancia(PapagaioTema.fundo, claro))
    #expect(luminancia(PapagaioTema.texto, escuro) > luminancia(PapagaioTema.fundo, escuro))
}

@Test("Tempos finitos fora de Int não derrubam o app e minutos grandes não truncam")
func tempoExtremo() {
    for valor in [Double.greatestFiniteMagnitude, Double(Int.max)] {
        #expect(valor.comoRelogio == "0:00")
        #expect(valor.comoCronometro == "00:00")
        #expect(valor.faladoPorExtenso == "0 s")
        #expect(valor.comoDuracaoPorExtenso == "%d segundos".localized(0))
    }
    let minutos = Double(Int32.max) + 1
    #expect((minutos * 60).comoRelogio == "2147483648:00")
    #expect((minutos * 60).comoCronometro == "2147483648:00")
}

@Test("Duração digitada recusa infinito, overflow e valor negativo")
func leituraDeDuracaoValida() {
    #expect(TimeInterval.lendo("1h 15min") == 4_500)
    #expect(TimeInterval.lendo("1,5") == 90)
    #expect(TimeInterval.lendo("0") == 0)
    #expect(TimeInterval.lendo("-2") == nil)
    #expect(TimeInterval.lendo("inf") == nil)
    #expect(TimeInterval.lendo("1e308") == nil)
    #expect(TimeInterval.lendo(String(repeating: "9", count: 400) + "h") == nil)
}

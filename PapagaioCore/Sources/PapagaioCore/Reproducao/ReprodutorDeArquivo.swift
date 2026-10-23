import AVFoundation
import Foundation
import Observation

/// Player de áudio com navegação por trecho — backend portado do Eko
/// (`AudioPlaybackController`).
///
/// Toca **dois arquivos em paralelo**: o microfone (`.wav`) e o canal do
/// sistema (`.m4a`) são reproduzidos juntos, sincronizados pelo
/// `deviceCurrentTime` do `AVAudioPlayer` — o "merge só no playback" do Eko.
/// Nunca há mixagem prévia em disco, e é por isso que o áudio não sai mais
/// abafado (a mixagem antiga re-encodava tudo para AAC mono de 16 kHz).
///
/// Para arquivo de canal único (importado ou gravação antiga) o secundário é
/// `nil` e toca normal. Usa `AVAudioPlayer`, não `AVPlayer` — é o que o Eko
/// usa, e é o que abre o `.wav` do microfone e o `.m4a` do tap sem os
/// problemas do player antigo.
///
/// - Important: quem cria **tem que chamar `encerrar()`** ao sair da tela. O
///   temporizador de observação retém o bloco e sobrevive à view que o criou.
@MainActor
@Observable
public final class ReprodutorDeArquivo {
    /// ~10 Hz: rápido o bastante para o destaque não parecer travado, devagar o
    /// bastante para não acordar a main thread à toa. É o intervalo do Passo 10.
    public static let intervaloDeObservacao: TimeInterval = 0.1

    /// Posição atual, em segundos. Alimentada pelo temporizador de observação.
    public private(set) var tempo: TimeInterval = 0
    /// Duração do arquivo — o maior dos dois canais quando existem dois.
    public private(set) var duracao: TimeInterval = 0
    public private(set) var tocando = false
    public var volume: Float = 1 {
        didSet {
            let nivel = min(max(volume, 0), 1)
            primario?.volume = nivel
            secundario?.volume = nivel
        }
    }
    /// - Important: o `didSet` **não pode** atribuir a `velocidade`.
    ///   Numa classe `@Observable` a propriedade vira computada, e escrever nela
    ///   de dentro do próprio observador reentra no setter: recursão infinita e
    ///   estouro de pilha assim que o valor muda. O limite passou para
    ///   `aplicarVelocidade()` e `definirVelocidade(_:)`, que é onde ele
    ///   precisa valer de fato — nada fora da faixa chega ao `AVAudioPlayer`.
    public var velocidade: Float = 1 {
        didSet { aplicarVelocidade() }
    }

/// Mutável de propósito: a transcrição chega **depois** de a tela abrir
    /// (o processamento leva minutos). Recriar o player nesse momento faria o
    /// áudio voltar ao começo no meio da escuta.
    public var trechos: [Trecho] {
        didSet {
            // Nova transcrição chegou: o cursor da palavra pode apontar para um
            // trecho que não existe mais. Re-sincroniza no próximo tick.
            indiceDePalavraAtiva = nil
            idDoTrechoDaPalavraAtiva = nil
        }
    }

    /// O trecho e a palavra que estão tocando. O **trecho** é calculado por
    /// busca binária a cada leitura; a **palavra** dentro do trecho é
    /// incrementada pelo observador (etapa de `atualizarTempo`) e re-sincroniza
    /// com binária a cada `saltar` — buscar sempre custaria pouco numa lista de
    /// 150 elementos, mas o estado incremental mantém o custo **O(1) amortizado**
    /// no caminho quente dos 10 Hz.
    public var indiceAtivo: Int? {
        NavegacaoPorTrecho.indiceAtivo(em: tempo, trechos: trechos)
    }

    /// Índice da palavra ativa dentro do trecho ativo — `nil` quando o trecho
    /// ainda não começou, ou é legado e não tem palavras.
    public private(set) var indiceDePalavraAtiva: Int?

    /// Existe para o critério de aceite "sair da view não deixa observador vivo":
    /// é o que o teste consegue afirmar sem inspecionar o player.
    public var observando: Bool { temporizador != nil }

    /// Canal do microfone (ou o arquivo único, no caso de importado/legado).
    private let primario: AVAudioPlayer?
    /// Canal do sistema, tocado em paralelo ao microfone quando ambos existem.
    private let secundario: AVAudioPlayer?

    @ObservationIgnored private var temporizador: Timer?
    /// Trecho de onde veio o cursor da palavra — mudou de trecho, re-sincroniza.
    @ObservationIgnored private var idDoTrechoDaPalavraAtiva: UUID?

    public init(
        audio: URL,
        trechos: [Trecho],
        secundario urlSecundario: URL? = nil,
        intervalo: TimeInterval = ReprodutorDeArquivo.intervaloDeObservacao
    ) {
        self.trechos = trechos
        let principal = try? AVAudioPlayer(contentsOf: audio)
        let outro = urlSecundario.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        // Só o canal do sistema abriu (microfone truncado ou removido): ele
        // vira o principal. Antes a tela mostrava um player com duração e o
        // botão de tocar não fazia nada, porque o transporte segue o primário.
        self.primario = principal ?? outro
        self.secundario = principal == nil ? nil : outro
        self.intervaloDeObservacao = intervalo

        primario?.enableRate = true
        primario?.volume = volume
        secundario?.enableRate = true
        secundario?.volume = volume
    }

    /// `preparar()` carrega a duração e liga o observador.
    ///
    /// A duração do `AVAudioPlayer` já vem sincrona do `init`; aqui é onde o
    /// observador de tempo nasce — antes de qualquer `tocar()`, para que o
    /// `tempo` publicado nunca fique preso no 0.
    public func preparar() async {
        let primaria = primario?.duration ?? 0
        let secundaria = secundario?.duration ?? 0
        duracao = max(primaria, secundaria)
        temporizador?.invalidate()
        // `Timer.scheduledTimer` é indisponível de contexto async no Swift 6.2
        // (pode nunca disparar); criar o timer e anexá-lo ao RunLoop da main
        // foge disso e garante o modo `.common` (roda também durante gestos).
        //
        // Bloco, e não `target:`/`selector:`, por dois motivos. O `#selector`
        // exige um método `@objc`, e só classe que herda de `NSObject` pode
        // declarar membro `@objc` — esta não herda (é `@Observable` puro).
        // E o inicializador com alvo **retém** o alvo: o `deinit` abaixo nunca
        // rodaria, justamente a rede de segurança que ele existe para ser.
        //
        // O timer é entregue no RunLoop da main, então a isolação já é a certa.
        let timer = Timer(timeInterval: intervaloDeObservacao, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.atualizarTempo() }
        }
        temporizador = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Transporte

    public func tocar() {
        guard let primario, !primario.isPlaying else { return }
        // Sincroniza os dois pelo mesmo deviceCurrentTime — evita que um
        // comece perceptivelmente antes do outro.
        let inicio = primario.deviceCurrentTime + 0.05
        aplicarVelocidade()
        primario.play(atTime: inicio)
        secundario?.play(atTime: inicio)
        tocando = true
    }

    public func pausar() {
        primario?.pause()
        secundario?.pause()
        // Sincroniza na própria ação: sem isto a tela pode ficar até um tick
        // (100 ms) atrás do ponto real em que o áudio parou.
        atualizarTempo()
    }

    public func alternar() {
        tocando ? pausar() : tocar()
    }

    public func definirVelocidade(_ novaVelocidade: Float) {
        velocidade = Self.velocidadeNormalizada(novaVelocidade)
    }

    public func voltar(_ segundos: TimeInterval = 10) async {
        await saltar(paraSegundo: tempo - segundos)
    }

    public func avancar(_ segundos: TimeInterval = 10) async {
        await saltar(paraSegundo: tempo + segundos)
    }

    // MARK: - Navegação

    /// Salta para o início do trecho — o gesto do Passo 10.
    public func saltar(para trecho: Trecho) async {
        await saltar(paraSegundo: trecho.start)
    }

    /// Vai ao começo do trecho e inicia a escuta.
    public func tocar(aPartirDe trecho: Trecho) async {
        await saltar(para: trecho)
        tocar()
    }

    /// Salta para um instante. No `AVAudioPlayer` o `currentTime` é exato —
    /// sem a tolerância de quadro sincronizado do `AVPlayer` que fazia cliques
    /// em AAC pousarem no trecho anterior.
    ///
    /// O cursor da palavra re-sincroniza com binária aqui: um seek pode ir para
    /// frente ou para trás a qualquer momento, e a heurística incremental do
    /// tick não sabe disso.
    public func saltar(paraSegundo segundo: TimeInterval) async {
        let teto = duracao > 0 ? duracao : segundo
        let alvo = min(max(0, segundo), teto)

        // Atualiza antes do tick: o destaque responde ao clique, não ao
        // próximo tick do observador.
        tempo = alvo
        primario?.currentTime = alvo
        secundario?.currentTime = alvo
        atualizarPalavraAtiva(aposSalto: true)
    }

    // MARK: - Encerramento

    /// Para o áudio e remove o observador.
    ///
    /// Chame no `onDisappear`. O `Timer` retém o alvo até o `invalidate`;
    /// sem isto a view morre e o observador continua rodando, que é
    /// exatamente o que o critério de aceite do Passo 10 proíbe.
    public func encerrar() {
        temporizador?.invalidate()
        temporizador = nil
        primario?.stop()
        secundario?.stop()
        tocando = false
    }

    /// Rede de segurança para quem esquecer o `encerrar()`.
    ///
    /// `isolated deinit` (SE-0371) é o que torna isto possível num tipo
    /// `@MainActor`: um `deinit` comum é `nonisolated` e não poderia tocar no
    /// estado da classe.
    isolated deinit {
        encerrar()
    }

    // MARK: - Observação

    private func atualizarTempo() {
        tempo = primario?.currentTime ?? 0
        tocando = primario?.isPlaying ?? false
        atualizarPalavraAtiva()
    }

    /// Cursor incremental da palavra dentro do trecho ativo.
    ///
    /// No caminho quente (tick do observador) o trabalho é olhar **só a próxima
    /// palavra**: se ela já começou, avança; senão, o destaque continua onde
    /// está — O(1) amortizado. Re-sincroniza com binária quando o trecho muda,
    /// quando o tempo andou para trás sem seek (clock do player) ou após um
    /// `saltar`.
    private func atualizarPalavraAtiva(aposSalto: Bool = false) {
        guard let indiceDoTrecho = NavegacaoPorTrecho.indiceAtivo(em: tempo, trechos: trechos),
              indiceDoTrecho < trechos.count
        else {
            indiceDePalavraAtiva = nil
            idDoTrechoDaPalavraAtiva = nil
            return
        }

        let palavras = trechos[indiceDoTrecho].palavras
        guard let atual = indiceDePalavraAtiva,
              idDoTrechoDaPalavraAtiva == trechos[indiceDoTrecho].id
        else {
            // Primeiro tick ou trecho novo: começa com binária na nova lista.
            indiceDePalavraAtiva = NavegacaoPorPalavra.indiceAtivo(em: tempo, palavras: palavras)
            idDoTrechoDaPalavraAtiva = trechos[indiceDoTrecho].id
            return
        }

        // Trecho legado (sem palavras) ou índice inválido após troca de lista.
        guard palavras.indices.contains(atual) else {
            indiceDePalavraAtiva = nil
            return
        }

        if aposSalto || palavras[atual].start > tempo {
            indiceDePalavraAtiva = NavegacaoPorPalavra.indiceAtivo(em: tempo, palavras: palavras)
            return
        }

        // Avanço incremental: anda até a última palavra que já começou.
        var andando = atual
        while andando + 1 < palavras.count, palavras[andando + 1].start <= tempo {
            andando += 1
        }
        if andando != atual {
            indiceDePalavraAtiva = andando
        }
    }

    private func aplicarVelocidade() {
        let taxa = Self.velocidadeNormalizada(velocidade)
        primario?.rate = taxa
        secundario?.rate = taxa
    }

    private let intervaloDeObservacao: TimeInterval

    private static func velocidadeNormalizada(_ valor: Float) -> Float {
        min(max(valor.isFinite ? valor : 1, 0.5), 2)
    }
}

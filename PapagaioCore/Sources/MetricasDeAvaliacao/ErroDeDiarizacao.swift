import Foundation

/// Um intervalo de fala atribuído a um falante, em segundos desde o início do áudio.
public struct IntervaloDeFala: Sendable, Codable, Equatable {
    public let falante: String
    public let inicio: TimeInterval
    public let fim: TimeInterval

    public init(falante: String, inicio: TimeInterval, fim: TimeInterval) {
        self.falante = falante
        self.inicio = inicio
        self.fim = fim
    }

    func contem(_ instante: TimeInterval) -> Bool { instante >= inicio && instante < fim }
}

/// DER (*diarization error rate*) no formato do `md-eval` do NIST: fala perdida,
/// falso alarme e confusão de falante, somados e divididos pelo tempo de fala
/// da referência.
public struct ResultadoDeDiarizacao: Sendable, Codable, Equatable {
    public var falaDeReferencia: TimeInterval
    public var falaPerdida: TimeInterval
    public var falsoAlarme: TimeInterval
    public var confusao: TimeInterval
    public var falantesNaReferencia: Int
    public var falantesNaHipotese: Int

    public init(
        falaDeReferencia: TimeInterval = 0,
        falaPerdida: TimeInterval = 0,
        falsoAlarme: TimeInterval = 0,
        confusao: TimeInterval = 0,
        falantesNaReferencia: Int = 0,
        falantesNaHipotese: Int = 0
    ) {
        self.falaDeReferencia = falaDeReferencia
        self.falaPerdida = falaPerdida
        self.falsoAlarme = falsoAlarme
        self.confusao = confusao
        self.falantesNaReferencia = falantesNaReferencia
        self.falantesNaHipotese = falantesNaHipotese
    }

    public var der: Double {
        falaDeReferencia > 0 ? (falaPerdida + falsoAlarme + confusao) / falaDeReferencia : 0
    }

    /// Soma de tempos para o DER do corpus: o mesmo motivo do WER agregado.
    public static func + (a: ResultadoDeDiarizacao, b: ResultadoDeDiarizacao) -> ResultadoDeDiarizacao {
        ResultadoDeDiarizacao(
            falaDeReferencia: a.falaDeReferencia + b.falaDeReferencia,
            falaPerdida: a.falaPerdida + b.falaPerdida,
            falsoAlarme: a.falsoAlarme + b.falsoAlarme,
            confusao: a.confusao + b.confusao,
            falantesNaReferencia: a.falantesNaReferencia + b.falantesNaReferencia,
            falantesNaHipotese: a.falantesNaHipotese + b.falantesNaHipotese
        )
    }
}

public enum ErroDeDiarizacao {
    /// Calcula o DER quadro a quadro.
    ///
    /// - Parameters:
    ///   - colar: segundos ignorados em volta de cada fronteira da referência
    ///     (0,25 s é o padrão do NIST). A fronteira exata de um turno é
    ///     ambígua até para quem anota à mão; sem colar, o DER mede mais a
    ///     anotação do que o modelo.
    ///   - passo: resolução dos quadros.
    public static func avaliar(
        referencia: [IntervaloDeFala],
        hipotese: [IntervaloDeFala],
        colar: TimeInterval = 0.25,
        passo: TimeInterval = 0.01
    ) -> ResultadoDeDiarizacao {
        let fim = (referencia + hipotese).map(\.fim).max() ?? 0
        let fronteiras = referencia.flatMap { [$0.inicio, $0.fim] }
        let quadros = Int((fim / passo).rounded(.up))

        // Primeira passada: quem fala em cada quadro avaliado.
        var avaliados: [(ref: Set<String>, hip: Set<String>)] = []
        avaliados.reserveCapacity(quadros)
        for indice in 0..<quadros {
            let instante = (Double(indice) + 0.5) * passo
            if colar > 0, fronteiras.contains(where: { abs($0 - instante) < colar }) { continue }
            avaliados.append((
                ref: Set(referencia.filter { $0.contem(instante) }.map(\.falante)),
                hip: Set(hipotese.filter { $0.contem(instante) }.map(\.falante))
            ))
        }

        // O rótulo da hipótese é arbitrário ("S1", "S2"…): o mapeamento que
        // mais sobrepõe a referência é o que o DER assume.
        var sobreposicao: [String: [String: Double]] = [:]
        for quadro in avaliados {
            for h in quadro.hip {
                for r in quadro.ref { sobreposicao[h, default: [:]][r, default: 0] += passo }
            }
        }
        let mapa = melhorMapeamento(sobreposicao)

        var resultado = ResultadoDeDiarizacao(
            falantesNaReferencia: Set(referencia.map(\.falante)).count,
            falantesNaHipotese: Set(hipotese.map(\.falante)).count
        )
        for quadro in avaliados {
            let nRef = quadro.ref.count
            let nHip = quadro.hip.count
            let corretos = quadro.hip.filter { h in mapa[h].map(quadro.ref.contains) ?? false }.count
            resultado.falaDeReferencia += Double(nRef) * passo
            resultado.falaPerdida += Double(max(0, nRef - nHip)) * passo
            resultado.falsoAlarme += Double(max(0, nHip - nRef)) * passo
            resultado.confusao += Double(min(nRef, nHip) - corretos) * passo
        }
        return resultado
    }

    /// Mapeamento injetivo hipótese → referência de maior peso total.
    ///
    /// Busca exaustiva: com os poucos falantes de uma reunião (a hipótese
    /// raramente passa de oito rótulos) ela termina em microssegundos e não
    /// tem os casos de empate mal resolvidos de um guloso. Acima de dez
    /// rótulos cai no guloso para não explodir.
    public static func melhorMapeamento(_ peso: [String: [String: Double]]) -> [String: String] {
        let hipoteses = peso.keys.sorted()
        let referencias = Set(peso.values.flatMap(\.keys)).sorted()

        guard hipoteses.count <= 10 else { return mapeamentoGuloso(peso) }

        var melhor: (total: Double, mapa: [String: String]) = (0, [:])
        func buscar(_ indice: Int, usadas: Set<String>, total: Double, mapa: [String: String]) {
            guard indice < hipoteses.count else {
                if total > melhor.total { melhor = (total, mapa) }
                return
            }
            let h = hipoteses[indice]
            // Deixar este rótulo sem par também é uma opção.
            buscar(indice + 1, usadas: usadas, total: total, mapa: mapa)
            for r in referencias where !usadas.contains(r) {
                guard let p = peso[h]?[r], p > 0 else { continue }
                var novo = mapa
                novo[h] = r
                buscar(indice + 1, usadas: usadas.union([r]), total: total + p, mapa: novo)
            }
        }
        buscar(0, usadas: [], total: 0, mapa: [:])
        return melhor.mapa
    }

    private static func mapeamentoGuloso(_ peso: [String: [String: Double]]) -> [String: String] {
        let pares = peso.flatMap { h, refs in refs.map { (h: h, r: $0.key, p: $0.value) } }
            .sorted { $0.p > $1.p }
        var mapa: [String: String] = [:]
        var usadas: Set<String> = []
        for par in pares where mapa[par.h] == nil && !usadas.contains(par.r) {
            mapa[par.h] = par.r
            usadas.insert(par.r)
        }
        return mapa
    }
}

/// Uma palavra transcrita com o falante que o pipeline atribuiu a ela.
public struct PalavraAtribuida: Sendable, Equatable {
    public let inicio: TimeInterval
    public let fim: TimeInterval
    /// `nil` quando o pipeline não decidiu — "Voz desconhecida" na interface.
    public let falante: String?

    public init(inicio: TimeInterval, fim: TimeInterval, falante: String?) {
        self.inicio = inicio
        self.fim = fim
        self.falante = falante
    }
}

/// Acerto de falante **por palavra**: o que a pessoa vê na transcrição.
///
/// O DER mede segmentos acústicos; o app mostra palavras. Uma palavra pode
/// cair na fronteira de dois segmentos ou num buraco entre eles, e é o
/// alinhamento do app que decide. Esta métrica mede o resultado final.
public struct AcertoDeFalantePorPalavra: Sendable, Codable, Equatable {
    public var total: Int
    public var atribuidas: Int
    public var corretas: Int

    public init(total: Int = 0, atribuidas: Int = 0, corretas: Int = 0) {
        self.total = total
        self.atribuidas = atribuidas
        self.corretas = corretas
    }

    /// Corretas sobre todas as palavras: palavra sem falante conta como erro.
    public var acuracia: Double { total > 0 ? Double(corretas) / Double(total) : 0 }
    public var cobertura: Double { total > 0 ? Double(atribuidas) / Double(total) : 0 }

    public static func + (a: Self, b: Self) -> Self {
        Self(total: a.total + b.total, atribuidas: a.atribuidas + b.atribuidas, corretas: a.corretas + b.corretas)
    }

    public static func avaliar(
        palavras: [PalavraAtribuida],
        referencia: [IntervaloDeFala]
    ) -> AcertoDeFalantePorPalavra {
        guard !referencia.isEmpty else { return AcertoDeFalantePorPalavra(total: palavras.count) }

        let verdade = palavras.map { falanteDeReferencia(de: $0, em: referencia) }
        var peso: [String: [String: Double]] = [:]
        for (palavra, real) in zip(palavras, verdade) {
            guard let falante = palavra.falante else { continue }
            peso[falante, default: [:]][real, default: 0] += 1
        }
        let mapa = ErroDeDiarizacao.melhorMapeamento(peso)

        var resultado = AcertoDeFalantePorPalavra(total: palavras.count)
        for (palavra, real) in zip(palavras, verdade) {
            guard let falante = palavra.falante else { continue }
            resultado.atribuidas += 1
            if mapa[falante] == real { resultado.corretas += 1 }
        }
        return resultado
    }

    /// O turno que mais cobre a palavra; num buraco entre turnos, o mais próximo.
    static func falanteDeReferencia(de palavra: PalavraAtribuida, em referencia: [IntervaloDeFala]) -> String {
        func cobertura(_ intervalo: IntervaloDeFala) -> TimeInterval {
            max(0, min(palavra.fim, intervalo.fim) - max(palavra.inicio, intervalo.inicio))
        }
        func distancia(_ intervalo: IntervaloDeFala) -> TimeInterval {
            max(0, intervalo.inicio - palavra.fim, palavra.inicio - intervalo.fim)
        }
        if let coberto = referencia.max(by: { cobertura($0) < cobertura($1) }), cobertura(coberto) > 0 {
            return coberto.falante
        }
        return referencia.min(by: { distancia($0) < distancia($1) })!.falante
    }
}

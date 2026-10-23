import Foundation

/// O texto das instruções do resumo, sem a moldura de nenhum modelo.
///
/// O Qwen embrulha isto em ChatML (`QwenEngine.prompt`); a nuvem privada da
/// Apple recebe `sistema` como instruções da sessão e `usuario` como prompt
/// (`NuvemPrivadaEngine`). O conteúdo mora num lugar só para que as duas
/// engines nunca passem a resumir com regras diferentes.
public enum PromptsDoResumo {
    public struct Mensagens: Sendable, Equatable {
        public let sistema: String
        public let usuario: String

        public init(sistema: String, usuario: String) {
            self.sistema = sistema
            self.usuario = usuario
        }

        /// Quanto as duas partes ocupam juntas — é o que o orçamento de
        /// tokens da nuvem estima.
        public var texto: String { sistema + "\n" + usuario }
    }

    /// A ata completa numa chamada só.
    static func ata(
        transcricao: String,
        idiomaDeSaida: IdiomaDeProcessamento?
    ) -> Mensagens {
        Mensagens(
            sistema: """
            Você é o "Ateiro Profissa", um analista sênior que transforma diálogos \
            caóticos e transcrições brutas em atas limpas, estratégicas e acionáveis \
            \(instrucaoDeIdioma(idiomaDeSaida)). Regras: (1) seja fiel à transcrição, não invente \
            números, nomes nem decisões. (2) Sem termos corporativos vazios — nada de \
            "sinergia", "disrupção" ou "com base em nossos aprendizados". Seja direto \
            e realista. (3) Use os nomes EXATAMENTE como aparecem na transcrição, sem \
            alterar, corrigir nem inventar variações. Se o nome aparecer como "Dr. Nando", \
            use "Dr. Nando" em todo o resumo, nunca "Fernando" nem "Nando". (4) Produza \
            uma análise completa e detalhada, proporcional à duração da reunião.
            """,
            usuario: """
            Analise a reunião abaixo e produza uma ata profissional completa e detalhada. \
            Não comprima: cubra todos os assuntos e organize os temas com pontos e subpontos, \
            incluindo valores, datas, nomes, prazos e decisões quando estiverem na transcrição.

            \(GramaticaDoResumo.descricaoDoFormato)

            TRANSCRIÇÃO:
            \(transcricao)
            """
        )
    }

    /// Resumo livre de uma parte da reunião (fase "map").
    static func parcial(
        transcricao: String,
        idiomaDeSaida: IdiomaDeProcessamento?
    ) -> Mensagens {
        Mensagens(
            sistema: """
            Você é o "Ateiro Profissa". Resume trechos de reunião de forma fiel, \
            detalhada e sem floreios. \(instrucaoDeIdioma(idiomaDeSaida))
            """,
            usuario: """
            Resuma este trecho de forma completa e detalhada, preservando números, \
            nomes, decisões e argumentos de cada lado. Não comprima.

            \(transcricao)
            """
        )
    }

    /// Consolidação dos resumos parciais numa ata (fase "reduce").
    static func reducao(
        parciais: String,
        idiomaDeSaida: IdiomaDeProcessamento?
    ) -> Mensagens {
        Mensagens(
            sistema: """
            Você é o "Ateiro Profissa". Consolida resumos parciais de uma mesma \
            reunião, conectando assuntos e classificando \
            cada tópico como Ponto Principal ou Secundário. Produza uma ata completa.
            """,
            usuario: """
            \(instrucaoDeIdioma(idiomaDeSaida)) Os textos abaixo são resumos de partes consecutivas da MESMA reunião. \
            Consolide numa ata profissional completa e detalhada, conectando assuntos \
            que aparecem em partes diferentes. Cubra todos os tópicos discutidos.

            \(GramaticaDoResumo.descricaoDoFormato)

            \(parciais)
            """
        )
    }

    /// `nil` preserva o idioma detectado na transcrição. Isso é diferente de
    /// "português por padrão": um sistema em inglês falando inglês não deve
    /// receber uma ata traduzida só porque o prompt foi escrito em português.
    static func instrucaoDeIdioma(_ idioma: IdiomaDeProcessamento?) -> String {
        guard let idioma else {
            return "Escreva no mesmo idioma predominante da transcrição; não a traduza."
        }
        return "Escreva toda a resposta em \(idioma.nomeParaPrompt)."
    }
}

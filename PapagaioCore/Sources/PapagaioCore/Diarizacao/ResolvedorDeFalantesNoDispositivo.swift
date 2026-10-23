import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Resolução contextual de falantes pelo modelo **on-device** da Apple
/// (`SystemLanguageModel`), para quando o Qwen não está no Mac.
///
/// Fica no dispositivo de propósito, mesmo com o resumo na nuvem privada: a
/// resolução roda em lotes (uma chamada a cada punhado de casos) e o limite
/// diário da nuvem é contado por requisição. Aqui não há limite nem rede, e a
/// tarefa é pequena — escolher entre três valores com 80 palavras de contexto.
public enum ResolvedorDeFalantesNoDispositivo {
    /// Metade do lote do Qwen: a janela do modelo on-device é de 4 mil tokens
    /// no macOS 26 (8 mil no 27), contra os 32 mil do Qwen.
    public static let casosPorChamada = 6

    public static var disponivel: Bool {
#if canImport(FoundationModels)
        SystemLanguageModel.default.isAvailable
#else
        false
#endif
    }

    /// Sem o modelo on-device, devolve o arquivo só com a costura de vozes
    /// iguais — que não depende de modelo nenhum.
    public static func resolver(_ arquivo: Arquivo) async throws -> Arquivo {
#if canImport(FoundationModels)
        guard disponivel else { return ResolvedorDeFalantes.costurarVozesIguais(arquivo) }
        return try await ResolvedorDeFalantes.resolver(
            arquivo, casosPorChamada: casosPorChamada
        ) { casos in
            try await responder(casos)
        }
#else
        return ResolvedorDeFalantes.costurarVozesIguais(arquivo)
#endif
    }

    /// A resposta do modelo a um lote, ainda em JSON bruto. Pública para o
    /// diagnóstico do `papagaio-eval` mostrar o que ele disse em cada lote.
    public static func responder(_ casos: [ResolvedorDeFalantes.Caso]) async throws -> String {
#if canImport(FoundationModels)
        let mensagens = ResolvedorDeFalantes.mensagens(para: casos)
        // É classificação de um texto que a pessoa já tem: as proteções
        // padrão recusariam conversas legítimas sobre temas delicados.
        let sessao = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: mensagens.sistema
        )
        var opcoes = GenerationOptions()
        opcoes.temperature = 0
        opcoes.maximumResponseTokens = 32 * casos.count
        let resposta = try await sessao.respond(
            to: mensagens.usuario,
            schema: try esquema(quantidade: casos.count),
            includeSchemaInPrompt: true,
            options: opcoes
        )
        return resposta.content.jsonString
#else
        throw CocoaError(.featureUnsupported)
#endif
    }

#if canImport(FoundationModels)
    /// O mesmo contrato da gramática GBNF do Qwen: chaves posicionais
    /// (`"1"`, `"2"`, …) e três valores possíveis.
    static func esquema(quantidade: Int) throws -> GenerationSchema {
        let voz = DynamicGenerationSchema(
            name: "Voz",
            anyOf: ["voz-1", "voz-2", "indeterminado"]
        )
        let raiz = DynamicGenerationSchema(
            name: "Resolucoes",
            properties: (1...max(1, quantidade)).map { numero in
                DynamicGenerationSchema.Property(
                    name: String(numero),
                    schema: DynamicGenerationSchema(referenceTo: "Voz")
                )
            }
        )
        return try GenerationSchema(root: raiz, dependencies: [voz])
    }
#endif
}

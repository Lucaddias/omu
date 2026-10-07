import Foundation
import os
import SwiftData

/// Repositório local da biblioteca.
///
/// A configuração explícita `.none` mantém os dados somente neste dispositivo.
///
/// `@ModelActor` porque `ModelContext` não é `Sendable`: o ator garante que
/// todo acesso ao contexto acontece numa mesma fila.
@ModelActor
public actor SwiftDataRepository: ArquivoRepository {
    /// Falhas de persistência que não derrubam a operação, mas não podem ser
    /// silenciosas (ex.: palavras que não codificaram para JSON).
    private static let logger = Logger(subsystem: "PapagaioCore", category: "Persistencia")

    private enum ErroDeSalvamento: LocalizedError {
        case previewIncompleto

        var errorDescription: String? {
            "A conversa precisa ser carregada por completo antes de ser salva."
        }
    }

    /// Container local, com o schema completo do app.
    public static func containerLocal(
        nome: String = "Papagaio",
        emMemoria: Bool = false
    ) throws -> ModelContainer {
        let schema = esquemaLocal()
        let configuracao = ModelConfiguration(
            nome,
            schema: schema,
            isStoredInMemoryOnly: emMemoria,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuracao])
    }

#if OMU_PERF
    public static func containerLocal(
        nome: String = "Papagaio",
        url: URL
    ) throws -> ModelContainer {
        let schema = esquemaLocal()
        let configuracao = ModelConfiguration(
            nome,
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuracao])
    }
#endif

    private static func esquemaLocal() -> Schema {
        Schema([
            ArquivoPersistido.self,
            TrechoPersistido.self,
            InsightPersistido.self,
            NotaPersistida.self,
            EspacoPersistido.self,
        ])
    }

    // MARK: - ArquivoRepository

    /// Aplica uma versão que veio de outro Mac pela sincronização, **com o
    /// estado de lixeira que ela traz**.
    ///
    /// `salvar` nunca tira nada da lixeira — é a proteção contra um resultado
    /// tardio do pipeline ressuscitar o que a pessoa apagou. Mas na
    /// sincronização o `apagadoEm` recebido é a decisão de alguém: sem
    /// aplicá-lo, uma conversa restaurada por um colega continuava na lixeira
    /// de todos os outros.
    public func salvarRecebido(_ a: Arquivo) async throws {
        try await salvar(a)
        guard let persistido = try buscarPersistido(id: a.id),
              persistido.apagadoEm != a.apagadoEm
        else { return }
        persistido.apagadoEm = a.apagadoEm
        try modelContext.save()
    }

    public func salvar(_ a: Arquivo) async throws {
        // Um preview pode ter `palavras=[]` apenas porque a lista adiou o
        // decode. Recusá-lo protege os timestamps caso algum chamador esqueça
        // de reidratar o arquivo antes de uma edição.
        guard a.possuiPalavrasComTimestamp != true else {
            throw ErroDeSalvamento.previewIncompleto
        }

        let existente = try buscarPersistido(id: a.id)
        let persistido = existente ?? ArquivoPersistido(id: a.id.rawValue)

        persistido.titulo = a.titulo
        persistido.criadoEm = a.criadoEm
        persistido.importadoEm = a.importadoEm
        persistido.duracao = a.duracao
        persistido.pastaRelativa = a.pastaRelativa
        persistido.idExterno = a.idExterno
        persistido.usavaFones = a.usavaFones
        persistido.tituloManual = a.tituloManual
        persistido.engineTranscricao = a.engineTranscricao
        persistido.engineResumo = a.engineResumo
        // Uma atualização tardia do pipeline não pode ressuscitar um item que
        // já foi movido para a lixeira. Restauração é uma operação explícita
        // (`restaurar`), não um efeito colateral de `salvar`.
        if existente == nil || a.apagadoEm != nil {
            persistido.apagadoEm = a.apagadoEm
        }
        persistido.espaco = try espacoPersistido(a.espaco)

        if existente == nil { modelContext.insert(persistido) }

        // Trechos, insights e notas são reescritos por inteiro. Eles chegam
        // como valores no `Arquivo` de domínio, e reconciliar item a item
        // custaria mais que regravar. `ordem` preserva a sequência de notas
        // quando duas compartilham o mesmo timestamp.
        regravarTrechos(a.trechos, em: persistido)
        regravarResumo(a.resumo, em: persistido)

        for antiga in persistido.notas ?? [] { modelContext.delete(antiga) }
        persistido.notas = []
        for (ordem, nota) in a.notas.enumerated() {
            let persistida = NotaPersistida(id: nota.id)
            persistida.texto = nota.texto
            persistida.start = nota.start
            persistida.critica = nota.critica
            persistida.tipo = nota.tipo.rawValue
            persistida.ordem = ordem
            persistida.arquivo = persistido
            modelContext.insert(persistida)
        }

        try salvarContexto()
    }

    /// Ver `ArquivoRepository.salvarResultadoDoProcessamento`.
    ///
    /// Registro que ainda não existe (CLI, que processa sem ter salvo antes)
    /// é gravado por inteiro. O que já existe só recebe as partes pedidas.
    public func salvarResultadoDoProcessamento(
        _ a: Arquivo,
        partes: PartesDoProcessamento
    ) async throws {
        guard let persistido = try buscarPersistido(id: a.id) else {
            try await salvar(a)
            return
        }

        if partes.contains(.transcricao) {
            guard a.possuiPalavrasComTimestamp != true else {
                throw ErroDeSalvamento.previewIncompleto
            }
            regravarTrechos(a.trechos, em: persistido)
            persistido.engineTranscricao = a.engineTranscricao
        }

        if partes.contains(.resumo) {
            var resumo = a.resumo
            // Título escolhido pela pessoa vence o que o modelo inventou —
            // a interface mostra o título do resumo quando ele existe.
            if persistido.tituloManual == true, let gerado = resumo {
                resumo = Resumo(
                    titulo: persistido.titulo,
                    visaoGeral: gerado.visaoGeral,
                    temas: gerado.temas,
                    citacoes: gerado.citacoes,
                    proximosPassos: gerado.proximosPassos
                )
            }
            regravarResumo(resumo, em: persistido)
            persistido.engineResumo = a.engineResumo
        }

        try salvarContexto()
    }

    /// Caminhos de mídia de **todos** os registros — qualquer espaço, ativos
    /// e na lixeira. Serve para reconhecer, na abertura, pastas de gravação
    /// que ficaram no disco sem registro (app encerrado no meio da gravação).
    public func pastasRelativasConhecidas() throws -> Set<String> {
        let todos = try modelContext.fetch(FetchDescriptor<ArquivoPersistido>())
        return Set(todos.map(\.pastaRelativa).filter { !$0.isEmpty })
    }

    private func regravarResumo(_ resumo: Resumo?, em persistido: ArquivoPersistido) {
        persistido.temResumo = resumo != nil
        persistido.resumoTitulo = resumo?.titulo ?? ""
        persistido.resumoVisaoGeral = resumo?.visaoGeral ?? ""
        for antigo in persistido.insights ?? [] { modelContext.delete(antigo) }
        persistido.insights = []
        if let resumo {
            inserirInsights(de: resumo, em: persistido)
        }
    }

    private func regravarTrechos(_ trechos: [Trecho], em persistido: ArquivoPersistido) {
        for antigo in persistido.trechos ?? [] { modelContext.delete(antigo) }
        persistido.trechos = []

        for trecho in trechos {
            let t = TrechoPersistido(id: trecho.id)
            t.start = trecho.start
            t.fim = trecho.end
            t.texto = trecho.texto
            t.speaker = trecho.speaker
            // Vazio é o mesmo que ausente: transcrições sem palavras guardam
            // `nil`, e a leitura cai no fallback do `Text` inteiro.
            //
            // Falha de codificação **não** pode virar `try?` silencioso: o
            // trecho era persistido sem timestamps de palavra sem nenhum
            // sinal, e a navegação palavra a palavra morria sem diagnóstico.
            if trecho.palavras.isEmpty {
                t.palavrasJSON = nil
            } else {
                do {
                    t.palavrasJSON = try JSONEncoder().encode(trecho.palavras)
                } catch {
                    Self.logger.error(
                        "Palavras do trecho \(trecho.id.uuidString) não codificaram: \(error.localizedDescription, privacy: .public). O trecho segue sem timestamps."
                    )
                    t.palavrasJSON = nil
                }
            }
            t.arquivo = persistido
            modelContext.insert(t)
        }
    }

    /// Busca com **prioridade de título**.
    ///
    /// Duas consultas, não uma com ordenação: quem procura "orçamento" e tem um
    /// arquivo chamado "Orçamento Q3" quer *aquele* primeiro, mesmo que outros
    /// dez mencionem a palavra no corpo. Ordenar por relevância calculada daria
    /// o mesmo resultado com muito mais código.
    ///
    /// `localizedStandardContains` é o que faz "orcamento" achar "Orçamento":
    /// ignora caixa **e** diacrítico. Um `contains` simples não acha.
    ///
    /// A assinatura precisa sobreviver a uma eventual migração para FTS5 sem
    /// mudar — por isso o retorno é `[Arquivo]` puro, sem tipo de score.
    public func buscar(termo: String, espaco: EspacoID) async throws -> [Arquivo] {
        let limpo = termo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty else { return [] }
        let alvo = espaco.rawValue

        let ordem = [SortDescriptor(\ArquivoPersistido.criadoEm, order: .reverse)]

        // Bucket A — o termo está no título.
        var porTitulo = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.titulo.localizedStandardContains(limpo) },
            sortBy: ordem
        )
        porTitulo.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]
        let bucketA = try modelContext.fetch(porTitulo)
            .filter { $0.apagadoEm == nil && $0.espaco?.id == alvo }
            // O descritor usa `criadoEm` porque SwiftData não traduz a
            // coalescência de `importadoEm ?? criadoEm` para SQL de forma
            // portátil. A ordenação final mantém o mesmo critério usado no
            // bucket de corpo: quando entrou na biblioteca, e não quando o
            // áudio foi originalmente gravado.
            .sorted { ($0.importadoEm ?? $0.criadoEm) > ($1.importadoEm ?? $1.criadoEm) }
        let idsDoTitulo = Set(bucketA.map(\.id))

        // Bucket B — o termo está no corpo: visão geral, trecho, insight ou nota.
        //
        // Quatro consultas separadas, unidas depois. Um `#Predicate` único com
        // as quatro condições em `||` (três delas sobre relações) **não compila**:
        // "the compiler is unable to type-check this expression in reasonable
        // time". Separar é mais rápido de compilar e mais fácil de ler.
        var porCorpo: [ArquivoPersistido] = []
        var jaVistos = idsDoTitulo

        func acrescentar(_ encontrados: [ArquivoPersistido]) {
            for arquivo in encontrados where !jaVistos.contains(arquivo.id) {
                jaVistos.insert(arquivo.id)
                porCorpo.append(arquivo)
            }
        }

        var porVisaoGeral = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.resumoVisaoGeral.localizedStandardContains(limpo) },
            sortBy: ordem
        )
        porVisaoGeral.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]
        acrescentar(try modelContext.fetch(porVisaoGeral).filter {
            $0.apagadoEm == nil && $0.espaco?.id == alvo
        })

        let porTrecho = FetchDescriptor<TrechoPersistido>(
            predicate: #Predicate { $0.texto.localizedStandardContains(limpo) }
        )
        acrescentar(
            try modelContext.fetch(porTrecho)
                .compactMap(\.arquivo)
                .filter { $0.apagadoEm == nil && $0.espaco?.id == alvo }
        )

        let porInsight = FetchDescriptor<InsightPersistido>(
            predicate: #Predicate { $0.texto.localizedStandardContains(limpo) }
        )
        acrescentar(
            try modelContext.fetch(porInsight)
                .compactMap(\.arquivo)
                .filter { $0.apagadoEm == nil && $0.espaco?.id == alvo }
        )

        let porNota = FetchDescriptor<NotaPersistida>(
            predicate: #Predicate { $0.texto.localizedStandardContains(limpo) }
        )
        acrescentar(
            try modelContext.fetch(porNota)
                .compactMap(\.arquivo)
                .filter { $0.apagadoEm == nil && $0.espaco?.id == alvo }
        )

        // `importadoEm ?? criadoEm`, e não só `criadoEm`: numa importação
        // `criadoEm` vale a data real da gravação, que pode estar longe no
        // passado — resultado de busca deve vir ordenado por quando entrou
        // na biblioteca, não por quando foi gravado.
        porCorpo.sort { ($0.importadoEm ?? $0.criadoEm) > ($1.importadoEm ?? $1.criadoEm) }
        return (bucketA + porCorpo).map { Self.paraDominio($0) }
    }

    public func listar(espaco: EspacoID) async throws -> [Arquivo] {
        let alvo = espaco.rawValue
        var descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.espaco?.id == alvo && $0.apagadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm, order: .reverse)]
        )
        descritor.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]
        return try modelContext.fetch(descritor).map { Self.paraDominio($0) }
    }

    /// Preview dos cartões: conserva texto e timeline para a busca local, mas
    /// adia o decode de `palavrasJSON` até a conversa ser aberta.
    public func listarParaBiblioteca(espaco: EspacoID) async throws -> [Arquivo] {
        let alvo = espaco.rawValue
        var descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.espaco?.id == alvo && $0.apagadoEm == nil },
            sortBy: [SortDescriptor(\.criadoEm, order: .reverse)]
        )
        descritor.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]
        return try modelContext.fetch(descritor).map {
            Self.paraDominio($0, decodificarPalavras: false)
        }
    }

    /// Itens removidos da biblioteca continuam persistidos e com o áudio no
    /// disco até que a pessoa confirme a exclusão definitiva na lixeira.
    public func listarNaLixeira(espaco: EspacoID) async throws -> [Arquivo] {
        let alvo = espaco.rawValue
        var descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.espaco?.id == alvo && $0.apagadoEm != nil }
        )
        descritor.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]

        return try modelContext.fetch(descritor)
            .sorted { ($0.apagadoEm ?? .distantPast) > ($1.apagadoEm ?? .distantPast) }
            .map { Self.paraDominio($0) }
    }

    /// Cartões da lixeira sem materializar arrays de palavras.
    public func listarNaLixeiraParaBiblioteca(espaco: EspacoID) async throws -> [Arquivo] {
        let alvo = espaco.rawValue
        var descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.espaco?.id == alvo && $0.apagadoEm != nil }
        )
        descritor.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]
        return try modelContext.fetch(descritor)
            .sorted { ($0.apagadoEm ?? .distantPast) > ($1.apagadoEm ?? .distantPast) }
            .map { Self.paraDominio($0, decodificarPalavras: false) }
    }

    /// Busca todos os timestamps de palavra apenas quando o detalhe os exige.
    public func buscarCompleto(id: ArquivoID) async throws -> Arquivo? {
        let alvo = id.rawValue
        var descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.id == alvo }
        )
        descritor.relationshipKeyPathsForPrefetching = [\.trechos, \.insights, \.notas]
        guard let persistido = try modelContext.fetch(descritor).first else { return nil }
        return Self.paraDominio(persistido)
    }

    /// Move o registro para a lixeira sem alterar `pastaRelativa`. Mover a
    /// pasta de mídia aqui tornaria a restauração mais frágil e não traz ganho:
    /// ela já está isolada no container do app.
    public func moverParaLixeira(_ id: ArquivoID) async throws {
        guard let persistido = try buscarPersistido(id: id) else { return }
        guard persistido.apagadoEm == nil else { return }
        persistido.apagadoEm = Date()
        try salvarContexto()
    }

    /// Devolve o mesmo registro — incluindo trechos, resumo e pasta de áudio —
    /// à listagem normal.
    public func restaurar(_ id: ArquivoID) async throws {
        guard let persistido = try buscarPersistido(id: id) else { return }
        guard persistido.apagadoEm != nil else { return }
        persistido.apagadoEm = nil
        try salvarContexto()
    }

    /// Apaga o registro **e os arquivos em disco** de maneira definitiva.
    ///
    /// Critério de aceite da lixeira: apenas esta ação apaga também a pasta de
    /// mídia. Deixar o áudio órfão no container é vazamento de disco que a
    /// pessoa não tem como limpar.
    public func apagar(_ id: ArquivoID) async throws {
        try await apagar(id) { relativo in
            try Armazenamento.padrao().removerGravacao(relativa: relativo)
        }
    }

    /// Mesmo fluxo, removendo a mídia do armazenamento **de quem chama**. A
    /// variante sem argumento usa sempre o container padrão: uma biblioteca
    /// aberta sobre outra raiz apagava o registro e deixava o áudio no disco.
    public func apagar(_ id: ArquivoID, em armazenamento: Armazenamento) async throws {
        try await apagar(id) { relativo in
            try armazenamento.removerGravacao(relativa: relativo)
        }
    }

    /// Mesmo fluxo com a remoção da mídia injetável — os testes simulam a
    /// falha dela sem tocar o disco real do usuário.
    func apagar(_ id: ArquivoID, removerMidia: (String) throws -> Void) async throws {
        guard let persistido = try buscarPersistido(id: id) else { return }
        guard persistido.apagadoEm != nil else {
            throw ErroLixeira.arquivoNaoEstaNaLixeira
        }

        let relativo = persistido.pastaRelativa

        // A mídia sai primeiro para que uma falha no filesystem deixe o
        // registro intacto na lixeira e a operação possa ser repetida. Se o
        // `save` falhar depois, a pasta já ausente é aceita pelo armazenamento
        // e uma nova tentativa consegue concluir a remoção do registro.
        if !relativo.isEmpty {
            do {
                try removerMidia(relativo)
            } catch ErroArmazenamento.caminhoDeGravacaoInvalido {
                // Um caminho fora do formato `Gravacoes/<nome>` nunca é
                // apagado do disco — mas também não pode prender o registro
                // na lixeira para sempre. Sai o registro; o caso fica no log.
                Self.logger.error(
                    "Registro apagado sem remover mídia: caminho fora do padrão (\(relativo, privacy: .private))"
                )
            }
        }

        modelContext.delete(persistido)
        try salvarContexto()
    }

    /// Exclui todos os registros de um espaço, ativos e na lixeira. É usado
    /// somente pela remoção da conta; por isso não aplica a regra de que o
    /// arquivo precisa passar antes pela lixeira.
    public func apagarTodosOsDados(espaco: EspacoID) throws {
        let alvo = espaco.rawValue
        let descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.espaco?.id == alvo }
        )
        for arquivo in try modelContext.fetch(descritor) {
            modelContext.delete(arquivo)
        }

        let descritorDoEspaco = FetchDescriptor<EspacoPersistido>(
            predicate: #Predicate { $0.id == alvo }
        )
        for espacoPersistido in try modelContext.fetch(descritorDoEspaco) {
            modelContext.delete(espacoPersistido)
        }
        try salvarContexto()
    }

    /// Remove somente um registro que acabou de ser salvo por uma operação
    /// invalidada. É a compensação de uma corrida entre save e exclusão de
    /// perfil; a mídia correspondente é tratada pelo chamador.
    public func descartarRegistro(_ id: ArquivoID) throws {
        guard let persistido = try buscarPersistido(id: id) else { return }
        modelContext.delete(persistido)
        try salvarContexto()
    }

    /// A versão local-first não oferece mais seleção de equipes. Para não
    /// esconder conversas criadas nos espaços antigos, reúne todos os registros
    /// (ativos, na lixeira e também os legados sem relação de espaço) no espaço
    /// pessoal antes de a interface começar a listá-los.
    ///
    /// Esta operação é idempotente: depois da primeira execução, todos os
    /// arquivos já apontam para `destino` e nenhum espaço antigo resta para
    /// remover.
    public func migrarTodosOsEspacos(para destino: EspacoID) throws {
        let idDoDestino = destino.rawValue
        let espacoDestino = try espacoPersistido(destino)
        let arquivos = try modelContext.fetch(FetchDescriptor<ArquivoPersistido>())

        for arquivo in arquivos where arquivo.espaco?.id != idDoDestino {
            arquivo.espaco = espacoDestino
        }

        let espacos = try modelContext.fetch(FetchDescriptor<EspacoPersistido>())
        for espaco in espacos where espaco.id != idDoDestino {
            modelContext.delete(espaco)
        }

        try salvarContexto()
    }

    // MARK: - Apoio

    /// Todo caminho que muta o SwiftData passa por aqui. Sem rollback, uma
    /// falha de disco deixa os objetos em memória marcados para inserção,
    /// edição ou exclusão e uma operação posterior pode persistir esse estado
    /// parcial por acidente.
    private func salvarContexto() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func buscarPersistido(id: ArquivoID) throws -> ArquivoPersistido? {
        let alvo = id.rawValue
        let descritor = FetchDescriptor<ArquivoPersistido>(
            predicate: #Predicate { $0.id == alvo }
        )
        return try modelContext.fetch(descritor).first
    }

    private func espacoPersistido(_ id: EspacoID) throws -> EspacoPersistido {
        let alvo = id.rawValue
        let descritor = FetchDescriptor<EspacoPersistido>(
            predicate: #Predicate { $0.id == alvo }
        )
        if let existente = try modelContext.fetch(descritor).first { return existente }

        let novo = EspacoPersistido(id: alvo, nome: "Meu espaço")
        modelContext.insert(novo)
        return novo
    }

    private func inserirInsights(de resumo: Resumo, em arquivo: ArquivoPersistido) {
        var ordem = 0
        func inserir(_ tipo: String, texto: String, detalhe: String? = nil,
                     start: TimeInterval? = nil, speaker: String? = nil) {
            let insight = InsightPersistido()
            insight.tipo = tipo
            insight.texto = texto
            insight.detalhe = detalhe
            insight.start = start
            insight.speaker = speaker
            insight.ordem = ordem
            insight.arquivo = arquivo
            modelContext.insert(insight)
            ordem += 1
        }

        for tema in resumo.temas {
            inserir(TipoDeInsight.tema, texto: tema.titulo, detalhe: tema.detalhe)
        }
        for citacao in resumo.citacoes {
            inserir(TipoDeInsight.citacao, texto: citacao.texto,
                    start: citacao.start, speaker: citacao.speaker)
        }
        for passo in resumo.proximosPassos {
            inserir(TipoDeInsight.proximoPasso, texto: passo.descricao,
                    detalhe: passo.responsavel)
        }
    }

    // MARK: - Mapeamento para o domínio

    /// Arranca o código de token especial (`[_BEG_]`, `[_TT_88]`) que a primeira
    /// versão da extração mesclou a palavras reais (`"Alô?[_TT_200]"` → `"Alô?"`).
    /// Palavra que vira só o código (caso do `[_BEG_]` isolado) fica vazia e é
    /// descartada pelo `filter` do chamador.
    static func curarTextoDePalavraLegada(_ texto: String) -> String {
        texto.replacingOccurrences(of: #"\[_[^]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func paraDominio(
        _ p: ArquivoPersistido,
        decodificarPalavras: Bool = true
    ) -> Arquivo {
        let trechosPersistidos = (p.trechos ?? []).sorted { $0.start < $1.start }
        let possuiPalavrasComTimestamp = trechosPersistidos.contains {
            Self.possuiPalavrasCodificadas($0.palavrasJSON)
        }
        let trechos = trechosPersistidos.map { pTrecho in
            let palavras: [Palavra]
            if decodificarPalavras {
                palavras = Self.decodificarPalavras(pTrecho.palavrasJSON, trecho: pTrecho.id)?
                    .map {
                        Palavra(
                            id: $0.id,
                            start: $0.start,
                            end: $0.end,
                            texto: curarTextoDePalavraLegada($0.texto),
                            confianca: $0.confianca,
                            noSpeechProb: $0.noSpeechProb,
                            // A diarização sobrevive ao round-trip: sem isto
                            // os falantes somiam ao reabrir o app (o init com
                            // default apagava o campo).
                            falanteAcustico: $0.falanteAcustico
                        )
                    }
                    .filter { !$0.texto.isEmpty } ?? []
            } else {
                palavras = []
            }

            return Trecho(
                id: pTrecho.id,
                start: pTrecho.start,
                end: pTrecho.fim,
                texto: pTrecho.texto,
                speaker: pTrecho.speaker,
                palavras: palavras,
                // Derivada das palavras, que são persistidas com a confiança
                // de cada uma: o selo por trecho volta sem campo novo no banco.
                confianca: Trecho.confiancaMedia(palavras)
            )
        }

        let insights = (p.insights ?? []).sorted { $0.ordem < $1.ordem }
        let notas = (p.notas ?? [])
            .sorted {
                $0.start == $1.start
                    ? $0.ordem < $1.ordem
                    : $0.start < $1.start
            }
            .map {
                NotaDaConversa(
                    id: $0.id,
                    texto: $0.texto,
                    start: $0.start,
                    critica: $0.critica,
                    tipo: TipoDeNotaDaConversa(rawValue: $0.tipo) ?? .nota
                )
            }
        var resumo: Resumo?
        if p.temResumo {
            resumo = Resumo(
                titulo: p.resumoTitulo,
                visaoGeral: p.resumoVisaoGeral,
                temas: insights.filter { $0.tipo == TipoDeInsight.tema }
                    .map { Tema(titulo: $0.texto, detalhe: $0.detalhe ?? "") },
                citacoes: insights.filter { $0.tipo == TipoDeInsight.citacao }
                    .map { Citacao(texto: $0.texto, speaker: $0.speaker, start: $0.start) },
                proximosPassos: insights.filter { $0.tipo == TipoDeInsight.proximoPasso }
                    .map { ProximoPasso(descricao: $0.texto, responsavel: $0.detalhe) }
            )
        }

        return Arquivo(
            id: ArquivoID(rawValue: p.id),
            titulo: p.titulo,
            criadoEm: p.criadoEm,
            duracao: p.duracao,
            pastaRelativa: p.pastaRelativa,
            espaco: p.espaco.map { EspacoID(rawValue: $0.id) } ?? .legado,
            trechos: trechos,
            notas: notas,
            resumo: resumo,
            engineTranscricao: p.engineTranscricao,
            engineResumo: p.engineResumo,
            apagadoEm: p.apagadoEm,
            idExterno: p.idExterno,
            importadoEm: p.importadoEm,
            usavaFones: p.usavaFones,
            possuiPalavrasComTimestamp: decodificarPalavras ? nil : possuiPalavrasComTimestamp,
            tituloManual: p.tituloManual
        )
    }

    /// Sem palavras guardadas devolve `nil` em silêncio — é o estado normal de
    /// um trecho sem timestamps. JSON que existe e não decodifica é registrado:
    /// antes o trecho perdia a navegação por palavra sem deixar pista.
    private static func decodificarPalavras(_ json: Data?, trecho: UUID) -> [Palavra]? {
        guard let json, !json.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode([Palavra].self, from: json)
        } catch {
            logger.error(
                "Palavras do trecho \(trecho.uuidString) não decodificaram: \(error.localizedDescription, privacy: .public). O trecho segue sem timestamps."
            )
            return nil
        }
    }

    /// Reconhece `[]` sem instanciar `Palavra`; o encoder do app serializa
    /// arrays sem espaços, e os espaços em branco são aceitos para legado.
    private static func possuiPalavrasCodificadas(_ json: Data?) -> Bool {
        guard let json else { return false }
        var indice = json.startIndex
        while indice < json.endIndex, [9, 10, 13, 32].contains(json[indice]) {
            indice = json.index(after: indice)
        }
        guard indice < json.endIndex, json[indice] == 91 else { return false }
        indice = json.index(after: indice)
        while indice < json.endIndex, [9, 10, 13, 32].contains(json[indice]) {
            indice = json.index(after: indice)
        }
        return indice < json.endIndex && json[indice] != 93
    }
}

/// Ações irreversíveis só podem partir da coleção Lixeira. A interface já
/// aplica essa regra, mas o repositório a repete para proteger chamadas futuras
/// e estados visuais desatualizados.
public enum ErroLixeira: LocalizedError, Equatable {
    case arquivoNaoEstaNaLixeira

    public var errorDescription: String? {
        switch self {
        case .arquivoNaoEstaNaLixeira:
            "Mova o arquivo para a lixeira antes de apagá-lo definitivamente."
        }
    }
}

import SwiftUI

/// Controle no topo da aba de Transcrição para dar nome de verdade às vozes
/// que a diarização só rotula como "Voz 1", "Voz 2"... Sem isto, ler uma
/// entrevista longa vira uma adivinhação de qual "Voz" é o entrevistado e
/// qual é quem entrevista.
///
/// Renomear aqui não toca a transcrição em si (`Trecho`/`Palavra` no
/// domínio) — é só uma preferência de exibição (ver
/// `PreferenciasVisuaisDoArquivo.nomesDeVoz`), então todas as falas daquela
/// voz mudam de rótulo instantaneamente, sem reescrever nada no disco.
struct EditorDeNomesDeVoz: View {
    /// Rótulos acústicos brutos ("S1", "S2"...), na ordem em que a
    /// diarização os numerou.
    let vozes: [String]
    /// Nome escolhido para cada rótulo bruto — ausente ou vazio quando ainda
    /// não renomeado.
    let nomes: [String: String]
    /// Nomes já digitados na ficha da entrevista (entrevistado +
    /// entrevistadores), para sugerir enquanto a pessoa digita.
    let sugestoes: [String]
    let aoRenomear: (_ vozAcustica: String, _ novoNome: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.medio) {
            HStack(spacing: PapagaioTema.Espaco.curto) {
                Image(systemName: "person.text.rectangle")
                    .font(.callout)
                    .foregroundStyle(PapagaioTema.textoSecundario)
                Text("Quem é quem?".localized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PapagaioTema.texto)
                BotaoDeAjudaPapagaio(
                    texto: "Dê um nome de verdade a cada voz identificada pela diarização. Isso atualiza todas as falas dela na transcrição de uma vez.".localized,
                    ajuda: "Sobre nomear vozes".localized,
                    largura: 300
                )
            }

            LayoutDeFluxo(espacoHorizontal: PapagaioTema.Espaco.medio, espacoVertical: PapagaioTema.Espaco.medio) {
                ForEach(vozes, id: \.self) { voz in
                    CampoDeNomeDeVoz(
                        rotuloPadrao: RotuloDeVoz.padrao(voz),
                        nomeAtual: nomes[voz] ?? "",
                        sugestoes: sugestoes,
                        aoSalvar: { novoNome in aoRenomear(voz, novoNome) }
                    )
                }
            }
        }
        .padding(PapagaioTema.Espaco.largo)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeCard, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1)
        }
    }
}

/// Um campo "Voz N: [nome]" com autocomplete simples — uma lista de
/// sugestões que aparece por baixo do campo enquanto a pessoa digita,
/// filtrada pelo que já foi escrito.
private struct CampoDeNomeDeVoz: View {
    let rotuloPadrao: String
    let nomeAtual: String
    let sugestoes: [String]
    let aoSalvar: (String) -> Void

    @State private var texto: String
    @FocusState private var focado: Bool

    init(rotuloPadrao: String, nomeAtual: String, sugestoes: [String], aoSalvar: @escaping (String) -> Void) {
        self.rotuloPadrao = rotuloPadrao
        self.nomeAtual = nomeAtual
        self.sugestoes = sugestoes
        self.aoSalvar = aoSalvar
        _texto = State(initialValue: nomeAtual)
    }

    /// Sugestões que ainda fazem sentido mostrar: casam com o que já foi
    /// digitado (prefixo, sem diferenciar maiúsculas) e não são exatamente o
    /// que já está no campo.
    private var sugestoesFiltradas: [String] {
        guard focado else { return [] }
        let digitado = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        return sugestoes.filter { sugestao in
            guard sugestao.localizedCaseInsensitiveCompare(digitado) != .orderedSame else { return false }
            guard !digitado.isEmpty else { return true }
            return sugestao.range(of: digitado, options: .caseInsensitive) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PapagaioTema.Espaco.minimo) {
            Text(rotuloPadrao)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PapagaioTema.textoSecundario)
                .lineLimit(1)
                    .minimumScaleFactor(0.82)
                .fixedSize(horizontal: true, vertical: false)

            TextField(rotuloPadrao, text: $texto)
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .padding(.horizontal, PapagaioTema.Espaco.medio)
                .frame(height: PapagaioTema.Altura.compacta)
                .background(PapagaioTema.superficieSuave, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                        .stroke(focado ? PapagaioTema.destaque : PapagaioTema.borda, lineWidth: focado ? 1.5 : 1)
                }
                .focused($focado)
                .onSubmit(salvar)
                // Perder o foco (clicar fora, trocar de campo) também conta
                // como "terminei de digitar" — sem isto, um nome só salvava
                // apertando Enter, e a maioria das pessoas simplesmente
                // clica em outro lugar depois de digitar.
                .onChange(of: focado) { estava, agora in
                    if estava, !agora { salvar() }
                }
        }
        .frame(width: 200, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if !sugestoesFiltradas.isEmpty {
                listaDeSugestoes
                    // Abaixo do campo, e não do rótulo — some visualmente
                    // por cima do que vier depois na grade, então sai do
                    // fluxo do `LayoutDeFluxo` via `.overlay` em vez de
                    // empurrar as outras vozes para baixo.
                    .offset(y: PapagaioTema.Altura.compacta + 18)
                    .zIndex(1)
            }
        }
    }

    private var listaDeSugestoes: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sugestoesFiltradas, id: \.self) { sugestao in
                Button {
                    texto = sugestao
                    salvar()
                    focado = false
                } label: {
                    Text(sugestao)
                        .font(.callout)
                        .foregroundStyle(PapagaioTema.texto)
                        .padding(.horizontal, PapagaioTema.Espaco.medio)
                        .padding(.vertical, PapagaioTema.Espaco.curto)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .frame(width: 200)
        .background(PapagaioTema.superficie, in: RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PapagaioTema.raioDeControle, style: .continuous)
                .stroke(PapagaioTema.borda, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func salvar() {
        let limpo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limpo != nomeAtual.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        aoSalvar(limpo)
    }
}

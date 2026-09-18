import AppKit
import QuartzCore
import SwiftUI

/// A janela que hospeda o painel de gravação por cima dos outros apps.
///
/// É um `NSPanel`, e não uma `Window` do SwiftUI, por três exigências que só o
/// AppKit atende:
///
/// - **Sobrevive à troca de app.** `.floating` a mantém acima das janelas dos
///   outros programas, que é o ponto de gravar enquanto se trabalha em outro
///   lugar. `hidesOnDeactivate = false` impede que ela suma quando o Papagaio
///   deixa de ser o app da frente.
/// - **Não rouba o foco ao aparecer.** `.nonactivatingPanel` com
///   `becomesKeyOnlyIfNeeded` deixa a pessoa continuar digitando no Zoom, no
///   Notion ou onde estiver; o painel só toma o teclado quando ela clica no
///   campo de nota.
/// - **Acompanha em todos os espaços.** `.canJoinAllSpaces` faz a janela seguir
///   quem troca de Mission Control no meio da conversa.
@MainActor
final class JanelaFlutuanteDeGravacao {
    private var painel: NSPanel?
    private var observadorAparencia: NSObjectProtocol?

    /// A moldura de antes de minimizar, para voltar exatamente ao mesmo
    /// lugar e tamanho ao restaurar.
    private var quadroAntesDeMinimizar: NSRect?

    /// Tamanho inicial: o "padrão" da `PainelFlutuanteDeGravacao`, com o campo
    /// de nota visível. Cabe folgado em qualquer Mac, inclusive num Air de 13".
    private static let tamanhoInicial = NSSize(width: 360, height: 190)

    /// Piso e teto do arrasto — valem o tempo todo, inclusive minimizado: é o
    /// mesmo painel resizável, só que no menor tamanho dele, e continua
    /// respondendo a arrastar a borda pra aumentar ou diminuir normalmente.
    private static let tamanhoMinimo = NSSize(width: 240, height: 84)
    private static let tamanhoMaximo = NSSize(width: 620, height: 460)

    func exibir(gravador: GravadorViewModel, aoAbrirNoApp: @escaping () -> Void) {
        if let painel {
            // A aparência pode ter mudado em Configurações desde a última
            // vez que o painel apareceu — sem atualizar aqui, ele ficava
            // preso na aparência de quando nasceu até o app reiniciar.
            observarAparenciaSeNecessario()
            atualizarAparencia()
            painel.orderFrontRegardless()
            return
        }

        observarAparenciaSeNecessario()

        quadroAntesDeMinimizar = nil

        let conteudo = PainelFlutuanteDeGravacao(
            gravador: gravador,
            aoAbrirNoApp: aoAbrirNoApp,
            aoAlternarTamanho: { [weak self] in self?.alternarTamanho() }
        )
        // `.preferredColorScheme` só vale dentro do próprio `NSHostingView`:
        // este painel vive fora da hierarquia do `ContentView`, então nunca
        // herdava a escolha manual de tema — só a aparência real do Mac.
        .preferredColorScheme(aparenciaAtual.esquemaPreferido)

        let novo = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.tamanhoInicial),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        novo.title = "Gravando".localized
        novo.titlebarAppearsTransparent = true
        novo.titleVisibility = .hidden
        novo.isMovableByWindowBackground = true
        novo.level = .floating
        novo.hidesOnDeactivate = false
        novo.becomesKeyOnlyIfNeeded = true
        novo.isReleasedWhenClosed = false
        novo.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Os três botões de tráfego (fechar/minimizar/zoom) não têm função
        // aqui — pausar/finalizar/cancelar já são os botões do próprio
        // painel — e no tamanho mínimo (84pt de altura) eles disputavam
        // espaço com o cronômetro e ficavam sobrepostos, com um aspecto
        // "quebrado".
        novo.standardWindowButton(.closeButton)?.isHidden = true
        novo.standardWindowButton(.miniaturizeButton)?.isHidden = true
        novo.standardWindowButton(.zoomButton)?.isHidden = true
        // `minSize`/`maxSize` entram antes de qualquer `setFrame`, e ficam —
        // sem exceção, nunca mais removidos depois (nem ao minimizar): uma
        // janela real maior que o próprio teto declarado, ainda que por uma
        // fração de segundo, deixava o redimensionamento por arrasto
        // travado dali em diante.
        novo.minSize = Self.tamanhoMinimo
        novo.maxSize = Self.tamanhoMaximo
        // As cores do `PapagaioTema` resolvem contra a `NSAppearance` da
        // janela, não contra o `colorScheme` do SwiftUI — sem isto, mesmo
        // com o `.preferredColorScheme` acima, o fundo e os controles do
        // painel continuavam claros num Mac claro, aparência forçada ou não.
        novo.appearance = aparenciaAtual.nsAppearance
        novo.contentView = NSHostingView(rootView: conteudo)

        let destino = retanguloDeDestino(para: novo)

        // Se sabemos de onde o cartão de gravação está saindo na janela
        // principal, o painel nasce ali — mas dentro do teto acima, nunca
        // maior — e encolhe animado até o canto, como o PiP do FaceTime. Sem
        // essa origem (por exemplo, gravação iniciada com o foco fora da
        // tela de captura) ele só aparece direto no destino.
        if let origem = gravador.origemDoPainelNaTela, origem.width > 40, origem.height > 40 {
            novo.setFrame(dentroDosLimites(origem), display: false)
            novo.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { contexto in
                contexto.duration = 0.32
                contexto.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                novo.animator().setFrame(destino, display: true)
            }
        } else {
            novo.setFrame(destino, display: false)
            novo.orderFrontRegardless()
        }

        painel = novo
    }

    /// Encaixa um retângulo dentro do piso/teto do painel, preservando o
    /// centro — usado para o cartão de origem, que costuma ser bem maior que
    /// os 620×460 do teto.
    private func dentroDosLimites(_ retangulo: NSRect) -> NSRect {
        let largura = min(max(retangulo.width, Self.tamanhoMinimo.width), Self.tamanhoMaximo.width)
        let altura = min(max(retangulo.height, Self.tamanhoMinimo.height), Self.tamanhoMaximo.height)
        return NSRect(
            x: retangulo.midX - largura / 2,
            y: retangulo.midY - altura / 2,
            width: largura,
            height: altura
        )
    }

    /// Lida direto do `UserDefaults`, e não via `@AppStorage`: esta classe
    /// não é uma `View`, e o painel pode ser mostrado sem que nenhuma tela
    /// SwiftUI esteja de olho nesse valor no momento.
    private var aparenciaAtual: AparenciaDoApp {
        let bruta = UserDefaults.standard.string(forKey: "aparenciaDoApp") ?? AparenciaDoApp.sistema.rawValue
        return AparenciaDoApp(rawValue: bruta) ?? .sistema
    }

    /// Atualiza o painel ao vivo quando o tema muda em Configurações.
    /// Só `window.appearance = nil` reconsulta `NSApp.effectiveAppearance`
    /// num NSPanel nonactivating; `displayIfNeeded` evita esperar virar key.
    /// Não recria o `NSHostingView` de propósito: recriar perderia o foco do
    /// campo de nota no meio da gravação.
    private func atualizarAparencia() {
        guard let painel else { return }
        painel.appearance = aparenciaAtual.nsAppearance
        painel.viewsNeedDisplay = true
        painel.contentView?.needsDisplay = true
        painel.invalidateShadow()
        painel.displayIfNeeded()
    }

    private func observarAparenciaSeNecessario() {
        guard observadorAparencia == nil else { return }
        observadorAparencia = NotificationCenter.default.addObserver(
            forName: .aparenciaDoAppMudou, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.atualizarAparencia() }
        }
    }

    /// Some com o painel. Quando `origem` aponta para um lugar válido da tela
    /// (o cartão de gravação voltou a aparecer na janela principal), ele
    /// encolhe animado de volta para lá antes de fechar — o mesmo gesto de
    /// "nascer" em `exibir(gravador:aoAbrirNoApp:)`, só que ao contrário.
    func esconder(origem: CGRect? = nil) {
        guard let painel else { return }
        self.painel = nil

        guard let origem, origem.width > 40, origem.height > 40 else {
            painel.close()
            return
        }

        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.26
            contexto.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            painel.animator().setFrame(origem, display: true)
        } completionHandler: {
            // O AppKit conclui animações de janela na main thread, mas a
            // assinatura antiga deste callback não carrega essa anotação.
            MainActor.assumeIsolated {
                painel.close()
            }
        }
    }

    // MARK: - Minimizar / restaurar

    /// Alterna entre o tamanho mínimo (barra de transporte) e o tamanho de
    /// antes — sempre o mesmo painel, sempre redimensionável por arrasto nos
    /// 240×84 a 620×460 de sempre. Chamado só pelo botão do próprio painel:
    /// tentar detectar isso sozinho por arrasto (borda da tela) já atrapalhou
    /// o arrasto normal e outras animações antes.
    private func alternarTamanho() {
        guard let painel else { return }
        let atual = painel.frame

        let destino: NSRect
        if atual.width <= Self.tamanhoMinimo.width + 12 {
            destino = quadroAntesDeMinimizar ?? retanguloDeDestino(para: painel)
        } else {
            quadroAntesDeMinimizar = atual
            guard let area = (painel.screen ?? NSScreen.main)?.visibleFrame else { return }
            let ladoEsquerdo = atual.midX < area.midX
            let altura = Self.tamanhoMinimo.height
            let y = min(max(atual.midY - altura / 2, area.minY), area.maxY - altura)
            destino = NSRect(
                x: ladoEsquerdo ? atual.minX : atual.maxX - Self.tamanhoMinimo.width,
                y: y,
                width: Self.tamanhoMinimo.width,
                height: altura
            )
        }

        NSAnimationContext.runAnimationGroup { contexto in
            contexto.duration = 0.22
            contexto.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            painel.animator().setFrame(destino, display: true)
        }
    }

    /// Canto inferior direito da tela onde está o cursor, com folga.
    ///
    /// Escolhido por eliminação: o topo tem a barra de menus e o notch, a
    /// esquerda costuma ter o Dock em telas pequenas, e o centro é onde a
    /// pessoa está trabalhando. Também é onde o macOS já coloca avisos, então a
    /// pessoa olha para lá naturalmente.
    ///
    /// A tela é a do cursor, e não a principal: em setup de dois monitores, a
    /// janela precisa nascer onde a pessoa está olhando.
    private func retanguloDeDestino(para painel: NSPanel) -> NSRect {
        let tela = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main

        guard let area = tela?.visibleFrame else {
            let atual = painel.frame
            return NSRect(
                x: atual.midX - Self.tamanhoInicial.width / 2,
                y: atual.midY - Self.tamanhoInicial.height / 2,
                width: Self.tamanhoInicial.width,
                height: Self.tamanhoInicial.height
            )
        }

        let folga: CGFloat = 24
        let origem = NSPoint(
            x: area.maxX - Self.tamanhoInicial.width - folga,
            y: area.minY + folga
        )
        return NSRect(origin: origem, size: Self.tamanhoInicial)
    }
}

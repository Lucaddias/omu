import Foundation
import Testing
@testable import Papagaio

#if OMU_PERF
@Test("A sonda usa a raiz real do loop quando HOME do processo é o container")
func raizDaSondaEmAppSandboxed() {
    let homeDoContainer = URL(
        fileURLWithPath: "/Users/tester/Library/Containers/com.papagaio.Papagaio.perf/Data",
        isDirectory: true
    )
    let homeReal = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let ambiente = [
        "HOME": homeReal.path,
        "OMU_PERF_DIR": "/Users/tester/OmuPerf",
    ]

    let home = ConfiguracaoPerf.homeDoUsuario(ambiente: ambiente, fallback: homeDoContainer)
    let raiz = ConfiguracaoPerf.diretorioDoLoop(home: home, ambiente: ambiente)

    #expect(home.path == "/Users/tester")
    #expect(raiz.path == "/Users/tester/OmuPerf")
}

@Test("A sonda não aceita raiz de loop fora de OmuPerf")
func raizDaSondaRejeitaDiretorioExterno() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let ambiente = ["OMU_PERF_DIR": "/Users/tester/Documents"]

    #expect(
        ConfiguracaoPerf.diretorioDoLoop(home: home, ambiente: ambiente).path
            == "/Users/tester/OmuPerf"
    )
}
#endif

@MainActor
@Test("Inicialização em testes não executa serviços externos")
func inicializacaoDeTesteNaoConectaAutomaticamente() async {
    let politica = PoliticaDeInicializacaoExterna(
        ambiente: ["PAPAGAIO_TEST_MODE": "1"]
    )
    var tentativasDeConexao = 0

    await politica.executar {
        tentativasDeConexao += 1
    }

    #expect(!politica.permiteServicosExternos)
    #expect(tentativasDeConexao == 0)
}

@MainActor
@Test("Inicialização normal preserva os serviços externos")
func inicializacaoNormalPermiteConexao() async {
    let politica = PoliticaDeInicializacaoExterna(ambiente: [:])
    var tentativasDeConexao = 0

    await politica.executar {
        tentativasDeConexao += 1
    }

    #expect(politica.permiteServicosExternos)
    #expect(tentativasDeConexao == 1)
}

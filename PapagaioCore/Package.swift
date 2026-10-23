// swift-tools-version: 6.0
import Foundation
import PackageDescription

let buildForPerformance = ProcessInfo.processInfo.environment["OMU_PERF_BUILD"] == "1"
let swiftSettingsBase: [SwiftSetting] = [.swiftLanguageMode(.v6)]
let swiftSettings = buildForPerformance
    ? swiftSettingsBase + [.define("OMU_PERF")]
    : swiftSettingsBase

let package = Package(
    name: "PapagaioCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PapagaioCore", type: .dynamic, targets: ["PapagaioCore"]),
        .executable(name: "papagaio-eval", targets: ["papagaio-eval"]),
    ],
    dependencies: [
        // Diarização acústica offline (pyannote community-1 em CoreML).
        // Versão fixada: a API do OfflineDiarizerManager muda entre releases.
        // Primeira dependência remota do projeto.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
    ],
    targets: [
        // Runtimes locais, pré-compilados com backend Metal.
        // Baixados por Scripts/bootstrap-runtimes.sh (versão + SHA-256 fixados),
        // fora do git por causa do tamanho (~1 GB + 52 MB do ONNX Runtime).
        // Ver D-3.1.
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),
        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
        // ONNX Runtime (M.1): roda o Silero VAD em CPU. O pod archive oficial
        // não publica module map; o bootstrap acrescenta um ao framework
        // (ver Scripts/bootstrap-runtimes.sh).
        .binaryTarget(name: "onnxruntime", path: "Frameworks/onnxruntime.xcframework"),

        // Cada runtime fica isolado no seu próprio target Swift.
        //
        // Não é organização: é obrigatório. Os dois frameworks embutem versões
        // **diferentes** do ggml, e importar `whisper` e `llama` no mesmo
        // contexto de módulo quebra o build com "'ggml_type' has different
        // definitions in different modules". Separando os targets, cada módulo
        // clang enxerga só o seu ggml. O ONNX Runtime não conflita com ggml
        // (símbolos próprios), mas segue a mesma regra por consistência — o
        // module C do onnxruntime não atravessa a fronteira deste target.
        // Ver D-3.2.
        .target(
            name: "WhisperRuntime",
            dependencies: ["whisper"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "LlamaRuntime",
            dependencies: ["llama"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "OnnxApi",
            dependencies: ["onnxruntime"],
            swiftSettings: swiftSettings,
            // O onnxruntime.framework é C++ (libc++).
            linkerSettings: [.linkedLibrary("c++")]
        ),

        // Wrapper Sendable sobre o FluidAudio (diarização offline). O target é
        // isolado por causa do CoreML: MLModel não é Sendable, e a fronteira do
        // módulo impede que os tipos do FluidAudio vazem para o domínio.
        .target(
            name: "DiarizationRuntime",
            dependencies: ["FluidAudio"],
            swiftSettings: swiftSettings
        ),

        // Biblioteca de domínio. NÃO importa SwiftUI — a CLI depende dela.
        // Também não importa `whisper`/`llama`/`onnxruntime` direto: só os
        // wrappers acima.
        .target(
            name: "PapagaioCore",
            dependencies: ["WhisperRuntime", "LlamaRuntime", "OnnxApi", "DiarizationRuntime"],
            // O modelo do Silero VAD entra no bundle do alvo (2,3 MB). Veja
            // Scripts/bootstrap-runtimes.sh, que o baixa com versão e SHA-256
            // fixados dentro de Sources/PapagaioCore/Resources/.
            // Os modelos de diarização entram como cópia opaca: o `.process`
            // recursivo não aceita arquivos repetidos dentro dos .mlmodelc.
            resources: [
                .process("Resources"),
                .copy("ModelosDeDiarizacao"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "papagaio-eval",
            dependencies: ["PapagaioCore", "WhisperRuntime", "LlamaRuntime"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PapagaioCoreTests",
            dependencies: ["PapagaioCore"],
            swiftSettings: swiftSettings,
            // O bundle .xctest carrega de
            // Products/Debug/PapagaioCoreTests.xctest/Contents/MacOS/, e os
            // frameworks ficam três níveis acima, em Products/Debug/.
            // Sem este rpath o `dlopen` do bundle falha em
            // "@rpath/whisper.framework/…", e `DYLD_FRAMEWORK_PATH` não
            // resolve: o SIP remove variáveis DYLD_* do helper de teste do
            // Xcode, que é um binário assinado pelo sistema.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])
            ]
        ),
    ]
)

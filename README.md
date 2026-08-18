# Papagaio

App macOS que grava reuniões online, transcreve e resume **100% no dispositivo**,
com biblioteca local. Whisper large-v3 (`whisper.cpp`) para transcrição, Qwen
(`llama.cpp`) para resumo, SwiftData local para a biblioteca.

## Configurando o projeto pela primeira vez

Depois de clonar, rode isto — sem ele o Xcode falha na resolução de pacotes:

```bash
./Scripts/bootstrap-runtimes.sh
```

O script baixa, com versão e SHA-256 fixados, o que fica fora do git:

1. os XCFrameworks de `whisper.cpp`, `llama.cpp` e ONNX Runtime (~200 MB) para
   `PapagaioCore/Frameworks/`, declarados no `Package.swift` como
   `binaryTarget(path:)`. Sem eles, a resolução falha com
   `local binary target 'whisper' … does not contain a binary artifact`;
2. o modelo do Silero VAD (2,3 MB) para
   `PapagaioCore/Sources/PapagaioCore/Resources/`. Sem ele a resolução falha com
   `The file 'Resources' couldn't be opened`;
3. os modelos de diarização do FluidAudio (~21,5 MB) para
   `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/`.

Os binários **não** estão em Git LFS: são reproduzíveis a partir das releases
oficiais, e o LFS disputava com o bootstrap a posse dos mesmos arquivos, o que
quebrava `git pull` depois de rodar o script. Ver o `.gitignore`, que registra o
motivo.

Depois disso, abra `Papagaio.xcworkspace`.

Os pesos GGUF do Whisper e do Qwen são outra coisa: não vêm no bootstrap nem no
bundle. O app os baixa na primeira execução, com checksum, para o Application
Support — e bloqueia antes de tentar se a máquina tiver menos de 18 GB de RAM.

## Rodando os testes

```bash
cd PapagaioCore && swift test
```

```bash
xcodebuild test -project Papagaio.xcodeproj -scheme Papagaio -destination 'platform=macOS,arch=arm64'
```

Se `swift test` falhar em
`CodeSign … resource fork, Finder information, or similar detritus not allowed`,
o repositório está dentro de uma pasta sincronizada pelo iCloud Drive: o file
provider põe `com.apple.FinderInfo` no bundle `.xctest`, e apagar o atributo não
resolve porque ele volta no build seguinte. Rode com a área de build fora dali:

```bash
cd PapagaioCore && swift test --scratch-path /tmp/papagaio-build
```

Ver D-10.3 em `Master Plans/DECISIONS.md`.

## Formatação

```bash
swift format lint --strict --recursive Papagaio PapagaioTests PapagaioCore/Sources PapagaioCore/Tests
```

A configuração está em `.swift-format` e o CI trata achado como falha.

## Contribuindo

- Mudanças em `main` passam por Pull Request (branch protection ativa). O CI
  (`.github/workflows/ci.yml`) roda os testes do `PapagaioCore`, os testes do app
  e o lint de formatação em cada PR.
- Reorganizações estruturais grandes (mover/renomear muitos arquivos) devem ir em
  branch própria e ser avisadas ao time antes do merge, para evitar edições
  concorrentes na mesma área.
- Decisões técnicas vão para `Master Plans/DECISIONS.md`: o que foi decidido, as
  alternativas descartadas e por quê.
- A assinatura **não** fixa Developer Team (D-13.3): quem publicar seleciona o
  seu no Xcode e deixa a assinatura automática resolver a identidade.

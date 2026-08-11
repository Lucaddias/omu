# Papagaio

## Configurando o projeto pela primeira vez

Depois de clonar, rode nesta ordem — sem isso o Xcode falha na resolução de pacotes:

```bash
git lfs install
git lfs pull
./Scripts/bootstrap-runtimes.sh
```

Por quê:

1. **`git lfs pull`** — os frameworks em `PapagaioCore/Frameworks/` (whisper, llama, onnxruntime, ~1 GB) são versionados via Git LFS. Sem este passo, cada `.xcframework` chega como um ponteiro de texto de 129 bytes, e o Xcode falha com `"Failed to decode XCFramework Info.plist"`.
2. **`bootstrap-runtimes.sh`** — baixa o modelo do Silero VAD (2,3 MB), que fica fora do git (ver `.gitignore`). Sem ele, a resolução de pacotes falha com `"The file 'Resources' couldn't be opened"`.

Depois disso, abra `Papagaio.xcworkspace` normalmente.

## Rodando os testes

```bash
cd PapagaioCore && swift test
```

## Contribuindo

- Mudanças em `main` passam por Pull Request (branch protection ativa) — o CI (`.github/workflows/ci.yml`) builda o app e roda os testes do `PapagaioCore` em cada PR.
- Reorganizações estruturais grandes (mover/renomear muitos arquivos) devem ir em branch própria e ser avisadas ao time antes do merge, para evitar edições concorrentes na mesma área.

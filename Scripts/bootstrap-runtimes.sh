#!/bin/bash
#
# Baixa os XCFrameworks pré-compilados de whisper.cpp, llama.cpp e do
# ONNX Runtime, o modelo do Silero VAD e os modelos de diarização do
# FluidAudio.
#
# Por que um script e não `binaryTarget(url:checksum:)` do SPM: os zips do
# whisper/llama publicam o `.xcframework` dentro de `build-apple/`, e o SPM
# exige o artefato na **raiz** do arquivo. Então baixamos, verificamos o
# SHA-256 e reempacotamos na estrutura que o SPM aceita. O ONNX Runtime vem
# na raiz, mas **não publica module map** — o Swift precisa de um para
# `import onnxruntime` (ver `patchear_module_map_do_onnx` abaixo).
#
# Por que XCFramework e não compilar do fonte: nenhum dos projetos publica
# mais `Package.swift` (404 em master, verificado em 2026-07-31), e o binário
# oficial já vem com o backend Metal. Ver D-3.1.
#
# Por que só a fatia de macOS: o release oficial empacota 7 plataformas
# (macOS, iOS, iOS-simulator, tvOS, tvOS-simulator, xrOS, xrOS-simulator) com
# dSYM para cada uma — 1,2 GB ao todo. O `Package.swift` deste projeto builda
# só `platforms: [.macOS("26.0")]`; as outras 6 nunca são usadas. E dSYM é
# símbolo de debug para SIMBOLICAR CRASH de build distribuído — não faz falta
# no dia a dia de desenvolvimento local. Cortando as duas coisas, sobra
# ~o essencial. Se um dia precisar investigar um crash de produção com o
# endereço de memória cru, rode com DSYMS=1 (ver abaixo) para manter o dSYM
# de macOS.
#
# Uso:  Scripts/bootstrap-runtimes.sh
#       DSYMS=1 Scripts/bootstrap-runtimes.sh   # mantém o dSYM de macOS
# Os frameworks ficam em PapagaioCore/Frameworks/ e são ignorados pelo git —
# ver .gitignore. São 100% reproduzíveis a partir das URLs/checksums abaixo,
# por isso não há motivo para versionar o binário (nem via LFS — foi tentado,
# ver histórico do .gitignore: o script e o LFS disputando dono dos mesmos
# arquivos é o que quebrava o `git pull` depois de rodar este script).

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINO="$RAIZ/PapagaioCore/Frameworks"
RECURSOS="$RAIZ/PapagaioCore/Sources/PapagaioCore/Resources"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

MANTER_DSYMS="${DSYMS:-0}"
FATIA_MACOS="macos-arm64_x86_64"

# Versões fixadas. Trocar aqui exige trocar o checksum junto.
# Qwen3.5 usa a arquitetura `qwen35`, suportada a partir deste runtime.
LLAMA_TAG="b9222"
LLAMA_SHA="39b5d476d5716249fa9fcb7796b89f1a7dc6bd8828531b825efd936cdd51d4f7"
WHISPER_TAG="v1.9.1"
WHISPER_SHA="8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
# ONNX Runtime (M.1) e modelo do Silero VAD: pod archive oficial do
# onnxruntime.ai e o `silero_vad.onnx` fixado num commit do snakers4/silero-vad
# (a tag de release não cobre o artefato do modelo).
ONNX_TAG="1.24.2"
ONNX_SHA="f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
SILERO_SHA="1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"

# Remove tudo do xcframework que não é a fatia de macOS (e, por padrão, os
# dSYMs também) — inclusive as referências correspondentes no Info.plist,
# senão o Xcode reclama de "Missing path ... as defined by DebugSymbolsPath"
# (a fatia de macOS que sobra ainda tem essa chave apontando pra uma pasta
# que acabamos de apagar) ou de uma fatia "listada mas ausente".
podar_para_macos() {
    local xcf="$1"
    local caminho="$DESTINO/$xcf"
    [ -d "$caminho" ] || return

    for fatia in "$caminho"/*/; do
        local nome
        nome="$(basename "$fatia")"
        [ "$nome" = "$FATIA_MACOS" ] && continue
        rm -rf "$fatia"
    done

    local plist="$caminho/Info.plist"
    [ -f "$plist" ] || return

    # Uma passada só, de trás para frente, sobre os índices ORIGINAIS do
    # Info.plist (antes de qualquer remoção) — evita o problema de índice
    # reindexando no meio do laço.
    local total
    total="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$plist" 2>/dev/null | grep -c "LibraryIdentifier" || true)"
    local i=$((total - 1))
    while [ "$i" -ge 0 ]; do
        local identificador
        identificador="$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$i:LibraryIdentifier" "$plist" 2>/dev/null || true)"
        if [ "$identificador" = "$FATIA_MACOS" ]; then
            if [ "$MANTER_DSYMS" != "1" ]; then
                /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:$i:DebugSymbolsPath" "$plist" 2>/dev/null || true
            fi
        else
            /usr/libexec/PlistBuddy -c "Delete :AvailableLibraries:$i" "$plist" 2>/dev/null || true
        fi
        i=$((i - 1))
    done

    if [ "$MANTER_DSYMS" != "1" ]; then
        rm -rf "$caminho/$FATIA_MACOS/dSYMs"
    fi
}

baixar() {
    local nome="$1" url="$2" sha="$3" xcf="$4"

    if [ -d "$DESTINO/$xcf" ]; then
        # Sem Git LFS, o checkout deixa ponteiros de texto dentro do
        # xcframework. A pasta existe, mas não é um framework utilizável e o
        # Xcode deixa de resolver o produto PapagaioCore. Só pulamos quando
        # houver o Info.plist real do XCFramework.
        local info="$DESTINO/$xcf/Info.plist"
        if [ -f "$info" ] && ! head -n 1 "$info" | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
            echo "==> $nome já presente em PapagaioCore/Frameworks/$xcf — pulando"
            return
        fi

        echo "==> removendo ponteiro incompleto de $xcf"
        rm -rf "$DESTINO/$xcf"
    fi

    echo "==> baixando $nome ($url)"
    curl -sSL --fail -o "$TEMP/$nome.zip" "$url"

    echo "==> verificando SHA-256"
    local obtido
    obtido="$(shasum -a 256 "$TEMP/$nome.zip" | awk '{print $1}')"
    if [ "$obtido" != "$sha" ]; then
        echo "ERRO: checksum de $nome não confere" >&2
        echo "  esperado: $sha" >&2
        echo "  obtido:   $obtido" >&2
        exit 1
    fi

    echo "==> extraindo"
    mkdir -p "$TEMP/$nome"
    unzip -q "$TEMP/$nome.zip" -d "$TEMP/$nome"

    local origem
    origem="$(find "$TEMP/$nome" -maxdepth 3 -type d -name "$xcf" | head -1)"
    if [ -z "$origem" ]; then
        echo "ERRO: $xcf não encontrado dentro do zip de $nome" >&2
        exit 1
    fi

    mkdir -p "$DESTINO"
    cp -R "$origem" "$DESTINO/$xcf"
    podar_para_macos "$xcf"
    echo "==> PapagaioCore/Frameworks/$xcf pronto (só macOS$([ "$MANTER_DSYMS" = "1" ] && echo ", com dSYM" || echo ", sem dSYM"))"
}

baixar_arquivo() {
    local nome="$1" url="$2" sha="$3" destino="$4"

    if arquivo_confere "$destino" "$sha"; then
        echo "==> $nome verificado em $destino — pulando"
        return
    fi

    echo "==> baixando $nome ($url)"
    curl -sSL --fail -o "$TEMP/$nome" "$url"

    echo "==> verificando SHA-256"
    local obtido
    obtido="$(shasum -a 256 "$TEMP/$nome" | awk '{print $1}')"
    if [ "$obtido" != "$sha" ]; then
        echo "ERRO: checksum de $nome não confere" >&2
        echo "  esperado: $sha" >&2
        echo "  obtido:   $obtido" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$destino")"
    # O arquivo válido só substitui o anterior depois de download e checksum.
    # Um encerramento durante a cópia não deixa um arquivo final truncado.
    local preparado
    preparado="$(mktemp "$(dirname "$destino")/.bootstrap.XXXXXX")"
    if ! cp "$TEMP/$nome" "$preparado" || ! mv -f "$preparado" "$destino"; then
        rm -f "$preparado"
        return 1
    fi
    echo "==> $destino pronto"
}

arquivo_confere() {
    local caminho="$1" sha="$2"
    [ -f "$caminho" ] || return 1
    local obtido
    obtido="$(shasum -a 256 "$caminho" | awk '{print $1}')"
    [ "$obtido" = "$sha" ]
}

# O pod archive do ONNX Runtime não traz module map; sem ele, `import
# onnxruntime` do Swift falha ("no such module"). O patch acrescenta um em
# cada slice do xcframework, exatamente como validado em scratch:
# - slices planos (iOS): <framework>/Modules/module.modulemap
# - slices versionados (macOS): <framework>/Versions/A/Modules/... + symlink
#   <framework>/Modules -> Versions/Current/Modules
patchear_module_map_do_onnx() {
    local xcf="$DESTINO/onnxruntime.xcframework"
    [ -d "$xcf" ] || return

    local conteudo='framework module onnxruntime {
  umbrella header "onnxruntime_c_api.h"

  export *
  module * { export * }
}'

    for slice in "$xcf"/*/; do
        local fw="$slice/onnxruntime.framework"
        [ -d "$fw" ] || continue
        if [ -d "$fw/Versions/A" ]; then
            mkdir -p "$fw/Versions/A/Modules"
            printf '%s\n' "$conteudo" > "$fw/Versions/A/Modules/module.modulemap"
            [ -L "$fw/Modules" ] || ln -sfn Versions/Current/Modules "$fw/Modules"
        else
            mkdir -p "$fw/Modules"
            printf '%s\n' "$conteudo" > "$fw/Modules/module.modulemap"
        fi
    done
    echo "==> module map do onnxruntime.xcframework patcheado"
}

# Diarização acústica offline: os quatro .mlmodelc + plda-parameters.json do
# repo FluidInference/speaker-diarization-coreml, na árvore exata que o
# ModelHub do FluidAudio espera (cada modelo é um diretório com
# coremldata.bin na raiz — os bundles já vêm compilados, o carregamento é
# MLModel(contentsOf:)). Ficam embutidos no bundle, como o silero_vad.onnx,
# por que o GerenciadorDeModelosDeDiarizacao os lê de lá. A pasta entra no
# Package.swift como `.copy` (cópia opaca — o `.process` recursivo recusa
# arquivos com o mesmo nome em pastas diferentes).
#
# Por que checksum por arquivo e não por pacote: o FluidAudio não valida o
# conteúdo — só existência/layout. O SHA-256 por arquivo trava o conteúdo
# baixado no commit de hoje do repo; se o repo mudar, o bootstrap falha alto
# em vez de o app carregar um modelo trocado em silêncio.
DIARIZACAO_BASE="https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/main"
DIARIZACAO_DESTINO="$RAIZ/PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/diarizacao/speaker-diarization"

# caminho|sha256 — gerados em 2026-08-11 a partir do HEAD do repo acima.
DIARIZACAO_ARTEFATOS="
Segmentation.mlmodelc/analytics/coremldata.bin|64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb
Segmentation.mlmodelc/coremldata.bin|ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc
Segmentation.mlmodelc/metadata.json|88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124
Segmentation.mlmodelc/model.mil|d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f
Segmentation.mlmodelc/weights/weight.bin|c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2
FBank.mlmodelc/analytics/coremldata.bin|0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a
FBank.mlmodelc/coremldata.bin|57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759
FBank.mlmodelc/metadata.json|2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a
FBank.mlmodelc/model.mil|27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed
FBank.mlmodelc/weights/weight.bin|9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36
Embedding.mlmodelc/analytics/coremldata.bin|8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682
Embedding.mlmodelc/coremldata.bin|4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004
Embedding.mlmodelc/metadata.json|1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5
Embedding.mlmodelc/model.mil|22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3
Embedding.mlmodelc/weights/weight.bin|99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b
PldaRho.mlmodelc/analytics/coremldata.bin|8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7
PldaRho.mlmodelc/coremldata.bin|4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418
PldaRho.mlmodelc/metadata.json|b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945
PldaRho.mlmodelc/model.mil|83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041
PldaRho.mlmodelc/weights/weight.bin|80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36
plda-parameters.json|38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f
"

baixar_diarizacao() {
    for linha in $DIARIZACAO_ARTEFATOS; do
        local caminho sha destino
        caminho="${linha%%|*}"
        sha="${linha##*|}"
        destino="$DIARIZACAO_DESTINO/$caminho"
        baixar_arquivo "$(basename "$caminho")" \
            "$DIARIZACAO_BASE/$caminho" "$sha" "$destino"
    done
}

# Permite exercitar as funções com fixtures locais sem executar downloads reais.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

baixar "llama" \
    "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-xcframework.zip" \
    "$LLAMA_SHA" "llama.xcframework"

baixar "whisper" \
    "https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_TAG/whisper-$WHISPER_TAG-xcframework.zip" \
    "$WHISPER_SHA" "whisper.xcframework"

baixar "onnxruntime" \
    "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-$ONNX_TAG.zip" \
    "$ONNX_SHA" "onnxruntime.xcframework"
patchear_module_map_do_onnx

baixar_arquivo "silero_vad.onnx" \
    "https://raw.githubusercontent.com/snakers4/silero-vad/76e3dc408eb2a5c655c34e230d2d5459b4439daa/src/silero_vad/data/silero_vad.onnx" \
    "$SILERO_SHA" "$RECURSOS/silero_vad.onnx"

baixar_diarizacao

echo
echo "Pronto. Slices de macOS:"
for xcf in llama whisper onnxruntime; do
    if [ -d "$DESTINO/$xcf.xcframework/macos-arm64_x86_64" ]; then
        echo "  $xcf.xcframework  ✓ macos-arm64_x86_64"
    else
        echo "  $xcf.xcframework  ✗ SEM slice de macOS"
    fi
done
if [ -d "$DIARIZACAO_DESTINO" ]; then
    echo "  diarização         ✓ $(find "$DIARIZACAO_DESTINO" -type f | wc -l | tr -d ' ') arquivos"
else
    echo "  diarização         ✗ SEM modelos de diarização"
fi

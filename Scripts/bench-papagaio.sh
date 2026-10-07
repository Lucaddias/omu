#!/bin/bash
# Backtest de performance do Papagaio (Ōmu).
#
# Roda micro-benchmarks determinísticos e macro-benchmarks com modelos reais,
# grava baseline JSON e opcionalmente compara com o baseline anterior.
#
# USO:
#   ./Scripts/bench-papagaio.sh                       # micro + macro, grava baseline
#   ./Scripts/bench-papagaio.sh --so-micro            # só micro (rápido, sem modelos)
#   ./Scripts/bench-papagaio.sh --audio <arquivo.wav> # transcreve este áudio (padrão: fixture)
#   ./Scripts/bench-papagaio.sh --comparar            # compara com baseline existente
#   ./Scripts/bench-papagaio.sh --saida <caminho.json>
#
# Requisitos: ./Scripts/bootstrap-runtimes.sh já executado.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/PapagaioCore"

SO_MICRO=false
COMPARAR=false
AUDIO=""
SAIDA=""
ITERACOES=5
MODELOS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --so-micro) SO_MICRO=true; shift ;;
        --comparar) COMPARAR=true; shift ;;
        --audio) AUDIO="$2"; shift 2 ;;
        --saida) SAIDA="$2"; shift 2 ;;
        --iteracoes) ITERACOES="$2"; shift 2 ;;
        --modelos) MODELOS="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: $1" >&2
            exit 2
            ;;
    esac
done

# Áudio fixture padrão: mede RTF do Whisper sem exigir --audio.
if [[ -z "$AUDIO" ]]; then
    FIXTURE="$ROOT_DIR/PapagaioCore/Tests/PapagaioCoreTests/Fixtures/fala_ola_mundo.wav"
    if [[ -f "$FIXTURE" ]]; then
        AUDIO="$FIXTURE"
    fi
fi

if [[ -z "$SAIDA" ]]; then
    SAIDA="$ROOT_DIR/PapagaioCore/Benchmarks/baseline.json"
fi

# Modelos fora do container do sandbox (legíveis pelo CLI sem TCC).
if [[ -z "$MODELOS" ]]; then
    for candidata in \
        "$HOME/Library/Application Support/Papagaio/Models" \
        "$HOME/Documents/InterviewLab/Models"
    do
        if [[ -f "$candidata/ggml-large-v3.bin" ]]; then
            MODELOS="$candidata"
            break
        fi
    done
fi

mkdir -p "$(dirname "$SAIDA")"

echo "=== bench-papagaio ==="
echo "Pacote:  $PACKAGE_DIR"
echo "Saída:   $SAIDA"
echo "Iterações: $ITERACOES"
echo

# Build release — medição em debug seria enganosa.
echo "Compilando em release…"
cd "$PACKAGE_DIR"
swift build -c release 2>&1 | tail -5

BINARIA="$PACKAGE_DIR/.build/release/papagaio-eval"
if [[ ! -x "$BINARIA" ]]; then
    # Alguns layouts do SwiftPM usam arm64-apple-macosx
    BINARIA="$(find "$PACKAGE_DIR/.build/release" -maxdepth 1 -name papagaio-eval -type f | head -1)"
fi
if [[ ! -x "$BINARIA" ]]; then
    echo "ERRO: binária papagaio-eval não encontrada em $PACKAGE_DIR/.build/release" >&2
    exit 1
fi

ARGUMENTOS=(bench --iteracoes "$ITERACOES" --saida "$SAIDA")

if [[ "$SO_MICRO" == true ]]; then
    ARGUMENTOS+=(--so-micro)
fi
if [[ -n "$AUDIO" ]]; then
    ARGUMENTOS+=(--audio "$AUDIO")
fi
if [[ -n "$MODELOS" ]]; then
    ARGUMENTOS+=(--modelos "$MODELOS")
fi
if [[ "$COMPARAR" == true && -f "$SAIDA" ]]; then
    ARGUMENTOS+=(--comparar "$SAIDA")
fi

echo
echo "Rodando: $BINARIA ${ARGUMENTOS[*]}"
echo

"$BINARIA" "${ARGUMENTOS[@]}"

#!/bin/bash
# Benchmark local do PapagaioCore; todas as saídas ficam em ~/OmuPerf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/PapagaioCore"
OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
RUNS_DIR="$OMU_PERF_DIR/runs"
BUILD_DIR="$OMU_PERF_DIR/build"
STATE_DIR="$OMU_PERF_DIR/estado"

SO_MICRO=false
AUDIO=""
SAIDA=""
ITERACOES=5
MODELOS=""
BASELINE=""
SCRATCH_PATH=""
SOMENTE_CASO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --so-micro) SO_MICRO=true; shift ;;
        --comparar) BASELINE="$2"; shift 2 ;;
        --somente-caso) SOMENTE_CASO="$2"; shift 2 ;;
        --audio) AUDIO="$2"; shift 2 ;;
        --saida) SAIDA="$2"; shift 2 ;;
        --iteracoes) ITERACOES="$2"; shift 2 ;;
        --modelos) MODELOS="$2"; shift 2 ;;
        --scratch-path) SCRATCH_PATH="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,8p' "$0"
            printf 'Uso: %s [--so-micro] [--somente-caso aec.processarBlocos] [--audio ~/OmuPerf/fixtures/...] [--modelos DIR] [--saida ~/OmuPerf/runs/...] [--comparar JSON] [--scratch-path DIR]\n' "$0"
            exit 0
            ;;
        *)
            echo "Argumento desconhecido: $1" >&2
            exit 2
            ;;
    esac
done

[[ "$ITERACOES" =~ ^[1-9][0-9]*$ ]] || { echo "Iterações precisa ser inteiro positivo." >&2; exit 2; }
mkdir -p "$RUNS_DIR" "$BUILD_DIR"
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
[[ -n "$SAIDA" ]] || SAIDA="$RUNS_DIR/bench-$RUN_ID.json"
[[ -n "$SCRATCH_PATH" ]] || SCRATCH_PATH="$BUILD_DIR/spm-cli-$RUN_ID"
BUILD_LOG="$RUNS_DIR/build-cli-$RUN_ID.log"
BENCH_LOG="$RUNS_DIR/bench-cli-$RUN_ID.log"

caminho_real() {
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

SAIDA="$(caminho_real "$SAIDA")"
case "$SAIDA" in
    "$RUNS_DIR"/*) ;;
    *) echo "A saída precisa ficar em ~/OmuPerf/runs/." >&2; exit 2 ;;
esac
mkdir -p "$(dirname "$SAIDA")"

SCRATCH_REAL="$(caminho_real "$SCRATCH_PATH")"
case "$SCRATCH_REAL" in
    "$BUILD_DIR"/*) ;;
    *) echo "O scratch precisa ficar em ~/OmuPerf/build/." >&2; exit 2 ;;
esac

if [[ -n "$AUDIO" ]]; then
    AUDIO_REAL="$(caminho_real "$AUDIO")"
    FIXTURES_REAL="$(caminho_real "$OMU_PERF_DIR/fixtures")/"
    case "$AUDIO_REAL" in
        "$FIXTURES_REAL"*) AUDIO="$AUDIO_REAL" ;;
        *) echo "O áudio precisa ser uma fixture de ~/OmuPerf/fixtures/." >&2; exit 2 ;;
    esac
fi

if [[ -n "$BASELINE" ]]; then
    BASELINE="$(caminho_real "$BASELINE")"
    [[ -f "$BASELINE" ]] || { echo "Baseline não encontrada: $BASELINE" >&2; exit 2; }
    case "$BASELINE" in "$OMU_PERF_DIR"/*) ;; *) echo "Baseline precisa estar em ~/OmuPerf/." >&2; exit 2 ;; esac
fi

if [[ -n "$MODELOS" ]]; then
    MODELOS="$(caminho_real "$MODELOS")"
fi

[[ ! -d "$STATE_DIR/infra.lock" ]] || { echo "Build/teste/geração ativo; aguarde antes do benchmark." >&2; exit 3; }
LOCK="$STATE_DIR/measurement.lock"
mkdir "$LOCK" 2>/dev/null || { echo "Outra medição está ativa." >&2; exit 3; }
CAFFEINATE_PID=""
limpar() {
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        [[ "$(ps -p "$CAFFEINATE_PID" -o comm= | xargs)" == *caffeinate ]] && kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap limpar EXIT INT TERM
"$SCRIPT_DIR/perf/ambiente.sh" >"$RUNS_DIR/bench-$RUN_ID-environment.log" 2>&1
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"

run_limitado() {
    local limite="$1"
    local log="$2"
    shift 2
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' "$limite" "$@" >"$log" 2>&1 &
    local pid=$!
    printf 'pid=%s log=%s\n' "$pid" "$log"
    if wait "$pid"; then
        tail -n 8 "$log"
    else
        local codigo=$?
        cat "$log" >&2
        return "$codigo"
    fi
}

echo "=== bench-papagaio ==="
echo "Worktree: $ROOT_DIR"
echo "Scratch:  $SCRATCH_REAL"
echo "Saída:    $SAIDA"
echo "Iterações: $ITERACOES"
echo

run_limitado 7200 "$BUILD_LOG" env OMU_PERF_BUILD=1 swift build --package-path "$PACKAGE_DIR" -c release --skip-update --scratch-path "$SCRATCH_REAL"

BINARIA="$(find "$SCRATCH_REAL" -path '*/release/papagaio-eval' -type f -perm -111 -print -quit)"
[[ -x "$BINARIA" ]] || { echo "papagaio-eval não encontrado no scratch Release." >&2; exit 1; }

ARGUMENTOS=(bench --iteracoes "$ITERACOES" --saida "$SAIDA")
[[ "$SO_MICRO" == true ]] && ARGUMENTOS+=(--so-micro)
[[ -n "$SOMENTE_CASO" ]] && ARGUMENTOS+=(--somente-caso "$SOMENTE_CASO")
[[ -n "$AUDIO" ]] && ARGUMENTOS+=(--audio "$AUDIO")
[[ -n "$MODELOS" ]] && ARGUMENTOS+=(--modelos "$MODELOS")
[[ -n "$BASELINE" ]] && ARGUMENTOS+=(--comparar "$BASELINE")

run_limitado 7200 "$BENCH_LOG" "$BINARIA" "${ARGUMENTOS[@]}"
printf 'Relatório: %s\nAmostras e execução: %s\n' "$SAIDA" "$BENCH_LOG"

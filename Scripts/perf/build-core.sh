#!/bin/bash
# Build versionado do papagaio-eval para A/B de micro-benchmarks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
STATE_DIR="$OMU_PERF_DIR/estado"
ROTULO="${1:-}"
[[ "$ROTULO" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Uso: $0 <rotulo-seguro>" >&2; exit 2; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || {
    echo "Recusei o build do core: o worktree tem alterações sem commit." >&2
    exit 2
}
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
GIT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"

SCRATCH="$OMU_PERF_DIR/build/spm-core-$ROTULO"
DESTINO="$OMU_PERF_DIR/apps/core-$ROTULO"
LOG="$OMU_PERF_DIR/runs/build-core-$ROTULO.log"
mkdir -p "$OMU_PERF_DIR/build" "$OMU_PERF_DIR/runs" "$STATE_DIR" "$OMU_PERF_DIR/apps"
[[ ! -e "$DESTINO" ]] || { echo "Destino já existe: $DESTINO" >&2; exit 2; }
[[ ! -d "$STATE_DIR/measurement.lock" ]] || { echo "Medição ativa; não iniciar build." >&2; exit 3; }
mkdir "$STATE_DIR/infra.lock" 2>/dev/null || { echo "Outra build/teste/geração está ativa." >&2; exit 3; }

CAFFEINATE_PID=""
limpar() {
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        [[ "$(ps -p "$CAFFEINATE_PID" -o comm= | xargs)" == *caffeinate ]] && kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    rmdir "$STATE_DIR/infra.lock" 2>/dev/null || true
}
trap limpar EXIT INT TERM

"$SCRIPT_DIR/ambiente.sh" --short >"$OMU_PERF_DIR/runs/build-core-$ROTULO-environment.log" 2>&1
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
OMU_PERF_BUILD=1 /usr/bin/nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' 7200 \
    swift build \
    --package-path "$ROOT_DIR/PapagaioCore" \
    -c release \
    --skip-update \
    --scratch-path "$SCRATCH" \
    >"$LOG" 2>&1 &
BUILD_PID=$!
printf 'pid=%s log=%s\n' "$BUILD_PID" "$LOG"
if wait "$BUILD_PID"; then
    :
else
    STATUS=$?
    cat "$LOG" >&2
    exit "$STATUS"
fi

BINARIA="$(find "$SCRATCH" -type f -name papagaio-eval -perm -111 -print -quit)"
[[ -x "$BINARIA" ]] || { echo "papagaio-eval Release não encontrado em $SCRATCH" >&2; cat "$LOG" >&2; exit 1; }
/usr/bin/ditto "$(dirname "$BINARIA")" "$DESTINO"
/usr/bin/xattr -cr "$DESTINO"
cat >"$DESTINO/PerfBuild.json" <<EOF_BUILD
{"rotulo":"$ROTULO","commit":"$GIT_COMMIT","branch":"$GIT_BRANCH","produto":"papagaio-eval"}
EOF_BUILD
printf 'Core isolado pronto: %s\n' "$DESTINO/papagaio-eval"

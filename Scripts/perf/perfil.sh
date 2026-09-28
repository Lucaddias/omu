#!/bin/bash
# Perfil é para formular hipóteses, nunca substitui o A/B.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMU_PERF_DIR="$HOME/OmuPerf"
STATE_DIR="$OMU_PERF_DIR/estado"
[[ $# -ge 4 ]] || { echo "Uso: perfil.sh <template> --launch APP.app|--attach PID <duracao> [argumentos app...]" >&2; exit 2; }
TEMPLATE="$1"; KIND="$2"; TARGET="$3"; DURATION="$4"
shift 4
[[ "$KIND" == "--launch" || "$KIND" == "--attach" ]] || { echo "Use --launch ou --attach." >&2; exit 2; }
if [[ "$KIND" == "--launch" ]]; then
    [[ -d "$TARGET" ]] || { echo "APP de perfil ausente: $TARGET" >&2; exit 2; }
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist")
    [[ "$BUNDLE_ID" == "com.papagaio.Papagaio.perf" ]] || { echo "Só a build isolada de perf pode ser perfilada." >&2; exit 2; }
    EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET/Contents/Info.plist")
    TARGET_EXECUTABLE="$TARGET/Contents/MacOS/$EXECUTABLE"
    [[ -x "$TARGET_EXECUTABLE" ]] || { echo "Executável ausente: $TARGET_EXECUTABLE" >&2; exit 2; }
else
    [[ "$TARGET" =~ ^[0-9]+$ ]] || { echo "PID inválido." >&2; exit 2; }
    [[ "$(ps -p "$TARGET" -o comm= | xargs)" == *Omu ]] || { echo "PID não parece ser Ōmu." >&2; exit 2; }
fi
mkdir -p "$OMU_PERF_DIR/traces" "$OMU_PERF_DIR/runs"
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
NOME_TEMPLATE="$(echo "$TEMPLATE" | tr ' /' '__')"
TRACE="$OMU_PERF_DIR/traces/$RUN_ID-$NOME_TEMPLATE.trace"
LOG="$OMU_PERF_DIR/runs/profile-$RUN_ID.log"
TOC="$OMU_PERF_DIR/runs/profile-$RUN_ID-toc.xml"
[[ ! -d "$STATE_DIR/infra.lock" ]] || { echo "Build/teste/geração ativo; não perfilar." >&2; exit 3; }
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
"$SCRIPT_DIR/ambiente.sh" 2>&1 | tee "$OMU_PERF_DIR/runs/profile-$RUN_ID-environment.log"
CAFFEINATE_PID="$(cat "$OMU_PERF_DIR/estado/caffeinate.pid")"
if [[ "$KIND" == "--launch" ]]; then
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' 7200 \
        xcrun xctrace record --template "$TEMPLATE" --output "$TRACE" --time-limit "$DURATION" \
        --no-prompt --env PAPAGAIO_TEST_MODE=1 --env "OMU_PERF_DIR=$OMU_PERF_DIR" \
        --launch -- "$TARGET" "$@" >"$LOG" 2>&1 &
else
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' 7200 \
        xcrun xctrace record --template "$TEMPLATE" --output "$TRACE" --time-limit "$DURATION" \
        --no-prompt --attach "$TARGET" >"$LOG" 2>&1 &
fi
TRACE_PID=$!
printf 'xctrace pid=%s log=%s\n' "$TRACE_PID" "$LOG"
if wait "$TRACE_PID"; then
    :
else
    CODE=$?
    cat "$LOG" >&2
    exit "$CODE"
fi
[[ -d "$TRACE" ]] || { cat "$LOG" >&2; echo "Trace não foi criado." >&2; exit 1; }
xcrun xctrace export --input "$TRACE" --toc --output "$TOC"
printf 'Trace: %s\nTOC para identificar tabelas exportáveis: %s\n' "$TRACE" "$TOC"

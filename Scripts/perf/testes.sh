#!/bin/bash
# Gates de correção sequenciais, com log e limite de tempo.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OMU_PERF_DIR="$HOME/OmuPerf"
STATE_DIR="$OMU_PERF_DIR/estado"
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
RUNS_DIR="$OMU_PERF_DIR/runs"
mkdir -p "$RUNS_DIR" "$OMU_PERF_DIR/build"
[[ ! -d "$STATE_DIR/measurement.lock" ]] || { echo "Medição ativa; não iniciar testes." >&2; exit 3; }
mkdir "$STATE_DIR/infra.lock" 2>/dev/null || { echo "Outra build/teste/geração está ativa." >&2; exit 3; }
CORE_LOG="$RUNS_DIR/testes-core-$RUN_ID.log"
APP_LOG="$RUNS_DIR/testes-app-$RUN_ID.log"
RESULTADO="$RUNS_DIR/testes-app-$RUN_ID.xcresult"
STATUS_JSON="$RUNS_DIR/testes-$RUN_ID.json"
DERIVED_APP_TEST="$OMU_PERF_DIR/build/app-test-$RUN_ID"
CAFFEINATE_PID=""
limpar() {
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        [[ "$(ps -p "$CAFFEINATE_PID" -o comm= | xargs)" == *caffeinate ]] && kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    rmdir "$STATE_DIR/infra.lock" 2>/dev/null || true
}
trap limpar EXIT INT TERM
"$SCRIPT_DIR/ambiente.sh" >"$RUNS_DIR/testes-$RUN_ID-environment.log" 2>&1
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"

run_limitado() {
    local timeout="$1" log="$2"
    shift 2
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' "$timeout" "$@" >"$log" 2>&1 &
    local pid=$!
    printf 'pid=%s log=%s\n' "$pid" "$log"
    if wait "$pid"; then tail -n 12 "$log"; else local status=$?; cat "$log" >&2; return "$status"; fi
}

echo "PapagaioCore: log $CORE_LOG"
STATUS_CORE=0
if run_limitado 1800 "$CORE_LOG" env OMU_PERF_RUNS="$RUNS_DIR" "$ROOT_DIR/Scripts/testa-papagaio-core.sh" \
    --skip-update --scratch-path "$OMU_PERF_DIR/build/spm-testes"; then
    :
else
    STATUS_CORE=$?
fi

echo "PapagaioTests em modo isolado: resultado $RESULTADO"
STATUS_APP=0
if run_limitado 900 "$APP_LOG" env PAPAGAIO_TEST_MODE=1 \
    xcodebuild test \
    -project "$ROOT_DIR/Loro.xcodeproj" \
    -scheme Loro \
    -destination 'platform=macOS' \
    -testLanguage pt \
    -testRegion BR \
    -skipPackagePluginValidation \
    -skipPackageUpdates \
    -parallel-testing-enabled NO \
    -resultBundlePath "$RESULTADO" \
    -derivedDataPath "$DERIVED_APP_TEST" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO; then
    :
else
    STATUS_APP=$?
fi
printf 'Status core=%s; app=%s\n' "$STATUS_CORE" "$STATUS_APP"
printf 'Core log: %s\nApp log: %s\nResult bundle: %s\n' "$CORE_LOG" "$APP_LOG" "$RESULTADO"
python3 - "$STATUS_JSON" "$STATUS_CORE" "$STATUS_APP" "$CORE_LOG" "$APP_LOG" "$RESULTADO" <<'PY'
import datetime,json,sys
saida,core,app,core_log,app_log,resultado=sys.argv[1:]
with open(saida,"w",encoding="utf-8") as arquivo:
    json.dump({"hora_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "core_status":int(core),"app_status":int(app),"core_log":core_log,
        "app_log":app_log,"xcresult":resultado},arquivo,ensure_ascii=False,indent=2)
    arquivo.write("\n")
print(f"Resumo JSON: {saida}")
PY
(( STATUS_CORE == 0 && STATUS_APP == 0 ))

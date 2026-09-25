#!/bin/bash
# A/B intercalado, em um processo novo por amostra.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
STATE_DIR="$OMU_PERF_DIR/estado"
SCENARIO="${1:-}"; APP_A="${2:-}"; APP_B="${3:-}"; N="${4:-}"
shift 4 || true
FIXTURES=(); MODELS="$HOME/Library/Application Support/Papagaio/Models"; TIMEOUT=7200
GABARITOS=(); QUALITY_BASELINES=(); BASELINE_ARQUIVOS=(); EXIGIR_IDENTICA=false
SEED_COUNT=0; SEED_TRECHOS=32; EVAL_BIN=""; REQUIRE_IDLE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fixture) FIXTURES+=("$2"); shift 2 ;;
        --modelos) MODELS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --seed-count) SEED_COUNT="$2"; shift 2 ;;
        --seed-trechos) SEED_TRECHOS="$2"; shift 2 ;;
        --eval-bin) EVAL_BIN="$2"; shift 2 ;;
        --gabarito) GABARITOS+=("$2"); shift 2 ;;
        --quality-baseline) QUALITY_BASELINES+=("$2"); shift 2 ;;
        --baseline-arquivo) BASELINE_ARQUIVOS+=("$2"); shift 2 ;;
        --require-idle) REQUIRE_IDLE=true; shift ;;
        --exigir-identica) EXIGIR_IDENTICA=true; shift ;;
        *) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$SCENARIO" && -d "$APP_A" && -d "$APP_B" ]] || { echo "Uso: medir.sh <cenario> <A.app> <B.app> <n> [--fixture PATH]" >&2; exit 2; }
SCENARIO_UPPER="$(printf '%s' "$SCENARIO" | tr '[:lower:]' '[:upper:]')"
[[ "$N" =~ ^[1-9][0-9]{0,3}$ && "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "n/timeout inválido." >&2; exit 2; }
[[ "$SEED_COUNT" =~ ^(0|[1-9][0-9]{0,3})$ && "$SEED_TRECHOS" =~ ^(0|[1-9][0-9]{0,2})$ ]] || {
    echo "seed-count/seed-trechos precisam ser inteiros não negativos." >&2
    exit 2
}
(( SEED_COUNT <= 1000 && SEED_TRECHOS <= 500 )) || {
    echo "Seed acima do limite do catálogo (1000 conversas, 500 trechos)." >&2
    exit 2
}
case "$SCENARIO_UPPER" in
    L1|L2|Q1-IDLE|Q1|I1|P1|P2|P3|P4|P5|P6|O1|S1|U1|U2|U3) ;;
    *) echo "Cenário não implementado ou inválido: $SCENARIO" >&2; exit 2 ;;
esac
for APP in "$APP_A" "$APP_B"; do
    APP_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$APP")"
    APPS_ROOT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/apps")/"
    case "$APP_REAL" in "$APPS_ROOT"*) ;; *) echo "App precisa estar dentro de ~/OmuPerf/apps/." >&2; exit 2 ;; esac
    if [[ "$APP" == "$APP_A" ]]; then APP_A="$APP_REAL"; else APP_B="$APP_REAL"; fi
    ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
    [[ "$ID" == "com.papagaio.Papagaio.perf" ]] || { echo "Bundle ID inválido: $ID" >&2; exit 2; }
    [[ -f "$APP/Contents/Resources/PerfBuild.json" ]] || { echo "PerfBuild.json ausente em $APP" >&2; exit 2; }
    codesign --verify --deep --strict "$APP"
done
SHORT=false
COOL_EACH=false
case "$SCENARIO_UPPER" in
    L1|U1|U2) SHORT=true ;;
    P1|P2|P3|P5|P6|Q1|Q1-IDLE|I1|P4|U3|S1) COOL_EACH=true ;;
esac
if [[ "$REQUIRE_IDLE" == true ]]; then SHORT=false; fi
case "$SCENARIO_UPPER" in
    I1|P1|P2|P3|P5|P6|Q1|U3)
        (( ${#FIXTURES[@]} == 1 )) || { echo "Esse cenário exige exatamente um --fixture." >&2; exit 2; }
        ;;
    P4) (( ${#FIXTURES[@]} == 3 )) || { echo "P4 exige exatamente três --fixture." >&2; exit 2; } ;;
    S1) (( ${#FIXTURES[@]} == 10 )) || { echo "S1 exige dez fixtures sintéticas (--fixture repetido dez vezes)." >&2; exit 2; } ;;
    L2) [[ "$SEED_COUNT" == 200 || "$SEED_COUNT" == 1000 ]] || { echo "L2 exige --seed-count 200 ou 1000." >&2; exit 2; } ;;
    U1) [[ "$SEED_COUNT" == 200 ]] || { echo "U1 exige --seed-count 200." >&2; exit 2; } ;;
    U2) [[ "$SEED_COUNT" == 1000 ]] || { echo "U2 exige --seed-count 1000." >&2; exit 2; } ;;
esac
case "$SCENARIO_UPPER" in
    P1|P2|P3|P5|P6|Q1) (( ${#GABARITOS[@]} == 1 )) || { echo "Esse cenário exige um --gabarito." >&2; exit 2; } ;;
    P4) (( ${#GABARITOS[@]} == 3 )) || { echo "P4 exige três --gabarito para o gate de qualidade." >&2; exit 2; } ;;
esac
FIXROOT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/fixtures")/"
verificar_hash_fixture() {
    python3 - "$OMU_PERF_DIR/fixtures/manifest.json" "$1" <<'PY'
import hashlib,json,sys
manifest_path,fixture_path=sys.argv[1:]
manifest=json.load(open(manifest_path,encoding="utf-8"))
entry=manifest.get("arquivos",{}).get(__import__("os").path.basename(fixture_path))
if not entry:
    raise SystemExit(f"Fixture sem entrada no manifesto: {fixture_path}")
hasher=hashlib.sha256()
with open(fixture_path,"rb") as audio:
    for block in iter(lambda: audio.read(1024*1024), b""):
        hasher.update(block)
digest=hasher.hexdigest()
if digest != entry.get("sha256"):
    raise SystemExit(f"SHA-256 divergiu do manifesto: {fixture_path}")
PY
}
for indice in "${!FIXTURES[@]}"; do
    FIXTURES[$indice]="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${FIXTURES[$indice]}")"
    case "${FIXTURES[$indice]}" in "$FIXROOT"*) ;; *) echo "Áudio fora de ~/OmuPerf/fixtures/." >&2; exit 2 ;; esac
    [[ -f "${FIXTURES[$indice]}" ]] || { echo "Fixture ausente." >&2; exit 2; }
    verificar_hash_fixture "${FIXTURES[$indice]}"
done
for indice in "${!GABARITOS[@]}"; do
    GABARITOS[$indice]="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${GABARITOS[$indice]}")"
    case "${GABARITOS[$indice]}" in "$FIXROOT"*) ;; *) echo "Gabarito fora de ~/OmuPerf/fixtures/." >&2; exit 2 ;; esac
    [[ -f "${GABARITOS[$indice]}" ]] || { echo "Gabarito ausente." >&2; exit 2; }
    verificar_hash_fixture "${GABARITOS[$indice]}"
done
for indice in "${!QUALITY_BASELINES[@]}"; do
    QUALITY_BASELINES[$indice]="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${QUALITY_BASELINES[$indice]}")"
    case "${QUALITY_BASELINES[$indice]}" in "$OMU_PERF_DIR"/*) ;; *) echo "Baseline de qualidade fora de ~/OmuPerf/." >&2; exit 2 ;; esac
    [[ -f "${QUALITY_BASELINES[$indice]}" ]] || { echo "Baseline de qualidade ausente." >&2; exit 2; }
done
if (( ${#QUALITY_BASELINES[@]} > 0 && ${#QUALITY_BASELINES[@]} != ${#GABARITOS[@]} )); then
    echo "Passe uma baseline de qualidade para cada gabarito, ou nenhuma." >&2
    exit 2
fi
for indice in "${!BASELINE_ARQUIVOS[@]}"; do
    BASELINE_ARQUIVOS[$indice]="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "${BASELINE_ARQUIVOS[$indice]}")"
    case "${BASELINE_ARQUIVOS[$indice]}" in "$OMU_PERF_DIR"/*) ;; *) echo "Baseline exata fora de ~/OmuPerf/." >&2; exit 2 ;; esac
    [[ -f "${BASELINE_ARQUIVOS[$indice]}" ]] || { echo "Baseline exata ausente." >&2; exit 2; }
done
if [[ "$EXIGIR_IDENTICA" == true ]] && (( ${#BASELINE_ARQUIVOS[@]} != ${#GABARITOS[@]} )); then
    echo "--exigir-identica precisa de um --baseline-arquivo para cada gabarito." >&2
    exit 2
fi
MODELS="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$MODELS")"
MODELS_DO_APP="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$HOME/Library/Application Support/Papagaio/Models")"
MODELS_DE_FIXTURE="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/fixtures")/"
case "$MODELS" in
    "$MODELS_DO_APP") ;;
    "$MODELS_DE_FIXTURE"*) ;;
    *) echo "Modelos precisam ser os locais do app ou fixtures em ~/OmuPerf/." >&2; exit 2 ;;
esac
[[ -d "$MODELS" ]] || { echo "Diretório de modelos ausente: $MODELS" >&2; exit 2; }
mkdir -p "$OMU_PERF_DIR/runs" "$STATE_DIR"
[[ ! -d "$STATE_DIR/infra.lock" ]] || { echo "Build/teste/geração ativa; não medir." >&2; exit 3; }
LOCK="$STATE_DIR/measurement.lock"
mkdir "$LOCK" 2>/dev/null || { echo "Outra medição está ativa." >&2; exit 3; }
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
DATASET="$OMU_PERF_DIR/runs/medicao-$SCENARIO-$RUN_ID"
mkdir -p "$DATASET"
CAFFEINATE_PID=""
cleanup() {
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        C="$(ps -p "$CAFFEINATE_PID" -o comm= | xargs)"
        [[ "$C" == *caffeinate ]] && kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
if [[ "$SHORT" == true && "$SEED_COUNT" == 0 ]]; then
    "$SCRIPT_DIR/ambiente.sh" --short 2>&1 | tee "$DATASET/ambiente-0.log"
else
    "$SCRIPT_DIR/ambiente.sh" 2>&1 | tee "$DATASET/ambiente-0.log"
fi
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
IDLE_NS="$(ioreg -c IOHIDSystem -d 4 | awk -F'= ' '/HIDIdleTime/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
IDLE_S=$(( ${IDLE_NS:-0} / 1000000000 ))
if (( IDLE_S < 120 )); then
    [[ "$SHORT" == true ]] || { echo "PAUSA: usuário ativo em cenário longo." >&2; exit 13; }
    N=$((N*2))
fi
SAMPLES="$DATASET/amostras.jsonl"; ORDER="$DATASET/ordem.txt"
: > "$SAMPLES"; : > "$ORDER"
swap_bytes() { sysctl vm.swapusage | python3 -c 'import re,sys; m=re.search(r"used = ([0-9.]+)([KMG])",sys.stdin.read()); f={"K":1024,"M":1024**2,"G":1024**3}; print(int(float(m.group(1))*f[m.group(2)]) if m else 0)' ; }

SEED_TEMPLATE=""
if (( SEED_COUNT > 0 )); then
    [[ -x "$EVAL_BIN" ]] || { echo "Passe --eval-bin executável para semear a biblioteca." >&2; exit 2; }
    EVAL_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$EVAL_BIN")"
    BUILD_ROOT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/build")/"
    case "$EVAL_REAL" in "$BUILD_ROOT"*) EVAL_BIN="$EVAL_REAL" ;; *) echo "papagaio-eval precisa estar em ~/OmuPerf/build/." >&2; exit 2 ;; esac
    CATALOGO="$OMU_PERF_DIR/fixtures/bibliotecas-semente.json"
    [[ -f "$CATALOGO" ]] || { echo "Gere primeiro o catálogo de biblioteca sintética." >&2; exit 2; }
    verificar_hash_fixture "$CATALOGO"
    SEED_TEMPLATE="$DATASET/seed-template"
    SEED_LOG="$DATASET/seed-library.log"
    mkdir -p "$SEED_TEMPLATE"
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift;exec @ARGV' 3600 \
        "$EVAL_BIN" seed-library --raiz "$SEED_TEMPLATE" --quantidade "$SEED_COUNT" \
        --trechos "$SEED_TRECHOS" --catalogo "$CATALOGO" >"$SEED_LOG" 2>&1 &
    SEED_PID=$!
    printf 'seed pid=%s log=%s\n' "$SEED_PID" "$SEED_LOG"
    if wait "$SEED_PID"; then :; else SEED_STATUS=$?; cat "$SEED_LOG" >&2; exit "$SEED_STATUS"; fi
    sleep 90
    if [[ "$SHORT" == true ]]; then "$SCRIPT_DIR/ambiente.sh" --short 2>&1 | tee "$DATASET/ambiente-seed.log"; else "$SCRIPT_DIR/ambiente.sh" 2>&1 | tee "$DATASET/ambiente-seed.log"; fi
    CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
fi

encerrar_app_desta_amostra() {
    local app="$1" root="$2"
    local executable
    executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
    local binary="$app/Contents/MacOS/$executable"
    local pid
    pid="$(ps -ww -axo pid=,command= | awk -v bin="$binary" -v raiz="--perf-raiz $root" 'index($0,bin)>0 && index($0,raiz)>0 {print $1; exit}')"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    local comando
    comando="$(ps -ww -p "$pid" -o command=)"
    [[ "$comando" == *"$binary"* && "$comando" == *"--perf-raiz $root"* ]] || return 0
    kill -TERM "$pid" 2>/dev/null || return 0
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        comando="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$comando" == *"$binary"* && "$comando" == *"--perf-raiz $root"* ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
}

run_one() {
    [[ ! -e "$STATE_DIR/STOP" ]] || { echo "STOP presente; encerrar após a amostra atual." >&2; return 20; }
    local side="$1" app="$2" index="$3" cenario="$4" classe="$5"
    local root="$DATASET/root-$classe-$side-$index" events="$DATASET/events-$classe-$side-$index.jsonl" log="$DATASET/open-$classe-$side-$index.log"
    local swap_log="$DATASET/swap-$classe-$side-$index.log"
    local app_label app_version app_commit
    app_label="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["rotulo"])' "$app/Contents/Resources/PerfBuild.json")"
    app_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["commit"])' "$app/Contents/Resources/PerfBuild.json")"
    app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
    if (( SEED_COUNT > 0 )) && [[ "$classe" == amostra ]]; then
        mkdir -p "$root"
        /bin/cp -Rc "$SEED_TEMPLATE/." "$root/"
    fi
    local automatic=YES app_scenario="$cenario"
    [[ "$SCENARIO_UPPER" == I1 || "$SCENARIO_UPPER" == S1 || "$SCENARIO_UPPER" == U3 ]] && automatic=NO
    [[ "$SCENARIO_UPPER" == S1 && "$classe" == amostra ]] && app_scenario=s1-import
    local -a args=(--perf-cenario "$app_scenario" --perf-raiz "$root" --perf-modelos "$MODELS" --perf-saida "$events" --perf-timeout "$TIMEOUT"
        -AppleLanguages '(pt-BR)' -AppleLocale pt_BR -processamentoAutomatico "$automatic"
        -traducaoAutomatica YES -exibirFichaAutomaticamente NO -painelFlutuanteDuranteGravacao NO
        -contextoDaConta perfil -equipeAtiva '' -aparenciaDoApp sistema
        -camposVisiveisDoCartao 1023 -modeloDeCartao 1
        -mostrarConfiancaTranscricao NO -mostrarPorcentagemConfianca YES
        -ocultarSecaoNaoIniciado NO -ocultarSecaoEmAndamento NO -ocultarSecaoConcluidas NO -ocultarSecaoAtrasada NO
        -mostrarTarefasOcultasDaConversa NO -ocultarColunaNaoIniciado NO -ocultarColunaEmAndamento NO
        -ocultarColunaConcluidas NO -ocultarColunaAtrasada NO -mostrarTarefasOcultas NO)
    for fixture in "${FIXTURES[@]}"; do args+=(--perf-fixture "$fixture"); done
    if [[ "$SCENARIO_UPPER" == U1 ]]; then args+=(--perf-detalhe-id "00000000-0000-0000-0000-000000000001"); fi
    local before after start finish wall status leaks_status leaks_log leaks_pid target_pid
    leaks_status=not-run; leaks_log="$DATASET/leaks-$classe-$side-$index.log"; leaks_pid=""
    before="$(swap_bytes)"; start="$(python3 -c 'import time;print(time.monotonic_ns())')"
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift;exec @ARGV' "$TIMEOUT" /usr/bin/open -n -F -W \
        --env PAPAGAIO_TEST_MODE=1 "$app" --args "${args[@]}" >"$log" 2>&1 &
    local pid=$!; status=ok
    ( while kill -0 "$pid" 2>/dev/null; do swap_bytes; sleep 1; done ) >"$swap_log" &
    local monitor_pid=$!
    if [[ "$SCENARIO_UPPER" == S1 && "$classe" == amostra ]]; then
        local executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
        target_pid=""
        for ((probe=0;probe<120;probe++)); do
            if [[ -f "$events" ]] && /usr/bin/grep -Fq '"evento":"terminate.scheduled"' "$events"; then
                target_pid="$(ps -ww -axo pid=,command= | awk -v bin="$executable" -v raiz="--perf-raiz $root" 'index($0,bin)>0 && index($0,raiz)>0 {print $1; exit}')"
                [[ "$target_pid" =~ ^[0-9]+$ ]] && break
            fi
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        if [[ "$target_pid" =~ ^[0-9]+$ ]]; then
            local processo="$(ps -ww -p "$target_pid" -o command= 2>/dev/null || true)"
            if [[ "$processo" == *"$executable"* && "$processo" == *"--perf-raiz $root"* ]]; then
                /usr/bin/nohup /usr/bin/perl -e 'alarm shift;exec @ARGV' 50 /usr/bin/leaks "$target_pid" >"$leaks_log" 2>&1 &
                leaks_pid=$!
                leaks_status=running
            else
                status=leaks-target-mismatch
                leaks_status=target-mismatch
            fi
        else
            status=leaks-target-missing
            leaks_status=target-missing
        fi
    fi
    if wait "$pid"; then :; else status="falhou:$?"; fi
    if [[ -n "$leaks_pid" ]]; then
        if wait "$leaks_pid"; then
            leaks_status=ok
        else
            LEAKS_EXIT=$?
            leaks_status="failed:$LEAKS_EXIT"
            status=leaks-failed
        fi
    fi
    if [[ "$status" != ok ]]; then encerrar_app_desta_amostra "$app" "$root"; fi
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    finish="$(python3 -c 'import time;print(time.monotonic_ns())')"; after="$(swap_bytes)"
    local swap_max
    swap_max="$(awk -v antes="$before" -v depois="$after" 'BEGIN {max=(antes>depois?antes:depois)} {if ($1>max) max=$1} END {print max}' "$swap_log")"
    wall="$(python3 -c 'import sys;print((int(sys.argv[2])-int(sys.argv[1]))/1e9)' "$start" "$finish")"
    local quality_result="$DATASET/qualidade-$classe-$side-$index"
    case "$SCENARIO_UPPER" in
        P1|P2|P3|P4|P5|P6|Q1)
            if [[ "$status" == ok ]]; then
                local -a output_dumps=()
                while IFS= read -r output_json; do output_dumps+=("$output_json"); done < <(python3 - "$events" <<'PY'
import json,sys
try:
    for line in open(sys.argv[1],encoding="utf-8"):
        item=json.loads(line)
        if item.get("evento")=="output.dump":
            print(item.get("caminho",""))
except (OSError,json.JSONDecodeError): pass
PY
                )
                mkdir -p "$quality_result"
                if (( ${#output_dumps[@]} != ${#GABARITOS[@]} )); then
                    echo "Quantidade de dumps não corresponde aos gabaritos em $events" >&2
                    status=quality-fail
                else
                    local quality_index
                    for ((quality_index=0; quality_index<${#GABARITOS[@]}; quality_index++)); do
                        [[ -f "${output_dumps[$quality_index]}" ]] || { status=quality-fail; break; }
                        local -a quality_args=(--referencia "${GABARITOS[$quality_index]}" --saida-arquivo "${output_dumps[$quality_index]}" --resultado "$quality_result/$quality_index.json")
                        if (( ${#QUALITY_BASELINES[@]} > 0 )); then
                            quality_args+=(--baseline "${QUALITY_BASELINES[$quality_index]}")
                        fi
                        if (( ${#BASELINE_ARQUIVOS[@]} > 0 )); then
                            quality_args+=(--baseline-arquivo "${BASELINE_ARQUIVOS[$quality_index]}")
                        fi
                        [[ "$EXIGIR_IDENTICA" == true ]] && quality_args+=(--exigir-identica)
                        if ! python3 "$SCRIPT_DIR/qualidade.py" "${quality_args[@]}" >"$quality_result/log-$quality_index.json"; then
                            status=quality-fail
                        fi
                    done
                fi
            fi
            ;;
    esac
    if [[ "$SCENARIO_UPPER" == S1 && "$status" == ok ]]; then
        local import_count
        import_count="$(python3 - "$events" <<'PY'
import json,sys
try:
    print(sum(json.loads(line).get("evento")=="import.end" for line in open(sys.argv[1],encoding="utf-8")))
except (OSError,json.JSONDecodeError):
    print(0)
PY
        )"
        [[ "$import_count" == 10 ]] || status=import-fail
    fi
    python3 - "$events" "$SAMPLES" "$SCENARIO" "$cenario" "$side" "$index" "$classe" "$status" "$wall" "$finish" "$before" "$after" "$swap_max" "$log" "$quality_result" "$app" "$app_label" "$app_version" "$MODELS" "$app_commit" "$OMU_PERF_DIR/fixtures/manifest.json" "$leaks_log" "$leaks_status" "${FIXTURES[@]}" <<'PY'
import json,os,re,sys
(path,out,scenario,app_scenario,side,index,kind,status,wall,exit_ns,before,after,swap_peak,log,quality_path,
 app_path,app_label,app_version,models_path,commit,manifest_path,leaks_path,leaks_status,*fixture_paths)=sys.argv[1:]
events=[]
if os.path.isfile(path):
    for line in open(path,encoding="utf-8"):
        try: events.append(json.loads(line))
        except json.JSONDecodeError: pass
def first(name): return next((x for x in events if x.get("evento")==name),None)
def elapsed(a,b):
    x,y=first(a),first(b)
    return max(0,(y["t_ns"]-x["t_ns"])/1e9) if x and y else None
def elapsed_pipeline():
    begins=[x for x in events if x.get("evento")=="pipeline.start"]
    ends=[x for x in events if x.get("evento")=="pipeline.end"]
    return max(0,(ends[-1]["t_ns"]-begins[0]["t_ns"])/1e9) if begins and ends else None
start=first("process.start"); origin=start.get("t_ns",0) if start else 0
frame=first("ui.first_frame"); ready=first("ui.interactive")
samples=[x for x in events if x.get("evento")=="sample"]
early=[x for x in samples if x.get("t_ns",origin)-origin<=5_000_000_000]
mem=[x["phys_footprint_bytes"] for x in samples if isinstance(x.get("phys_footprint_bytes"),(int,float))]
phases={}
for event in events:
    if event.get("evento")=="pipeline.phase.end":
        name=event.get("fase","?")
        phases[name]=phases.get(name,0)+event.get("duracao_s",0)
audio_duration=sum(x.get("duracao_audio_s",0) for x in events if x.get("evento")=="import.end")
processing_duration=elapsed_pipeline()
terminate_request=first("terminate.request")
closing_to_exit=max(0,(int(exit_ns)-terminate_request["t_ns"])/1e9) if terminate_request else None
metrics={"ttff_s":(frame["t_ns"]-origin)/1e9 if frame and start else None,
"tti_s":(ready["t_ns"]-origin)/1e9 if ready and start else None,"app_wall_s":float(wall),
"pico_footprint_bytes":max(mem) if mem else None,
"crescimento_footprint_bytes":(mem[-1]-mem[0]) if len(mem)>1 else None,
"cpu_primeiros_5s_s":max((x.get("cpu_s",0) for x in early),default=0)-min((x.get("cpu_s",0) for x in early),default=0) if early else None,
"processing_total_s":processing_duration,"audio_duration_s":audio_duration if audio_duration else None,
"rtf":processing_duration/audio_duration if processing_duration is not None and audio_duration>0 else None,
"import_total_s":sum(x.get("duracao_s",0) for x in events if x.get("evento")=="import.end"),
"import_count":sum(x.get("evento")=="import.end" for x in events),
"import_errors":sum(x.get("evento")=="import.end" and bool(x.get("erro")) for x in events),
"scenario_errors":sum(x.get("evento")=="scenario.error" for x in events),
"closing_s":elapsed("terminate.request","app.will_terminate"),"closing_to_process_exit_s":closing_to_exit,
"main_hitches":sum(x.get("evento")=="main.hitch" for x in events),"main_hangs":sum(x.get("evento")=="main.hang" for x in events),
"thermal_states":sorted({x.get("thermal_state") for x in samples if x.get("thermal_state")}),
"phase_seconds":phases,
"model_loads":{name:sum(x.get("evento")=="model.load.start" and x.get("modelo")==name for x in events) for name in ("whisper","qwen","silero")},
"model_unloads":{name:sum(x.get("evento")=="model.unload.start" and x.get("modelo")==name for x in events) for name in ("whisper","qwen","silero")},
"model_load_seconds":{name:sum(x.get("duracao_s",0) for x in events if x.get("evento")=="model.load.end" and x.get("modelo")==name) for name in ("whisper","qwen","silero")},
"search_key_latency_s":[x.get("latencia_s") for x in events if x.get("evento")=="search.response"]}
leaks_text=""
if leaks_status=="ok" and os.path.isfile(leaks_path):
    leaks_text=open(leaks_path,encoding="utf-8",errors="replace").read()
leaks_match=re.search(r"(\d+)\s+leaks?\s+for\s+([\d,]+)\s+total leaked bytes",leaks_text,re.IGNORECASE)
if scenario.upper()=="S1" and leaks_status=="ok" and not leaks_match:
    raise SystemExit("saída de leaks sem resumo reconhecido; consulte "+leaks_path)
metrics["leaks_status"]=leaks_status
metrics["leaks_count"]=int(leaks_match.group(1)) if leaks_match else None
metrics["leaks_bytes"]=int(leaks_match.group(2).replace(",","")) if leaks_match else None
states=metrics["thermal_states"]
record={"cenario":scenario,"cenario_app":app_scenario,"lado":side,"indice":int(index),"classe":kind,"status":status,
"contaminada_swap":int(swap_peak)>int(before),"contaminada_thermal":any(state!="nominal" for state in states),
"swap_antes_bytes":int(before),"swap_depois_bytes":int(after),
"app":{"rotulo":app_label,"versao":app_version,"caminho":app_path,"bundle_id":"com.papagaio.Papagaio.perf"},
"commit":commit,"modelos_path":models_path,
"fixtures":[],"eventos":path,"log":log,"qualidade":quality_path if os.path.isdir(quality_path) else None,"metricas":metrics}
if fixture_paths and os.path.isfile(manifest_path):
    manifest=json.load(open(manifest_path,encoding="utf-8"))
    registry=manifest.get("arquivos",{})
    record["fixtures"]=[{"path":fixture,"sha256":registry.get(os.path.basename(fixture),{}).get("sha256")} for fixture in fixture_paths]
with open(out,"a",encoding="utf-8") as f: f.write(json.dumps(record,ensure_ascii=False,sort_keys=True)+"\n")
print(json.dumps(record,ensure_ascii=False,sort_keys=True))
PY
    [[ "$status" == ok && -f "$events" ]] || { echo "Falha ($status); log: $log" >&2; return 1; }
}

echo "Cenário=$SCENARIO n=$N/lado; dados=$DATASET"
run_one A "$APP_A" 0 l1 L3
run_one B "$APP_B" 0 l1 L3
sleep 90
if [[ "$SHORT" == true ]]; then "$SCRIPT_DIR/ambiente.sh" --short 2>&1 | tee "$DATASET/ambiente-1.log"; else "$SCRIPT_DIR/ambiente.sh" 2>&1 | tee "$DATASET/ambiente-1.log"; fi
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
TOTAL=$((N*2)); NUM=0; IA=0; IB=0
BLOCK=1
for ((pair=0;pair<N;pair++)); do
    if (( pair%2==0 )); then ORDEM=(A B); else ORDEM=(B A); fi
    for side in "${ORDEM[@]}"; do
        NUM=$((NUM+1))
        if [[ "$side" == A ]]; then app="$APP_A"; IA=$((IA+1)); index="$IA"; else app="$APP_B"; IB=$((IB+1)); index="$IB"; fi
        printf '%s\t%s\t%s\n' "$side" "$index" "$SCENARIO" >> "$ORDER"
        run_one "$side" "$app" "$index" "$SCENARIO" amostra
        if [[ "$COOL_EACH" == true ]] && (( NUM<TOTAL )); then
            sleep 90
            BLOCK=$((BLOCK+1))
            if [[ "$SHORT" == true ]]; then "$SCRIPT_DIR/ambiente.sh" --short 2>&1 | tee "$DATASET/ambiente-$BLOCK.log"; else "$SCRIPT_DIR/ambiente.sh" 2>&1 | tee "$DATASET/ambiente-$BLOCK.log"; fi
            CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
        elif (( NUM%4==0 && NUM<TOTAL )); then
            sleep 90
            BLOCK=$((BLOCK+1))
            if [[ "$SHORT" == true ]]; then "$SCRIPT_DIR/ambiente.sh" --short 2>&1 | tee "$DATASET/ambiente-$BLOCK.log"; else "$SCRIPT_DIR/ambiente.sh" 2>&1 | tee "$DATASET/ambiente-$BLOCK.log"; fi
            CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
        fi
    done
done
if [[ "$SCENARIO_UPPER" == S1 ]]; then
    python3 "$SCRIPT_DIR/validar-stress.py" "$SAMPLES" "$DATASET/qualidade-stress.json" "$N"
fi
printf 'Concluído: %s\nAmostras: %s\nOrdem: %s\n' "$DATASET" "$SAMPLES" "$ORDER"

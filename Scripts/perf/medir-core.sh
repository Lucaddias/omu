#!/bin/bash
# A/B intercalado dos micro-benchmarks do Core; C1 executa todos, P7 isola AEC.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
STATE_DIR="$OMU_PERF_DIR/estado"
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    printf 'Uso: %s <C1|C2|P7> <A/papagaio-eval> <B/papagaio-eval> <n> [--timeout S] [--modelos DIR] [--fixture WAV]\n' "$0"
    printf 'C2 usa ptbr_30s.wav, gabaritos do manifesto e modelos já existentes. P7 isola aec.processarBlocos.\n'
    exit 0
fi
SCENARIO="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
BIN_A="${2:-}"
BIN_B="${3:-}"
N="${4:-}"
TIMEOUT=7200
MODELS="$HOME/Library/Application Support/Papagaio/Models"
AUDIO="$OMU_PERF_DIR/fixtures/ptbr_30s.wav"
shift 4 || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            printf 'Uso: %s <C1|C2|P7> <A/papagaio-eval> <B/papagaio-eval> <n> [--timeout S] [--modelos DIR] [--fixture WAV]\n' "$0"
            printf 'C2 usa ptbr_30s.wav, gabaritos do manifesto e modelos já existentes. P7 isola aec.processarBlocos.\n'
            exit 0
            ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --modelos) MODELS="$2"; shift 2 ;;
        --fixture) AUDIO="$2"; shift 2 ;;
        *) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
    esac
done
[[ "$SCENARIO" == C1 || "$SCENARIO" == C2 || "$SCENARIO" == Q2 || "$SCENARIO" == T2 || "$SCENARIO" == P7 ]] || { echo "Use C1, C2, Q2, T2 ou P7." >&2; exit 2; }
[[ "$N" =~ ^[1-9][0-9]{0,2}$ && "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "n/timeout inválido." >&2; exit 2; }
(( N <= 100 )) || { echo "n acima do limite de segurança (100)." >&2; exit 2; }
APPS_ROOT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/apps")"
BIN_A="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BIN_A")"
BIN_B="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BIN_B")"
for BIN in "$BIN_A" "$BIN_B"; do
    case "$BIN" in "$APPS_ROOT"/core-*/papagaio-eval) ;; *) echo "CLI precisa estar em ~/OmuPerf/apps/core-*/papagaio-eval." >&2; exit 2 ;; esac
    [[ -x "$BIN" && -f "$(dirname "$BIN")/PerfBuild.json" ]] || { echo "Build do core ausente: $BIN" >&2; exit 2; }
done
if [[ "$SCENARIO" == C2 || "$SCENARIO" == Q2 || "$SCENARIO" == T2 ]]; then
    FIXROOT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/fixtures")/"
    AUDIO="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$AUDIO")"
    case "$AUDIO" in "$FIXROOT"*) ;; *) echo "Fixture C2 precisa estar em ~/OmuPerf/fixtures/." >&2; exit 2 ;; esac
    [[ "$(basename "$AUDIO")" == "ptbr_30s.wav" ]] || { echo "C2 compara Whisper com ptbr_30s.gabarito.json; use ptbr_30s.wav." >&2; exit 2; }
    [[ -f "$AUDIO" && -f "$OMU_PERF_DIR/fixtures/manifest.json" ]] || { echo "Áudio/manifesto C2 ausente." >&2; exit 2; }
    python3 - "$OMU_PERF_DIR/fixtures/manifest.json" "$AUDIO" <<'PY'
import hashlib,json,os,sys
manifest=json.load(open(sys.argv[1],encoding="utf-8"))
audio=sys.argv[2]
entry=manifest.get("arquivos",{}).get(os.path.basename(audio))
if not entry: raise SystemExit("áudio C2 sem entrada no manifesto")
hasher=hashlib.sha256()
with open(audio,"rb") as stream:
    for block in iter(lambda:stream.read(1024*1024),b""): hasher.update(block)
if hasher.hexdigest()!=entry.get("sha256"): raise SystemExit("hash da fixture C2 divergiu")
PY
    MODELS="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$MODELS")"
    MODELS_DEFAULT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$HOME/Library/Application Support/Papagaio/Models")"
    MODELS_FIXTURES="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/fixtures")/"
    case "$MODELS" in "$MODELS_DEFAULT"|"$MODELS_FIXTURES"*) ;; *) echo "Modelos C2 precisam estar no diretório local ou em fixtures." >&2; exit 2 ;; esac
    [[ -d "$MODELS" ]] || { echo "Diretório de modelos C2 ausente: $MODELS" >&2; exit 2; }
    [[ -r "$MODELS/ggml-large-v3.bin" && -r "$MODELS/Qwen_Qwen3.5-9B-Q4_K_M.gguf" ]] || {
        echo "C2 requer Whisper large-v3 e Qwen3.5-9B já disponíveis no caminho informado." >&2
        exit 2
    }
fi

mkdir -p "$OMU_PERF_DIR/runs" "$STATE_DIR"
[[ ! -d "$STATE_DIR/infra.lock" ]] || { echo "Build/teste/geração ativa; não medir." >&2; exit 3; }
LOCK="$STATE_DIR/measurement.lock"
mkdir "$LOCK" 2>/dev/null || { echo "Outra medição está ativa." >&2; exit 3; }
RUN_ID="$(date '+%Y%m%dT%H%M%S')-$$"
DATASET="$OMU_PERF_DIR/runs/medicao-core-$SCENARIO-$RUN_ID"
mkdir -p "$DATASET"
CAFFEINATE_PID=""
cleanup() {
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        [[ "$(ps -p "$CAFFEINATE_PID" -o comm= | xargs)" == *caffeinate ]] && kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
# Pré-voo curto com espera e nova tentativa: A/B intercalado absorve a sessão ativa,
# e a inatividade de entrada fica registrada no log de cada bloco.
preflight_bloco() {
    local destino="$1" tentativa
    for ((tentativa=1; tentativa<=30; tentativa++)); do
        "$SCRIPT_DIR/ambiente.sh" --short >"$destino" 2>&1 && { cat "$destino"; return 0; }
        [[ ! -e "$STATE_DIR/STOP" ]] || return 20
        printf 'Pré-voo reprovado (tentativa %s); nova checagem em 60 s: %s\n' "$tentativa" "$(tail -n 2 "$destino" | tr '\n' ' ')"
        sleep 60
    done
    return 14
}
preflight_bloco "$DATASET/ambiente-0.log"
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
SAMPLES="$DATASET/amostras.jsonl"
ORDER="$DATASET/ordem.txt"
: > "$SAMPLES"
: > "$ORDER"
swap_bytes() {
    sysctl vm.swapusage | python3 -c 'import re,sys; m=re.search(r"used = ([0-9.]+)([KMG])",sys.stdin.read()); f={"K":1024,"M":1024**2,"G":1024**3}; print(int(float(m.group(1))*f[m.group(2)]) if m else 0)'
}

run_one() {
    [[ ! -e "$STATE_DIR/STOP" ]] || { echo "STOP presente; encerrar após a amostra atual." >&2; return 20; }
    local side="$1" binary="$2" index="$3" metadata label commit report log swap_log before after status swap_peak thermal_warning
    metadata="$(dirname "$binary")/PerfBuild.json"
    label="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["rotulo"])' "$metadata")"
    commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["commit"])' "$metadata")"
    report="$DATASET/report-$side-$index.json"
    log="$DATASET/bench-$side-$index.log"
    swap_log="$DATASET/swap-$side-$index.log"
    before="$(swap_bytes)"
    local -a args=(bench --iteracoes 1 --saida "$report")
    if [[ "$SCENARIO" == P7 ]]; then
        args+=(--somente-caso aec.processarBlocos)
    elif [[ "$SCENARIO" == C1 ]]; then
        args+=(--so-micro)
    elif [[ "$SCENARIO" == T2 ]]; then
        # T2: triagem de ~256 tokens com gramática; só descarta ideias, nunca aceita.
        args+=(--modelos "$MODELS" --audio "$AUDIO" --triagem-qwen)
    elif [[ "$SCENARIO" == Q2 ]]; then
        # Q2: só resumo/tradução do Qwen, aquecimento curto (A/B do LlamaRuntime).
        args+=(--modelos "$MODELS" --audio "$AUDIO" --somente-qwen)
    else
        args+=(--modelos "$MODELS" --audio "$AUDIO")
    fi
    /usr/bin/nohup /usr/bin/perl -e 'alarm shift;exec @ARGV' "$TIMEOUT" "$binary" "${args[@]}" >"$log" 2>&1 &
    local pid=$!; status=ok
    ( while kill -0 "$pid" 2>/dev/null; do swap_bytes; sleep 1; done ) >"$swap_log" &
    local monitor_pid=$!
    if wait "$pid"; then :; else status="falhou:$?"; fi
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    after="$(swap_bytes)"
    swap_peak="$(awk -v a="$before" -v b="$after" 'BEGIN {m=(a>b?a:b)} {if ($1>m)m=$1} END {print m}' "$swap_log")"
    thermal_warning="$(pmset -g therm | /usr/bin/grep -Ei 'warning|serious|critical|throttl' | /usr/bin/grep -Ev 'No (thermal|performance) warning level' || true)"
    [[ -z "$thermal_warning" ]] || status=thermal
    python3 - "$report" "$SAMPLES" "$SCENARIO" "$side" "$index" "$status" "$before" "$after" "$swap_peak" "$binary" "$label" "$commit" "$log" <<'PY'
import json,math,os,sys
(report_path,out,scenario,side,index,status,before,after,swap_peak,binary,label,commit,log)=sys.argv[1:]
try:
    document=json.load(open(report_path,encoding="utf-8")) if os.path.isfile(report_path) else {}
    results=document.get("resultados",[])
except (OSError,json.JSONDecodeError):
    document={}; results=[]; status="invalid-report"
process_peak=document.get("processPeakRSSBytes")
if not results: raise SystemExit("relatório sem resultados de micro-benchmark")
if scenario=="P7" and not any(x.get("nome")=="aec.processarBlocos" for x in results):
    raise SystemExit("relatório sem resultado aec.processarBlocos")
if scenario=="C1":
    required={"segmentacao.agrupar","segmentacao.mesclarCanais","alinhamento.atribuir",
        "filtroRepeticao.remover","falas.agrupar","navegacao.indiceAtivo",
        "exportacao.markdown","aec.processarBlocos","vad.janelasDeFala",
        "vad.silero.lote","idioma.detectar"}
    missing=required-{item.get("nome") for item in results}
    if missing: raise SystemExit("faltam casos do C1: "+", ".join(sorted(missing)))
elif scenario=="C2":
    required={"macro.whisper.cicloCargaDescarga","macro.whisper.transcrever",
        "macro.qwen.cicloCargaDescarga","macro.qwen.resumir","macro.qwen.traduzir"}
    missing=required-{item.get("nome") for item in results}
    if missing: raise SystemExit("faltam macros do C2: "+", ".join(sorted(missing)))
    results=[item for item in results if item.get("nome","").startswith("macro.")]
elif scenario=="T2":
    if not any(item.get("nome")=="macro.qwen.triagem" for item in results):
        raise SystemExit("falta macro.qwen.triagem no T2")
elif scenario=="Q2":
    # Sem tradução no app desde 4411410: o Q2 mede o resumo curto (passe único) e o longo.
    required={"macro.qwen.cicloCargaDescarga","macro.qwen.resumirCurto","macro.qwen.resumir"}
    missing=required-{item.get("nome") for item in results}
    if missing: raise SystemExit("faltam macros do Q2: "+", ".join(sorted(missing)))
    results=[item for item in results if item.get("nome","") in required]
with open(out,"a",encoding="utf-8") as stream:
    for result in results:
        name=result.get("nome","unknown")
        details=result.get("detalhes") or {}
        artifact_path=None
        if scenario in ("C2","Q2","T2") and name in ("macro.whisper.transcrever","macro.qwen.resumir","macro.qwen.resumirCurto","macro.qwen.traduzir","macro.qwen.triagem"):
            import base64
            artifact_dir=os.path.join(os.path.dirname(out),"quality-artifacts")
            os.makedirs(artifact_dir,exist_ok=True)
            arquivo={"resumo":{"titulo":"Validação macro","visaoGeral":"Saída de referência sintética.",
                "temas":[],"citacoes":[],"proximosPassos":[]}}
            if name=="macro.whisper.transcrever":
                encoded=details.get("transcricao_json_base64")
                if not encoded: raise SystemExit("C2 sem saída de transcrição")
                arquivo["trechos"]=json.loads(base64.b64decode(encoded))
                filename="whisper"
            elif name in ("macro.qwen.resumir","macro.qwen.resumirCurto","macro.qwen.triagem"):
                encoded_source=details.get("source_trechos_json_base64")
                encoded_summary=details.get("resumo_json_base64")
                if not encoded_source or not encoded_summary: raise SystemExit("C2 sem saída de resumo")
                arquivo["trechos"]=json.loads(base64.b64decode(encoded_source))
                arquivo["resumo"]=json.loads(base64.b64decode(encoded_summary))
                filename={"macro.qwen.resumir":"qwen-summary","macro.qwen.resumirCurto":"qwen-short","macro.qwen.triagem":"qwen-triage"}[name]
            else:
                encoded=details.get("traducao_trechos_json_base64")
                if not encoded: raise SystemExit("C2 sem saída de tradução")
                arquivo["trechos"]=json.loads(base64.b64decode(encoded))
                filename="qwen-translation"
            artifact_path=os.path.join(artifact_dir,f"{filename}-{side}-{index}.json")
            with open(artifact_path,"w",encoding="utf-8") as artifact:
                json.dump(arquivo,artifact,ensure_ascii=False,separators=(",",":"))
        erle=None
        peak=int(process_peak) if process_peak is not None else None
        if name=="aec.processarBlocos":
            erle=float(details.get("erle_db","nan"))
            peak=int(details.get("peak_rss_bytes","0"))
            if not math.isfinite(erle) or peak <= 0:
                raise SystemExit("resultado AEC sem ERLE finito ou pico de memória")
        metric={"segundos":result.get("segundosMediano"),"amostras_s":result.get("amostrasSegundos"),
            "erle_db":erle,"peak_rss_bytes":peak}
        if name=="macro.whisper.transcrever":
            duracao=float(details.get("duracao_s",0) or 0)
            metric["rtf"]=result.get("segundosMediano",0)/duracao if duracao else None
        row={"cenario":f"{scenario}:{name}","cenario_base":scenario,"caso":name,
            "lado":side,"indice":int(index),"classe":"amostra","status":status,
            "contaminada_swap":int(swap_peak)>int(before),"contaminada_thermal":status=="thermal",
            "swap_antes_bytes":int(before),"swap_depois_bytes":int(after),
            "app":{"rotulo":label,"caminho":binary},"commit":commit,"log":log,
            "quality_artifact_path":artifact_path,"metricas":metric}
        stream.write(json.dumps(row,ensure_ascii=False,sort_keys=True)+"\n")
        print(json.dumps(row,ensure_ascii=False,sort_keys=True))
PY
    [[ "$status" == ok && -f "$report" ]] || { echo "Falha ($status); log: $log" >&2; return 1; }
}

# 60 s quando a última amostra saiu limpa (sem swap crescendo, sem alerta térmico);
# 90 s caso contrário. Registrado em resfriamento.log.
resfriamento_adaptativo() {
    local segundos=90 motivo="última amostra contaminada ou ausente"
    if [[ -s "$SAMPLES" ]] && python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read().splitlines()[-1]); sys.exit(0 if r.get("status")=="ok" and not r.get("contaminada_swap") and not r.get("contaminada_thermal") else 1)' "$SAMPLES" \
        && [[ -z "$(pmset -g therm | /usr/bin/grep -Ei 'warning|serious|critical|throttl' | /usr/bin/grep -Ev 'No (thermal|performance) warning level' || true)" ]]; then
        segundos=60; motivo="térmica nominal e swap estável"
    fi
    printf '%s\t%ss\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$segundos" "$motivo" >>"$DATASET/resfriamento.log"
    sleep "$segundos"
}

TOTAL=$((N*2)); COUNT=0; INDEX_A=0; INDEX_B=0; BLOCK=0
for ((pair=0;pair<N;pair++)); do
    if (( pair%2==0 )); then ORDEM=(A B); else ORDEM=(B A); fi
    for side in "${ORDEM[@]}"; do
        COUNT=$((COUNT+1))
        if [[ "$side" == A ]]; then binary="$BIN_A"; INDEX_A=$((INDEX_A+1)); index="$INDEX_A"; else binary="$BIN_B"; INDEX_B=$((INDEX_B+1)); index="$INDEX_B"; fi
        printf '%s\t%s\n' "$side" "$index" >> "$ORDER"
        run_one "$side" "$binary" "$index"
        if (( COUNT<TOTAL )); then
            if [[ "$SCENARIO" == P7 || "$SCENARIO" == C2 || "$SCENARIO" == Q2 || "$SCENARIO" == T2 ]] || (( COUNT%4==0 )); then
                resfriamento_adaptativo
                BLOCK=$((BLOCK+1))
                preflight_bloco "$DATASET/ambiente-$BLOCK.log"
                CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
            fi
        fi
    done
done
if [[ "$SCENARIO" == P7 ]]; then python3 - "$SAMPLES" "$DATASET/qualidade-erle.json" <<'PY'
import json,statistics,sys
source,destination=sys.argv[1:]
records=[json.loads(line) for line in open(source,encoding="utf-8")]
valid=[x for x in records if x.get("status")=="ok" and not x.get("contaminada_swap") and not x.get("contaminada_thermal")]
def erles(side): return [float(x["metricas"]["erle_db"]) for x in valid if x.get("lado")==side]
a,b=erles("A"),erles("B")
def picos(side): return [int(x["metricas"]["peak_rss_bytes"]) for x in valid if x.get("lado")==side]
mem_a,mem_b=picos("A"),picos("B")
if not a or not b or not mem_a or not mem_b: raise SystemExit("P7 inconclusivo: faltam ERLE/pico válidos dos dois lados")
median_a,median_b=statistics.median(a),statistics.median(b)
limite_memoria=16*1024**3
aceito=median_b>=median_a-1.0 and max(mem_a)<limite_memoria and max(mem_b)<limite_memoria
report={"erle_a_db":median_a,"erle_b_db":median_b,"delta_b_menos_a_db":median_b-median_a,
    "tolerancia_db":1.0,"pico_rss_a_bytes":max(mem_a),"pico_rss_b_bytes":max(mem_b),
    "limite_rss_bytes":limite_memoria,"aceito":aceito,"n_a":len(a),"n_b":len(b)}
with open(destination,"w",encoding="utf-8") as stream: json.dump(report,stream,ensure_ascii=False,indent=2)
print(json.dumps(report,ensure_ascii=False,sort_keys=True))
if not report["aceito"]: raise SystemExit("P7 reprovado: ERLE caiu mais de 1 dB ou pico excedeu 16 GiB")
PY
fi
if [[ "$SCENARIO" == C2 ]]; then
    python3 "$SCRIPT_DIR/validar-c2.py" "$SAMPLES" "$DATASET"
fi
if [[ "$SCENARIO" == Q2 || "$SCENARIO" == T2 ]]; then
    # Portão EXATO: resumo e tradução byte a byte iguais em todas as amostras A e B.
    python3 - "$DATASET/quality-artifacts" "$DATASET/qualidade-q2.json" <<'PY'
import glob,hashlib,json,os,sys
pasta,destino=sys.argv[1:]
relatorio={}
for prefixo in ("qwen-summary","qwen-short","qwen-translation","qwen-triage"):
    hashes={os.path.basename(f):hashlib.sha256(open(f,"rb").read()).hexdigest() for f in sorted(glob.glob(f"{pasta}/{prefixo}-*.json"))}
    if not hashes: continue
    relatorio[prefixo]={"arquivos":hashes,"identicos":len(set(hashes.values()))==1 and len(hashes)>1}
relatorio["aceito"]=all(v["identicos"] for v in relatorio.values() if isinstance(v,dict))
json.dump(relatorio,open(destino,"w",encoding="utf-8"),ensure_ascii=False,indent=2)
print(json.dumps({k:(v["identicos"] if isinstance(v,dict) else v) for k,v in relatorio.items()}))
if not relatorio["aceito"]: raise SystemExit("Q2: saídas do Qwen divergem entre amostras (portão EXATO)")
PY
fi
printf 'Concluído: %s\nAmostras: %s\nOrdem: %s\n' "$DATASET" "$SAMPLES" "$ORDER"

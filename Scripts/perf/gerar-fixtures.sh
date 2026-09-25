#!/bin/bash
# Gera fixtures sintéticas locais. say grava em arquivo (-o); nunca reproduz áudio.
set -euo pipefail
if [[ -z "${OMU_PERF_DIR:-}" ]]; then OMU_PERF_DIR="$HOME/OmuPerf"; fi
FIXTURES="$OMU_PERF_DIR/fixtures"
STATE_DIR="$OMU_PERF_DIR/estado"
mkdir -p "$FIXTURES"
[[ ! -f "$FIXTURES/manifest.json" ]] || { echo "Manifest já existe; preservando fixtures atuais."; exit 0; }
mkdir -p "$OMU_PERF_DIR/build" "$OMU_PERF_DIR/runs" "$STATE_DIR"
[[ ! -d "$STATE_DIR/measurement.lock" ]] || { echo "Medição ativa; não gerar fixtures." >&2; exit 3; }
mkdir "$STATE_DIR/infra.lock" 2>/dev/null || { echo "Outra build/teste/geração está ativa." >&2; exit 3; }
CAFFEINATE_PID=""
limpar() {
    if [[ -n "$CAFFEINATE_PID" ]] && kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
        [[ "$(ps -p "$CAFFEINATE_PID" -o comm= | xargs)" == *caffeinate ]] && kill -TERM "$CAFFEINATE_PID" 2>/dev/null || true
    fi
    rmdir "$STATE_DIR/infra.lock" 2>/dev/null || true
}
trap limpar EXIT INT TERM
"$(cd "$(dirname "$0")" && pwd)/ambiente.sh" >"$OMU_PERF_DIR/runs/fixtures-environment.log" 2>&1
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"
for comando in say ffmpeg ffprobe afconvert python3 shasum; do
    command -v "$comando" >/dev/null || { echo "Ferramenta ausente: $comando" >&2; exit 2; }
done
TMP="$OMU_PERF_DIR/build/fixtures-tmp-$$"
mkdir -p "$TMP"
mkdir -p "$TMP/pt" "$TMP/en"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 0.35 -c:a pcm_s16le "$TMP/silencio-curto.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 30 -c:a pcm_s16le "$TMP/silencio-padrao.wav"

cat > "$TMP/pt/frases.tsv" <<'PHRASES'
S1|Luciana|Bom dia, pessoal. Vamos revisar o plano da equipe para esta semana.
S2|Eddy|A primeira entrega do projeto Aurora fica para terça-feira, dia vinte e nove.
S1|Luciana|Eu atualizo o protótipo e envio a revisão até o meio-dia.
S3|Flo|A equipe conclui cinco entrevistas e organiza os principais aprendizados até sexta.
S2|Eddy|Combinado. Vamos reservar quatro mil reais para os testes com participantes.
S1|Luciana|Reduzimos duas licenças e mantemos a verba de acessibilidade.
PHRASES

VOICE_EN="$(say -v '?' | awk '$2 == "en_US" { print $1; exit }')"
[[ -n "$VOICE_EN" ]] || { echo "Nenhuma voz en_US instalada." >&2; exit 2; }
cat > "$TMP/en/frases.tsv" <<PHRASES
E1|$VOICE_EN|Good morning, team. Today we will review the Aurora project plan.|Bom dia, equipe. Hoje vamos revisar o plano do projeto Aurora.
E2|$VOICE_EN|The first delivery is due Tuesday, and the prototype review is due at noon.|A primeira entrega fica para terça-feira e a revisão do protótipo para o meio-dia.
E1|$VOICE_EN|We will interview five participants by Friday and share the findings.|Vamos entrevistar cinco participantes até sexta-feira e compartilhar os resultados.
E2|$VOICE_EN|The team approved four thousand dollars for accessibility and testing.|A equipe aprovou quatro mil dólares para acessibilidade e testes.
E1|$VOICE_EN|I will update the schedule and send the consent form for legal review.|Vou atualizar o cronograma e enviar o termo de consentimento para revisão jurídica.
PHRASES

gerar_base() {
    local idioma="$1" tabela="$2"
    local destino="$FIXTURES/$idioma""_30s.wav"
    local lista="$TMP/$idioma/concat.txt"
    local metadados="$TMP/$idioma/segmentos.tsv"
    : > "$lista"; : > "$metadados"
    local indice=0 inicio=0 fim
    while IFS='|' read -r falante voz texto texto_saida; do
        [[ -n "$texto" ]] || continue
        [[ -n "$texto_saida" ]] || texto_saida="$texto"
        local aiff="$TMP/$idioma/fala-$indice.aiff"
        local wav="$TMP/$idioma/fala-$indice.wav"
        say -v "$voz" -r 175 -o "$aiff" "$texto"
        afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
        local duracao
        duracao="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$wav")"
        printf "file '%s'\n" "$wav" >> "$lista"
        printf "file '%s'\n" "$TMP/silencio-curto.wav" >> "$lista"
        fim="$(awk -v s="$inicio" -v d="$duracao" 'BEGIN { printf "%.6f", s+d }')"
        printf '%s\t%s\t%s\t%s\t%s\n' "$inicio" "$fim" "$falante" "$texto" "$texto_saida" >> "$metadados"
        inicio="$(awk -v s="$inicio" -v d="$duracao" 'BEGIN { printf "%.6f", s+d+0.35 }')"
        indice=$((indice+1))
    done < "$tabela"
    printf "file '%s'\n" "$TMP/silencio-padrao.wav" >> "$lista"
    ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$lista" -t 30 -ar 16000 -ac 1 -c:a pcm_s16le "$destino"
    python3 - "$metadados" "$FIXTURES/$idioma" "$idioma" <<'PY'
import json,sys
from pathlib import Path
metadata,stem,language=sys.argv[1:]
segments=[]
for line in Path(metadata).read_text(encoding="utf-8").splitlines():
    start,end,speaker,source_text,target_text=line.split("\t",4)
    if float(end)<=30:
        segments.append({"inicio_s":float(start),"fim_s":float(end),"falante":speaker,"texto":target_text,"texto_origem":source_text})
durations=[("30s",30)]
if language=="ptbr":
    durations += [("5m",300),("30m",1800),("60m",3600),("3h",10800)]
for label,duration in durations:
    repeated=[]
    for loop in range(duration//30):
        offset=loop*30
        repeated.extend({**s,"inicio_s":s["inicio_s"]+offset,"fim_s":s["fim_s"]+offset} for s in segments)
    result={"idioma":language,"duracao_s":duration,"janela_comparacao_s":30,
            "texto":" ".join(s["texto"] for s in repeated),
            "texto_origem":" ".join(s["texto_origem"] for s in repeated),"trechos":repeated,
            "tolerancias":{"wer_delta":0.005,"der_delta":0.01,"timestamp_ms":100}}
    Path(f"{stem}_{label}.gabarito.json").write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY
}
gerar_base ptbr "$TMP/pt/frases.tsv"
gerar_base en "$TMP/en/frases.tsv"

# Gabaritos sintéticos para os macros C2 (prefill Qwen e tradução PT→EN).
python3 - "$FIXTURES" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
source=("Bem, acho que precisamos revisar o orçamento do trimestre. "
        "O João disse que o custo subiu 15 por cento e a Maria discordou. "
        "Vamos marcar uma reunião na sexta para decidir. "
        "Ponto número dois: o prazo do projeto Alpha foi adiado. "
        "Todos concordaram em reavaliar na próxima semana.")
translation=("Well, I think we need to review the quarterly budget. "
             "João said the cost went up by 15 percent and Maria disagreed. "
             "Let's schedule a meeting on Friday to decide. "
             "Point number two: the deadline for the Alpha project was postponed. "
             "Everyone agreed to reassess it next week.")
def segments(count,text):
    return [{"inicio_s":i*40.0,"fim_s":i*40.0+38.0,
             "falante":"eu" if i%2==0 else "interlocutor","texto":text}
            for i in range(count)]
tolerancias={"wer_delta":0.005,"der_delta":0.01,"timestamp_ms":100}
macro=segments(400,source)
root.joinpath("macro-qwen-400.gabarito.json").write_text(json.dumps({
    "idioma":"ptbr","duracao_s":16_000,"janela_comparacao_s":30,
    "texto":" ".join(x["texto"] for x in macro),"trechos":macro,"tolerancias":tolerancias
},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
traducao=segments(40,translation)
root.joinpath("macro-traducao-40.gabarito.json").write_text(json.dumps({
    "idioma":"en","duracao_s":1_600,"janela_comparacao_s":30,
    "texto":" ".join(x["texto"] for x in traducao),"trechos":traducao,"tolerancias":tolerancias
},ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
PY

for item in "5m 300 9" "30m 1800 59" "60m 3600 119" "3h 10800 359"; do
    set -- $item
    ffmpeg -hide_banner -loglevel error -y -stream_loop "$3" -i "$FIXTURES/ptbr_30s.wav" -t "$2" -c:a pcm_s16le "$FIXTURES/ptbr_$1.wav"
done

ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -ar 48000 -ac 2 -c:a pcm_s16le "$FIXTURES/ptbr_48k_stereo.wav"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -c:a aac -b:a 96k "$FIXTURES/ptbr_aac.m4a"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -c:a alac "$FIXTURES/ptbr_alac.m4a"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -c:a libmp3lame -b:a 96k "$FIXTURES/ptbr.mp3"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -c:a flac "$FIXTURES/ptbr.flac"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -c:a pcm_s16be "$FIXTURES/ptbr.aiff"
cp "$FIXTURES/ptbr.aiff" "$FIXTURES/ptbr.aif"
afconvert -f caff -d LEI16@16000 -c 1 "$FIXTURES/ptbr_30s.wav" "$FIXTURES/ptbr.caf"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -c:a aac -f adts "$FIXTURES/ptbr.aac"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=black:s=64x64:r=1 -i "$FIXTURES/ptbr_30s.wav" -map 0:v -map 1:a -t 30 -c:v mpeg4 -q:v 10 -c:a aac -shortest "$FIXTURES/ptbr.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=black:s=64x64:r=1 -i "$FIXTURES/ptbr_30s.wav" -map 0:v -map 1:a -t 30 -c:v mpeg4 -q:v 10 -c:a aac -shortest "$FIXTURES/ptbr.mov"

ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -t 0.5 -c:a pcm_s16le "$FIXTURES/borda_0p5s.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anullsrc=r=16000:cl=mono -t 300 -c:a pcm_s16le "$FIXTURES/borda_silencio_5m.wav"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i anoisesrc=color=pink:sample_rate=16000:duration=30 -c:a pcm_s16le "$FIXTURES/borda_ruido_30s.wav"
head -c 4096 "$FIXTURES/ptbr_30s.wav" > "$FIXTURES/borda_truncado.wav"
: > "$FIXTURES/borda_zero_bytes.wav"
cp "$FIXTURES/ptbr_30s.wav" "$FIXTURES/borda_extensao_errada.mp3"
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/ptbr_30s.wav" -filter_complex "[0:a]asplit=2[sistema][mic];[mic]adelay=120:all=1,volume=0.35[eco];[sistema][eco]amerge=inputs=2[a]" -map "[a]" -t 30 -ac 2 -c:a pcm_s16le "$FIXTURES/eco_2_canais_120ms.wav"

python3 - "$FIXTURES/bibliotecas-semente.json" <<'PY'
import json,sys
items=[]
for i in range(1000):
    items.append({"indice":i,"titulo":f"Reunião sintética {i+1:04d}",
      "resumo":f"Decisão de projeto {i%17}; responsável sintético {i%9}; prazo da semana {i%5}.",
      "consulta":f"busca-token-{i:04d}",
      "trechos":[f"Conversa sintética {i} item {j}: revisar prazo, orçamento, acessibilidade e plano de entrega." for j in range(32)]})
with open(sys.argv[1],"w",encoding="utf-8") as f:
    json.dump({"versao":1,"conversas":items},f,ensure_ascii=False,separators=(",",":"))
    f.write("\n")
PY

python3 - "$FIXTURES" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1])
files={}
for path in sorted(root.iterdir()):
    if path.is_file() and path.name not in ("manifest.json","sha256sums.txt"):
        files[path.name]={"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"bytes":path.stat().st_size}
manifest={"gerado_localmente":True,"duracoes_s":[30,300,1800,3600,10800],"arquivos":files}
(root/"manifest.json").write_text(json.dumps(manifest,ensure_ascii=False,indent=2,sort_keys=True)+"\n",encoding="utf-8")
(root/"sha256sums.txt").write_text("".join(f"{entry['sha256']}  {name}\n" for name,entry in files.items()),encoding="utf-8")
PY
echo "Fixtures sintéticas geradas em $FIXTURES"

#!/bin/bash
# Pré-voo local antes de cada bloco de medição.
set -euo pipefail

OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
STATE_DIR="$OMU_PERF_DIR/estado"
SHORT=false
INFRA=false
[[ "${1:-}" == "--short" ]] && SHORT=true
# Build/teste não são medição: só exigem energia, térmica, disco e memória.
[[ "${1:-}" == "--infra" ]] && { SHORT=true; INFRA=true; }

[[ -d "$STATE_DIR" ]] || { echo "Estado do loop ausente: $STATE_DIR" >&2; exit 2; }

# Remove apenas o caffeinate registrado por uma rodada anterior deste loop.
if [[ -e "$STATE_DIR/caffeinate.pid" ]]; then
    PID_ANTERIOR="$(cat "$STATE_DIR/caffeinate.pid")"
    if [[ "$PID_ANTERIOR" =~ ^[0-9]+$ ]] && kill -0 "$PID_ANTERIOR" 2>/dev/null; then
        COMANDO_ANTERIOR="$(ps -p "$PID_ANTERIOR" -o comm= | xargs)"
        if [[ "$COMANDO_ANTERIOR" == *caffeinate ]]; then
            kill -TERM "$PID_ANTERIOR" 2>/dev/null || true
        fi
    fi
fi

[[ ! -e "$STATE_DIR/STOP" ]] || { echo "STOP presente; caffeinate anterior encerrado se pertencia ao loop; não iniciar medição."; exit 20; }

BATERIA="$(pmset -g batt)"
echo "$BATERIA"
[[ "$BATERIA" == *"AC Power"* ]] || { echo "PAUSA: Mac na bateria."; exit 10; }
ENERGIA="$(pmset -g custom)"
LOW_POWER_AC="$(echo "$ENERGIA" | awk '/^AC Power:/{ac=1;next} ac && /lowpowermode/{print $2;exit}')"
echo "Low Power Mode em AC: ${LOW_POWER_AC:-desconhecido}"
[[ "${LOW_POWER_AC:-}" == "0" ]] || { echo "PAUSA: Low Power Mode ligado ou não verificável."; exit 16; }

TERMICO="$(pmset -g therm)"
echo "$TERMICO"
ALERTA_TERMICA="$(echo "$TERMICO" | /usr/bin/grep -Ei 'warning|serious|critical|throttl' | /usr/bin/grep -Ev 'No (thermal|performance) warning level' || true)"
if [[ -n "$ALERTA_TERMICA" ]]; then
    echo "PAUSA: aviso térmico ou de desempenho."
    echo "$ALERTA_TERMICA"
    exit 11
fi

LIVRE_KB="$(df -k "$HOME" | awk 'NR == 2 {print $4}')"
LIVRE_GB=$((LIVRE_KB / 1024 / 1024))
echo "Espaço livre: ${LIVRE_GB} GiB"
(( LIVRE_GB >= 30 )) || { echo "PAUSA: menos de 30 GB livres."; exit 12; }

echo "Swap: $(sysctl vm.swapusage)"
MEMORIA="$(memory_pressure -Q)"
echo "Memória: $(echo "$MEMORIA" | tail -n 2)"
PERCENTUAL_LIVRE="$(echo "$MEMORIA" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -n 1 | /usr/bin/tr -d '%')"
if [[ "$PERCENTUAL_LIVRE" =~ ^[0-9]+$ ]] && (( PERCENTUAL_LIVRE < 20 )); then
    echo "PAUSA: memória livre abaixo de 20%."
    exit 15
fi
echo "Carga: $(uptime)"
echo "Backup: $(tmutil status 2>/dev/null | head -n 4 || true)"

ATIVIDADE_NS="$(ioreg -c IOHIDSystem -d 4 | awk -F'= ' '/HIDIdleTime/ {gsub(/[^0-9]/, "", $2); print $2; exit}')"
ATIVIDADE_S=$(( ${ATIVIDADE_NS:-0} / 1000000000 ))
echo "Inatividade de entrada: ${ATIVIDADE_S}s"
if (( ATIVIDADE_S < 120 )) && [[ "$SHORT" != true ]]; then
    echo "PAUSA: a sessão está ativa; só cenários curtos podem medir com n maior."
    exit 13
fi

if [[ "$INFRA" == true ]]; then
    PROCESSOS_PESADOS=""
    OCIOSA=""
else
# Build/indexação/backup competem pelos mesmos núcleos: limite de 10%.
# Apps interativos (compositor, terminal, agente, navegador) ficam sempre um pouco ativos
# enquanto o loop roda na sessão gráfica; o A/B intercalado absorve esse ruído de fundo,
# então só pausamos se passarem de 60% ou se a CPU ociosa global cair abaixo de 70%.
AMOSTRA_TOP="$(top -l 2 -s 1 -o cpu -n 50 -stats pid,cpu,command)"
PROCESSOS_PESADOS="$(echo "$AMOSTRA_TOP" | awk '
    /^[[:space:]]*PID[[:space:]]+%CPU/ { amostra++; next }
    amostra == 2 && ($2 + 0) >= 10 && tolower($0) ~ /(xcodebuild|xcode|swift-|swiftc|swift-frontend|sourcekit|mds_stores|mdworker|fileproviderd|backupd|mediaanalysisd|photoanalysisd|searchpartyuse|papagaio|omu)/ { print }
    amostra == 2 && ($2 + 0) >= 60 && tolower($0) ~ /(chrome|terminal|zoom|windowserver|finder|chatgpt|claude|codex|opencode|cursor|zed|notion)/ { print }
')"
OCIOSA="$(echo "$AMOSTRA_TOP" | awk '/^CPU usage/ { n++; if (n == 2) { for (i = 1; i <= NF; i++) if ($i ~ /idle/) { v = $(i-1); gsub(/%/, "", v); print int(v) } } }')"
echo "CPU ociosa: ${OCIOSA:-?}%"
if [[ "$OCIOSA" =~ ^[0-9]+$ ]] && (( OCIOSA < 70 )); then
    echo "PAUSA: CPU ociosa global abaixo de 70%."
    exit 14
fi
fi
if [[ -n "$PROCESSOS_PESADOS" ]]; then
    echo "PAUSA: processo pesado ou Ōmu detectado:"
    echo "$PROCESSOS_PESADOS"
    exit 14
fi
PROCESSOS_OMU="$(ps -axo comm= | awk -F/ '$NF == "Omu" || $NF == "Papagaio" || $NF == "Loro" {print}')"
if [[ -n "$PROCESSOS_OMU" ]]; then
    echo "PAUSA: já existe um processo Ōmu/Papagaio; não medir sobre ele."
    echo "$PROCESSOS_OMU"
    exit 18
fi

nohup caffeinate -dims -t 7200 >/dev/null 2>&1 &
CAFFEINATE_PID=$!
sleep 0.2
kill -0 "$CAFFEINATE_PID" 2>/dev/null || { echo "caffeinate não iniciou; não medir." >&2; exit 17; }
echo "$CAFFEINATE_PID" > "$OMU_PERF_DIR/estado/caffeinate.pid"
echo "Pré-voo aprovado; caffeinate pid $(cat "$OMU_PERF_DIR/estado/caffeinate.pid")."

#!/bin/bash
# S1: 20 aberturas/fechamentos, imports sintéticos sequenciais e leaks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
APP_A="${1:-}"
APP_B="${2:-}"
[[ -d "$APP_A" && -d "$APP_B" ]] || { echo "Uso: $0 <aceito.app> <candidato.app>" >&2; exit 2; }
APP_A="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$APP_A")"
APP_B="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$APP_B")"
APPS_ROOT="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$OMU_PERF_DIR/apps")/"
for APP in "$APP_A" "$APP_B"; do
    case "$APP" in "$APPS_ROOT"*) ;; *) echo "As apps precisam estar em ~/OmuPerf/apps/." >&2; exit 2 ;; esac
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
    [[ "$BUNDLE_ID" == "com.papagaio.Papagaio.perf" ]] || { echo "Bundle ID inválido: $BUNDLE_ID" >&2; exit 2; }
    codesign --verify --deep --strict "$APP"
done
[[ ! -e "$OMU_PERF_DIR/estado/STOP" ]] || { echo "STOP presente; não iniciar S1." >&2; exit 20; }

# Abre/fecha 20 vezes, em processos isolados. L1 não inicia processamento.
"$SCRIPT_DIR/medir.sh" L1 "$APP_A" "$APP_B" 10 --require-idle

[[ ! -e "$OMU_PERF_DIR/estado/STOP" ]] || { echo "STOP presente; S1 encerrado após L1." >&2; exit 20; }
FIXTURES="$OMU_PERF_DIR/fixtures"
[[ -f "$FIXTURES/manifest.json" ]] || { echo "Gere as fixtures sintéticas antes de S1." >&2; exit 2; }
S1_FIXTURES=(
    ptbr_30s.wav
    ptbr_48k_stereo.wav
    ptbr_aac.m4a
    ptbr.mp3
    borda_0p5s.wav
    borda_silencio_5m.wav
    borda_ruido_30s.wav
    borda_truncado.wav
    borda_zero_bytes.wav
    borda_extensao_errada.mp3
)
ARGS=()
for nome in "${S1_FIXTURES[@]}"; do
    [[ -f "$FIXTURES/$nome" ]] || { echo "Fixture S1 ausente: $FIXTURES/$nome" >&2; exit 2; }
    ARGS+=(--fixture "$FIXTURES/$nome")
done

# S1 mantém o app aberto por 60 s após a décima importação para capturar leaks.
"$SCRIPT_DIR/medir.sh" S1 "$APP_A" "$APP_B" 1 "${ARGS[@]}"

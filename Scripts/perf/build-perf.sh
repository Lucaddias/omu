#!/bin/bash
# Build isolado da app de performance. Uso: build-perf.sh <rotulo>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OMU_PERF_DIR="${OMU_PERF_DIR:-$HOME/OmuPerf}"
STATE_DIR="$OMU_PERF_DIR/estado"
ROTULO="${1:-}"
[[ "$ROTULO" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Uso: $0 <rotulo-seguro>" >&2; exit 2; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || {
    echo "Recusei a build: o worktree tem alterações sem commit." >&2
    exit 2
}
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
GIT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
SIGNING_IDENTITY="${OMU_PERF_SIGNING_IDENTITY:--}"

DERIVED="$OMU_PERF_DIR/build/dd-$ROTULO"
DESTINO="$OMU_PERF_DIR/apps/$ROTULO.app"
LOG="$OMU_PERF_DIR/runs/build-app-$ROTULO.log"
ENTITLEMENTS="$ROOT_DIR/Config/Papagaio-Perf.entitlements"
DESTINO_PREEXISTENTE=false
[[ -f "$ENTITLEMENTS" ]] || { echo "Entitlements de perf ausentes." >&2; exit 1; }
mkdir -p "$OMU_PERF_DIR/build" "$OMU_PERF_DIR/runs" "$STATE_DIR" "$(dirname "$DESTINO")"
if [[ -e "$DESTINO" || -L "$DESTINO" ]]; then
    [[ ! -L "$DESTINO" && -d "$DESTINO" ]] || { echo "Destino não é um diretório comum: $DESTINO" >&2; exit 2; }
    DESTINO_PREEXISTENTE=true
fi
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
"$SCRIPT_DIR/ambiente.sh" >"$OMU_PERF_DIR/runs/build-app-$ROTULO-environment.log" 2>&1
CAFFEINATE_PID="$(cat "$STATE_DIR/caffeinate.pid")"

echo "xcodebuild Release; log: $LOG"
OMU_PERF_BUILD=1 /usr/bin/nohup /usr/bin/perl -e 'alarm shift; exec @ARGV' 7200 \
    xcodebuild build \
    -project "$ROOT_DIR/Loro.xcodeproj" \
    -scheme Loro \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" \
    -quiet \
    -skipPackagePluginValidation \
    -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=NO \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) OMU_PERF' \
    >"$LOG" 2>&1 &
BUILD_PID=$!
printf 'pid=%s\n' "$BUILD_PID"
if wait "$BUILD_PID"; then
    :
else
    STATUS=$?
    cat "$LOG" >&2
    exit "$STATUS"
fi

PRODUTO="$DERIVED/Build/Products/Release/Ōmu.app"
[[ -d "$PRODUTO" ]] || { echo "Ōmu.app não encontrado em $PRODUTO" >&2; cat "$LOG" >&2; exit 1; }
if [[ "$DESTINO_PREEXISTENTE" == true ]]; then
    rmdir "$DESTINO" 2>/dev/null || { echo "Destino passou a conter dados; preservado: $DESTINO" >&2; exit 2; }
fi
/usr/bin/ditto "$PRODUTO" "$DESTINO"
mkdir -p "$DESTINO/Contents/Resources"
cat > "$DESTINO/Contents/Resources/PerfBuild.json" <<EOF_BUILD
{"rotulo":"$ROTULO","commit":"$GIT_COMMIT","branch":"$GIT_BRANCH","signing_identity":"$SIGNING_IDENTITY"}
EOF_BUILD
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.papagaio.Papagaio.perf' "$DESTINO/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Ōmu Perf' "$DESTINO/Contents/Info.plist"
/usr/bin/xattr -cr "$DESTINO"

FRAMEWORKS="$DESTINO/Contents/Frameworks"
if [[ -d "$FRAMEWORKS" ]]; then
    while IFS= read -r -d '' dylib; do
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$dylib"
    done < <(find "$FRAMEWORKS" -type f -name '*.dylib' -print0)
    while IFS= read -r -d '' bundle; do
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$bundle"
    done < <(find "$FRAMEWORKS" -depth -type d \( -name '*.framework' -o -name '*.bundle' \) -print0)
fi
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$DESTINO"
codesign --verify --deep --strict --verbose=2 "$DESTINO"
TEAM_ID="$(codesign -dv --verbose=4 "$DESTINO" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
if [[ "$SIGNING_IDENTITY" != "-" && -z "$TEAM_ID" ]]; then
    echo "A identidade selecionada não aparece na assinatura final." >&2
    exit 1
fi
printf 'TeamIdentifier=%s\n' "${TEAM_ID:-ad-hoc}"
SIGNED_ENTITLEMENTS="$OMU_PERF_DIR/runs/entitlements-$ROTULO.plist"
codesign -d --entitlements :- "$DESTINO" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
plutil -lint "$SIGNED_ENTITLEMENTS"
for chave in \
    com.apple.developer.icloud-container-identifiers \
    com.apple.developer.icloud-services \
    com.apple.developer.applesignin \
    com.apple.developer.aps-environment \
    com.apple.security.network.client \
    com.apple.security.network.server \
    com.apple.security.personal-information.addressbook \
    com.apple.security.personal-information.calendars; do
    if /usr/libexec/PlistBuddy -c "Print :$chave" "$SIGNED_ENTITLEMENTS" >/dev/null 2>&1; then
        echo "Entitlement externo indevido na build de perf: $chave" >&2
        exit 1
    fi
done
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINO/Contents/Info.plist")
[[ "$BUNDLE_ID" == "com.papagaio.Papagaio.perf" ]] || { echo "Bundle ID inesperado: $BUNDLE_ID" >&2; exit 1; }
printf 'Build isolada pronta: %s\n' "$DESTINO"

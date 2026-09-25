#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/../PapagaioCore" && pwd)"
LOG_DIR="${OMU_PERF_RUNS:-${TMPDIR:-/tmp}}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/papagaio-core-tests-$(date '+%Y%m%dT%H%M%S')-$$.log"

cd "$PACKAGE_DIR"

# A recuperação só pode tocar os produtos gerados pela execução atual.
# Preserve o caminho informado pelo chamador, inclusive quando contém espaços.
BUILD_DIR="$PACKAGE_DIR/.build"
ARGUMENTOS=("$@")
for ((i = 0; i < ${#ARGUMENTOS[@]}; i++)); do
    case "${ARGUMENTOS[$i]}" in
        --scratch-path)
            if ((i + 1 < ${#ARGUMENTOS[@]})); then
                BUILD_DIR="${ARGUMENTOS[$((i + 1))]}"
            fi
            ;;
        --scratch-path=*) BUILD_DIR="${ARGUMENTOS[$i]#--scratch-path=}" ;;
    esac
done

# Em pastas sincronizadas pelo File Provider, recursos .mlmodelc podem receber
# FinderInfo. O SwiftPM copia esse atributo para o bundle de testes e o
# codesign rejeita o bundle já compilado. O File Provider regrava o atributo
# em milissegundos após `xattr -c`, então a limpeza e o assinatura têm de ser
# imediatas — e o retry do SwiftPM pode reencontrar o atributo. Primeiro
# executamos o caminho normal: qualquer falha que não seja exatamente essa
# continua sendo uma falha real.

ERRO_DE_ATRIBUTOS='resource fork, Finder information, or similar detritus not allowed'

limpar_bundle() {
    local bundle="$1"
    [[ -e "$bundle" ]] || return 0
    # Limpa em profundidade; ignora erros de xattr ausente.
    find "$bundle" -depth -exec xattr -c {} \; 2>/dev/null || true
}

assinar_e_testar() {
    # Assina só o bundle de testes da configuração atual (ignora cópias " 2"
    # órfãs) e roda imediatamente, antes do File Provider regravar FinderInfo.
    local config="$1"
    shift
    local bundle="$BUILD_DIR/out/Products/$config/PapagaioCoreTests.xctest"
    if [[ ! -d "$bundle" ]]; then
        bundle="$(find "$BUILD_DIR/out/Products" -maxdepth 2 -name 'PapagaioCoreTests.xctest' -type d | head -1)"
    fi
    [[ -d "$bundle" ]] || return 1
    limpar_bundle "$bundle"
    codesign --force --sign - --timestamp=none "$bundle" 2>/dev/null || return 1
    swift test --no-parallel --skip-build "$@"
}

if swift test --no-parallel "$@" 2>&1 | tee "$LOG_FILE"; then
    exit 0
fi

if ! grep -Fq "$ERRO_DE_ATRIBUTOS" "$LOG_FILE"; then
    exit 1
fi

PRODUTOS="$BUILD_DIR/out/Products"
if [[ ! -d "$PRODUTOS" ]]; then
    echo 'O SwiftPM reportou atributos inválidos, mas os artefatos esperados não existem.' >&2
    exit 1
fi

echo 'FinderInfo do File Provider no .xctest — limpando e assinando à mão...'
# A fonte também carrega o atributo; limpa para a próxima cópia de recursos.
find "$PACKAGE_DIR/Sources/PapagaioCore/ModelosDeDiarizacao" -depth -exec xattr -c {} \; 2>/dev/null || true

# O build anterior já compilou os testes e parou no codesign: reassina e roda.
# Nunca use --skip-build sem reassinar antes — o .xctest antigo sem assinatura
# válida produziria falha ou falso sucesso.
TENTATIVAS=5
for ((t = 1; t <= TENTATIVAS; t++)); do
    # Se o bundle foi assinado mas os testes rodaram e falharam de verdade,
    # não adianta repetir: é falha de teste, não de atributo.
    if assinar_e_testar Debug "$@" 2>&1 | tee "$LOG_FILE"; then
        exit 0
    fi
    if ! grep -Fq "$ERRO_DE_ATRIBUTOS" "$LOG_FILE"; then
        exit 1
    fi
    echo "tentativa $t de $TENTATIVAS falhou no codesign; repetindo..." >&2
    sleep 0.2
done

echo 'Não foi possível assinar o bundle de testes com atributos limpos.' >&2
exit 1

#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/../PapagaioCore" && pwd)"
LOG_FILE="$(mktemp -t papagaio-core-tests.XXXXXX)"
trap 'rm -f "$LOG_FILE"' EXIT

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
# codesign rejeita o bundle já compilado. Primeiro executamos o caminho normal:
# qualquer falha que não seja exatamente essa continua sendo uma falha real.
if swift test --no-parallel "$@" 2>&1 | tee "$LOG_FILE"; then
    exit 0
fi

ERRO_DE_ATRIBUTOS='resource fork, Finder information, or similar detritus not allowed'
if ! grep -Fq "$ERRO_DE_ATRIBUTOS" "$LOG_FILE"; then
    exit 1
fi

PRODUTOS="$BUILD_DIR/out/Products"
if [[ ! -d "$PRODUTOS" ]]; then
    echo 'O SwiftPM reportou atributos inválidos, mas os artefatos esperados não existem.' >&2
    exit 1
fi

echo 'Removendo atributos estendidos dos produtos gerados e repetindo a compilação...'
xattr -cr "$PRODUTOS"

# Nunca use --skip-build como recuperação: a falha pode ocorrer no bundle de
# recursos antes de recompilar os testes. Executar o .xctest antigo nesse caso
# produz um falso sucesso. A nova tentativa precisa compilar e assinar tudo.
swift test --no-parallel "$@"

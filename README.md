# Ōmu

> Reuniões gravadas, transcritas e transformadas em contexto acionável — com
> processamento local e espaços de equipe no iCloud.

[![CI](https://github.com/Lucaddias/Papagaio/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Lucaddias/Papagaio/actions/workflows/ci.yml)
[![Plataforma](https://img.shields.io/badge/plataforma-macOS%2026%2B-111827.svg)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-6-F05138.svg)](https://www.swift.org/)
[![Licença](https://img.shields.io/badge/licença-não%20definida-lightgrey.svg)](#licença)

O Ōmu é um aplicativo macOS para capturar ou importar áudios de reuniões,
organizar a biblioteca resultante e gerar transcrições, resumos, notas e tarefas.
O fluxo individual permanece no dispositivo; equipes usam um espaço CloudKit
compartilhado para sincronizar os dados textuais das conversas.

## Visão do produto

| O que resolve | Como aparece no app |
| --- | --- |
| Centralizar reuniões | Biblioteca com gravação, importação, busca, favoritos, pastas e lixeira. |
| Reduzir trabalho manual | Transcrição com timestamps, resumo, notas e tarefas vinculadas à conversa. |
| Preservar o contexto | Player com navegação pelos trechos da transcrição e anexos por conversa. |
| Trabalhar em grupo | Equipes com código de seis caracteres, convites do iCloud e espaço separado do perfil pessoal. |

## Recursos

- Gravação de microfone e áudio do sistema, com importação de arquivos de áudio.
- Transcrição local com Whisper, segmentação, timestamps e diarização.
- Resumo local com Qwen, incluindo temas, citações e próximos passos.
- Biblioteca pesquisável, favoritos, pastas, tarefas, anexos e lixeira com restauração.
- Perfil com Sign in with Apple e preferências visuais.
- Equipes CloudKit: criação de workspace, convite via `CKShare`, aceite de convite e entrada por código de seis caracteres.
- Sincronização de conversas textuais em espaços de equipe. Áudio e anexos continuam locais nesta etapa.

## Arquitetura

```text
Papagaio/                 Interface SwiftUI, recursos de produto e CloudKit
PapagaioCore/             Captura, persistência, transcrição, VAD e sumarização
PapagaioTests/            Testes do app e dos fluxos de persistência/equipes
Scripts/                  Bootstrap de runtimes e execução reproduzível de testes
ci_scripts/               Preparação do Xcode Cloud
docs/                     Capturas, histórico e documentação complementar
```

O app usa SwiftUI e Swift Concurrency. A biblioteca individual é persistida com
SwiftData; cada equipe recebe uma custom zone CloudKit compartilhada por
`CKShare`. O processamento de áudio e IA é executado no Mac com `whisper.cpp`,
`llama.cpp`, ONNX Runtime/Silero VAD e FluidAudio.

`Loro.xcodeproj`, o scheme `Loro`, o target `Loro` e os diretórios `Papagaio*`
são nomes técnicos mantidos por compatibilidade. O produto se chama Ōmu: o
`PRODUCT_NAME` é `Ōmu`, então a build gera `Ōmu.app` — e é o nome do arquivo do
bundle, não `CFBundleDisplayName`, que o Finder e o Dock exibem no macOS.

## Requisitos

- macOS 26 ou posterior, em Apple Silicon.
- Xcode compatível com o SDK do macOS 26 e Swift 6.
- Espaço em disco e memória suficientes para os runtimes e modelos locais.
- Conta iCloud ativa no Mac para criar, aceitar ou usar equipes.

Os frameworks de runtime não ficam versionados no Git. Isso reduz o tamanho do
repositório e mantém o clone reproduzível: o bootstrap baixa versões fixadas e
verifica o SHA-256 de cada artefato.

## Começar a desenvolver

```bash
git clone https://github.com/Lucaddias/Papagaio.git
cd Papagaio
./Scripts/bootstrap-runtimes.sh
open Loro.xcodeproj
```

No Xcode, selecione o scheme `Loro` e execute no seu Mac. Para usar equipes,
habilite o container `iCloud.com.papagaio.Papagaio` na assinatura do target e
publique o schema correspondente no CloudKit Dashboard. O registro público
`CodigoDeEquipe` precisa disponibilizar os campos `codigoDeEntrada` (consultável)
e `urlDoCompartilhamento`. A exclusão global de equipes também requer o tipo
público `EquipeExcluida`, com `equipeID` (String), `excluidaEm` (Date) e
`estadoDaExclusao` (String). Esse
marcador permite que instalações de participantes removam a cópia local ao se
conectarem novamente depois que a zona compartilhada foi apagada.

No tipo `Equipe` da zona compartilhada, publique também o campo `nomesDosParticipantes`
como `Bytes`. Ele guarda o mapa de nomes exibidos pela equipe; cada participante
altera somente o próprio nome, enquanto o proprietário pode corrigir qualquer um.

## Validar localmente

```bash
./Scripts/bootstrap-runtimes.sh
./Scripts/testa-papagaio-core.sh

xcodebuild build \
  -project Loro.xcodeproj \
  -scheme Loro \
  -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO
```

O GitHub Actions configura o bootstrap, os testes dos scripts
(`python3 -m unittest Scripts/tests/test_scripts.py`), os testes do
`PapagaioCore`, os testes do app com `PAPAGAIO_TEST_MODE=1` e o build para pull
requests direcionados a `main`. No modo de teste, o lançamento usa um host vazio; os testes continuam
responsáveis por injetar armazenamento temporário e serviços falsos.

## Limites conhecidos

- A sincronização de equipes cobre os dados textuais das conversas; mídias e
  anexos não são enviados ao CloudKit nesta versão.
- O fluxo de criação, convite, aceite e sincronização deve ser validado com
  duas contas iCloud reais antes de uma distribuição pública.

## Contribuição

1. Crie uma branch a partir de `main`.
2. Faça uma alteração pequena e verificável.
3. Rode os comandos de validação relevantes.
4. Abra um pull request explicando comportamento, testes e limites da mudança.

Evite versionar `PapagaioCore/Frameworks/`, modelos baixados, `.build/`, dados
derivados do Xcode e `.DS_Store`; eles já estão cobertos pelo `.gitignore`.

## Licença

Ainda não há uma licença de código aberto definida para este repositório. Até
uma licença ser adicionada, não assuma permissão para redistribuir o código ou
os modelos incluídos no fluxo de desenvolvimento.

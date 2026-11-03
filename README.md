# Ōmu

> Reuniões gravadas, transcritas e transformadas em contexto acionável — com
> processamento local e espaços de equipe no iCloud.

[![CI](https://github.com/Lucaddias/omu/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Lucaddias/omu/actions/workflows/ci.yml)
[![Plataforma](https://img.shields.io/badge/plataforma-macOS%2026%2B-111827.svg)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-6-F05138.svg)](https://www.swift.org/)
[![Licença](https://img.shields.io/badge/licença-MIT-blue.svg)](LICENSE)

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

## Avaliação

O `papagaio-eval run` mede a qualidade do mesmo pipeline que o app usa para um
áudio importado — Whisper com detecção de voz, filtro de repetição, agrupamento
em trechos, diarização com alinhamento por palavra e resumo do Qwen com
validação de citações — contra referências conhecidas.

Medido num MacBook Pro M5 (10 núcleos, 24 GB) em 3/11/2026. O relatório
completo, item por item, está em
[`PapagaioCore/Benchmarks/avaliacao.json`](PapagaioCore/Benchmarks/avaliacao.json).

| Etapa | Métrica | Resultado | Dados |
| --- | --- | --- | --- |
| Transcrição | WER · CER | **6,2%** · 2,3% | 100 falas reais do Multilingual LibriSpeech em português, 10 vozes, 26 min |
| Transcrição | Velocidade | **7,1× o tempo real** | as mesmas falas, sem contar a carga do modelo (0,9 s) |
| Falantes | Palavras com o falante certo | **97,6%** | 10 conversas montadas com 2 ou 3 vozes reais, 21 min |
| Falantes | Número de falantes | 10 de 10 | as mesmas conversas |
| Falantes | DER, colar de 0,25 s | 11,4% (confusão: 0,2%) | as mesmas conversas |
| Resumo | Fatos preservados | **14 de 19** | 4 reuniões roteirizadas, fala sintetizada |
| Resumo | Citações sugeridas que existem na transcrição | 11 de 12 | as mesmas reuniões |

**O que os números mostram**

- **O resumo perde quem, não o quê.** Os 5 fatos perdidos são todos de
  responsável: decisões, prazos e números aparecem, mas "a Carla entrega na
  sexta" vira "as telas serão entregues na sexta" — e, numa reunião, o relatório
  do Igor foi atribuído à Júlia. Um áudio importado chega ao Qwen sem rótulo de
  falante, então o "eu entrego" fica sem dono. O próximo passo é levar os
  rótulos da diarização ao prompt do resumo e medir de novo com esta suíte.
- **O DER é quase todo pausa, não confusão.** 11,2 dos 11,4 pontos são fala
  "perdida", e 86% desse tempo está abaixo de −45 dBFS: são pausas de respiração
  dentro das falas do audiolivro, que a referência conta como fala e o modelo
  corretamente deixa de fora. A troca de falante errada fica em 0,2%, o que bate
  com os 97,6% de palavras atribuídas certo.
- **A validação de citações tem trabalho a fazer:** uma das 12 citações
  sugeridas não existe na transcrição e foi descartada antes de chegar à tela.

**Como cada número é calculado**

- **WER e CER**: taxa de erro por palavra e por caractere, somada no corpus
  inteiro (erros totais sobre o total da referência, não a média por frase). O
  texto é normalizado como o Whisper faz fora do inglês: caixa baixa, sem
  pontuação e **com acento** — "e" e "é" contam como palavras diferentes.
- **DER**: fala perdida + falso alarme + confusão de falante, sobre o tempo de
  fala da referência, com o colar de 0,25 s do NIST nas trocas de turno e o
  mapeamento de rótulos que mais sobrepõe a referência.
- **Palavras com o falante certo**: o que a pessoa vê na transcrição. Cada
  palavra recebe o falante pelo alinhamento do app (`AlinhamentoDeFalantes` e a
  costura de vozes iguais); palavra sem falante conta como erro.
- **Fatos preservados**: cada reunião tem uma lista de decisões, responsáveis,
  prazos e números, e cada fato exige termos específicos no resumo (por exemplo
  "Bruno" + "checkout" + "quarta"). É uma checagem por termos, reproduzível e
  conferível à mão, e por isso conservadora: uma boa paráfrase pode contar como
  fato perdido.
- **Citações**: quantas das citações sugeridas pelo Qwen existem literalmente na
  transcrição. As que não existem nunca chegam à tela, porque a
  `ValidacaoDeCitacoes` as descarta.

**Limites**

- O MLS é leitura de audiolivro: fala mais limpa e pausada que uma reunião
  real, então o WER de uma reunião tende a ser maior.
- As conversas são montadas com falas de pessoas diferentes, sem sobreposição
  de vozes e sem ruído — o caso fácil da diarização.
- As reuniões são fala sintetizada, numa voz só: a suíte mede o resumo, não a
  separação de falantes.

**Reproduzir**

```bash
./Scripts/bootstrap-runtimes.sh
./Scripts/avaliacao/preparar-dados.py          # ~150 MB em ~/OmuPerf/fixtures/avaliacao
cd PapagaioCore
swift run -c release papagaio-eval run --modelos <pasta com ggml-large-v3.bin e Qwen_Qwen3.5-9B-Q4_K_M.gguf>
```

Os pesos são os mesmos que o app baixa; as URLs e os SHA-256 fixados estão em
`PapagaioCore/Sources/PapagaioCore/Runtime/Preflight.swift`.

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
git clone https://github.com/Lucaddias/omu.git
cd omu
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

O código do Ōmu é distribuído sob a [licença MIT](LICENSE). Os modelos baixados
pelo app e pelos scripts (Whisper, Qwen, Silero VAD e os modelos de diarização)
não fazem parte deste repositório e seguem as licenças dos seus autores.

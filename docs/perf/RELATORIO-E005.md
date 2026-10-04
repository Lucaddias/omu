# Relatório — fechamento do E005 e versão 1.3.3

Data: 2026-10-04 · Branch `perf/loop-20260924` · Aceito: tag `perf/aceito-E005` (`fc778f6`)

## Resultado

O E005 fechou como **MELHOROU**. O app processa reuniões usando menos memória, sem ficar mais lento e com a mesma saída. A versão 1.3.3 leva ao `main` os dois experimentos aceitos do loop de performance (E004 e E005), duas correções de qualidade e a remoção da tradução automática.

## O que melhorou

### E005 — menos RAM durante o processamento

O Whisper ficava carregado durante toda a diarização, que é a fase de maior pico. Agora ele é descarregado uma vez, depois de transcrever todos os canais (`53f7a1a`). O processamento também passa a declarar atividade iniciada pelo usuário, para o macOS não frear o app com a janela oculta (`fc778f6`).

Medido contra o aceito anterior (E004), mesma fixture, saídas idênticas nos dois lados:

| Cenário | Pico de RAM antes | Pico de RAM depois | Variação | p | Tempo total |
|---|---|---|---|---|---|
| P1 — reunião de 30 s | 4,09 GB | 3,75 GB | −8,4% | 0,004 | 44,0 → 44,3 s (neutro) |
| P2 — 5 min (métrica primária) | 5,01 GB | 4,28 GB | −14,5% | 0,004 | 77,3 → 76,8 s (neutro) |
| P3 — 60 min | 5,16 GB | 4,29 GB | −16,7% | 0,05 | 540,0 → 540,0 s (neutro) |
| P4 — fila de 3 arquivos | 4,32 GB | 4,02 GB | −6,9% | 0,05 | 136,6 → 135,8 s (neutro) |
| P5 — reunião em inglês | 3,82 GB | 3,75 GB | −1,7% (neutro) | 0,05 | 37,2 → 36,8 s (neutro) |
| P6 — 30 min, janela oculta | 4,61 GB | 3,80 GB | −17,6% | 0,05 | 355,2 → 294,0 s (−17,3%) |

Abertura (L1), ociosidade (O1) e estresse (S1) ficaram neutros, sem regressão.

### E004 — biblioteca grande abre mais rápido (aceito em 29/09)

A listagem deixou de decodificar as palavras de cada trecho; elas são lidas ao abrir o detalhe (`738b566`).

| Biblioteca | Tempo até interativo | Pico de RAM |
|---|---|---|
| 200 conversas | 1,06 → 0,66 s (−37,9%) | 86,1 → 61,1 MB (−29,0%) |
| 1.000 conversas | 3,59 → 1,71 s (−52,3%) | 241,7 → 79,8 MB (−67,0%) |

### Correções de qualidade encontradas durante o E005

- **VAD (`dfe6556`).** O Silero é um modelo recorrente, mas só recebia os quadros acima do limiar de energia. Isso comprimia o tempo, fragmentava fala contínua e perdia palavras. Agora ele recebe todos os quadros em ordem e só corta após 3 s de silêncio. WER nas fixtures: 30 s de 37,7% para 11,5%; 5 min de 36,9% para 14,6%.
- **Idioma do resumo (`94bf1e8`).** Sem tradução, uma reunião em inglês saía com resumo em português. O resumo agora segue o idioma detectado. Na fixture em inglês, transcrição e resumo saem em inglês, com WER 0%.

Essas duas correções mudam a saída do app. Elas foram aplicadas igualmente à base e à candidata antes das medições finais, então os números de RAM e tempo acima não são efeito delas.

### Também nesta versão

- Tradução automática removida (`4411410`): transcrição e resumo ficam no idioma falado.
- Harness de performance em `Scripts/perf/` e sonda `PerfProbe`, que só existe em builds compiladas com `OMU_PERF`.

## Portões

- Testes no commit final: PapagaioCore 220/220, app 109/109.
- Build Release do commit final compilada, assinada ad hoc e verificada.
- P1 na build final: saída idêntica à referência, pico 3,77 GB.
- Saídas idênticas entre base e candidata em P1–P6 (IDs e datas normalizados).
- Nenhum hang novo; todos os picos abaixo do teto de 16 GB.

## Limites da evidência

- **Duas hipóteses num experimento.** O P6 sem a asserção de atividade mostrou 1 hang em cada amostra da candidata (base: 2/0/0). A asserção (H12 da especificação) entrou para remover isso, sem pré-registro próprio. Com ela: 0 hangs em 3 amostras.
- **P1, P2, P3 e P5 foram medidos sem H12.** P4 e P6 usaram o pacote completo, com código de produto igual ao do commit final.
- **O ganho de tempo do P6 veio de amostras só do lado candidato**, comparadas com a base medida cerca de duas horas antes, não intercaladas.
- **Smoke P5 da build final não rodou.** O pré-voo reprovou por CPU ociosa abaixo de 70% durante 20 min (processos do sistema e um job do usuário).
- **L1, O1 e S1 não foram repetidos** depois das correções de VAD e idioma; esses cenários não transcrevem.
- **Q1 (fechar) e C1 (micro-benchmarks) não foram medidos** nesta rodada.
- **Ganho acumulado desde a base não foi medido.** Os percentuais de E004 e E005 são contra o aceito anterior de cada um e não devem ser somados.
- **Qualidade absoluta ainda é fraca em áudio longo:** WER 18,5% e DER 19,5% na fixture de 60 min, iguais na base e na candidata.

## Estado atual

- Rodadas: 5 — 2 MELHOROU (E004, E005), 3 NEUTRO (E001b, E002, E003, todos revertidos).
- Build aceita: `~/OmuPerf/apps/aceito.app` → `E005-final.app`.
- O pico de RAM do pipeline está na diarização (~4,3 GB em 5 min), não no resumo do Qwen (~1,9 GB).
- RAM do Qwen (H21): bloqueado. Só há a quantização Q4_K_M local e não existe portão semântico para validar um resumo diferente.
- App Store: bloqueado por assinatura. Este Mac não tem identidade de codesign válida nem provisioning profile para `com.papagaio.Papagaio`.
- A regra do loop "sem push/merge no main" foi suspensa para esta publicação por pedido direto do usuário.

## Próximos passos

1. Recalibrar A/A com o E005 como base e medir o ganho acumulado desde `perf/base-sem-traducao`.
2. Repetir P5, L1, O1 e S1 na build final quando o Mac estiver ocioso.
3. Próximas hipóteses: salvar incremental no SwiftData (H04), tirar migrações do primeiro frame (H03), AEC em streaming (H05).

Dados brutos em `~/OmuPerf/runs/`; diário completo em `~/OmuPerf/estado/DIARIO.md`.

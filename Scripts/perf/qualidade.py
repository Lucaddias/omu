#!/usr/bin/env python3
"""WER, DER aproximado, timestamps e resumo para fixtures locais sintéticas."""
from __future__ import annotations

import argparse
import difflib
import itertools
import json
import math
import os
import re
import unicodedata
from pathlib import Path
from typing import Any, Optional


def tokens(texto: str) -> list[str]:
    normalizado = unicodedata.normalize("NFKC", texto).casefold()
    return re.findall(r"\w+", normalizado, flags=re.UNICODE)


def distancia_edicao(a: list[str], b: list[str]) -> int:
    anterior = list(range(len(b) + 1))
    for i, token_a in enumerate(a, 1):
        atual = [i]
        for j, token_b in enumerate(b, 1):
            atual.append(min(
                anterior[j] + 1,
                atual[j - 1] + 1,
                anterior[j - 1] + (token_a != token_b),
            ))
        anterior = atual
    return anterior[-1]


def taxa_erro_palavras(referencia: str, hipotese: str) -> float:
    palavras = tokens(referencia)
    return distancia_edicao(palavras, tokens(hipotese)) / max(1, len(palavras))


def wer_por_janelas_silenciosas(
    ref: list[dict[str, Any]], hyp: list[dict[str, Any]], duracao: float, janela: float = 30
) -> float:
    """Soma WER por ciclos sintéticos de 30 s separados por silêncio conhecido."""
    if not ref or not hyp or janela <= 0:
        return taxa_erro_palavras(
            " ".join(texto_trecho(item) for item in ref),
            " ".join(texto_trecho(item) for item in hyp),
        )
    quantidade = max(1, int(math.ceil(duracao / janela)))
    ref_por_janela: list[list[str]] = [[] for _ in range(quantidade)]
    hyp_por_janela: list[list[str]] = [[] for _ in range(quantidade)]
    for segmento in ref:
        inicio = campo_tempo(segmento, "inicio_s", "start")
        indice = min(quantidade - 1, max(0, int(inicio // janela)))
        ref_por_janela[indice].extend(tokens(texto_trecho(segmento)))

    for segmento in hyp:
        palavras = [
            palavra for palavra in segmento.get("palavras", [])
            if isinstance(palavra, dict) and texto_trecho(palavra).strip()
        ]
        if palavras:
            # O pipeline pode agrupar palavras de ciclos de 30 s num só
            # Trecho. Distribua cada palavra pelo timestamp próprio para que
            # um segmento que atravesse a fronteira não infle o WER da janela.
            for palavra in palavras:
                inicio = campo_tempo(palavra, "start", "inicio_s")
                indice = min(quantidade - 1, max(0, int(inicio // janela)))
                hyp_por_janela[indice].extend(tokens(texto_trecho(palavra)))
        else:
            inicio = campo_tempo(segmento, "start", "inicio_s")
            indice = min(quantidade - 1, max(0, int(inicio // janela)))
            hyp_por_janela[indice].extend(tokens(texto_trecho(segmento)))
    erros = 0
    total_referencia = 0
    for palavras_ref, palavras_hyp in zip(ref_por_janela, hyp_por_janela):
        erros += distancia_edicao(palavras_ref, palavras_hyp)
        total_referencia += len(palavras_ref)
    return erros / max(1, total_referencia)


def texto_trecho(trecho: dict[str, Any]) -> str:
    return str(trecho.get("texto", trecho.get("text", "")))


def campo_tempo(trecho: dict[str, Any], nome: str, alternativo: str) -> float:
    return float(trecho.get(nome, trecho.get(alternativo, 0.0)) or 0.0)


def alinhar_timestamps(ref: list[dict[str, Any]], hyp: list[dict[str, Any]]) -> dict[str, Any]:
    if not ref:
        return {"max_desvio_ms": 0.0, "pares": 0, "desvios_ms": []}

    # O pipeline pode agrupar todas as palavras de uma fala num único Trecho.
    # Quando os dois lados têm palavras temporizadas, alinhe cada frase do
    # gabarito às palavras por conteúdo e compare os limites acústicos delas.
    palavras = [
        palavra
        for trecho in hyp
        for palavra in trecho.get("palavras", [])
        if isinstance(palavra, dict) and texto_trecho(palavra).strip()
    ]
    if palavras:
        desvios: list[float] = []
        cursor = 0
        for esperado in ref:
            inicio_ref = campo_tempo(esperado, "inicio_s", "start")
            fim_ref = campo_tempo(esperado, "fim_s", "end")
            while cursor < len(palavras) and campo_tempo(palavras[cursor], "end", "fim_s") < inicio_ref - 2.0:
                cursor += 1
            fim_candidatos = cursor
            while (
                fim_candidatos < len(palavras)
                and campo_tempo(palavras[fim_candidatos], "start", "inicio_s") <= fim_ref + 2.0
            ):
                fim_candidatos += 1

            ref_tokens = tokens(texto_trecho(esperado))
            hyp_tokens: list[str] = []
            origem_palavra: list[int] = []
            for indice in range(cursor, fim_candidatos):
                tokens_palavra = tokens(texto_trecho(palavras[indice]))
                hyp_tokens.extend(tokens_palavra)
                origem_palavra.extend([indice] * len(tokens_palavra))

            matches = difflib.SequenceMatcher(
                a=ref_tokens, b=hyp_tokens, autojunk=False
            ).get_matching_blocks()
            indices_alinhados = sorted({
                origem_palavra[posicao]
                for bloco in matches
                for posicao in range(bloco.b, bloco.b + bloco.size)
            })
            if not indices_alinhados:
                continue

            primeira = palavras[indices_alinhados[0]]
            ultima = palavras[indices_alinhados[-1]]
            inicio_hyp = campo_tempo(primeira, "start", "inicio_s")
            fim_hyp = campo_tempo(ultima, "end", "fim_s")
            desvios.extend((abs(inicio_ref - inicio_hyp) * 1000, abs(fim_ref - fim_hyp) * 1000))
            cursor = indices_alinhados[-1] + 1

        return {
            "max_desvio_ms": max(desvios, default=0.0),
            "pares": len(desvios) // 2,
            "desvios_ms": desvios,
            "nivel": "palavra",
        }

    # Compatibilidade com dumps antigos sem metadados temporais por palavra.
    desvios = []
    cursor = 0
    for esperado in ref:
        texto_ref = set(tokens(texto_trecho(esperado)))
        if not texto_ref or not hyp:
            continue
        candidatos = []
        for indice in range(cursor, len(hyp)):
            texto_hyp = set(tokens(texto_trecho(hyp[indice])))
            intersecao = len(texto_ref & texto_hyp)
            semelhanca = intersecao / max(1, len(texto_ref | texto_hyp))
            candidatos.append((semelhanca, indice))
        if not candidatos:
            continue
        semelhanca, indice = max(candidatos, key=lambda item: (item[0], -item[1]))
        if semelhanca <= 0:
            continue
        atual = hyp[indice]
        inicio_ref = campo_tempo(esperado, "inicio_s", "start")
        fim_ref = campo_tempo(esperado, "fim_s", "end")
        inicio_hyp = campo_tempo(atual, "start", "inicio_s")
        fim_hyp = campo_tempo(atual, "end", "fim_s")
        desvios.extend((abs(inicio_ref - inicio_hyp) * 1000, abs(fim_ref - fim_hyp) * 1000))
        cursor = indice + 1
    return {
        "max_desvio_ms": max(desvios, default=0.0),
        "pares": len(desvios) // 2,
        "desvios_ms": desvios,
        "nivel": "trecho",
    }


def falante(segmento: dict[str, Any]) -> Optional[str]:
    valor = segmento.get("falante", segmento.get("speaker"))
    return str(valor) if valor not in (None, "") else None


def der_aproximado(ref: list[dict[str, Any]], hyp: list[dict[str, Any]], duracao: float) -> Optional[dict[str, Any]]:
    if not ref or not hyp:
        return None
    passos = max(1, int(duracao * 10))
    def frames_por_falante(segmentos: list[dict[str, Any]], referencia: bool) -> list[Optional[str]]:
        frames: list[Optional[str]] = [None] * passos
        if not referencia:
            palavras = [
                palavra
                for trecho in segmentos
                for palavra in trecho.get("palavras", [])
                if isinstance(palavra, dict)
                and palavra.get("falanteAcustico") not in (None, "")
            ]
            if palavras:
                for palavra in palavras:
                    voz = str(palavra["falanteAcustico"])
                    inicio = campo_tempo(palavra, "start", "inicio_s")
                    fim = campo_tempo(palavra, "end", "fim_s")
                    primeiro = max(0, int(inicio * 10))
                    ultimo = min(passos, int(math.ceil(fim * 10)))
                    for indice in range(primeiro, ultimo):
                        if frames[indice] is None:
                            frames[indice] = voz
                return frames

        for segmento in segmentos:
            voz = falante(segmento)
            if voz is None:
                continue
            if referencia:
                inicio = campo_tempo(segmento, "inicio_s", "start")
                fim = campo_tempo(segmento, "fim_s", "end")
            else:
                inicio = campo_tempo(segmento, "start", "inicio_s")
                fim = campo_tempo(segmento, "end", "fim_s")
            primeiro = max(0, int(inicio * 10))
            ultimo = min(passos, int(math.ceil(fim * 10)))
            for indice in range(primeiro, ultimo):
                if frames[indice] is None:
                    frames[indice] = voz
        return frames

    frames_ref = frames_por_falante(ref, True)
    frames_hyp = frames_por_falante(hyp, False)
    pares = [(r, h) for r, h in zip(frames_ref, frames_hyp) if r is not None and h is not None]

    refs = sorted({x for x in frames_ref if x is not None})
    hyps = sorted({x for x in frames_hyp if x is not None})
    melhor = 0
    melhor_mapa: dict[str, str] = {}
    limite = min(len(refs), len(hyps))
    for escolhidos in itertools.permutations(refs, limite):
        mapa = dict(zip(hyps[:limite], escolhidos))
        acertos = sum(mapa.get(h) == r for r, h in pares)
        if acertos > melhor:
            melhor, melhor_mapa = acertos, mapa

    referencia_vozeada = sum(x is not None for x in frames_ref)
    if referencia_vozeada == 0:
        return None
    erros = 0
    falsos = 0
    perdidos = 0
    confusoes = 0
    for r, h in zip(frames_ref, frames_hyp):
        if r is None and h is not None:
            falsos += 1
        elif r is not None and h is None:
            perdidos += 1
        elif r is not None and h is not None and melhor_mapa.get(h) != r:
            confusoes += 1
    erros = falsos + perdidos + confusoes
    return {
        "der": erros / referencia_vozeada,
        "quadros_com_referencia": referencia_vozeada,
        "falsos": falsos,
        "perdidos": perdidos,
        "confusoes": confusoes,
        "mapeamento": melhor_mapa,
    }


def validar_resumo(resumo: Any, texto_transcricao: str) -> dict[str, Any]:
    if not isinstance(resumo, dict):
        return {"valido": False, "motivos": ["resumo ausente ou inválido"], "citacoes_invalidas": 0}
    obrigatorias = ("titulo", "visaoGeral", "temas", "citacoes", "proximosPassos")
    faltando = [campo for campo in obrigatorias if campo not in resumo]
    tipos_invalidos = [
        campo for campo in ("temas", "citacoes", "proximosPassos")
        if campo in resumo and not isinstance(resumo[campo], list)
    ]
    citacoes = resumo.get("citacoes", [])
    texto_normalizado = tokens(texto_transcricao)
    citacoes_invalidas = 0
    for citacao in citacoes if isinstance(citacoes, list) else []:
        frase = tokens(str(citacao.get("texto", ""))) if isinstance(citacao, dict) else []
        existe = any(texto_normalizado[i:i + len(frase)] == frase for i in range(len(texto_normalizado))) if frase else False
        palavras_validas = 8 <= len(frase) <= 32
        if not existe or not palavras_validas:
            citacoes_invalidas += 1
    motivos = []
    if faltando:
        motivos.append("faltam campos: " + ", ".join(faltando))
    if tipos_invalidos:
        motivos.append("tipo inválido: " + ", ".join(tipos_invalidos))
    if citacoes_invalidas:
        motivos.append(f"{citacoes_invalidas} citações inválidas")
    if isinstance(citacoes, list) and len(citacoes) > 3:
        motivos.append("mais de três citações")
    return {
        "valido": not motivos,
        "motivos": motivos,
        "citacoes_invalidas": citacoes_invalidas,
        "quantidade_citacoes": len(citacoes) if isinstance(citacoes, list) else 0,
    }


def assinatura_exata(arquivo: dict[str, Any]) -> dict[str, Any]:
    """Ignora IDs e metadados voláteis; compara conteúdo, falantes e tempos."""
    trechos = []
    for trecho in arquivo.get("trechos", []):
        palavras = []
        for palavra in trecho.get("palavras", []):
            palavras.append({
                chave: palavra.get(chave)
                for chave in ("start", "end", "texto", "confianca", "noSpeechProb", "falanteAcustico")
            })
        trechos.append({
            "start": trecho.get("start"),
            "end": trecho.get("end"),
            "texto": trecho.get("texto"),
            "speaker": trecho.get("speaker"),
            "palavras": palavras,
        })
    resumo = arquivo.get("resumo")
    if isinstance(resumo, dict):
        resumo = {
            chave: resumo.get(chave)
            for chave in ("titulo", "visaoGeral", "temas", "citacoes", "proximosPassos")
        }
    return {"trechos": trechos, "resumo": resumo}


def carregar(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def exigir_escopo(path: Path, raiz: Path, descricao: str) -> None:
    caminho = path.resolve()
    base = raiz.resolve()
    if os.path.commonpath((str(caminho), str(base))) != str(base):
        raise ValueError(f"{descricao} precisa estar dentro de {base}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--referencia", required=True, type=Path)
    parser.add_argument("--saida-arquivo", required=True, type=Path, help="dump JSON do Arquivo produzido pelo app")
    parser.add_argument("--baseline", type=Path, help="resultado anterior desta ferramenta")
    parser.add_argument("--baseline-arquivo", type=Path, help="dump do Arquivo aceito para comparação exata")
    parser.add_argument("--exigir-identica", action="store_true")
    parser.add_argument("--resultado", type=Path, required=True)
    args = parser.parse_args()

    exigir_escopo(args.referencia, Path.home() / "OmuPerf" / "fixtures", "gabarito")
    exigir_escopo(args.saida_arquivo, Path.home() / "OmuPerf" / "runs", "dump de saída")
    exigir_escopo(args.resultado, Path.home() / "OmuPerf" / "runs", "resultado")
    if args.baseline:
        exigir_escopo(args.baseline, Path.home() / "OmuPerf" / "runs", "baseline de qualidade")
    if args.baseline_arquivo:
        exigir_escopo(args.baseline_arquivo, Path.home() / "OmuPerf" / "runs", "baseline de saída")

    referencia = carregar(args.referencia)
    arquivo = carregar(args.saida_arquivo)
    segmentos_ref = referencia.get("trechos", referencia.get("segments", []))
    segmentos_hyp = arquivo.get("trechos", [])
    texto_ref = referencia.get("texto") or " ".join(texto_trecho(s) for s in segmentos_ref)
    texto_hyp = " ".join(texto_trecho(s) for s in segmentos_hyp)
    duracao = float(referencia.get("duracao_s", max((campo_tempo(s, "fim_s", "end") for s in segmentos_ref), default=0)))
    wer = wer_por_janelas_silenciosas(
        segmentos_ref,
        segmentos_hyp,
        duracao,
        float(referencia.get("janela_comparacao_s", 30)),
    ) if segmentos_ref and segmentos_hyp else taxa_erro_palavras(texto_ref, texto_hyp)
    der = der_aproximado(segmentos_ref, segmentos_hyp, duracao)
    timestamps = alinhar_timestamps(segmentos_ref, segmentos_hyp)
    resumo = validar_resumo(arquivo.get("resumo"), texto_hyp)
    resultado: dict[str, Any] = {
        "wer": wer,
        "der": der["der"] if der else None,
        "der_detalhes": der,
        "timestamps": timestamps,
        "resumo": resumo,
    }

    exata = None
    if args.baseline_arquivo:
        arquivo_base = carregar(args.baseline_arquivo)
        exata = assinatura_exata(arquivo) == assinatura_exata(arquivo_base)
        resultado["saida_identica"] = exata
    if args.exigir_identica and not args.baseline_arquivo:
        parser.error("--exigir-identica requer --baseline-arquivo")

    aceito = resumo["valido"]
    if args.baseline:
        base = carregar(args.baseline)
        tolerancias = referencia.get("tolerancias", {})
        limite_wer = float(base["wer"]) + float(tolerancias.get("wer_delta", 0.005))
        base_der = base.get("der")
        limite_der = (float(base_der) + float(tolerancias.get("der_delta", 0.01))) if base_der is not None else None
        limite_timestamp = float(tolerancias.get("timestamp_ms", 100))
        aceito = (
            wer <= limite_wer
            and (der is None or limite_der is None or der["der"] <= limite_der)
            and timestamps["max_desvio_ms"] <= limite_timestamp
            and resumo["valido"]
        )
        resultado["gates"] = {
            "wer_max": limite_wer,
            "der_max": limite_der,
            "timestamp_ms_max": limite_timestamp,
            "aceito": aceito,
        }
    if args.exigir_identica:
        aceito = aceito and exata is True
        resultado.setdefault("gates", {})["saida_identica"] = bool(exata)

    resultado["aceito"] = aceito
    args.resultado.parent.mkdir(parents=True, exist_ok=True)
    args.resultado.write_text(json.dumps(resultado, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(resultado, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if aceito is not False else 1


if __name__ == "__main__":
    raise SystemExit(main())

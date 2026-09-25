#!/usr/bin/env python3
"""Estatística A/B para o loop local; usa apenas a biblioteca padrão."""
from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import random
import statistics
import sys
from pathlib import Path
from typing import Any


def percentil90(valores: list[float]) -> float:
    ordenados = sorted(valores)
    return ordenados[max(0, math.ceil(len(ordenados) * 0.90) - 1)]


def mediana(valores: list[float]) -> float:
    return statistics.median(valores)


def cv_robusto(valores: list[float]) -> float:
    centro = mediana(valores)
    if centro == 0:
        return 0.0
    mad = mediana([abs(x - centro) for x in valores])
    return 1.4826 * mad / abs(centro)


def desvio_absoluto_medio_da_mediana(valores: list[float]) -> float:
    centro = mediana(valores)
    return mediana([abs(x - centro) for x in valores])


def ranks_com_empates(valores: list[float]) -> list[float]:
    ordenados = sorted(enumerate(valores), key=lambda item: item[1])
    ranks = [0.0] * len(valores)
    inicio = 0
    while inicio < len(ordenados):
        fim = inicio + 1
        while fim < len(ordenados) and ordenados[fim][1] == ordenados[inicio][1]:
            fim += 1
        rank_medio = ((inicio + 1) + fim) / 2
        for indice in range(inicio, fim):
            ranks[ordenados[indice][0]] = rank_medio
        inicio = fim
    return ranks


def mann_whitney_p(a: list[float], b: list[float], direcao: str) -> float:
    """p unilateral: hipótese alternativa de B menor/maior que A."""
    n_a, n_b = len(a), len(b)
    todos = a + b
    ranks = ranks_com_empates(todos)
    soma_b = sum(ranks[n_a:])
    u_b = soma_b - n_b * (n_b + 1) / 2
    media = n_a * n_b / 2

    if n_a <= 10 and n_b <= 10:
        combinacoes = math.comb(n_a + n_b, n_b)
        favoraveis = 0
        epsilon = 1e-9
        for indices in itertools.combinations(range(n_a + n_b), n_b):
            u = sum(ranks[i] for i in indices) - n_b * (n_b + 1) / 2
            if direcao == "lower" and u <= u_b + epsilon:
                favoraveis += 1
            elif direcao == "higher" and u >= u_b - epsilon:
                favoraveis += 1
        return favoraveis / combinacoes

    grupos: dict[float, int] = {}
    for valor in todos:
        grupos[valor] = grupos.get(valor, 0) + 1
    correcao = sum(t**3 - t for t in grupos.values())
    total = n_a + n_b
    variancia = n_a * n_b / 12 * ((total + 1) - correcao / (total * (total - 1)))
    if variancia <= 0:
        return 1.0
    desvio = math.sqrt(variancia)
    ajuste = 0.5 if direcao == "lower" else -0.5
    z = (u_b - media + ajuste) / desvio
    cdf = 0.5 * (1 + math.erf(z / math.sqrt(2)))
    return min(1.0, max(0.0, cdf if direcao == "lower" else 1 - cdf))


def bootstrap_razao(a: list[float], b: list[float], iteracoes: int = 20_000) -> tuple[float, float]:
    rng = random.Random(20260924)
    razoes = []
    for _ in range(iteracoes):
        centro_a = mediana([rng.choice(a) for _ in a])
        centro_b = mediana([rng.choice(b) for _ in b])
        if centro_a != 0:
            razoes.append(centro_b / centro_a)
    if not razoes:
        return (float("nan"), float("nan"))
    razoes.sort()
    return (
        razoes[max(0, math.ceil(len(razoes) * 0.025) - 1)],
        razoes[min(len(razoes) - 1, math.ceil(len(razoes) * 0.975) - 1)],
    )


def carregar(path: Path, cenario: str) -> list[dict[str, Any]]:
    path = path.resolve()
    runs = (Path.home() / "OmuPerf" / "runs").resolve()
    if os.path.commonpath((str(path), str(runs))) != str(runs):
        raise ValueError("amostras precisam estar dentro de ~/OmuPerf/runs/")
    linhas = []
    with path.open(encoding="utf-8") as arquivo:
        for numero, linha in enumerate(arquivo, 1):
            try:
                item = json.loads(linha)
            except json.JSONDecodeError as erro:
                raise ValueError(f"{path}:{numero}: JSON inválido: {erro}") from erro
            if item.get("cenario") != cenario or item.get("classe") != "amostra":
                continue
            if (
                item.get("status") != "ok"
                or item.get("contaminada_swap")
                or item.get("contaminada_thermal")
            ):
                continue
            linhas.append(item)
    return linhas


def valores_por_lado(registros: list[dict[str, Any]], metrica: str) -> tuple[list[float], list[float]]:
    saida: dict[str, list[float]] = {"A": [], "B": []}
    for item in registros:
        valor: Any = item.get("metricas", {})
        for componente in metrica.split("."):
            valor = valor.get(componente) if isinstance(valor, dict) else None
        if isinstance(valor, list):
            lado = item.get("lado")
            if lado in saida:
                saida[lado].extend(
                    float(elemento) for elemento in valor
                    if isinstance(elemento, (int, float)) and math.isfinite(float(elemento))
                )
            continue
        if isinstance(valor, (int, float)) and math.isfinite(float(valor)):
            lado = item.get("lado")
            if lado in saida:
                saida[lado].append(float(valor))
    return saida["A"], saida["B"]


def analisar(registros: list[dict[str, Any]], metrica: str, piso_mde: float, direcao: str) -> dict[str, Any]:
    a, b = valores_por_lado(registros, metrica)
    if not a or not b:
        return {"metrica": metrica, "n_a": len(a), "n_b": len(b), "veredito": "INCONCLUSIVO"}

    med_a, med_b = mediana(a), mediana(b)
    razao = med_b / med_a if med_a else (1.0 if med_b == 0 else None)
    cv = cv_robusto(a)
    mde = max(piso_mde, 2 * cv)
    ic = bootstrap_razao(a, b)
    if not all(math.isfinite(x) for x in ic):
        ic = (None, None)
    p_melhora = mann_whitney_p(a, b, direcao)
    p_piora = mann_whitney_p(a, b, "higher" if direcao == "lower" else "lower")
    efeito_melhora = ((1 - razao) if direcao == "lower" else (razao - 1)) if razao is not None else -math.inf
    efeito_piora = ((razao - 1) if direcao == "lower" else (1 - razao)) if razao is not None else math.inf

    if p_melhora <= 0.05 and efeito_melhora >= mde:
        veredito = "MELHOROU"
    elif p_piora <= 0.05 and efeito_piora >= mde:
        veredito = "PIOROU"
    else:
        veredito = "NEUTRO"

    resultado = {
        "metrica": metrica,
        "a": {"mediana": med_a, "p90": percentil90(a), "n": len(a)},
        "b": {"mediana": med_b, "p90": percentil90(b), "n": len(b)},
        "mad_a": desvio_absoluto_medio_da_mediana(a),
        "mad_b": desvio_absoluto_medio_da_mediana(b),
        "razao_b_a": razao,
        "ic95_razao": list(ic),
        "p_melhora": p_melhora,
        "p_piora": p_piora,
        "cv_robusto_a": cv,
        "mde": mde,
        "veredito": veredito,
    }
    if metrica == "main_hangs" and max(b) > max(a):
        resultado["guardrail_falhou"] = True
        resultado["veredito"] = "PIOROU"
    return resultado


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("amostras", type=Path)
    parser.add_argument("--cenario", required=True)
    parser.add_argument("--metrica", required=True)
    parser.add_argument("--piso-mde", type=float, default=0.03)
    parser.add_argument("--direcao", choices=("lower", "higher"), default="lower")
    parser.add_argument("--guardrail", action="append", default=[], metavar="METRICA:PISO")
    parser.add_argument("--saida", type=Path)
    args = parser.parse_args()

    if args.saida:
        destino = args.saida.resolve()
        runs = (Path.home() / "OmuPerf" / "runs").resolve()
        if os.path.commonpath((str(destino), str(runs))) != str(runs):
            parser.error("--saida precisa estar dentro de ~/OmuPerf/runs/")
        args.saida.parent.mkdir(parents=True, exist_ok=True)

    registros = carregar(args.amostras, args.cenario)
    primario = analisar(registros, args.metrica, args.piso_mde, args.direcao)
    guardrails = []
    for especificacao in args.guardrail:
        nome, piso = especificacao.split(":", 1)
        resultado = analisar(registros, nome, float(piso), "lower")
        guardrails.append(resultado)
        if resultado.get("veredito") == "PIOROU":
            primario["veredito"] = "PIOROU"
        elif resultado.get("veredito") == "INCONCLUSIVO" and primario.get("veredito") != "PIOROU":
            primario["veredito"] = "INCONCLUSIVO"
    relatorio = {
        "cenario": args.cenario,
        "metrica_primaria": primario,
        "guardrails": guardrails,
        "veredito": primario["veredito"],
        "n_amostras_validas": len(registros),
    }
    texto = json.dumps(relatorio, ensure_ascii=False, indent=2, sort_keys=True)
    if args.saida:
        args.saida.write_text(texto + "\n", encoding="utf-8")
    print("A × B: mediana · p90 · n · razão · IC95% · p")
    m = primario
    if "a" in m and "b" in m:
        razao_texto = "indefinida" if m["razao_b_a"] is None else f"{m['razao_b_a']:.6g}"
        print(
            f"{m['a']['mediana']:.6g}/{m['a']['p90']:.6g}/{m['a']['n']} × "
            f"{m['b']['mediana']:.6g}/{m['b']['p90']:.6g}/{m['b']['n']} · "
            f"{razao_texto} · {m['ic95_razao']} · p={m['p_melhora']:.6g}"
        )
    print(f"Veredito: {relatorio['veredito']}")
    if not registros:
        print("Sem amostras válidas; verifique status e contaminação.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

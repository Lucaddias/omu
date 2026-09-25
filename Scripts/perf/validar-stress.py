#!/usr/bin/env python3
"""Applies quality, leak and memory guardrails to one S1 ABBA run."""
from __future__ import annotations

import json
import math
import os
import statistics
import sys
from pathlib import Path
from typing import Any


def inside(path: Path, root: Path) -> bool:
    return os.path.commonpath((str(path.resolve()), str(root.resolve()))) == str(root.resolve())


def numeric(rows: list[dict[str, Any]], key: str) -> list[float]:
    values: list[float] = []
    for row in rows:
        value = row.get("metricas", {}).get(key)
        if not isinstance(value, (int, float)) or not math.isfinite(float(value)):
            raise ValueError(f"métrica ausente/inválida: {key}")
        values.append(float(value))
    return values


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("uso: validar-stress.py <amostras.jsonl> <resultado.json> <n>")
    source, destination, n_text = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    runs = Path.home() / "OmuPerf" / "runs"
    if not inside(source, runs) or not inside(destination, runs):
        raise SystemExit("amostras e resultado precisam ficar em ~/OmuPerf/runs/")
    n = int(n_text)
    rows = [
        json.loads(line)
        for line in source.read_text(encoding="utf-8").splitlines()
        if json.loads(line).get("cenario") == "S1"
        and json.loads(line).get("classe") == "amostra"
    ]
    sides: dict[str, list[dict[str, Any]]] = {}
    for side in ("A", "B"):
        selected = [row for row in rows if row.get("lado") == side]
        if len(selected) != n or any(row.get("status") != "ok" for row in selected):
            raise ValueError(f"S1 inconclusivo: amostras inválidas no lado {side}")
        if any(row.get("metricas", {}).get("import_count") != 10 for row in selected):
            raise ValueError(f"S1 incompleto: lado {side} não importou dez arquivos em cada amostra")
        if any(row.get("metricas", {}).get("leaks_status") != "ok" for row in selected):
            raise ValueError(f"S1 inconclusivo: leaks não foi concluído no lado {side}")
        sides[side] = selected

    errors_a = sum(numeric(sides["A"], "import_errors"))
    errors_b = sum(numeric(sides["B"], "import_errors"))
    scenario_errors_a = sum(numeric(sides["A"], "scenario_errors"))
    scenario_errors_b = sum(numeric(sides["B"], "scenario_errors"))
    leaks_a = sum(numeric(sides["A"], "leaks_count"))
    leaks_b = sum(numeric(sides["B"], "leaks_count"))
    leaked_bytes_a = sum(numeric(sides["A"], "leaks_bytes"))
    leaked_bytes_b = sum(numeric(sides["B"], "leaks_bytes"))
    peak_a = numeric(sides["A"], "pico_footprint_bytes")
    peak_b = numeric(sides["B"], "pico_footprint_bytes")
    growth_a = numeric(sides["A"], "crescimento_footprint_bytes")
    growth_b = numeric(sides["B"], "crescimento_footprint_bytes")

    absolute_limit = 16 * 1024**3
    growth_limit = statistics.median(growth_a) + 0.03 * statistics.median(peak_a)
    accepted = (
        errors_b <= errors_a
        and scenario_errors_b <= scenario_errors_a
        and leaks_b <= leaks_a
        and leaked_bytes_b <= leaked_bytes_a
        and max(peak_a) < absolute_limit
        and max(peak_b) < absolute_limit
        and statistics.median(growth_b) <= growth_limit
    )
    report = {
        "aceito": accepted,
        "import_errors_a": errors_a,
        "import_errors_b": errors_b,
        "scenario_errors_a": scenario_errors_a,
        "scenario_errors_b": scenario_errors_b,
        "leaks_a": leaks_a,
        "leaks_b": leaks_b,
        "leaks_bytes_a": leaked_bytes_a,
        "leaks_bytes_b": leaked_bytes_b,
        "pico_footprint_a_bytes": max(peak_a),
        "pico_footprint_b_bytes": max(peak_b),
        "crescimento_footprint_a_mediano_bytes": statistics.median(growth_a),
        "crescimento_footprint_b_mediano_bytes": statistics.median(growth_b),
        "limite_crescimento_b_bytes": growth_limit,
        "limite_absoluto_bytes": absolute_limit,
        "n_a": len(sides["A"]),
        "n_b": len(sides["B"]),
    }
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    if not accepted:
        raise SystemExit("S1 reprovado: novos erros/leaks ou crescimento de memória acima dos guardrails")
    return 0


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Applies quality, leak and memory guardrails to one S1 ABBA run."""
from __future__ import annotations

import json
import math
import os
import re
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


def leak_roots(row: dict[str, Any]) -> dict[str, int]:
    """Separate app leak roots from the OS-owned linkd shortcut XPC cycle.

    `leaks` reports the full unrooted graph, including cycles inside an XPC
    connection to linkd when that service has no process. The number of those
    nodes changes between identical app runs, so preserve it as a diagnostic
    while comparing rooted app allocations for the S1 regression gate.
    """
    event_path = Path(row["eventos"])
    log_path = event_path.parent / f"leaks-amostra-{row['lado']}-{row['indice']}.log"
    if not log_path.is_file():
        raise ValueError(f"relatório leaks ausente: {log_path}")

    app_count = app_bytes = linkd_count = linkd_bytes = 0
    resumo = False
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    tamanho = re.compile(r"^(\s*)(\d+)\s+\(([\d,.]+)\s*(bytes|B|K|KB|M|MB)?\)\s+ROOT (LEAK|CYCLE):")
    root_rows = []
    for line in lines:
        if re.search(r"Process \d+: \d+ leaks? for [\d,]+ total leaked bytes\.", line, re.IGNORECASE):
            resumo = True
        match = tamanho.match(line)
        if match:
            root_rows.append((len(match.group(1)), match, line))
    if not resumo:
        raise ValueError(f"relatório leaks sem resumo: {log_path}")
    if not root_rows and row.get("metricas", {}).get("leaks_count", 0) != 0:
        raise ValueError(f"relatório leaks sem raízes interpretáveis: {log_path}")
    nivel_raiz = min((indent for indent, _, _ in root_rows), default=0)
    for indent, match, line in root_rows:
        if indent != nivel_raiz:
            continue
        quantidade = int(match.group(2))
        valor = float(match.group(3).replace(",", ""))
        unidade = (match.group(4) or "bytes").upper()
        fator = 1 if unidade in {"BYTES", "B"} else 1024 if unidade in {"K", "KB"} else 1024**2
        bytes_raiz = int(round(valor * fator))
        classe = match.group(5)
        ciclo_linkd = (
            classe == "CYCLE"
            and 'Connection: "com.apple.linkd.autoShortcut" [no process]' in line
        )
        if ciclo_linkd:
            linkd_count += quantidade
            linkd_bytes += bytes_raiz
        else:
            app_count += quantidade
            app_bytes += bytes_raiz

    return {
        "app_root_count": app_count,
        "app_root_bytes": app_bytes,
        "linkd_cycle_count": linkd_count,
        "linkd_cycle_bytes_rounded": linkd_bytes,
    }


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
    termination_timeouts: dict[str, int] = {}
    for side in ("A", "B"):
        selected = [row for row in rows if row.get("lado") == side]
        statuses = {"ok", "s1-termination-timeout"}
        if len(selected) != n or any(row.get("status") not in statuses for row in selected):
            raise ValueError(f"S1 inconclusivo: amostras inválidas no lado {side}")
        if any(row.get("contaminada_swap") or row.get("contaminada_thermal") for row in selected):
            raise ValueError(f"S1 inconclusivo: amostra contaminada no lado {side}")
        if any(row.get("metricas", {}).get("import_count") != 10 for row in selected):
            raise ValueError(f"S1 incompleto: lado {side} não importou dez arquivos em cada amostra")
        if any(row.get("metricas", {}).get("leaks_status") != "ok" for row in selected):
            raise ValueError(f"S1 inconclusivo: leaks não foi concluído no lado {side}")
        sides[side] = selected
        termination_timeouts[side] = sum(row.get("status") == "s1-termination-timeout" for row in selected)

    errors_a = sum(numeric(sides["A"], "import_errors"))
    errors_b = sum(numeric(sides["B"], "import_errors"))
    scenario_errors_a = sum(numeric(sides["A"], "scenario_errors"))
    scenario_errors_b = sum(numeric(sides["B"], "scenario_errors"))
    hangs_a = sum(numeric(sides["A"], "main_hangs"))
    hangs_b = sum(numeric(sides["B"], "main_hangs"))
    leaks_raw_a = sum(numeric(sides["A"], "leaks_count"))
    leaks_raw_b = sum(numeric(sides["B"], "leaks_count"))
    leaked_bytes_raw_a = sum(numeric(sides["A"], "leaks_bytes"))
    leaked_bytes_raw_b = sum(numeric(sides["B"], "leaks_bytes"))
    roots_a = [leak_roots(row) for row in sides["A"]]
    roots_b = [leak_roots(row) for row in sides["B"]]
    leaks_a = sum(item["app_root_count"] for item in roots_a)
    leaks_b = sum(item["app_root_count"] for item in roots_b)
    leaked_bytes_a = sum(item["app_root_bytes"] for item in roots_a)
    leaked_bytes_b = sum(item["app_root_bytes"] for item in roots_b)
    linkd_cycles_a = sum(item["linkd_cycle_count"] for item in roots_a)
    linkd_cycles_b = sum(item["linkd_cycle_count"] for item in roots_b)
    linkd_bytes_a = sum(item["linkd_cycle_bytes_rounded"] for item in roots_a)
    linkd_bytes_b = sum(item["linkd_cycle_bytes_rounded"] for item in roots_b)
    peak_a = numeric(sides["A"], "pico_footprint_bytes")
    peak_b = numeric(sides["B"], "pico_footprint_bytes")
    growth_a = numeric(sides["A"], "crescimento_footprint_bytes")
    growth_b = numeric(sides["B"], "crescimento_footprint_bytes")

    absolute_limit = 16 * 1024**3
    growth_limit = statistics.median(growth_a) + 0.03 * statistics.median(peak_a)
    accepted = (
        errors_b <= errors_a
        and scenario_errors_b <= scenario_errors_a
        and hangs_b <= hangs_a
        and termination_timeouts["B"] <= termination_timeouts["A"]
        and termination_timeouts["A"] == 0
        and termination_timeouts["B"] == 0
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
        "main_hangs_a": hangs_a,
        "main_hangs_b": hangs_b,
        "leaks_total_reported_a": leaks_raw_a,
        "leaks_total_reported_b": leaks_raw_b,
        "leaks_total_bytes_reported_a": leaked_bytes_raw_a,
        "leaks_total_bytes_reported_b": leaked_bytes_raw_b,
        "termination_timeouts_a": termination_timeouts["A"],
        "termination_timeouts_b": termination_timeouts["B"],
        "absolute_termination_gate_passed": termination_timeouts["A"] == 0 and termination_timeouts["B"] == 0,
        "app_root_leaks_a": leaks_a,
        "app_root_leaks_b": leaks_b,
        "app_root_leak_bytes_a": leaked_bytes_a,
        "app_root_leak_bytes_b": leaked_bytes_b,
        "system_linkd_cycle_nodes_a": linkd_cycles_a,
        "system_linkd_cycle_nodes_b": linkd_cycles_b,
        "system_linkd_cycle_bytes_rounded_a": linkd_bytes_a,
        "system_linkd_cycle_bytes_rounded_b": linkd_bytes_b,
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

#!/usr/bin/env python3
"""Runs fixture quality gates and A/B tolerance checks for C2 outputs."""
from __future__ import annotations

import json
import hashlib
import os
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any


def inside(path: Path, root: Path) -> bool:
    return os.path.commonpath((str(path.resolve()), str(root.resolve()))) == str(root.resolve())


def median(values: list[float]) -> float:
    if not values:
        raise ValueError("amostras de qualidade ausentes")
    return statistics.median(values)


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("uso: validar-c2.py <amostras.jsonl> <dataset>")
    samples_path, dataset = Path(sys.argv[1]), Path(sys.argv[2])
    root_runs = (Path.home() / "OmuPerf" / "runs").resolve()
    root_fixtures = (Path.home() / "OmuPerf" / "fixtures").resolve()
    if not inside(samples_path, root_runs) or not inside(dataset, root_runs):
        raise SystemExit("amostras/dataset precisam ficar em ~/OmuPerf/runs/")
    quality_script = Path(__file__).with_name("qualidade.py")
    rows = [json.loads(line) for line in samples_path.read_text(encoding="utf-8").splitlines() if line]
    rows = [row for row in rows if row.get("cenario_base") == "C2"]
    references = {
        "macro.whisper.transcrever": root_fixtures / "ptbr_30s.gabarito.json",
        "macro.qwen.resumir": root_fixtures / "macro-qwen-400.gabarito.json",
        "macro.qwen.traduzir": root_fixtures / "macro-traducao-40.gabarito.json",
    }
    manifest_path = root_fixtures / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    registry = manifest.get("arquivos", {})
    for reference in references.values():
        entry = registry.get(reference.name)
        if entry is None:
            raise ValueError(f"gabarito C2 não aparece no manifesto: {reference.name}")
        digest = hashlib.sha256(reference.read_bytes()).hexdigest()
        if digest != entry.get("sha256"):
            raise ValueError(f"hash do gabarito C2 divergiu: {reference.name}")
    quality_dir = dataset / "qualidade-c2"
    quality_dir.mkdir(parents=True, exist_ok=True)
    output_results: dict[str, dict[str, list[dict[str, Any]]]] = {
        case: {"A": [], "B": []} for case in references
    }

    for case, reference in references.items():
        if not reference.is_file():
            raise ValueError(f"gabarito C2 ausente: {reference}")
        samples = [row for row in rows if row.get("caso") == case]
        if not samples:
            raise ValueError(f"C2 sem amostras de qualidade para {case}")
        for row in samples:
            side = row.get("lado")
            if side not in ("A", "B") or row.get("status") != "ok":
                raise ValueError(f"C2 com amostra inválida em {case}")
            if row.get("contaminada_swap") or row.get("contaminada_thermal"):
                raise ValueError(f"C2 contaminado em {case}; descarte e refaça o bloco")
            artifact = Path(row.get("quality_artifact_path", ""))
            if not inside(artifact, root_runs) or not artifact.is_file():
                raise ValueError(f"artefato de qualidade ausente/fora de runs: {artifact}")
            result_path = quality_dir / f"{case.replace('.', '-')}-{side}-{row['indice']}.json"
            process = subprocess.run([
                sys.executable, str(quality_script),
                "--referencia", str(reference),
                "--saida-arquivo", str(artifact),
                "--resultado", str(result_path),
            ], capture_output=True, text=True)
            if process.returncode != 0:
                raise ValueError(f"quality gate falhou em {case} {side}{row['indice']}: {process.stderr.strip()}")
            output_results[case][side].append(json.loads(result_path.read_text(encoding="utf-8")))

    tolerance_report: dict[str, Any] = {}
    accepted = True
    for case, sides in output_results.items():
        a, b = sides["A"], sides["B"]
        if not a or not b or len(a) != len(b):
            raise ValueError(f"C2 inconclusivo em {case}: A/B sem o mesmo n válido")
        measurements = [row for row in rows if row.get("caso") == case]
        peak_a = [int(row["metricas"]["peak_rss_bytes"]) for row in measurements if row.get("lado") == "A" and row["metricas"].get("peak_rss_bytes")]
        peak_b = [int(row["metricas"]["peak_rss_bytes"]) for row in measurements if row.get("lado") == "B" and row["metricas"].get("peak_rss_bytes")]
        if len(peak_a) != len(a) or len(peak_b) != len(b):
            raise ValueError(f"C2 inconclusivo em {case}: pico RSS ausente")
        rss_a, rss_b = median([float(x) for x in peak_a]), median([float(x) for x in peak_b])
        rss_limit = rss_a * 1.03
        rss_absolute_limit = 16 * 1024**3
        reference = json.loads(references[case].read_text(encoding="utf-8"))
        tolerances = reference.get("tolerancias", {})
        wer_a = median([float(item["wer"]) for item in a])
        wer_b = median([float(item["wer"]) for item in b])
        wer_limit = wer_a + float(tolerances.get("wer_delta", 0.005))
        ders_a = [float(item["der"]) for item in a if item.get("der") is not None]
        ders_b = [float(item["der"]) for item in b if item.get("der") is not None]
        if bool(ders_a) != bool(ders_b) or len(ders_a) != len(ders_b):
            raise ValueError(f"C2 inconclusivo em {case}: DER ausente em um dos lados")
        der_limit = median(ders_a) + float(tolerances.get("der_delta", 0.01)) if ders_a else None
        der_b = median(ders_b) if ders_b else None
        timestamp_limit = float(tolerances.get("timestamp_ms", 100))
        timestamp_b = max(float(item["timestamps"]["max_desvio_ms"]) for item in b)
        summary_ok = all(item.get("resumo", {}).get("valido", False) for item in b)
        case_ok = wer_b <= wer_limit and (der_limit is None or der_b <= der_limit)
        case_ok = case_ok and timestamp_b <= timestamp_limit and summary_ok
        case_ok = case_ok and rss_b <= rss_limit and max(peak_a) < rss_absolute_limit and max(peak_b) < rss_absolute_limit
        tolerance_report[case] = {
            "n_a": len(a), "n_b": len(b),
            "wer_a_mediana": wer_a, "wer_b_mediana": wer_b, "wer_limite": wer_limit,
            "der_a_mediana": median(ders_a) if ders_a else None,
            "der_b_mediana": der_b, "der_limite": der_limit,
            "timestamp_b_max_ms": timestamp_b, "timestamp_limite_ms": timestamp_limit,
            "resumos_b_validos": summary_ok,
            "rss_a_mediano_bytes": rss_a, "rss_b_mediano_bytes": rss_b,
            "rss_b_limite_bytes": rss_limit, "rss_absoluto_limite_bytes": rss_absolute_limit,
            "aceito": case_ok,
        }
        accepted = accepted and case_ok

    report = {"cenario": "C2", "aceito": accepted, "casos": tolerance_report}
    destination = dataset / "qualidade-c2.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if accepted else 1


if __name__ == "__main__":
    raise SystemExit(main())

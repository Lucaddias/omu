#!/usr/bin/env python3
"""Portão EXATO do Q2 para builds anteriores a ef39c1e, cujos trechos sintéticos
recebiam UUID aleatório por execução: remove só as chaves `id` dos trechos e
exige JSON canônico byte a byte igual entre todas as amostras A e B."""
import glob, hashlib, json, os, sys

pasta, destino = sys.argv[1:]

def sem_ids(valor):
    if isinstance(valor, dict):
        return {k: sem_ids(v) for k, v in valor.items() if k != "id"}
    if isinstance(valor, list):
        return [sem_ids(v) for v in valor]
    return valor

relatorio = {}
for prefixo in ("qwen-summary", "qwen-translation"):
    hashes = {}
    for arquivo in sorted(glob.glob(f"{pasta}/{prefixo}-*.json")):
        canonico = json.dumps(sem_ids(json.load(open(arquivo, encoding="utf-8"))),
                              ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        hashes[os.path.basename(arquivo)] = hashlib.sha256(canonico.encode()).hexdigest()
    lados = {nome.rsplit("-", 2)[-2] for nome in hashes}
    relatorio[prefixo] = {"arquivos": hashes, "lados": sorted(lados),
                          "identicos": len(set(hashes.values())) == 1 and lados == {"A", "B"}}
relatorio["aceito"] = all(v["identicos"] for k, v in relatorio.items() if k != "aceito")
json.dump(relatorio, open(destino, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print(json.dumps({k: (v["identicos"] if isinstance(v, dict) else v) for k, v in relatorio.items()}))
sys.exit(0 if relatorio["aceito"] else 1)

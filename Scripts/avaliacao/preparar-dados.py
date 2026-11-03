#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["pyarrow==18.1.0"]
# ///
"""Monta os dados do `papagaio-eval run` em ~/OmuPerf/fixtures/avaliacao.

Três suítes, todas reproduzíveis a partir deste script:

- transcricao: falas reais do Multilingual LibriSpeech em português (split de
  teste, revisão fixada e SHA-256 conferido), com a transcrição de referência.
- conversas: falas de pessoas diferentes do mesmo split, coladas em sequência
  com pausas curtas. Os turnos são conhecidos ao centésimo de segundo, o que
  permite medir a diarização sem anotação manual.
- reunioes: os roteiros de Scripts/avaliacao/reunioes.json, sintetizados com a
  voz pt-BR Luciana do macOS (`say`), para medir o resumo contra fatos conhecidos.

Uso:  Scripts/avaliacao/preparar-dados.py [--destino DIR] [--falas N] [--conversas N]
Precisa de `uv`, `ffmpeg` e da voz Luciana do macOS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import wave
from collections import defaultdict
from pathlib import Path

import pyarrow.parquet as pq

RAIZ = Path(__file__).resolve().parents[2]
TAXA = 16_000

# Revisão fixada: o SHA-256 abaixo só vale para este commit do dataset.
MLS_REVISAO = "2e83e61823b4c47dcbcb1980bb88601274127609"
MLS_URL = (
    "https://huggingface.co/datasets/facebook/multilingual_librispeech/resolve/"
    f"{MLS_REVISAO}/portuguese/test-00000-of-00001.parquet"
)
MLS_SHA256 = "73317666498b6889851a72bea52b116c4744691dda4c8e66b8bd98af0496ba90"


def baixar_mls(destino: Path) -> Path:
    arquivo = destino / "brutos" / "mls-pt-test.parquet"
    if not arquivo.exists():
        arquivo.parent.mkdir(parents=True, exist_ok=True)
        print(f"baixando MLS pt (teste, ~59 MB) de {MLS_URL}")
        parcial = arquivo.with_suffix(".parcial")
        urllib.request.urlretrieve(MLS_URL, parcial)
        parcial.rename(arquivo)
    obtido = hashlib.sha256(arquivo.read_bytes()).hexdigest()
    if obtido != MLS_SHA256:
        arquivo.unlink()
        sys.exit(f"SHA-256 do MLS não confere: {obtido}")
    return arquivo


def para_wav(origem: Path, destino: Path, aparar: bool) -> None:
    """Decodifica para WAV 16 kHz mono e, se pedido, apara o silêncio das pontas.

    Aparar importa para a diarização: o silêncio no começo e no fim de cada
    fala contaria como "fala da referência" que o modelo, com razão, não marca.
    Os 0,1 s mantidos protegem o ataque das consoantes fracas — sem eles o "f"
    de "foice" sumia e o Whisper perdia a palavra. A suíte de transcrição não
    apara nada: ali o áudio vai como o dataset publica.
    """
    filtros = []
    if aparar:
        ponta = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1"
        filtros = ["-af", f"{ponta},areverse,{ponta},areverse"]
    subprocess.run(
        [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(origem),
            "-ac", "1", "-ar", str(TAXA), "-sample_fmt", "s16", *filtros,
            str(destino),
        ],
        check=True,
    )


def quadros(wav_path: Path) -> bytes:
    with wave.open(str(wav_path), "rb") as w:
        assert w.getframerate() == TAXA and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())


def gravar_wav(caminho: Path, pcm: bytes) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(caminho), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TAXA)
        w.writeframes(pcm)


def duracao(pcm: bytes) -> float:
    return len(pcm) / 2 / TAXA


def colar(falas: list[tuple[str, bytes]], semente: int) -> tuple[bytes, list[dict]]:
    """Cola as falas com pausas de 0,3 a 0,8 s e devolve os turnos."""
    sorteio = random.Random(semente)
    pcm = bytearray()
    turnos = []
    for indice, (falante, audio) in enumerate(falas):
        if indice:
            pcm += b"\x00\x00" * int(sorteio.uniform(0.3, 0.8) * TAXA)
        inicio = duracao(pcm)
        pcm += audio
        turnos.append({"falante": falante, "inicio": round(inicio, 3), "fim": round(duracao(pcm), 3)})
    return bytes(pcm), turnos


def preparar_mls(parquet: Path, destino: Path, n_falas: int, n_conversas: int, tmp: Path):
    tabela = pq.read_table(parquet, columns=["id", "speaker_id", "transcript", "audio"]).to_pylist()
    por_falante: dict[str, list[dict]] = defaultdict(list)
    for linha in sorted(tabela, key=lambda l: l["id"]):
        por_falante[linha["speaker_id"]].append(linha)
    falantes = sorted(por_falante)

    def decodificar(linha: dict, aparar: bool) -> bytes:
        bruto = tmp / f"{linha['id']}.opus"
        bruto.write_bytes(linha["audio"]["bytes"])
        wav = tmp / f"{linha['id']}.wav"
        para_wav(bruto, wav, aparar)
        return quadros(wav)

    # Rodízio entre falantes: as N falas cobrem todas as vozes por igual,
    # em vez de N falas do primeiro falante em ordem alfabética.
    filas = {f: list(por_falante[f]) for f in falantes}
    transcricao = []
    while len(transcricao) < n_falas and any(filas.values()):
        for falante in falantes:
            if len(transcricao) == n_falas or not filas[falante]:
                continue
            linha = filas[falante].pop(0)
            pcm = decodificar(linha, aparar=False)
            caminho = f"transcricao/{linha['id']}.wav"
            gravar_wav(destino / caminho, pcm)
            transcricao.append({
                "id": linha["id"], "audio": caminho,
                "duracao": round(duracao(pcm), 3), "referencia": linha["transcript"],
            })
    print(f"transcrição: {len(transcricao)} falas de {len(falantes)} falantes")

    # Conversas com falas que não estão na suíte de transcrição: alternam 2 e
    # 3 falantes, 8 turnos, sem o mesmo falante duas vezes seguidas.
    conversas = []
    for k in range(n_conversas):
        quantos = 2 if k % 2 == 0 else 3
        escolhidos = [falantes[(k * 3 + j) % len(falantes)] for j in range(quantos)]
        ordem = [escolhidos[t % quantos] for t in range(8)]
        falas = []
        referencia = []
        for falante in ordem:
            if not filas[falante]:
                sys.exit(f"falante {falante} sem falas sobrando para a conversa {k}")
            linha = filas[falante].pop(0)
            falas.append((falante, decodificar(linha, aparar=True)))
            referencia.append(linha["transcript"])
        pcm, turnos = colar(falas, semente=k)
        caminho = f"conversas/conversa-{k + 1:02d}.wav"
        gravar_wav(destino / caminho, pcm)
        conversas.append({
            "id": f"conversa-{k + 1:02d}", "audio": caminho, "duracao": round(duracao(pcm), 3),
            "referencia": " ".join(referencia), "turnos": turnos,
        })
    print(f"conversas: {len(conversas)} (2 e 3 falantes, 8 turnos cada)")
    return transcricao, conversas


def preparar_reunioes(destino: Path, tmp: Path) -> list[dict]:
    roteiros = json.loads((RAIZ / "Scripts/avaliacao/reunioes.json").read_text(encoding="utf-8"))
    reunioes = []
    for semente, reuniao in enumerate(roteiros["reunioes"]):
        falas = []
        for indice, (pessoa, texto) in enumerate(reuniao["turnos"]):
            sintetizado = tmp / f"{reuniao['id']}-{indice}.wav"
            subprocess.run(
                ["say", "-v", roteiros["voz"], "--file-format=WAVE",
                 f"--data-format=LEI16@{TAXA}", "-o", str(sintetizado), texto],
                check=True,
            )
            aparado = tmp / f"{reuniao['id']}-{indice}-aparado.wav"
            para_wav(sintetizado, aparado, aparar=True)
            falas.append((pessoa, quadros(aparado)))
        pcm, turnos = colar(falas, semente=100 + semente)
        caminho = f"reunioes/{reuniao['id']}.wav"
        gravar_wav(destino / caminho, pcm)
        reunioes.append({
            "id": reuniao["id"], "audio": caminho, "duracao": round(duracao(pcm), 3),
            "referencia": " ".join(texto for _, texto in reuniao["turnos"]),
            "turnos": turnos, "fatos": reuniao["fatos"],
        })
    print(f"reuniões: {len(reunioes)} sintetizadas")
    return reunioes


def main() -> None:
    argumentos = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    argumentos.add_argument("--destino", type=Path, default=Path.home() / "OmuPerf/fixtures/avaliacao")
    argumentos.add_argument("--falas", type=int, default=100)
    argumentos.add_argument("--conversas", type=int, default=10)
    opcoes = argumentos.parse_args()

    for ferramenta in ("ffmpeg", "say"):
        if not shutil.which(ferramenta):
            sys.exit(f"{ferramenta} não encontrado")

    destino: Path = opcoes.destino
    parquet = baixar_mls(destino)
    for pasta in ("transcricao", "conversas", "reunioes"):
        shutil.rmtree(destino / pasta, ignore_errors=True)

    with tempfile.TemporaryDirectory() as pasta_temporaria:
        tmp = Path(pasta_temporaria)
        transcricao, conversas = preparar_mls(parquet, destino, opcoes.falas, opcoes.conversas, tmp)
        reunioes = preparar_reunioes(destino, tmp)

    manifesto = {
        "fontes": {
            "transcricao": f"Multilingual LibriSpeech, português, split de teste (facebook/multilingual_librispeech@{MLS_REVISAO[:7]}, CC BY 4.0)",
            "conversas": "falas do mesmo split, de falantes diferentes, coladas com pausas de 0,3 a 0,8 s",
            "reunioes": "roteiros de Scripts/avaliacao/reunioes.json sintetizados com a voz Luciana (pt-BR) do macOS",
        },
        "transcricao": transcricao,
        "conversas": conversas,
        "reunioes": reunioes,
    }
    (destino / "manifesto.json").write_text(json.dumps(manifesto, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"manifesto: {destino / 'manifesto.json'}")


if __name__ == "__main__":
    main()

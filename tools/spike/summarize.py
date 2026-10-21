#!/usr/bin/env python3
"""Turns build/spike-results/results.jsonl (from tools/spike/run_on_device.sh) into the markdown tables in docs/spike-dictation.md.

    python3 tools/spike/summarize.py [results.jsonl]
Word error rate here normalises case, punctuation and digits (see SpikeMath.normalize), so formatting is not counted as an error
but spoken-form numbers written as digits are compared as words.
"""
import json
import sys
from collections import OrderedDict


def load(path):
    rows = OrderedDict()
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line:
            row = json.loads(line)
            rows[(row["engine"], row["tag"])] = row
    return rows


def fmt(value, digits=0):
    return "n/a" if value is None else f"{value:,.{digits}f}"


def first_utterance_ms(row):
    """The first call that returned text (a clip an engine answers with nothing says nothing about its first-call cost)."""
    for clip in row["clips"]:
        if clip["hypothesis"].strip():
            return clip["ms"]
    return row["coldFirstUtteranceMs"]


def wer_percent(errors, words):
    return 100 * errors / words if words else 0


def table(rows, header, lines):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(str(cell) for cell in line) + " |" for line in lines]
    return "\n".join(out)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "build/spike-results/results.jsonl"
    rows = load(path)
    engines = list(OrderedDict.fromkeys(engine for engine, _ in rows))
    first = next(iter(rows.values()))
    print(f"Device model `{first['device']}`, iOS {first['systemVersion']}.\n")

    print("### Speed and memory (warm pass: 36 clips of 0.8 to 5.9 s, run twice; the second pass is timed)\n")
    lines = []
    for engine in engines:
        warm = rows.get((engine, "warm")) or rows.get((engine, "cold"))
        if warm.get("error"):
            lines.append([f"`{engine}`", f"FAILED: {warm['error'][:80]}", "", "", "", "", "", ""])
            continue
        long = warm.get("long") or {}
        lines.append([f"`{engine}`", fmt(warm["latencyP50Ms"]), fmt(warm["latencyP95Ms"]), fmt(warm["rtfP50"], 3),
                      fmt(long.get("ms")), fmt(long.get("rtf"), 4), fmt(warm["peakMB"]), fmt(warm["peakResidentMB"])])
    print(table(rows, ["Engine", "p50 ms", "p95 ms", "RTF p50", "60.8 s clip ms", "60.8 s RTF", "Peak footprint MB", "Peak resident MB"], lines))

    print("\n### Thermal state at the start of each run\n")
    lines = []
    for engine in engines:
        for tag in ("cold", "warm"):
            row = rows.get((engine, tag))
            if row:
                lines.append([f"`{engine}`", tag, row["thermalBefore"], row["thermalAfter"], fmt(row.get("coolWaitSeconds", 0))])
    print(table(rows, ["Engine", "Pass", "Thermal before", "Thermal after", "Waited to cool (s)"], lines))

    print("\n### Start-up\n")
    lines = []
    for engine in engines:
        cold, warm = rows.get((engine, "cold")), rows.get((engine, "warm"))
        if not cold or cold.get("error"):
            continue
        lines.append([f"`{engine}`", fmt(cold["downloadMs"]), fmt(cold["loadMs"]),
                      fmt(cold["downloadMs"] + cold["loadMs"]), fmt(warm["loadMs"]) if warm else "n/a",
                      fmt(first_utterance_ms(warm)) if warm else "n/a"])
    print(table(rows, ["Engine", "Download+prep ms (first run)", "Load ms (first run)", "Download+load ms", "Load ms (relaunch)",
                       "First utterance ms (relaunch)"], lines))

    print("\n### Accuracy (36 clips, 3 voices x 12 phrases)\n")
    lines = []
    for engine in engines:
        row = rows.get((engine, "warm")) or rows.get((engine, "cold"))
        if row.get("error"):
            continue
        clips = row["clips"]
        words = sum(c["referenceWords"] for c in clips)
        errors = sum(c["substitutions"] + c["deletions"] + c["insertions"] for c in clips)
        exact = sum(1 for c in clips if c["substitutions"] + c["deletions"] + c["insertions"] == 0)
        empty = sum(1 for c in clips if not c["hypothesis"].strip())
        long = row.get("long")
        long_wer = wer_percent(long["substitutions"] + long["deletions"] + long["insertions"], long["referenceWords"]) if long else None
        lines.append([f"`{engine}`", f"{wer_percent(errors, words):.1f}", f"{exact}/{len(clips)}", empty,
                      f"{100 * row['formattedRate']:.0f}", fmt(long_wer, 1)])
    print(table(rows, ["Engine", "WER %", "Exact clips", "Empty outputs", "Capital + final punctuation %", "60.8 s clip WER %"], lines))


if __name__ == "__main__":
    main()

"""Benchmark zyaml vs PyYAML vs ruamel.yaml across file sizes and iteration counts."""

import argparse
import json
import time

import yaml as pyyaml
from ruamel.yaml import YAML as RuamelYAML

import zyaml

SIZES = {
    "small": lambda: "name: Alice\nage: 30\ncity: Tokyo\n",
    "medium": lambda: _gen_medium(),
    "large": lambda: _gen_large(),
    "xlarge": lambda: _gen_xlarge(),
}

ITERS = {
    "small": 10000,
    "medium": 1000,
    "large": 100,
    "xlarge": 10,
}


def _gen_medium() -> str:
    lines = []
    for i in range(100):
        lines.append(f"user_{i}:")
        lines.append(f"  name: user_{i}")
        lines.append(f"  age: {20 + (i % 60)}")
        lines.append(f"  email: user_{i}@example.com")
        lines.append(f"  active: {'true' if i % 2 == 0 else 'false'}")
    return "\n".join(lines) + "\n"


def _gen_large() -> str:
    lines = []
    for i in range(1000):
        lines.append(f"item_{i}:")
        lines.append(f"  id: {i}")
        lines.append(f"  name: Item Number {i}")
        lines.append(f"  price: {i * 1.99:.2f}")
        lines.append("  tags:")
        for j in range(5):
            lines.append(f"    - tag_{i}_{j}")
        lines.append("  metadata:")
        lines.append(f"    created: 2025-01-{(j % 28) + 1:02d}")
        lines.append(f"    updated: 2025-02-{(j % 28) + 1:02d}")
        lines.append(f"    views: {i * 100}")
    return "\n".join(lines) + "\n"


def _gen_xlarge() -> str:
    lines = []
    for i in range(10000):
        lines.append(f"record_{i}:")
        lines.append(f"  id: {i}")
        lines.append(f"  name: Record {i} with some longer text to pad the size")
        lines.append(f"  value: {i * 3.14159:.5f}")
        lines.append(f"  enabled: {'true' if i % 3 == 0 else 'false'}")
        lines.append(f"  category: cat_{i % 50}")
        lines.append(f"  score: {i % 100}")
        lines.append("  tags:")
        for j in range(3):
            lines.append(f"    - tag_{i % 100}_{j}")
    return "\n".join(lines) + "\n"


def bench_pyyaml(content: str, iters: int) -> float:
    start = time.perf_counter()
    for _ in range(iters):
        pyyaml.safe_load(content)
    return time.perf_counter() - start


def bench_ruamel(content: str, iters: int) -> float:
    ry = RuamelYAML(typ="safe")
    start = time.perf_counter()
    for _ in range(iters):
        ry.load(content)
    return time.perf_counter() - start


def bench_zyaml_parse(content: str, iters: int) -> float:
    encoded = content.encode("utf-8")
    lib = zyaml._get_lib()
    start = time.perf_counter()
    for _ in range(iters):
        p = lib.zyaml_parse(encoded, len(encoded))
        if p:
            lib.zyaml_free(p)
    return time.perf_counter() - start


def bench_zyaml_loads(content: str, iters: int) -> float:
    start = time.perf_counter()
    for _ in range(iters):
        zyaml.safe_load(content)
    return time.perf_counter() - start


def bench_zyaml_stringify(content: str, iters: int) -> float:
    doc = zyaml.parse(content)
    start = time.perf_counter()
    for _ in range(iters):
        doc.stringify()
    return time.perf_counter() - start


def run_benchmarks() -> list[dict]:
    results = []
    for name, gen_fn in SIZES.items():
        content = gen_fn()
        nbytes = len(content.encode("utf-8"))
        iters = ITERS[name]

        t_pyyaml = bench_pyyaml(content, iters)
        t_ruamel = bench_ruamel(content, iters)
        t_parse = bench_zyaml_parse(content, iters)
        t_loads = bench_zyaml_loads(content, iters)
        t_stringify = bench_zyaml_stringify(content, iters)

        results.append(
            {
                "size": name,
                "bytes": nbytes,
                "iterations": iters,
                "pyyaml": {"safe_load": t_pyyaml},
                "ruamel": {"load": t_ruamel},
                "zyaml": {
                    "parse_c": t_parse,
                    "safe_load": t_loads,
                    "stringify": t_stringify,
                },
                "speedup": {
                    "vs_pyyaml": t_pyyaml / t_loads if t_loads > 0 else 0,
                    "vs_ruamel": t_ruamel / t_loads if t_loads > 0 else 0,
                },
            }
        )
    return results


def print_table(results: list[dict]) -> None:
    print(
        f"{'Size':<10} {'Bytes':>10} {'Iters':>8} "
        f"{'PyYAML':>10} {'ruamel':>10} {'zyaml':>10} "
        f"{'vs PyYAML':>9} {'vs ruamel':>10}"
    )
    print("-" * 88)

    for r in results:
        t_pyyaml = r["pyyaml"]["safe_load"]
        t_ruamel = r["ruamel"]["load"]
        t_zyaml = r["zyaml"]["safe_load"]
        vs_pyyaml = r["speedup"]["vs_pyyaml"]
        vs_ruamel = r["speedup"]["vs_ruamel"]

        print(
            f"{r['size']:<10} {_fmt_bytes(r['bytes']):>10} {r['iterations']:>8} "
            f"{t_pyyaml:>8.3f}s {t_ruamel:>8.3f}s {t_zyaml:>8.3f}s "
            f"{vs_pyyaml:>7.1f}x {vs_ruamel:>8.1f}x"
        )

    print()
    print("zyaml = safe_load (equivalent to PyYAML/ruamel usage)")

    print()
    print("--- internal breakdown ---")
    print(
        f"{'Size':<10} {'Bytes':>10} {'Iters':>8} {'parse(C)':>10} {'loads':>10} {'stringify':>10}"
    )
    print("-" * 65)

    for r in results:
        print(
            f"{r['size']:<10} {_fmt_bytes(r['bytes']):>10} {r['iterations']:>8} "
            f"{r['zyaml']['parse_c']:>8.3f}s {r['zyaml']['safe_load']:>8.3f}s "
            f"{r['zyaml']['stringify']:>8.3f}s"
        )


def _fmt_bytes(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    return f"{n / 1024 / 1024:.1f} MB"


def main():
    parser = argparse.ArgumentParser(description="Benchmark zyaml vs PyYAML vs ruamel.yaml")
    parser.add_argument(
        "--json",
        metavar="FILE",
        nargs="?",
        const="-",
        help="Output results as JSON. Use a filename to write to file, or omit to print to stdout",
    )
    parser.add_argument(
        "--table",
        action="store_true",
        help="Print human-readable table (default when --json is not used)",
    )
    args = parser.parse_args()

    results = run_benchmarks()

    if args.json is not None:
        output = json.dumps(results, indent=2)
        if args.json == "-":
            print(output)
        else:
            with open(args.json, "w") as f:
                f.write(output + "\n")
            print(f"Results written to {args.json}")
    else:
        print_table(results)


if __name__ == "__main__":
    main()

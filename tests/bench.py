"""Benchmark zyaml vs PyYAML across file sizes and iteration counts."""

import os
import time

import yaml as pyyaml

import zyaml

BENCHMARK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_data")


def gen_small() -> str:
    return "name: Alice\nage: 30\ncity: Tokyo\n"


def gen_medium() -> str:
    lines = []
    for i in range(100):
        lines.append(f"user_{i}:")
        lines.append(f"  name: user_{i}")
        lines.append(f"  age: {20 + (i % 60)}")
        lines.append(f"  email: user_{i}@example.com")
        lines.append(f"  active: {'true' if i % 2 == 0 else 'false'}")
    return "\n".join(lines) + "\n"


def gen_large() -> str:
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


def gen_xlarge() -> str:
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


SIZES = {
    "small": gen_small,
    "medium": gen_medium,
    "large": gen_large,
    "xlarge": gen_xlarge,
}

ITERS = {
    "small": 10000,
    "medium": 1000,
    "large": 100,
    "xlarge": 10,
}


def bench_pyyaml(content: str, iters: int) -> float:
    start = time.perf_counter()
    for _ in range(iters):
        pyyaml.safe_load(content)
    return time.perf_counter() - start


def bench_zyaml_parse(content: str, iters: int) -> float:
    encoded = content.encode("utf-8")
    lib = zyaml._lib
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


def bench_zyaml_roundtrip(content: str, iters: int) -> float:
    doc = zyaml.parse(content)
    start = time.perf_counter()
    for _ in range(iters):
        doc.stringify()
    elapsed = time.perf_counter() - start
    return elapsed


def format_bytes(n: int) -> str:
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    return f"{n / 1024 / 1024:.1f} MB"


def main():
    print(
        f"{'Size':<10} {'Bytes':>10} {'Iters':>8} {'PyYAML':>12} {'zyaml(parse)':>12} {'zyaml(loads)':>12} {'zyaml(stringify)':>16} {'Speedup':>8}"
    )
    print("-" * 90)

    for name, gen_fn in SIZES.items():
        content = gen_fn()
        nbytes = len(content.encode("utf-8"))
        iters = ITERS[name]

        t_pyyaml = bench_pyyaml(content, iters)
        t_parse = bench_zyaml_parse(content, iters)
        t_loads = bench_zyaml_loads(content, iters)
        t_stringify = bench_zyaml_roundtrip(content, iters)

        speedup = t_pyyaml / t_parse if t_parse > 0 else 0

        print(
            f"{name:<10} {format_bytes(nbytes):>10} {iters:>8} "
            f"{t_pyyaml:>10.3f}s {t_parse:>10.3f}s {t_loads:>10.3f}s "
            f"{t_stringify:>14.3f}s {speedup:>7.1f}x"
        )


if __name__ == "__main__":
    main()

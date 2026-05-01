"""Profile the JSON path specifically."""

import ctypes
import json
import time

import zyaml

ITERS = 1000

medium = (
    "\n".join(
        f"user_{i}:\n  name: user_{i}\n  age: {20 + (i % 60)}\n  email: user_{i}@example.com\n  active: {'true' if i % 2 == 0 else 'false'}"
        for i in range(100)
    )
    + "\n"
)

enc = medium.encode("utf-8")
lib = zyaml._lib

# Warmup
p = lib.zyaml_parse(enc, len(enc))
jp = lib.zyaml_to_json(p)
json_bytes = ctypes.string_at(jp, ctypes.c_size_t.from_address(jp).value)
lib.zyaml_free_json(jp)
lib.zyaml_free(p)


def bench(label, fn, iters=ITERS):
    fn()
    start = time.perf_counter()
    for _ in range(iters):
        fn()
    elapsed = time.perf_counter() - start
    print(f"  {label:<45} {elapsed:>8.3f}s  ({elapsed / iters * 1e6:>8.1f} us/call)")


print("=== Medium document JSON path breakdown ===")
print()

bench("zyaml_parse (C)", lambda: lib.zyaml_parse(enc, len(enc)))

p = lib.zyaml_parse(enc, len(enc))
bench("zyaml_to_json (C)", lambda: lib.zyaml_to_json(p))

p = lib.zyaml_parse(enc, len(enc))
jp = lib.zyaml_to_json(p)


# read as cstr
def read_json():
    addr = jp
    length = 0
    while ctypes.c_char.from_address(addr + length).value != b"\x00":
        length += 1
    ctypes.string_at(addr, length).decode("utf-8")


bench("_read_cstr (byte scan + decode)", read_json)

json_str = read_json()
bench(f"json.loads ({len(json_str)} chars)", lambda: json.loads(json_str))

bench("zyaml_parse + to_json + read + json.loads", lambda: zyaml.safe_load(medium))

# Compare: old path
bench(
    "parse + _value_to_python (borrow)",
    lambda: zyaml._value_to_python(lib.zyaml_parse(enc, len(enc))),
)

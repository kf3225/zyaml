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
lib = zyaml._get_lib()

# Warmup
p = lib.zyaml_parse(enc, len(enc))
out_len = ctypes.c_size_t(0)
jp = lib.zyaml_to_json(p, ctypes.byref(out_len))
json_bytes = ctypes.string_at(jp, out_len.value)
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


def to_json_free():
    out_len = ctypes.c_size_t(0)
    jp = lib.zyaml_to_json(p, ctypes.byref(out_len))
    lib.zyaml_free_json(jp)


bench("zyaml_to_json (C)", to_json_free)

p = lib.zyaml_parse(enc, len(enc))
out_len = ctypes.c_size_t(0)
jp = lib.zyaml_to_json(p, ctypes.byref(out_len))


# read as cstr
def read_json():
    return ctypes.string_at(jp, out_len.value).decode("utf-8")


bench("_read_cstr (byte scan + decode)", read_json)

json_str = read_json()
bench(f"json.loads ({len(json_str)} chars)", lambda: json.loads(json_str))

bench("zyaml_parse + to_json + read + json.loads", lambda: zyaml.safe_load(medium))

# Compare: old path
bench(
    "parse + _value_to_python (borrow)",
    lambda: zyaml._value_to_python(lib.zyaml_parse(enc, len(enc))),
)

"""Detailed profiling of zyaml Python binding overhead."""

import ctypes
import time

import zyaml

ITERS = 1000


def bench(label, fn, iters=ITERS):
    # warmup
    fn()
    start = time.perf_counter()
    for _ in range(iters):
        fn()
    elapsed = time.perf_counter() - start
    print(f"  {label:<40} {elapsed:>8.3f}s  ({elapsed / iters * 1_000_000:>8.1f} us/call)")
    return elapsed


content = "name: Alice\nage: 30\ncity: Tokyo\n"
encoded = content.encode("utf-8")
lib = zyaml._lib

print(f"=== Micro-benchmark: small mapping ({ITERS} iters) ===")
print()

bench("zyaml_parse (C only)", lambda: (lib.zyaml_parse(encoded, len(encoded)),), ITERS)


# isolate parse + free
def parse_free():
    p = lib.zyaml_parse(encoded, len(encoded))
    lib.zyaml_free(p)


bench("parse + free", parse_free)


# parse + mapping_get_key
def parse_keys():
    p = lib.zyaml_parse(encoded, len(encoded))
    for i in range(lib.zyaml_mapping_len(p)):
        lib.zyaml_mapping_get_key(p, i)
    lib.zyaml_free(p)


bench("parse + get_keys", parse_keys)


# parse + mapping_get (deepClone)
def parse_values():
    p = lib.zyaml_parse(encoded, len(encoded))
    for k in [b"name", b"age", b"city"]:
        lib.zyaml_mapping_get(p, k, len(k))
    lib.zyaml_free(p)


bench("parse + get_values (deepClone)", parse_values)


# parse + full to_python
def parse_to_python():
    doc = zyaml.parse(content)
    doc.to_python()


bench("parse + to_python", parse_to_python)

# isolate to_python
doc = zyaml.parse(content)
bench("to_python on existing doc", lambda: doc.to_python(), 10000)

# isolate keys()
bench("keys() on existing doc", lambda: doc.keys(), 10000)

# isolate __getitem__
bench("doc['name'] on existing doc", lambda: doc["name"], 10000)

# isolate _read_cstr
kp = lib.zyaml_mapping_get_key(doc._ptr, 0)


def read_cstr_bench():
    kp2 = lib.zyaml_mapping_get_key(doc._ptr, 0)
    zyaml._read_cstr(kp2)


bench("_read_cstr (get_key + read)", read_cstr_bench, 10000)

# just the reading part (no allocDupZ)
addr = kp


def just_read():
    length = 0
    while ctypes.c_char.from_address(addr + length).value != b"\x00":
        length += 1
    buf = (ctypes.c_char * length).from_address(addr)
    bytes(buf).decode("utf-8")


bench("read cstr at known addr (no C call)", just_read, 10000)

print()
print(f"=== Profiling: medium document ({ITERS} iters) ===")
print()

medium = (
    "\n".join(
        f"user_{i}:\n  name: user_{i}\n  age: {20 + (i % 60)}\n  email: user_{i}@example.com\n  active: {'true' if i % 2 == 0 else 'false'}"
        for i in range(100)
    )
    + "\n"
)

enc_medium = medium.encode("utf-8")

bench("parse medium (C only)", lambda: lib.zyaml_parse(enc_medium, len(enc_medium)))
bench("parse + to_python medium", lambda: zyaml.parse(medium).to_python())

doc_m = zyaml.parse(medium)
bench("to_python medium (existing)", lambda: doc_m.to_python())
bench("keys() medium", lambda: doc_m.keys())

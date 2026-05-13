# zyaml Implementation Spec

This document describes the current implementation contract of zyaml. It is not
a full copy of the YAML 1.2.2 specification; it records the supported behavior,
public surfaces, and constraints that the repository must preserve.

## Scope

- zyaml is a native Zig YAML parser/emitter with Python bindings that expose a
  PyYAML-compatible convenience API.
- The core library targets YAML 1.2.2 data parsing and stringification for
  common configuration/data files.
- Comments, directives, anchors, aliases, custom tags, and presentation metadata
  are not preserved in the runtime value model. Supported anchors and aliases
  are resolved during parsing.
- The runtime value model is `null`, boolean, integer, float, string, sequence,
  and mapping.

## Architecture

- `src/ast/value.zig` owns the core `Value` union and scalar resolution.
- `src/parser/*` converts YAML bytes into `Value`.
- `src/encode/emitter.zig` converts `Value` back to YAML text.
- `src/decode/composer.zig` and `src/root.zig` provide the public Zig entry
  points.
- `src/c_api.zig`, `src/main.zig`, and `python/zyaml/*` are adapters over the
  core and must not be imported by core modules.
- Core modules receive allocators from callers and do not perform file I/O,
  networking, or process-level side effects.

## Parsing

- Top-level documents may contain scalars, block sequences, block mappings,
  flow sequences, and flow mappings.
- CR, LF, and CRLF input line breaks are normalized to LF before parsing (in
  `c_api.zig` `normalizeNewlines`). This applies to both `zyaml_parse` and
  `zyaml_parse_file`.
- Tabs are rejected for indentation.
- Plain, single-quoted, double-quoted, literal block, and folded block scalars
  are supported.
- Double-quoted scalar escapes support the YAML escapes implemented in
  `src/parser/scalar.zig`, including hex Unicode escapes.
- Empty mapping values parse as `null`.
- Duplicate scalar keys in block and flow mappings are rejected with
  `DuplicateKey`.
- Unknown aliases are rejected with `UnknownAlias`.
- Complex flow keys retain existing compatibility behavior when a key cannot be
  represented as a scalar duplicate-check key.
- When a plain scalar is being interpreted as a possible mapping key, detecting
  `:` commits to mapping parsing. Structural errors after that point propagate
  instead of falling back to scalar parsing.

## Scalar Resolution

- `Value.resolveScalar()` resolves YAML-like null, boolean, integer, and float
  spellings before falling back to string.
- Reserved YAML words and number-like strings are quoted by the emitter when
  needed to preserve round-trip type intent.

## Emitting

- `stringify` emits valid YAML for the current `Value` model.
- Mapping keys can be emitted in insertion order or sorted order via
  `EmitOptions.sort_keys`.
- The emitter quotes strings when required by YAML syntax, reserved words,
  number-like spellings, leading indicator characters, or embedded characters
  that make plain style unsafe.
- Shared formatting helpers handle indentation and sequence/mapping children so
  nested values use consistent output.

## C API

- Opaque `zyaml_value` pointers have two internal representations:
  **owned** (`*BoxedValue`, identified by a `BOX_MAGIC` header) and **borrowed**
  (`*Value`, returned by `_borrow` accessors). The magic value's first byte
  (`0x4C`) is outside the Value tag range (0–6), so the two representations are
  distinguishable without ambiguity.
- Accessors such as `zyaml_type`, `zyaml_as_bool`, and `zyaml_as_string_borrow`
  accept both owned and borrowed pointers transparently.
- Parse calls allocate owned values with the C allocator and return ownership to
  the caller, which must release them with `zyaml_free`. Passing a borrowed
  pointer to `zyaml_free` is safe (no-op).
- Borrowing accessors such as `zyaml_sequence_get_borrow`,
  `zyaml_mapping_get_value_borrow`, and `zyaml_mapping_get_key_borrow` return
  views tied to the lifetime of the parent `zyaml_value`. Borrowed pointers must
  not be used after the parent is freed.
- Builder functions (`zyaml_value_sequence_append`, `zyaml_value_mapping_put`)
  accept only owned pointers and return `false` for borrowed ones.
- Owning string-return APIs return null-terminated buffers that must be released
  with the matching free helper, currently `zyaml_free_cstr`,
  `zyaml_free_yaml`, `zyaml_free_json`, or `zyaml_free_string`.
- JSON export escapes control bytes, quotes, backslashes, and non-ASCII bytes
  explicitly.

## Python API

- `safe_load`, `load`, `safe_dump`, and `dump` provide the primary
  PyYAML-compatible API.
- The C extension is preferred when available; the ctypes fallback remains
  available for development and compatibility.
- Python wrapper objects own only root C values. Child wrappers returned from
  sequence or mapping access are borrowed and keep their parent alive.
- Python conversion raises `zyaml.YAMLError` for parser and binding errors.

## Implementation Constraints

- Character classification and escaping should use direct switches or readable
  conditionals. Lookup tables are not used unless a measured and documented
  bottleneck justifies one.
- Helpers that only need YAML token categories should accept `Token` rather than
  raw `u8`. Raw bytes remain appropriate when exact byte identity is required.
- Public API names may intentionally retain thin wrapper functions when they
  preserve ABI or clarify ownership. Unreferenced implementation-only exports
  should be removed.
- Allocation ownership must be explicit. Error paths use `errdefer` or local
  cleanup helpers to avoid leaks and double frees.

## Verification

Expected checks for behavior changes:

```bash
zig fmt src build.zig
zig build test
zig build
uv pip install -e .
uv run pytest tests/
uv run ruff check python/zyaml/ tests/
uv run ty check python/zyaml/__init__.py
```

Performance-sensitive changes should also run the repository benchmark and
confirm zyaml remains materially faster than PyYAML on parse and dump paths.

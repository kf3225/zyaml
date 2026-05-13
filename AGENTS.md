# zyaml — YAML 1.2.2 parser in Zig with Python bindings

## Project Overview

A native Zig YAML 1.2.2 parser library with Python bindings providing a PyYAML-compatible API.

## Build & Test

```bash
# Zig
zig build              # Build
zig build test         # Zig tests (41/41 + yaml-test-suite 1954/1954)

# Python (requires: eval "$(mise activate bash)")
uv pip install -e .    # Editable install with C extension
uv run pytest tests/   # Python tests (122/122)
uv run ty check python/zyaml/__init__.py  # Type check
uv run ruff check python/zyaml/           # Lint
```

**All tests must pass cleanly.** No segfaults, no leaks, no known failures tolerated.

---

## Architecture

### Layer Structure (Core + Adapter)

```
src/
├── ast/value.zig          # Core: Value type + scalar resolution logic
├── error.zig              # Core: Error type definitions
├── parser/
│   ├── scanner.zig        # Core: Character scanner (position tracking, indent detection)
│   └── parser.zig         # Core: YAML syntax parsing (Scanner → Value generation)
├── encode/emitter.zig     # Core: Value → YAML string output
├── decode/composer.zig    # Core: Thin wrapper over Parser
├── root.zig               # Core: Public API (parse/stringify/compose)
├── c_api.zig              # Adapter: C ABI (FFI bridge)
└── main.zig               # Adapter: CLI entry point

python/zyaml/
├── __init__.py            # Adapter: PyYAML-compatible API + ctypes binding
├── _ext.c                 # Adapter: C extension (Python ↔ Zig direct communication)
└── _ext.pyi               # Adapter: Type stubs
```

### Dependency Direction (Strict)

```
Adapter (c_api.zig, main.zig, _ext.c, __init__.py)
    ↓ one-way only
Core (parser.zig, emitter.zig, value.zig, scanner.zig, error.zig)
    ↓ no dependencies
Zig standard library only
```

**Rules:**
- Core must not import Adapter
- Core manages memory via allocator parameter; no file I/O or networking
- Adapter imports and uses Core types and functions

---

## Design Rules

### Code Conventions

| Rule | Guideline |
|---|---|
| Function length | ≤ 30 lines (hard limit: 50) |
| Nesting depth | ≤ 2 levels |
| Argument count | ≤ 3 (4+ → group into a struct) |
| Branch count | ≤ 5 (switch over enum variants exempt) |

### Principles

1. **Single Level of Abstraction (SLA):** All operations within a function must be at the same abstraction level. Do not mix low-level operations (`scanner.skip()`, etc.) with high-level calls (`parseValue()`, etc.). If mixed, extract into helper functions.

2. **DRY (Don't Repeat Yourself):** When the same logic appears in 2+ places, consolidate it. However, if consolidation would reverse the dependency direction, tolerate the duplication (copies across layer boundaries are OK).

3. **Guard Clause Priority:** Prefer early return/continue to reduce nesting. Use `if { return } ...` over `if { ... } else { ... }`.

4. **I/O and Logic Separation:** Do not mix side effects (file reads, output writes) with pure logic (parsing, transformation) in the same function.

5. **comptime Where It Clarifies:** Use `comptime` when it keeps code simpler or removes real runtime work without obscuring behavior: `inline for` over known-length arrays and `comptime` function parameters for literals are fine. Do not use lookup tables for character classification or escaping; prefer direct, readable switches and conditionals unless there is a measured, documented bottleneck and the table improves the design. **Do not use `std.StaticStringMap.initComptime`** — it causes post-test segfaults with `std.testing.allocator`.

6. **Ownership is Explicit:** Every allocation has exactly one owner. When ownership transfers across function boundaries, the transfer must be documented via function contract (name, parameter order, errdefer placement). Error paths must not double-free or leak.

7. **Token over raw byte for classification:** When a helper only needs YAML token categories, accept or return `Token` instead of `u8`. Keep `u8` only when the exact byte value is required, such as copying scalar content, computing numeric/hex output, or distinguishing characters collapsed into `Token.other`.

### Comment Conventions

- **Write "Why":** Document the intent behind why code is written a certain way
- **Don't write "What":** Do not comment on things readable from the code itself
- **Exception:** Definition enumerations (enums, test case arrays, etc.), framework boilerplate

---

## Coding Style (Zig)

### Memory Management

- Core functions receive `allocator` as a parameter (no global state)
- C API (`c_api.zig`) uses `c_allocator` + `ArenaAllocator` per parse call
- Always use `errdefer` for memory cleanup on error paths
- Use `deinitMappingEntries()` helper for `Value.Mapping` errdefer cleanup
- When `tryScalarAsMappingKey` detects `:` it commits to mapping interpretation — structural errors (InvalidIndentation, TabIndentation, DuplicateKey) propagate rather than silently falling back to scalar

### Parser Patterns

- `parseValueWithContext()` → Top-level dispatcher. Routes to per-type parse functions
- `tryScalarAsMappingKey()` → Returns `YamlError!?Value`. Propagates structural errors; returns null only for non-colon cases
- `keyToString()` → Shared Value → string key conversion
- `isPlainKey()` → Free function with readable character classification logic
- `parseEscapeTo()` → Uses direct switch cases for escape handling
- `skipNewlines()` / `hasInlineValue()` / `skipFlowWhitespaceAndComments()` → Shared scanner helpers (DRY)

### Emitter Patterns

- `emitMapEntry()` / `emitMapEntryValue()` → Mapping key-value output
- `emitSeqChild()` → Recursive sequence element output (nesting control)
- `writeNewlineIndent()` → Shared newline + indent output (DRY)
- `collectKeys()` → Unified sorted/unsorted key collection (DRY)
- `needsQuoting()` → Uses clear character checks + `Value.isReservedWord()` / `Value.looksLikeNumber()`

### C API (`c_api.zig`) Patterns

- `fromValue()` / `toValue()` → Opaque pointer ↔ Value conversion
- `parseWithArena()` → Shared arena-based parse logic for `zyaml_parse`/`zyaml_parse_file` (DRY)
- `freeNullTerminated()` → Shared null-terminated string cleanup (DRY)
- `buildEmitOptions()` / `nullTerminatedOutput()` → Shared export function logic
- `zyaml_type` → Uses `inline else` for maintainability
- `writeJsonEscapedChar()` → Keeps JSON escaping logic explicit and easy to audit

---

## Relevant Files

### Zig Core

- `src/ast/value.zig` — Value union type, `resolveScalar()`, `isReservedWord()`, `looksLikeNumber()`, `matchesVariants()` (comptime params)
- `src/parser/parser.zig` — Main parser
- `src/parser/scanner.zig` — Character scanner (`startWith` with comptime prefix)
- `src/encode/emitter.zig` — YAML stringification
- `src/error.zig` — Error type definitions

### Zig Adapter

- `src/c_api.zig` — C ABI export
- `src/root.zig` — Public API entry point
- `src/main.zig` — CLI entry point

### Python

- `python/zyaml/__init__.py` — PyYAML-compatible API (safe_load/safe_dump, etc.)
- `python/zyaml/_ext.c` — C extension module
- `python/zyaml/_ext.pyi` — Type stubs
- `tests/` — Test files (pytest)

### Build

- `build.zig` — C API ReleaseSafe, static C lib
- `setup.py` — C extension build (libzyaml_c.a static linking)
- `pyproject.toml` — setuptools configuration

---

## Performance

zyaml vs PyYAML vs ruamel.yaml:
- **parse:** 66-196x faster than PyYAML (120-290x vs ruamel)
- **stringify:** ~300x faster than PyYAML

## Instructions

- Communicate with the user in Japanese
- When a code change alters current behavior, supported syntax, public API, memory ownership, error semantics, or implementation constraints, update `docs/spec.md` in the same change.
- `uv pip install -e .` enables editable install with C extension
- `eval "$(mise activate bash)"` may be required
- pre-commit hooks are configured (ruff, ruff-format, ty check)

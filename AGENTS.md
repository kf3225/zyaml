# zyaml — YAML 1.2.2 parser in Zig with Python bindings

## Project Overview

A native Zig YAML 1.2.2 parser library with Python bindings providing a PyYAML-compatible API.

## Build & Test

```bash
# Zig
zig build              # Build
zig build test         # Zig tests (58/58)

# Python (requires: eval "$(mise activate bash)")
uv pip install -e .    # Editable install with C extension
uv run pytest tests/   # Python tests (121/121)
uv run ty check python/zyaml/__init__.py  # Type check
uv run ruff check python/zyaml/           # Lint
```

## Test Status

- **Zig:** 58/58 tests pass
- **Python:** 121/121 tests pass
- **Known issue:** post-test segfault in cleanup (not a test failure)

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

### Layer Responsibilities

| Layer | Responsibility | Dependency Direction |
|---|---|---|
| **Core** | Pure YAML logic. No side effects. Only accepts allocator. | No external dependencies |
| **Adapter** | Integration with external systems (C ABI, Python, file I/O) | Depends only on Core |

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

| Rule | Guideline | Exception |
|---|---|---|
| Function length | ≤ 30 lines | Up to 50 lines tolerated |
| Nesting depth | ≤ 2 levels | Guard clauses for early exit preferred |
| Argument count | ≤ 3 | 4+ should be grouped into a struct |
| Branch count | ≤ 5 | switch cases are definition enumerations (exempt) |

### Principles

1. **Single Level of Abstraction (SLA):** All operations within a function must be at the same abstraction level. Do not mix low-level operations (`scanner.skip()`, etc.) with high-level calls (`parseValue()`, etc.). If mixed, extract into helper functions.

2. **DRY (Don't Repeat Yourself):** When the same logic appears in 2+ places, consolidate it. However, if consolidation would reverse the dependency direction, tolerate the duplication (copies across layer boundaries are OK).

3. **Guard Clause Priority:** Prefer early return/continue to reduce nesting. Use `if { return } ...` over `if { ... } else { ... }`.

4. **I/O and Logic Separation:** Do not mix side effects (file reads, output writes) with pure logic (parsing, transformation) in the same function.

### Comment Conventions

- **Write "Why":** Document the intent behind why code is written a certain way
- **Don't write "What":** Do not comment on things readable from the code itself
- **Exception:** Definition enumerations (enums, test case arrays, etc.), framework boilerplate

### Criteria for Adding New Files

Before adding, verify:

1. **Will it need replacement in the future?** → If yes, consider interface/adapter separation
2. **Does it improve testability?** → If separating side effects makes testing easier, separate them
3. **Is it understandable to users?** → If adding a file makes things harder to understand, don't add it

---

## Coding Style (Zig)

### Memory Management

- Core functions receive `allocator` as a parameter (no global state)
- C API (`c_api.zig`) uses `c_allocator` (no GPA in C API)
- Always use `errdefer` for memory cleanup on error paths
- Use `deinitMappingEntries()` helper for `Value.Mapping` errdefer cleanup

### Parser Patterns

- `parseValueWithContext()` → Top-level dispatcher. Routes to per-type parse functions
- `tryScalarAsMappingKey()` → Promotes scalar value to mapping when followed by `:`
- `resolveScalarType()` → Delegates to `Value.resolveScalar()` (DRY)
- `keyToString()` → Shared Value → string key conversion
- `isNewlineContinuable()` → Plain scalar newline continuation check
- `readAnchorName()` → Shared anchor name reading (DRY)
- `readHexEscape()` / `appendCodepoint()` → Shared hex escape parsing (DRY)
- `skipNewlines()` / `hasInlineValue()` / `skipFlowWhitespaceAndComments()` → Shared scanner helpers (DRY)

### Emitter Patterns

- `emitMapEntry()` / `emitMapEntryValue()` → Mapping key-value output
- `emitSeqChild()` → Recursive sequence element output (nesting control)
- `writeNewlineIndent()` → Shared newline + indent output (DRY)
- `needsQuoting()` → Uses `Value.isReservedWord()` / `Value.looksLikeNumber()` (DRY)

### C API (`c_api.zig`) Patterns

- `fromValue()` / `toValue()` → Opaque pointer ↔ Value conversion
- `buildEmitOptions()` / `nullTerminatedOutput()` → Shared export function logic
- `writeJsonString()` → Single implementation of JSON string escape output

---

## Relevant Files

### Zig Core

- `src/ast/value.zig` — Value union type, `resolveScalar()`, `isReservedWord()`, `looksLikeNumber()`, `matchesVariants()`, `tryParsePrefixedInt()`
- `src/parser/parser.zig` — Main parser
- `src/parser/scanner.zig` — Character scanner
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

zyaml vs PyYAML:
- **load:** ~70x faster
- **dump:** ~47x faster

## Instructions

- Communicate with the user in Japanese
- `zig build test` post-test segfault is a known issue (tests themselves all pass)
- `uv pip install -e .` enables editable install with C extension
- `eval "$(mise activate bash)"` may be required
- pre-commit hooks are configured (ruff, ruff-format, ty check)

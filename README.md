# zyaml

**English** | [日本語](docs/README.ja.md)

A native **YAML 1.2.2** parser and emitter written in [Zig](https://ziglang.org), with zero-dependency Python bindings providing a PyYAML-compatible API.

[![CI](https://github.com/kf3225/zyaml/actions/workflows/ci.yml/badge.svg)](https://github.com/kf3225/zyaml/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python 3.9+](https://img.shields.io/badge/python-3.9%2B-blue.svg)](https://www.python.org/)

## Features

- **YAML 1.2.2 compliant** — 1954/1954 tests pass from the official [yaml-test-suite](https://github.com/yaml/yaml-test-suite)
- **PyYAML-compatible API** — drop-in replacement: `safe_load()`, `safe_dump()`, and more
- **Zero Python dependencies** — single native C extension, no libyaml required
- **Cross-platform** — Linux, macOS, Windows (x86_64 and aarch64)
- **Full-featured** — block/flow collections, multiline scalars, anchors/aliases, escape sequences, duplicate key detection
- **Generic type coercion** — `safe_load(data, type=list[MyDataclass])` for typed deserialization

## Performance

| Operation | vs PyYAML | vs ruamel.yaml |
|-----------|-----------|----------------|
| Parse     | **66–196×** faster | **120–290×** faster |
| Stringify | **~300×** faster | — |

## Quick Start (Python)

### Install

```bash
pip install zyaml
```

### Usage

```python
import zyaml as yaml

# Parse
data = yaml.safe_load("""
name: zyaml
version: 0.1.0
dependencies:
  - zig >= 0.14.0
""")
# {'name': 'zyaml', 'version': '0.1.0', 'dependencies': ['zig >= 0.14.0']}

# Dump
print(yaml.safe_dump(data))

# Typed deserialization
from dataclasses import dataclass

@dataclass
class Config:
    name: str
    version: str

cfg = yaml.safe_load("name: zyaml\nversion: 0.1.0", type=Config)
# Config(name='zyaml', version='0.1.0')
```

### PyYAML-Compatible API

| zyaml                  | PyYAML equivalent      |
|------------------------|------------------------|
| `safe_load(stream)`    | `yaml.safe_load()`     |
| `safe_load_all(stream)`| `yaml.safe_load_all()` |
| `safe_dump(data)`      | `yaml.safe_dump()`     |
| `safe_dump_all(docs)`  | `yaml.safe_dump_all()` |
| `load(stream)`         | `yaml.load()`          |
| `dump(data)`           | `yaml.dump()`          |

`safe_dump()` accepts the same keyword arguments as PyYAML: `indent`, `sort_keys`, `default_flow_style`, `explicit_start`, `explicit_end`, `stream`.

## Zig Usage

```zig
const zyaml = @import("zyaml");

const input =
    \\host: localhost
    \\port: 8080
;

var value = try zyaml.parse(allocator, input);
defer value.deinit(allocator);

// Access mapping entries
const host = value.mapping.get("host").?.string; // "localhost"
const port = value.mapping.get("port").?.integer; // 8080

// Stringify
const opts = zyaml.EmitOptions{ .indent = 4, .sort_keys = true };
const output = try zyaml.stringify(allocator, value, opts);
defer allocator.free(output);
```

## C API

```c
#include <zyaml.h>

YamlValue* doc = zyaml_parse(input, strlen(input));
if (!doc) {
    fprintf(stderr, "parse error: %s\n", zyaml_error_message());
    return 1;
}

printf("type = %d\n", zyaml_type(doc));
printf("keys = %zu\n", zyaml_mapping_len(doc));

zyaml_free(doc);
```

Full C API: [docs/spec.md](docs/spec.md)

## Architecture

```
src/
├── ast/value.zig          Value type + scalar resolution
├── error.zig              Error definitions
├── parser/
│   ├── scanner.zig        Character scanner
│   └── parser.zig         Syntax parser (Scanner → Value)
├── encode/emitter.zig     Value → YAML string
├── decode/composer.zig    Thin parse wrapper
├── root.zig               Public Zig API
├── c_api.zig              C ABI (FFI bridge)
└── main.zig               CLI entry point

python/zyaml/
├── __init__.py            PyYAML-compatible API + ctypes binding
├── _ext.c                 C extension (Python ↔ Zig)
└── _ext.pyi               Type stubs
```

**Dependency rule:** Adapter → Core → Zig stdlib only. Core never imports Adapter.

## Building from Source

### Prerequisites

- [Zig](https://ziglang.org) >= 0.14.0
- Python >= 3.9 (for Python bindings)

### Zig Only

```bash
zig build        # Build all artifacts
zig build test   # Run 41 unit tests + 1954 yaml-test-suite tests
```

### Python Bindings

```bash
zig build                         # Build libzyaml_c.a
uv pip install -e .               # Build C extension + editable install
uv run pytest tests/              # 121 Python tests
uv run ruff check python/zyaml/   # Lint
```

## Supported YAML Features

| Feature                         | Status |
|---------------------------------|--------|
| Block sequences & mappings      | ✅     |
| Flow sequences `[...]` & maps `{...}` | ✅ |
| Plain / single-quoted / double-quoted scalars | ✅ |
| Literal (`\|`) and folded (`>`) block scalars | ✅ |
| Block chomping indicators (`-`, `+`) | ✅ |
| Document markers (`---`, `...`) | ✅     |
| Anchors (`&`) and aliases (`*`) | ✅     |
| Comments                        | ✅     |
| Escape sequences (incl. Unicode) | ✅    |
| Duplicate key detection         | ✅     |
| YAML 1.2 schema (null/bool/int/float) | ✅ |
| JSON export (`zyaml_to_json`)   | ✅     |

## License

[MIT](LICENSE) — Copyright (c) 2026 KF

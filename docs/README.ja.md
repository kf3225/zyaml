# zyaml

[English](../README.md) | **日本語**

[Zig](https://ziglang.org) で書かれたネイティブ **YAML 1.2.2** パーサー・エミッター。PyYAML 互換 API を備えた依存ゼロの Python バインディング付き。

[![CI](https://github.com/kf3225/zyaml/actions/workflows/ci.yml/badge.svg)](https://github.com/kf3225/zyaml/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Python 3.9+](https://img.shields.io/badge/python-3.9%2B-blue.svg)](https://www.python.org/)

## 特徴

- **YAML 1.2.2 準拠** — 公式 [yaml-test-suite](https://github.com/yaml/yaml-test-suite) のテスト 1954/1954 にパス
- **PyYAML 互換 API** — `safe_load()`, `safe_dump()` などのドロップイン置換
- **Python 依存ゼロ** — 単一のネイティブ C 拡張、libyaml 不要
- **クロスプラットフォーム** — Linux / macOS / Windows（x86_64・aarch64）
- **豊富な機能** — ブロック/フローコレクション、複数行スカラー、アンカー/エイリアス、エスケープシーケンス、重複キー検出
- **ジェネリック型変換** — `safe_load(data, type=list[MyDataclass])` で型付きデシリアライズ

## パフォーマンス

| 操作       | vs PyYAML        | vs ruamel.yaml    |
|-----------|------------------|-------------------|
| パース     | **66–196 倍** 高速 | **120–290 倍** 高速 |
| 文字列化   | **約 300 倍** 高速  | —                 |

## クイックスタート（Python）

### インストール

```bash
pip install zyaml
```

### 使い方

```python
import zyaml as yaml

# パース
data = yaml.safe_load("""
name: zyaml
version: 0.1.0
dependencies:
  - zig >= 0.14.0
""")
# {'name': 'zyaml', 'version': '0.1.0', 'dependencies': ['zig >= 0.14.0']}

# ダンプ
print(yaml.safe_dump(data))

# 型付きデシリアライズ
from dataclasses import dataclass

@dataclass
class Config:
    name: str
    version: str

cfg = yaml.safe_load("name: zyaml\nversion: 0.1.0", type=Config)
# Config(name='zyaml', version='0.1.0')
```

### PyYAML 互換 API

| zyaml                  | PyYAML 相当            |
|------------------------|------------------------|
| `safe_load(stream)`    | `yaml.safe_load()`     |
| `safe_load_all(stream)`| `yaml.safe_load_all()` |
| `safe_dump(data)`      | `yaml.safe_dump()`     |
| `safe_dump_all(docs)`  | `yaml.safe_dump_all()` |
| `load(stream)`         | `yaml.load()`          |
| `dump(data)`           | `yaml.dump()`          |

`safe_dump()` は PyYAML と同じキーワード引数に対応: `indent`, `sort_keys`, `default_flow_style`, `explicit_start`, `explicit_end`, `stream`。

## Zig での使い方

```zig
const zyaml = @import("zyaml");

const input =
    \\host: localhost
    \\port: 8080
;

var value = try zyaml.parse(allocator, input);
defer value.deinit(allocator);

// マッピングのエントリにアクセス
const host = value.mapping.get("host").?.string; // "localhost"
const port = value.mapping.get("port").?.integer; // 8080

// 文字列化
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

C API の詳細: [docs/spec.md](spec.md)

## アーキテクチャ

```
src/
├── ast/value.zig          値型 + スカラー解決
├── error.zig              エラー定義
├── parser/
│   ├── scanner.zig        文字スキャナー
│   └── parser.zig         構文パーサー（Scanner → Value）
├── encode/emitter.zig     Value → YAML 文字列
├── decode/composer.zig    薄いパースラッパー
├── root.zig               公開 Zig API
├── c_api.zig              C ABI（FFI ブリッジ）
└── main.zig               CLI エントリポイント

python/zyaml/
├── __init__.py            PyYAML 互換 API + ctypes バインディング
├── _ext.c                 C 拡張（Python ↔ Zig）
└── _ext.pyi               型スタブ
```

**依存ルール:** Adapter → Core → Zig 標準ライブラリのみ。Core は Adapter をインポートしない。

## ソースからのビルド

### 前提条件

- [Zig](https://ziglang.org) >= 0.14.0
- Python >= 3.9（Python バインディングを使用する場合）

### Zig のみ

```bash
zig build        # 全成果物をビルド
zig build test   # 41 ユニットテスト + 1954 yaml-test-suite テストを実行
```

### Python バインディング

```bash
zig build                         # libzyaml_c.a をビルド
uv pip install -e .               # C 拡張をビルド + エディタブルインストール
uv run pytest tests/              # 121 Python テスト
uv run ruff check python/zyaml/   # リント
```

## 対応 YAML 機能

| 機能                                | 状態 |
|-------------------------------------|------|
| ブロックシーケンス & マッピング         | ✅   |
| フローシーケンス `[...]` & マップ `{...}` | ✅ |
| プレーン / 単一引用符 / 二重引用符スカラー | ✅   |
| リテラル（`\|`）および折りたたみ（`>`）ブロックスカラー | ✅ |
| ブロックチャンピング指示子（`-`, `+`）| ✅   |
| ドキュメントマーカー（`---`, `...`）  | ✅   |
| アンカー（`&`）とエイリアス（`*`）    | ✅   |
| コメント                             | ✅   |
| エスケープシーケンス（Unicode 含む）    | ✅   |
| 重複キー検出                          | ✅   |
| YAML 1.2 スキーマ（null/bool/int/float）| ✅   |
| JSON エクスポート（`zyaml_to_json`）  | ✅   |

## ライセンス

[MIT](../LICENSE) — Copyright (c) 2026 KF

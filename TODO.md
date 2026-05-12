# TODO

## 1. メモリリーク解消 ✅

- 1954/1954 passed, 0 failed, 0 skipped, 0 leaked

## 2. パフォーマンスチェック ✅

### Zig (ReleaseFast)
| 入力 | Parse | Stringify |
|------|-------|-----------|
| 37B | 18 us | 7 us |
| 778B | 38 us | 13 us |
| 20KB | 239 us | 51 us |

### Python (zyaml vs PyYAML, 20KB)
| 操作 | zyaml | PyYAML | 高速化 |
|------|-------|--------|--------|
| Parse | 0.2 ms | 20.5 ms | **107.6x** |
| Stringify | 0.2 ms | 10.6 ms | **54.8x** |

## 3. リファクタリング（進行中）

### パフォーマンス改善
- `deepClone` 呼び出し削減（エイリアス解決時の不要なクローン）
- `readAnchorName` / `keyToString` での `dupe` / `allocPrint` 呼び出しの削減
- `std.ArrayList.append` の不要な `ensureTotalCapacity` 呼び出しの排除

### コード品質
- `parser.zig` が2300行を超えている — 責任ごとに分割
- 関数のネスト深度 ≤ 2 の遵守確認
- 関数の行数 ≤ 30行（ハードリミット50行）の遵守確認
- `errdefer` の所有権管理の統一

### アーキテクチャ
- `parseValueWithContext` の switch 分岐（12ケース）の整理
- `tryScalarAsMappingKey` / `tryAsMappingOrReturn` パターンの簡素化
- `pending_anchor` の単一フィールド → ネスト対応の改善

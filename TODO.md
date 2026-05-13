# TODO - strict review notes

この TODO は 2026-05-13 時点のコードレビュー結果。優先度は「壊れやすさ」「メモリ安全性」「性能への影響」「保守性」の順で付けている。

## P0 - 正しさ・メモリ安全性

### 1. Python C extension の bool 返却で参照カウントを壊さない

- 対象: `python/zyaml/_ext.c:46`
- 問題: `value_to_py()` が `Py_True` / `Py_False` を borrowed reference のまま返している。呼び出し側は new reference として扱うため、単独の `safe_load("true")` や list/dict 内 bool で参照カウント破壊につながる。
- 修正案: `Py_RETURN_TRUE` / `Py_RETURN_FALSE`、または `Py_NewRef(zyaml_as_bool(v) ? Py_True : Py_False)` を使う。
- 検証: `uv run pytest tests/` に加え、`PYTHONMALLOC=debug` と refcount/ASAN ビルドの Python で bool を大量に含む YAML をロードするテストを追加する。

### 2. ctypes 経由の C 文字列を必ず解放する

- 対象: `python/zyaml/__init__.py:280`, `python/zyaml/__init__.py:298`, `python/zyaml/__init__.py:722`, `python/zyaml/__init__.py:736`
- 問題: `zyaml_as_string()` と `zyaml_stringify()` は C 側で allocate した null-terminated string を返すが、`_read_cstr()` が読むだけで free していない。`YamlValue.to_python()`, `YamlValue.stringify()`, `YamlValue.__repr__()` を繰り返すとリークする。
- 修正案: borrowed API を使える場所は `zyaml_as_string_borrow()` に寄せる。所有権付き API を使う場合は `_read_owned_cstr(ptr, free_fn)` のように読み取りと解放を一体化する。`zyaml_stringify()` 用には対応する free 関数名を C/Python で統一する。
- > **[QUESTION]** `zyaml_as_string_borrow()` は新規に C API (`c_api.zig`) に追加する関数という認識で合っているか？それとも既存の何かを指している？
- > **[ANSWER]** 既存 API を指している。`src/c_api.zig` にはすでに `zyaml_as_string_borrow(value, out_len)` があり、`python/zyaml/_ext.c` もこれを使っている。一方、`python/zyaml/__init__.py` の ctypes セットアップにはこの関数が登録されておらず、低レベル API の `_value_to_python()` / `__repr__()` が所有権付き `zyaml_as_string()` を読んで free していない。対応は「C API 追加」ではなく、ctypes 側に `zyaml_as_string_borrow` の argtypes/restype を追加し、読める箇所を borrowed に切り替えること。
- > **[QUESTION]** `zyaml_stringify()` 用の free 関数の名前は何を想定している？（例: `zyaml_free()` / `zyaml_string_free()` 等、命名規則の指定はあるか）
- > **[ANSWER]** 既存の `zyaml_free_cstr()` に寄せるのがよい。`zyaml_free()` は `YamlValue` 用なので文字列解放に使ってはいけない。現状は `zyaml_stringify_options()` の戻り値を `_ext.c` が `zyaml_free_cstr()` で解放しており、`zyaml_stringify()` の戻り値も同じ `c_alloc` 由来の C string なので `zyaml_free_cstr()` で統一できる。`zyaml_free_yaml()` も存在するが用途が重複しているため、新規追加より `zyaml_free_cstr()` を ctypes に登録して使う方針にする。
- 検証: Python から `parse("a: x")` 後に `to_python()` / `stringify()` / `repr()` を 100k 回実行し、RSS と leak sanitizer で増加しないことを見る。

### 3. C extension の append/put 失敗を無視しない

- 対象: `python/zyaml/_ext.c:120`, `python/zyaml/_ext.c:136`, `python/zyaml/_ext.c:76`, `python/zyaml/_ext.c:178`
- 問題: `zyaml_value_sequence_append()`, `zyaml_value_mapping_put()`, `PyDict_SetItem()`, `PyUnicode_Append()` の失敗を見ていない。OOM や不正入力時にリーク、部分構築、例外未設定が起きる。
- 修正案: すべての C API 戻り値をチェックし、失敗時は作成済みの Zig value / Python object を解放して `NULL` を返す。`PyUnicode_FromString()` の一時オブジェクトは `Py_DECREF` する。
- 検証: 失敗注入は難しいため、まずユニットテストで巨大 list/dict と非 UTF-8 相当の境界を追加し、ASAN/UBSAN/valgrind 相当で確認する。

### 4. フロー mapping の重複キーを block mapping と同じ方針にする

- 対象: `src/parser/flow.zig:97`, `src/parser/mapping.zig:310`
- 問題: block mapping は `DuplicateKey` を返すが、flow mapping は `fetchSwapRemove()` で古い値を破棄して上書きしている。同じ YAML 文書内で `{a: 1, a: 2}` と `a: 1\na: 2` の挙動が変わる。
- 修正案: 仕様として重複キーを禁止するなら `putFlowMapEntry()` も `getOrPut()` で検出して `YamlError.DuplicateKey` を返す。PyYAML 互換として last-wins にするなら block 側も揃え、テスト名に意図を書く。
- > **[QUESTION]** 修正案は2択（禁止 vs last-wins）だが、どちらにするか方針の指定はあるか？PyYAML の実際の挙動は last-wins だが、YAML 1.2 仕様では推奨されない。現在の block 側の `DuplicateKey` を残す前提で進めてよいか？
- > **[ANSWER]** `DuplicateKey` 禁止で揃える。理由は、このプロジェクトは「YAML 1.2.2 parser」を主目的にしており、AGENTS.md でも `DuplicateKey` を構造エラーとして伝播する方針が明記されているため。PyYAML 互換 API は重要だが、重複キーは入力の曖昧さを隠す挙動なので、少なくとも core parser では block/flow ともに `YamlError.DuplicateKey` に統一する。Python 側で PyYAML last-wins 互換モードが必要なら、将来の明示オプションとして別途扱う。
- 検証: block/flow 両方の重複キーケースを Zig と Python に追加する。

## P1 - パフォーマンス

### 5. 文字分類は読みやすい分岐を維持する

- 対象: `src/parser/parser.zig:21`, `src/parser/scalar.zig:60`
- 問題: lookup table 化は方針として読みやすさを落としやすく、分岐の意図が追いにくい。小さな switch/条件式で十分な箇所では table を作らない。
- 修正案: `isPlainKey()`、`parseEscapeTo()`、emitter の quoting 判定、C API の JSON escaping は direct switch / conditionals を維持する。今後 table 化を検討する場合は、対象の micro benchmark と読みやすさのトレードオフを TODO/PR に明記する。
- 追加方針: token category だけで判断できる helper は `u8` ではなく `Token` を受け取る。`Token.other` に潰れる文字を区別する必要がある場合や、実バイトを書き出す場合のみ `u8` を残す。
- 検証: `zig build test` と、quoted scalar / plain scalar の既存テストを維持する。

### 6. Python の低レベル `YamlValue` API で不要な deep clone を減らす

- 対象: `python/zyaml/__init__.py:677`, `python/zyaml/__init__.py:683`, `src/c_api.zig:201`, `src/c_api.zig:221`
- 問題: `YamlValue.__getitem__()` は `zyaml_sequence_get()` / `zyaml_mapping_get()` を使い、C 側で `deepClone()` している。`items()`, `values()`, nested access は clone と free を大量発生させる。
- 修正案: `YamlValue` に「borrowed child + parent owner」表現を追加するか、Python 側の `__getitem__` は borrow API を使い、親への参照を保持して lifetime を守る。
- > **[QUESTION]** 「borrowed child + parent owner」の具象イメージを教えてほしい。Python 側で `YamlValue` に親の ctypes ポインタを持たせて GC で親を延命する形か？それとも C 側に参照カウント付きの handle を導入する形か？ctypes での実装になるので、どの程度の複雑さを許容するか知りたい。
- > **[ANSWER]** まずは Python 側だけでよい。C 側の参照カウント付き handle は複雑さに対して見返りが薄い。具体的には `YamlValue.__slots__ = ("_ptr", "_owner", "_owned")` のようにし、root は `_owned=True, _owner=None`、borrowed child は `_owned=False, _owner=<親 YamlValue>` にする。`__del__` は `_owned` のときだけ `zyaml_free()` する。`__getitem__` は `zyaml_sequence_get_borrow()` / `zyaml_mapping_get_borrow()` を使って borrowed child を返す。これで child が生きている限り親も Python 参照で延命され、arena 内ポインタの lifetime を守れる。既存の clone API は必要なら `clone_item()` のような明示 API として残す。
- > **[QUESTION]** `zyaml_sequence_get_borrow()` / `zyaml_mapping_get_borrow()` は `c_api.zig` に新規追加する関数という認識で合っているか？（#2 の `zyaml_as_string_borrow` は既存と回答にあったが、sequence/mapping 版は既存か新規かの記載がなかったため）
- > **[ANSWER]** どちらも既存 API。`src/c_api.zig` に `zyaml_sequence_get_borrow(value, index)` と `zyaml_mapping_get_borrow(value, key, key_len)` がすでにあり、`python/zyaml/__init__.py` の `_setup_collection_api()` でも ctypes 登録済み。さらに index-based の `zyaml_mapping_get_value_borrow(value, index)` も既存で、`_mapping_to_python()` が使っている。したがって #6 の対応は C API 追加ではなく、`YamlValue.__getitem__()` / `items()` / `values()` が clone 版の `zyaml_sequence_get()` / `zyaml_mapping_get()` ではなく既存 borrow 版を使うよう Python 側の ownership 表現を変える作業になる。
- 検証: large mapping の全走査 benchmark を作り、clone 版と borrow 版の時間・alloc 数を比較する。

### 7. emitter の sort_keys で毎回 keys 配列を allocate しない選択肢を作る

- 対象: `src/encode/emitter.zig:128`
- 問題: `sort_keys=true` のたびに key slice 配列を allocate/sort する。Python の default は `sort_keys=True` なので、dump 性能の標準経路でコストになる。
- 修正案: `sort_keys=false` の高速経路は現状維持。`sort_keys=true` は caller 側で再利用できる scratch allocator/context を導入するか、Python default を PyYAML 互換として本当に必要な API だけに限定する。
- > **[QUESTION]** 「scratch allocator/context」の具象イメージを教えてほしい。`EmitOptions` に `std.ArrayList([]const u8)` を持たせて `collectKeys()` が再利用する形か？それとも C API 側に stateful な context（`zyaml_emit_context` みたいなもの）を新設して、複数回の `zyaml_stringify()` で使い回す形か？後者の場合は Python ↔ Zig 間の lifetime 管理が増えるので方針を知りたい。
- > **[ANSWER]** C API に stateful context はまだ入れない。まずは core emitter 内の 1 stringify 呼び出しに閉じた改善にする。`EmitOptions` は値設定だけに保ち、mutable な scratch は持たせない。現実的な第一段階は `MapIter` の sorted path に小規模 map 用の stack buffer fallback（例: 32/64 keys までは固定配列、超えたら allocate）を入れること。次の段階で必要なら `Emitter` に一時 allocator を渡す形にするが、Python から複数回使い回す `zyaml_emit_context` は lifetime 管理が増えるため、ベンチで明確な必要性が出るまで避ける。
- 検証: 10k keys の mapping dump benchmark を `sort_keys=true/false` で分ける。

## P2 - 可読性・保守性

### 8. parser の状態フィールドを用途別 struct に分ける

- 対象: `src/parser/parser.zig:50`
- 問題: `Parser` が scanner、anchor、flow、directive、quoted scalar の状態をすべて直接持っている。関数ごとの副作用範囲が読みにくく、将来の修正で状態復元漏れを作りやすい。
- 修正案: `AnchorState`, `FlowState`, `DirectiveState` のような小 struct にまとめる。まず field grouping だけに留め、挙動変更はしない。
- 検証: `zig build test`。差分は rename/move に限定する。

### 9. `parseValueWithContext()` の dispatcher を薄くする

- 対象: `src/parser/parser.zig:105`
- 問題: YAML の型判定、flow 初期化、mapping 変換、error policy が 1 関数に混在している。SLA と branch count のルールに反しており、新しい token ケース追加時に回帰しやすい。
- 修正案: `parseByLeadingToken()` と `parseScalarLikeThenMaybeMapping()` に分ける。flow depth の初期化は `parseFlowContainerAt()` に閉じ込める。
- > **[QUESTION]** 現在の `parseValueWithContext()` を読まないと境界が判断できないが、ざっくり「leading token によるルーティング（`-`/`[`/`{` 等）」→ `parseByLeadingToken()`、「plain/quoted scalar を読んでから `:` を判定して mapping に変換」→ `parseScalarLikeThenMaybeMapping()`」という分割で合っているか？それとも別の境界線を想定している？
- > **[ANSWER]** その理解で合っている。境界は「先頭 token からどの parser に渡すか」と「読んだ値を mapping key として再解釈するか」で切る。`parseValueWithContext()` は depth 管理、quote indent 設定、空入力処理、leading token dispatcher 呼び出しだけにする。`parseByLeadingToken()` は `.dash`, `.question`, `.open_bracket`, `.open_brace`, quote, anchor/tag/alias, block scalar を分岐する。`parseScalarLikeThenMaybeMapping()` は scalar/flow/anchor/tag/alias など「値として読んだ後に `tryAsMappingOrReturn()` すべきもの」だけを受け持つ。block sequence や block scalar のように mapping key 再解釈しないものは直接返す。
- 検証: 既存 suite に加え、各 leading token ごとの table test を追加する。

### 10. block scalar のエラー握りつぶしをなくす

- 対象: `src/parser/block.zig:57`
- 問題: `appendNTimes(... ) catch {}` で OOM を無視している。結果が壊れた YAML 文字列になる可能性がある。
- 修正案: `handleBlockScalarBlankLine()` を `YamlError!void` にし、呼び出し側で `try` する。
- 検証: `std.testing.allocator` の failure injection が使えるなら追加。最低限 `zig build test`。

### 11. `safe_load_all()` の document split を parser 側に寄せる

- 対象: `python/zyaml/__init__.py:492` 付近
- 問題: Python 側で `data.split("\n---")` しており、quoted/block scalar 内の `---`、先頭 `---`、コメント付き document marker など YAML の文脈を見ていない。
- 修正案: C API に multi-document parse iterator か sequence-returning API を追加し、Python はそれを呼ぶだけにする。
- > **[QUESTION]** iterator と sequence-returning のどちらを想定しているか？iterator（`zyaml_parse_start()` / `zyaml_parse_next()` / `zyaml_parse_end()` 的な3点セット）だと C API が増えるが大量ドキュメントに強い。sequence-returning（`zyaml_parse_all()` → `[]Value` を一発で返す）だとシンプルだがメモリを一気に消費する。どちらを優先するか、または両方必要か？
- > **[ANSWER]** まず sequence-returning を優先する。既存 core は multi-document を `Value.sequence` として扱う経路をすでに持っているので、`safe_load_all()` の正しさを直すには `zyaml_parse_all()` か Python 側で既存 parse 結果を「常に docs list として扱う」薄い API を追加するのが最小変更になる。iterator は大量ドキュメントには理想だが、parser state の外部公開、途中エラー時の所有権、Python generator の lifetime 管理が増える。まずは「常に list/sequence を返す parse_all」を実装し、必要が出たら iterator を P3/P4 の別タスクにする。
- 検証: block scalar 内 `---`、`--- # comment`、空 document を含む `safe_load_all()` テストを追加する。

### 12. ベンチマークを再現可能にする

- 対象: `tests/bench.py`, `src/bench.zig`
- 問題: `src/bench.zig` は `/tmp/bench_large.yaml` に依存し、Python benchmark は `_lib` 初期化前提が曖昧。README の性能値を検証する CI 経路もない。
- 修正案: benchmark 入力生成を Zig/Python で共有できる fixture に寄せ、`--json` 出力を CI artifact にできる形へ整える。性能値は中央値・環境・commit を記録する。
- 検証: `zig build bench` と `uv run python tests/bench.py --json -` が clean checkout で動くこと。

## 確認済み

- `uv run pytest tests/`: 121 passed, 2 warnings。
- `zig build test`: YAML test suite 1954/1954 passed まで確認。ただし今回のツールセッションではコマンド終了通知が返らなかったため、TODO 修正時はローカルで終了コードまで再確認する。

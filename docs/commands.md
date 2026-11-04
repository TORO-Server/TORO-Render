# コマンド一覧

```
godot --path . -s scripts/main.gd -- <コマンド> [--オプション 値] [--フラグ]
```

フラグは値を取らないオプション。値が `--` で始まるものはフラグとみなす（負の数 `-8` は値として扱える）。
コンテナでは `docker/run.sh <コマンド> ...` が同じ引数を受ける（`--data-dir` は `/data` が既定）。

## 共通（`run` / `watch` / `zoom` / `dev dbtest`）

| オプション | 既定 | 内容 |
| --- | --- | --- |
| `--config FILE` | `/config/maps.json`（あれば） | マップ設定 |
| `--db-host`, `--db-port` | 設定の `db`、無ければ `127.0.0.1:4000` | データベース |
| `--rate N` | 8000000 | 書き込みと blob 読み出しで共有するバイト/秒の上限。0 で無制限 |
| `--dry-run` |  | データベースへ書かない |
| `--live URL` | 設定の `live` | プレイヤー位置の WebSocket。`off` で無効 |
| `--max-load N` | `run` 4 / `watch` 2.5 | 1 分間の負荷平均がこれ以上なら待つ |
| `--max-players N` | `run` 0 / `watch` -1 | これを超える人数がいる間は待つ。負の値で人数を見ない |
| `--online-file FILE` |  | プロキシが書く `"<人数> <UNIX 時刻>"` のファイル |
| `--stale-after S` | 120 | `--online-file` がこの秒数より古いと「忙しい」とみなす |
| `--poll S` | 30 | 待機中に条件を調べ直す間隔 |
| `--data-dir DIR` | コンテナ: `/data`。`render` と `dev`: `res://data` | `build-data` の出力 |

## `render`

`render --region-dir DIR --tiles tx,ty,w,h[;...] [--persp NAME] [--out DIR] [--ref DIR]`

タイル矩形（zoom 0）を描いて `{x}_{y}.png`、`{x}_{y}.webp`（ロスレス）、`manifest.json`（HashCode 付き）を `--out` に出す。
矩形が複数のときは `OUT/r{tx}_{ty}/` に分ける。

| オプション | 内容 |
| --- | --- |
| `--persp NAME` | 視点（既定 `iso_S_90_lowres`） |
| `--ref DIR` | 参照 PNG と画素を比較して一致率を表示する |
| `--min-y`, `--max-y` | 描画する高さの範囲（-64 / 320） |
| `--repeat N` | 最初の矩形を N 回描く（計測用） |
| `--mesher cpu` | CPU の参照メッシャーを使う |
| `--cmp-chunk cx,cz[;...]` | CPU と GPU のメッシャーの差分を表示して終了 |
| `--verbose`, `--flip-front`, `--probe ...` | デバッグ用 |

## `scan`

`scan --region-dir DIR --out FILE`: 非空チャンクの `(cx, cz, min_y, max_y)` を int32 のリトルエンディアンで書く
（Dynmap-GPU と同じ形式）。

## `run`

`run --map-id N [オプション]`。マップは `--config` の `id` で引く。`--region-dir`、`--persp`、`--zoom-max`、`--mega` で
上書きまたは設定なしでの指定ができる。

| オプション | 既定 | 内容 |
| --- | --- | --- |
| `--state-dir DIR` | `/state` | スキャンキャッシュ、進捗、変更タイルの記録 |
| `--state FILE` |  | 進捗ファイルを別に指定 |
| `--scan-cache FILE` | 状態ディレクトリ内 | スキャンキャッシュの場所 |
| `--rescan` |  | キャッシュを使わずに再スキャンする |
| `--bbox tx0,ty0,tx1,ty1` |  | この範囲（両端を含む）のタイルだけ |
| `--only-missing` |  | 行がまだ無いタイルだけ描き、書く |
| `--count-missing` |  | 未作成のタイル数を数えて終了（GPU 不要） |
| `--skip-megas N` | 0 | 計画の先頭 N 個のメガタイルを飛ばす |
| `--limit N` | 0 | N 個のメガタイルで止める（試験用） |
| `--per-run N` | 8 | 1 バッチのメガタイル数 |
| `--gap S` | 1.0 | バッチの間隔 |
| `--zoom-all` |  | 全レベルの全親を点検する（全走査） |
| `--zoom-since MS` |  | この時刻（ミリ秒）以降に書かれた候補タイルも zoom の起点に加える |
| `--keep-png DIR` |  | 描いた PNG / WebP をここへも保存する |

## `watch`

`watch --config FILE [オプション]`: 設定の全マップを監視する。

| オプション | 既定 | 内容 |
| --- | --- | --- |
| `--map-id N[,N...]` | 全マップ | 監視するマップを絞る |
| `--state-dir DIR` | `/state` | 待ち行列と時刻（`watch-<MapID>.json`） |
| `--interval S` | 60 | 周期 |
| `--overlap S` | 30 | 次の周期が少し前から始まるための重なり（取りこぼし防止） |
| `--max-megas N` | 4 | 1 バッチのメガタイル数 |
| `--stale-after-queue S` | 600 | この秒数より長く待った分を最優先にする |
| `--once` |  | 1 回見て、最大 1 バッチだけ処理して終了（試験用） |

## `zoom`

`zoom --map-id N --zoom-max Z (--all | --seed FILE)`: 描かずに zoom-out を再構築する。`FILE` は 1 行に 1 タイル
（`x y`、zoom 0）。

## `build-data`

`build-data --jar FILE [--reports FILE] [--out DIR]`: クライアント jar から次を作る（`--out` の既定は `res://data`）。

- `blocks.json`, `atlas.bin`, `atlas.json`, `biomes.json`: 列単位の表（`BlockTable`）
- `assets/blockstates/*.json`, `assets/models/block/**.json`, `textures.bin`, `textures.json`: ブロックモデル（`StateRegistry`）
- `block_defaults.json`: ブロックの既定プロパティ（`--reports` が要る）

## `dev`

`dev <サブコマンド> [オプション]`。GPU が要らないものは `--headless` でも動く。

| サブコマンド | 内容 |
| --- | --- |
| `dump --region FILE.mca --chunk cx,cz` | 1 チャンクの NBT 木（配列は要素数のみ） |
| `column --region FILE.mca --chunk cx,cz` | セクションごとのパレット数と光の有無 |
| `topblocks --region-dir DIR --tile tx,ty` | `iso_S_90_lowres` の 1 タイルの各列の最上位の非空気ブロック |
| `colblocks --region-dir DIR --chunk cx,cz --xz x,z` | 1 列のブロック状態の変化と光 |
| `encodetest --dir DIR` | PNG に対するロスレス WebP のサイズと往復の確認 |
| `zoomtest [--seed N]` | zoom のシェーダーと CPU 参照実装を乱数タイルで比較（GPU が要る） |
| `dbtest --map-id N [--scratch-id 99001]` | 実マップで、保存済みの親タイルを子から再計算して一致を確認し、その後 scratch の MapID だけに書き込み・読み出し・削除の往復を行う |

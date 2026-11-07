# 設計

## 描画パイプライン

```
.mca 領域ファイル
  → scripts/render/nbt.gd, chunk_data.gd, gpu_world.gd     CPU: NBT 解析、パレット・long 配列・光をバッファに詰める
  → shaders/mesh_chunks.glsl  （コンピュート）             GPU: ブロック状態 → クアッド（隠面処理、滑らかな光、色調、流体）
  → shaders/raster.glsl       （頂点 + フラグメント）       GPU: 正射影ラスタライズ、深度、Dynmap のシェーディング、半透明パス
  → shaders/finish.glsl       （コンピュート）             GPU: 非乗算化してタイル画像にする
  → scripts/job/publisher.gd                               CRC32 の HashCode、ハッシュ一致のスキップ、ロスレス WebP、TiDB へ書き込み
  → shaders/zoom.glsl         （コンピュート）             GPU: 親タイル = 4 枚の子の 2x2 平均、zoom レベルごと
```

- `state_registry.gd` は blockstate とモデル（multipart、variants、要素の回転、rescale、面の回転、x/y の状態回転）を
  クアッドに焼く。Dynmap（Java）と同じ float32 演算で行うので、45° の植物の同点処理まで合う。
- `persp.gd` は Dynmap の `IsoHDPerspective` のワールド → マップ変換（倍精度）。計画（`Planner`）と変更検出
  （`AnvilChanges`）も同じ行列を使う。
- 半透明クアッドは CPU で float32-of-double の距離により奥から手前へ並べ、同点は チャンク / ブロック / クアッドの順に
  する。これで水とガラスの混ざり方が毎回同じになる。
- `mesher.gd` は CPU の参照実装（`render --mesher cpu`）。`--cmp-chunk cx,cz` で GPU メッシャーとの差分を取れる。
- タイル `(tx,ty)`（`iso_S_90_lowres`）はブロック x が `[32*tx, 32*tx+32)`、z が `[-32*ty-32, -32*ty-1]`。
  画像の 0 行目が北端。HashCode は ARGB の整数をリトルエンディアンに並べた CRC32（Dynmap が保存する値）。

## モジュール

| 場所 | 役割 |
| --- | --- |
| `scripts/main.gd` | `SceneTree` の入口。最初の単語でコマンドを振り分ける |
| `scripts/cli/args.gd` | `--key value` と `--flag` の解析。値が `--` で始まる場合はフラグとみなす |
| `scripts/store/mysql.gd` | MySQL テキストプロトコルの最小実装（`mysql_native_password`、TLS なし）。blob は `X'hex'` リテラル |
| `scripts/store/tile_store.gd` | `dynmap_Tiles` への点参照、書き込み、削除。読み書きで 1 つの転送量予算（`--rate`）を共有 |
| `scripts/store/zoom_builder.gd` | zoom-out の再構築。GPU（`zoom.glsl`）と CPU の参照実装（`combine_cpu`）を持つ |
| `scripts/map/planner.gd` | スキャン結果から候補タイルとメガタイルを求める。キーは並べ替え可能な int64 |
| `scripts/map/anvil_changes.gd` | 領域ファイルのヘッダ（チャンクごとの最終保存時刻）から変更を検出する |
| `scripts/job/renderer_pool.gd` | 1 つの `RenderingDevice`、ブロックモデル、ブロック表を共有し、（視点, 領域）ごとに `IsoRenderer` を持つ |
| `scripts/job/publisher.gd` | 次の規則でゼロ段のタイルを書く（候補判定、ハッシュ一致のスキップ、空タイルの削除） |
| `scripts/job/run_job.gd` | マップ全体のジョブ |
| `scripts/job/watch_job.gd` | 複数マップの常駐更新 |
| `scripts/job/gate.gd` | 描画してよいかの判定（負荷、プレイヤーの有無） |
| `scripts/job/live_feed.gd` | プレイヤー位置の WebSocket 購読 |
| `scripts/job/dirty_feed.gd` | ゲームサーバーからのブロック変更イベント（WebSocket サーバー、token 認証） |

## 設計上の判断

**Python を持たない。** 以前は計画、アップロード、zoom-out、バッチ実行、常駐更新、データ生成が Python で、描画コンテナと
ツール用コンテナを分けていた。今は 1 つのプロセスが描画からアップロードまで行うので、バッチごとにコンテナを起動する
必要がなく、描いた画像はファイルを介さずメモリのまま発行される。

**DB ドライバを使わない。** `Mysql` は約 250 行で、TiDB 7.5 に対して接続、問い合わせ、結果の読み取りができる。Godot に
MySQL クライアントが無いための自作で、データベースは同一ホストかトンネルの先にある前提（TLS なし）。

**zoom-out は GPU。** 親 1 枚は子 4 枚（各 128×128）の 2x2 平均（各チャンネル、切り捨て）。64 枚ずつまとめて 1 回の
ディスパッチで計算する。CPU の参照実装と一致することを `dev zoomtest` で確認できる。zoom の途中のタイルは WebP のまま
保持するため、`--zoom-all` で数万枚の親を作ってもメモリは小さい。

**透明ピクセルは (0,0,0,0) に正規化する。** レンダラーは透明ピクセルを 0 で書くが、ロスレス WebP は透明部の RGB を
保持しない。データベースから読んだタイルも透明部を 0 に戻すので、保存済みの子から作った親と、描き立ての画像から作った
親が一致する（HashCode の再現性）。

**HashCode は標準の CRC32。** `TileCodec.crc_hash` は zlib の CRC32 と一致する（以前は符号付き 32 ビットの表を使っており、
標準値と異なっていた。修正前に書かれたタイルは、次に描画されたときに画素そのままで一度だけ書き直される）。

**変更検出にゲームサーバーへの連携は要らない。** Anvil の領域ファイルは、チャンクごとの「最終保存時刻」を先頭 8 KB に
持つ。前回の周期以降に保存されたチャンクが変更されたチャンクで、mtime が動いていないファイルは開かない。秒単位の
時刻なので、直近 2 秒以内に更新されたファイルは次の周期でもう一度見る。

**プレイヤー位置で優先順位を付ける。** 描画の待ち行列を、メガタイルからプレイヤーまでの距離（マップ自身の投影を通した
メガタイル単位）で並べる。長く待っているものは先頭へ出す。位置は Dynmap のマップが表示するプレイヤーのものなので、
非表示のプレイヤーは含まれない。

**変更検出はイベントと Anvil の二層。** ゲームサーバー（TORO-Core の map-dirty モジュール）がブロック変更を
チャンク単位で集めて WebSocket で送り、watch はそれを Anvil の検出と同じ待ち行列に合流させる（先に入った時刻を保持）。
イベントは検知を速くするだけで、取りこぼしても Anvil の周期スキャンが拾う。逆にイベントだけに頼らないので、
サーバー側の連携が止まっても地図は止まらない。token は接続直後の 1 通で見せる（Godot の WebSocket サーバーは
接続時のヘッダーを読めないため、dynmap-live のヘッダー方式は取れない）。

**洪水制御は描画側に置く。** WorldEdit の一括編集や高速設置の荒らしは、検知側では量を潰しきれない（範囲が正当な
変更と区別できない）。そこで watch の待ち行列で、再描画の間隔（`--mega-cooldown`）、繰り返し変わるメガタイルの
降格と 1 バッチの枠上限、最古参の予約枠、滞留時の行順処理（`--bbox-threshold`）を効かせる。描画の予算
（Gate、1 バッチの数、転送速度）は変えない。対象は捨てず、待つ時間が延びるだけにする。

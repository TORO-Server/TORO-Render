# 運用

## セットアップ

1. **描画用データ**を Minecraft のクライアント jar から作る（リポジトリには含めない）。`--reports` はデータジェネレーターの
   `reports/blocks.json`（ブロックの既定プロパティ用）。約 10 秒で終わり、出力は `data/` へ。
   ```
   godot --headless --path . -s scripts/main.gd -- build-data --jar client-26.3.jar --reports blocks.json --out data
   ```
2. **ローカル実行**（Vulkan 対応 GPU、64x64 の小さなウィンドウが開く。`--gpu-index N` でデバイスを選ぶ）:
   ```
   tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out -Extra "--persp iso_SE_30_hires"
   ```
3. **コンテナ**（Mesa と、画面の無い Wayland コンポジタ。下の「なぜコンテナに Wayland コンポジタがあるのか」を参照）:
   ```
   docker build -f docker/Dockerfile -t toro-render:dev .
   ```
   サーバーへ作業ツリーを送ってそこでビルドするなら `tools/deploy.ps1 -Server user@host -Port 22`。
   単発のジョブは `docker/run.sh` から:
   ```
   WORLD_DIR=/path/to/region DATA_DIR=$PWD/data OUT_DIR=/dev/shm/out \
     docker/run.sh render --region-dir /world --tiles "0,2,8,8" --persp iso_SE_30_hires --out /out
   ```
   `docker/run.sh` が使う環境変数: `WORLD_DIR`（`/world` に読み取り専用）、`DATA_DIR`（`/data`）、`OUT_DIR`（`/out`）、
   `STATE_DIR`（`/state`）、`CONFIG`（`/config/maps.json`）、`ONLINE_FILE`（`/online.txt`）、`EXTRA_GROUPS`、`NETWORK`、
   `IMAGE`、`CPUS`、`MEMORY`。`run` と `zoom` では既定でホストのネットワークを使う（DB が `127.0.0.1` で公開されているため）。

## マップ設定

`run` と `watch` は 1 つの JSON からマップを読む（雛形: [docker/maps.example.json](../docker/maps.example.json)）。

```json
{
  "db": { "host": "127.0.0.1", "port": 4000, "user": "root", "database": "dynmap" },
  "live": "wss://map.example.net/up/ws",
  "maps": [
    { "id": 30002, "region": "/worlds/flat/region", "persp": "iso_SE_30_hires", "zoom_max": 7 }
  ]
}
```

- `id` は Dynmap の MapID。マップの Dynmap ワールド名（`main` など）は `dynmap_Maps` から引く。
- `persp` は 4 つの視点名のいずれか。`zoom_max` は作る zoom の段数。`mega`（既定 8）、`min_y`（-64）、`max_y`（320）も指定できる。
- `live` を省くとプレイヤー位置を使わない。
- DB にパスワードがある場合は環境変数 `DYNMAP_DB_PASSWORD` に入れる（設定ファイルに書かない）。
- 設定ファイルは `/config/maps.json` にあれば自動で読む。それ以外は `--config FILE`。

## マップ全体のジョブ（`run`）

```
docker/run.sh run --map-id 30002 --state-dir /state --only-missing
```

1. ワールドを一度スキャンする（結果は状態ディレクトリの `scan-<MapID>.bin` にキャッシュ。Dynmap-GPU と同じ形式）
2. 候補タイルとメガタイル（既定 8×8 タイル）を求める
3. サーバーが静かなときだけ、メガタイルを数個ずつ描いてアップロードする
4. 最後に、変更のあったタイルから zoom-out レベルを一度だけ再構築する

進捗は状態ディレクトリに残るので、いつ止めても、再開できる。始める前に `--count-missing` で未作成のタイル数を確認し、
本番では `--only-missing` から始めるのが安全。`--zoom-all` は全レベルを走査するので、必要なときだけ使う。

**静穏の条件**: 1 分間の負荷平均が `--max-load`（4）未満で、誰もオンラインでないこと（`--max-players 0`）。プレイヤーの有無は
次のどちらか（両方でもよい）から得る。

- ライブフィード（下記）。見えているプレイヤーが 1 人でもいれば静かでない
- `--online-file FILE`: プロキシが書く `"<人数> <UNIX 時刻>"` の 1 行のファイル。無い、読めない、古い（`--stale-after`、120 秒）
  場合は忙しいとみなす

どちらも指定しない場合は、プレイヤーを見ずに実行する（警告を出す）。処理中のバッチは、プレイヤーが来ても最後まで終える。

## 常駐更新（`watch`）

```
docker compose -f docker/compose.watch.yaml up -d
```

設定ファイルの全マップを 1 つのプロセスで担当する。周期（60 秒）ごとに、

1. 各マップの領域ファイルのうち mtime が動いたものだけ、先頭 8 KB を読む。チャンクごとの最終保存時刻が前回以降のものが
   変更されたチャンクで、地形の自動生成、ブロックの設置・破壊、レッドストーン、作物の成長などが対象になる
2. 変更チャンクと周囲 8 チャンク（光と隠面処理が隣を見るため）が投影されるメガタイルを待ち行列に入れる
   （状態ディレクトリの `watch-<MapID>.json` に保存）
3. 負荷が `--max-load`（2.5）未満なら、最も優先度の高いメガタイルを 1 バッチ（`--max-megas`、4）描き、ハッシュ一致の
   スキップ付きで書き込み、zoom-out の親を作り直す

レンダラーは起動したまま使い回す。歩き回っただけで保存済みの地形が変わらなければ、何も再描画しない。

初回の起動時は、その時点以降の変更だけを見る（`since` は起動時刻から）。停止中に起きた変更も、領域ファイルの時刻から
拾える。

### プレイヤー位置（WebSocket）

設定に `live` があると、[`LiveFeed`](../scripts/job/live_feed.gd) が監視する各 Dynmap ワールドをマップサイトの `/up/ws` へ
購読しに行く。ワールドごとに 1 本の接続で、

- 送る: `{"subscribe": "<ワールド名>"}`
- 受ける: `{"type":"players","players":[{"account","world","x","y","z","health","armor"}, ...]}`
  （位置が変わるたびに。Dynmap のマップが表示しているプレイヤーのみ）

切れたら 5 秒から 60 秒の間隔で自動的に再接続する。使い道は 2 つ:

- `watch`: 待ち行列を並べ替える。プレイヤーに近いメガタイルが先、それ以外は入れた順。`--stale-after-queue`（600 秒）より
  長く待っているものは、全てに先立って処理する
- `run`: 見えているプレイヤーがいる間は処理を始めない

非表示にしているプレイヤーはフィードに出ないので、「誰もいない」ことの厳密な保証が要る場合は `--online-file` も併用する。

## 本番運用の安全策

- コンテナ: CPU 1 個を最低の共有度で、`nice 19`、`ionice idle`、メモリ 1〜1.5 GB、ルートとワールドは読み取り専用、
  ケーパビリティなし、一時ファイルは tmpfs（SSD へ書かない）
- 負荷が上限を超える間は描画しない。`run` ではさらに、誰かがオンラインの間も待つ
- TiDB: `(MapID,x,y,zoom) IN (...)` の点参照のみ。書き込みは `--rate`（既定 8 MB/s）で制限し、ハッシュが同じタイルは書かず、
  空のタイルは行を削除する。全レベル走査をするのは `--zoom-all` だけ
- メモリ: 1 バッチ分の画像（メガタイル × 8 個 ≒ 数十 MB）と、チャンクキャッシュ（バッチ後に解放）だけを持つ

## なぜコンテナに Wayland コンポジタがあるのか

Godot の `--headless` には `RenderingDevice` が無く、Xvfb には DRI3 が無いため Mesa が llvmpipe（CPU）に落ちる。
wlroots の headless バックエンドを使う `cage` を入れると、Godot が内蔵 GPU のレンダーノード上で Vulkan を使える
（`docker/entrypoint.sh`）。Forward+ は起動に約 8 秒余計にかかるので、Mobile レンダラーを使う。GPU が要らないコマンド
（`scan`、`build-data`、`dev`、`run --count-missing`）は `--headless` でも動く。

## 速度の目安

8×8 のメガタイル（64 タイル、114 万クアッド、`iso_SE_30_hires`）が、低優先度のコンテナの UHD 730 で、描画 1.3 秒
（パック 0.76、メッシュ 0.46、ラスタ 0.05）+ ハッシュ・WebP 0.25 秒。同じ範囲を CPU のメッシャーで描くと数分かかる。
GDScript の NBT 解析（1 チャンク約 1.7 ms）が最大の負担になっている。

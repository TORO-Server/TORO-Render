# TORO-Renderer

内蔵 GPU（開発は Intel UHD 730 / Mesa ANV Vulkan）で動く、Dynmap 互換のマップタイルレンダラー。
Godot 4.7 の単一プロジェクトで、処理は GDScript、重い計算は GLSL で書いている。
Minecraft の Anvil ワールドを読み、ブロックモデルをそのままラスタライズして、Dynmap の TiDB タイル表
（`dynmap_Tiles`）へ zoom-out レベルまで含めて書き込む。

- Dynmap の標準的な 4 つの視点を描画できる: `iso_S_90_lowres` / `iso_S_90_hires` /
  `iso_SE_30_lowres` / `iso_SE_30_hires`
- Python は不要。計画・DB・zoom-out・常駐更新・アセット抽出まで全て GDScript（`scripts/main.gd` が唯一の入口）

## クイックスタート

```
# 1. クライアント jar から描画用データを作る（約 10 秒）
godot --headless --path . -s scripts/main.gd -- build-data --jar client-26.3.jar --reports blocks.json --out data

# 2. ローカルで数タイルを描く（Vulkan 対応 GPU、64x64 の小さなウィンドウが開く）
tools\run-local.ps1 -Region C:\worlds\flat\region -Tiles "-8,4,2,2" -Out out -Extra "--persp iso_SE_30_hires"
```

サーバーでの運用（コンテナ、マップ設定、全体レンダリング、常駐更新）は [docs/operations.md](docs/operations.md) を参照。

## コマンド

```
godot --path . -s scripts/main.gd -- <コマンド> [--オプション 値] [--フラグ]
```

コンテナで使う書き出し用テンプレート (release template) は `-s` を受け付けない。そのため `project.godot` の
`application/run/main_loop_type` で `scripts/main.gd` (クラス名 `RendererMain`) を入口にしている。
テンプレートは main scene が無いと起動しないので、空の `main.tscn` を main scene にしている。
`godot --path . -- <コマンド>` でも同じように動く。

| コマンド | 内容 |
| --- | --- |
| `render` | タイル矩形を PNG / ロスレス WebP / `manifest.json` へ出力（デバッグ、参照画像との比較） |
| `scan` | ワールドのスキャンキャッシュ（非空チャンクごとの `cx, cz, min_y, max_y`）を作る |
| `run` | マップ全体のジョブ: スキャン、計画、描画、アップロード、zoom-out 再構築。中断・再開できる |
| `watch` | 常駐更新。サーバーが保存したチャンクの周辺だけを再描画する。プレイヤーに近い場所を優先 |
| `zoom` | 描画せずに zoom-out レベルだけを再構築する |
| `build-data` | クライアント jar からブロック、モデル、テクスチャ、バイオームを取り出す |
| `dev` | デバッグ補助（`dump`, `column`, `topblocks`, `colblocks`, `encodetest`, `zoomtest`, `dbtest`） |

全オプションは [docs/commands.md](docs/commands.md)。

## ディレクトリ

```
scripts/main.gd     コマンドの振り分け
scripts/cli/        引数解析（Args）、ログと待機（Term）
scripts/render/     NBT、チャンク復号、ブロックモデル → クアッド、GPU メッシャー、ラスタライザー、視点
scripts/store/      Mysql（プロトコル実装）、TileStore（dynmap_Tiles）、ZoomBuilder
scripts/map/        MapDef、ScanCache、Planner（タイル・メガタイル計画）、AnvilChanges（変更検出）
scripts/job/        RendererPool、Publisher、RunJob、WatchJob、Gate（静穏判定）、LiveFeed（プレイヤー位置）
scripts/cmd/        各コマンドの実装
shaders/            mesh_chunks（メッシャー）、raster、finish（非乗算化）、zoom（2x2 平均）
docker/             Dockerfile、起動スクリプト、compose、設定例
tools/              PowerShell の補助スクリプト（ローカル実行、デプロイ）
docs/               詳細な文書
```

## ドキュメント

| 文書 | 内容 |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | 描画パイプライン、各モジュールの役割、設計上の判断 |
| [docs/operations.md](docs/operations.md) | セットアップ、マップ設定、全体ジョブ、常駐更新、プレイヤー位置の WebSocket、本番運用の安全策 |
| [docs/commands.md](docs/commands.md) | コマンドごとのオプション一覧 |
| [docs/igpu-report.md](docs/igpu-report.md) | 内蔵 GPU の調査と計測の報告（英語、2026-11-04 時点） |

## 既知の差異

- エンティティブロック（チェスト、ベッド、看板、旗、頭）と `uvlock` は描かない
- GPU の違いで、半透明の縁や同一平面の葉など、16k ピクセル中の数ピクセルが異なる
- `.glsl` などのインポート済みリソースは編集後に再インポートが必要: `godot --headless --path . --import`
  （Docker ビルドは自動で行う）

## ライセンス

[MIT License](LICENSE)

Minecraft のアセット（テクスチャ、モデル、ブロック状態）はリポジトリに含まれない。`build-data` が、利用者が持つ
クライアント jar から取り出す。ワールド → マップの変換式、シェーディング、タイルの形式は Dynmap（Apache License 2.0）の
仕様に合わせて実装している。

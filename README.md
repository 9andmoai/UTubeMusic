# UTube Music

iPhoneに曲を保存し、同じアプリでお気に入り・プレイリスト・オフライン再生を扱う個人用音楽アプリです。

- AI機能はありません。YouTube / YouTube Music / Spotify の公式アプリではありません
- 対象：iPhone 14 / iOS 27.0.1（利用者申告）。開発PC：Windows
- 現在の最新版：**0.3.11**（build 17）
- ライセンス：MIT（[LICENSE](LICENSE)）。依存ライブラリの条件は [一次資料](#一次資料・依存) を参照

## できること

- **探す**：YouTube Music の公開ホーム（プレイリスト／アルバムの棚）の表示、曲・プレイリスト・アルバム検索、入力中の検索候補、気分・ジャンル別の入口
- **聴く**：検索結果や公開プレイリスト／アルバムからそのまま再生（収録順・シャッフル対応）。保存済み音声があればそちらを優先し、未保存曲はストリーミング再生
- **試し聞き**：保存前に最大15秒。チャプター名にサビ／Chorus／Refrain があればその位置から
- **歌詞**：再生画面で同期歌詞カードを表示し、タップで全画面表示。行タップでその位置へ移動（時刻なし歌詞はテキスト表示）
- **ライブラリ**：お気に入り、自分のプレイリスト、複数プレイリストへの同時追加、公開リストの一括追加（曲順を保持）
- **保存とオフライン**：ダウンロードは任意。曲の情報だけ登録してオンライン再生もでき、後から「オフライン用にダウンロード」も可能。ダウンロードだけを1曲／複数選択で削除し、所属や曲順を残したままオンライン再生へ切り替えることもできます
- **再生の工夫**：バックグラウンド再生、ロック画面／イヤホン操作、シャッフル／リピート／キュー、冒頭の無音の自動スキップ（曲ごとの指定も可）、曲ごとの音量差を抑える調整（大きい曲だけ下げる）
- **その他**：年齢確認が必要な動画では同じ曲の公式音源を探して再生、通信量を抑えるためのメタデータ／ジャケットの再利用

細かい仕様や制限はバージョンごとに違うため、経緯は [CHANGELOG.md](CHANGELOG.md) にまとめています。

## 入れる方法（概要）

SideStore 経由で、無料の Apple Account を使って入れます。通常の7日更新も無料です（有料VPN契約は不要、LocalDevVPN を使用）。

1. Windows で初期準備をし、SideStore Stable を iPhone に導入する
2. GitHub Actions で生成した未署名IPA（`UTubeMusic-0.3.11-unsigned.ipa`）を iPhone の「ファイル」に置く
3. SideStore の My Apps から追加し、起動・保存・機内モード再生などを確認する

更新はアプリを削除せず、同じアプリIDへ上書きします。保存した曲・お気に入り・プレイリストは引き継がれます。

手順の詳細は [INSTALL_IPHONE.md](INSTALL_IPHONE.md) を参照してください。

## ビルドする方法

公開リポジトリで標準の GitHub-hosted runner を使う構成で、有料の larger runner は使いません。

1. このリポジトリをフォーク／クローンする
2. Actions → `Build personal iPhone app (free standard runner)` → Run workflow（手動実行のみ、同時1件、最大30分）
3. シミュレーターのビルドとテストを通してから、実機用ビルドを行う
4. 成功時の成果物 `UTubeMusic-0.3.11-SideStore` からIPAとSHA256を取得する（Actions の保管期限は1日なので、手元にも保管を）

Mac がある場合は Xcode と XcodeGen を用意して `bash scripts/build_ipa.sh` でも同じビルドができます。Windows では実行できません。

## バックアップ

「ファイル」→「このiPhone内」→「UTube Music」→「UTubeMusic」フォルダーを、アプリを終了してから丸ごと別の場所へコピーしてください。音声・画像・`library.json` がまとめて保管されます。`library.previous.json` は直前の索引で、誤削除用のごみ箱ではありません。

## 検証について

- CI ではネイティブ／Python の自動テストと、iPhone 14 相当の画面キャプチャで表示を確認しています。バージョンごとのテスト件数・検証済みソース・未確認事項は [CHANGELOG.md](CHANGELOG.md) に記録しています
- 自動テストで確認できる範囲と、iPhone 実機でしか確認できない範囲（実通信での長時間再生、日本語キーボード操作、聞こえ方など）は区別して記録しています。新機能は原則として「更新後に実機確認が必要」です
- 画面のデザイン検討は [design/](design/) にあります（サンプルデータによるレイアウト確認用で、実際の取得・再生は行いません）

## 一次資料・依存

- [GitHub Actions の無料条件と保存枠](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [SideStore の前提条件](https://docs.sidestore.io/docs/installation/prerequisites) / [導入手順](https://docs.sidestore.io/docs/installation/install) / [FAQ](https://docs.sidestore.io/docs/faq)
- [LocalDevVPN（日本 App Store）](https://apps.apple.com/jp/app/localdevvpn/id6755608044)
- [Python iOS 組み込み](https://docs.python.org/3.13/using/ios.html) / [Python Apple Support](https://github.com/beeware/Python-Apple-support)
- [yt-dlp EJS](https://github.com/yt-dlp/yt-dlp/wiki/EJS) / [Apple WebKit 用の実験的プラグイン](https://github.com/grqz/yt-dlp-apple-webkit-jsi)
- [Apple のバックグラウンド再生設定](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)
- [ytmusicapi の公開カタログ取得](https://ytmusicapi.readthedocs.io/en/stable/usage.html)

依存はバージョンと SHA256 を固定しています（Python-Apple-support 3.13-b14 / yt-dlp 2026.8.19 / yt-dlp-ejs 0.8.0 / certifi 2026.7.22 / WebKit plugin 0.1.1）。公開カタログの取得に非公式ライブラリ ytmusicapi を利用します。Google ログイン、ユーザーの Cookie、課金API、常設サーバーは不要です。権利・許可のあるコンテンツを対象にしてください。

# CacaoPhotoSlide

写真のフォルダをドロップすると、全画面のスライドショーにする Mac アプリ。音楽はなし。
既定は **Ken Burns**（写真がゆっくり寄ったり流れたりしながら、次の写真にクロスフェード）。

| できること | 中身 |
|---|---|
| フォルダを D&D | ウインドウに落とすか、Dock のアイコンに落とす。「開く…」（⌘O）でも |
| 開始写真 | 全部のサムネイルが並ぶ。クリックした写真から始める（ダブルクリックですぐ開始） |
| 全画面 | メニューバー・Dock・カーソルを隠し、画面を黒で覆う。表示中はスリープしない |
| 操作 | **Space** 停止 / 再開、**← →** 前へ / 次へ、**Esc** 終了 |
| 表示時間 | 1〜30 秒 |
| 切り替え | Ken Burns / クロスフェード / スライド / ズーム / なし。長さは 0.3〜3 秒 |
| 順番 | 名前順 / 撮影日順（EXIF、なければファイルの作成日）/ ランダム |
| 表示 | 全体を表示（余白は黒）/ 画面いっぱい（はみ出しを切る） |
| そのほか | 繰り返し、サブフォルダも含める。前回のフォルダを次回も開く |

読めるのは macOS の ImageIO が読める画像（JPEG, HEIC, PNG, TIFF, RAW など）。SVG は対象外。
EXIF の向きは反映する。画面サイズに合わせて縮めて読むので、大きな写真でも軽い。

## 使い方

1. 写真のフォルダをウインドウにドロップ（複数可。写真そのものを落としてもよい）。
2. 途中から見たければ、サムネイルをクリック（見出しに「開始: N 枚目」と出る。× で最初からに戻る）。
   ランダムのときも、選んだ写真を最初に出してから混ぜる。
3. 表示時間や切り替えを決めて「スライドショーを開始」（Return または ⌘Return）。
4. Space で止める／動かす。止めると画面下に「一時停止 N / 総数 ファイル名」が出る。
   ← → で送る（止めたままでも送れる）。Esc か Q で終わる。

## 構成

```
CacaoPhotoSlide/
├── project.yml                     # XcodeGen の定義（ここから .xcodeproj を生成）
├── CacaoPhotoSlide.xcodeproj       # 生成物（xcodegen generate で再生成できる）
├── bump-version.sh                 # 配布用ビルドの前に 0.0.1 上げる
├── make-dmg.sh                     # 配布用 dmg を作る（背景は dmg/make-background.swift で生成）
├── icon/make-icon.swift            # アプリアイコンを描くスクリプト
├── dist/                           # ビルド済み: *.app / *.dmg
└── CacaoPhotoSlide/                # Mac アプリ（SwiftUI）
    ├── CacaoPhotoSlideApp.swift    # エントリ・メニュー・Dock へのドロップ受け取り
    ├── AppModel.swift              # フォルダ・写真一覧・設定の保存・スライドショーの起動
    ├── PhotoLibrary.swift          # フォルダから画像を集めて並べる（EXIF の撮影日）
    ├── ImageLoader.swift           # 画面サイズに縮めて読み、前後 2〜3 枚をキャッシュ
    ├── SlideshowController.swift   # 再生の状態（今の写真・前の写真・停止・Ken Burns の動き）
    ├── SlideshowWindow.swift       # 画面を覆う窓。キー操作、カーソル／メニューバーを隠す
    ├── Settings.swift              # 切り替え・順番・表示の種類と設定キー
    └── Views/
        ├── ContentView.swift       # メイン窓（ドロップ・サムネイル・設定・開始）
        └── SlideshowView.swift     # 全画面の描画
```

### 描画のしくみ

SwiftUI のアニメーションには頼らず、`TimelineView` で毎フレーム「今の時刻」をもらい、
今の写真を出し始めた時刻からの経過で、切り替えの進み具合と Ken Burns の位置を自分で計算する。
こうすると Space で止めたときに動きもその場で止まり、再開すると続きから動く。
停止中に ← → で送ったときは、切り替えだけは実時間で最後まで動かし、新しい写真は出だしで止めておく。

## ビルド

必要: Xcode、XcodeGen（`brew install xcodegen`）。

```bash
cd ~/CacaoApps/CacaoPhotoSlide
./bump-version.sh                         # 配布用ビルドのたびにバージョンを 0.0.1 上げる
xcodegen generate                         # project.yml を変えたときだけ
xcodebuild -project CacaoPhotoSlide.xcodeproj -scheme CacaoPhotoSlide -configuration Release \
  -derivedDataPath build/DerivedData build
rm -rf dist/CacaoPhotoSlide.app && cp -R build/DerivedData/Build/Products/Release/CacaoPhotoSlide.app dist/
./make-dmg.sh                             # dist/CacaoPhotoSlide-<version>.dmg
```

署名していないので、初回は Applications 内のアプリを右クリック →「開く」。

## ライセンス

MIT License（[LICENSE](LICENSE)）。

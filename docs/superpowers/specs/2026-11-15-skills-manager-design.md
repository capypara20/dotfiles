# スキル管理を dotfiles に組み込む 設計メモ（第3版）

- 作成日：2026-11-15
- 状態：Roze の承認待ち（承認されたら実装計画へ進む）
- 経緯のメモ：[2026-11-15-skills-setup-notes.md](2026-11-15-skills-setup-notes.md)
- 第1版からの変更：別リポジトリ案をやめて dotfiles に組み込む。リンク方式をやめてコピー方式にする（dotfiles に合わせる）
- 第2版からの変更：台帳を見出しつきの TSV にする（Roze の希望）。dotfiles は公開のままでよい（Roze 了承）

---

## 1. 目的（なぜ作るか）

Roze は Claude Code と GitHub Copilot の両方で Agent Skills（`SKILL.md`）を使っている。
使うマシンは複数ある（仕事PC・ノートPC・miniPC）。スキルは数が多く、入れ替えも激しい。

いま困っていることは 2 つ。

- 使いたいマシンが複数ある
- 簡単にインストールしたい

dotfiles はすでに全マシンに clone 済みで、「clone → install 1 回」で環境がそろう仕組みが動いている。
そこにスキル管理を組み込み、**dotfiles の install を実行すればスキルもそろう** 状態にする。

目的は「同期」ではなく「管理運営」。何をなぜ入れたかが Git の履歴に残ることを大事にする。

## 2. ゴール・やらないこと・失敗とみなすこと

### ゴール

- 新しいマシンでは、今までどおり「dotfiles を clone → install 1 回」でスキルも使える
- スキルを増やすときは「台帳に 1 行 → push → 各PCで pull と install 1 回」で済む
- スキルだけを入れ直したいときは、スキル専用のスクリプトを単体で実行できる
- 1 回の実行で Claude Code と Copilot の両方にスキルが入る
- 基本は全PC同じセット。ただし実行時に、入れるスキルを選ぶこともできる
- 自作スキルと、他の人が GitHub で公開しているスキルの両方を扱える

### やらないこと

- リアルタイム同期や、常駐して自動更新する仕組み
- claude.ai アカウントへのスキルのアップロード
- Claude Code プラグインやマーケットプレイスの管理
- プロジェクト内（`.github/skills` など）のスキル管理
- 公開スキルのバージョン固定（必要になったら後で足す）
- Codex・Gemini CLI への対応（ただし後から足しやすい作りにする）
- 初版では、スキルを sync（PC → リポジトリ）の対象にしない（第 6 章）

### 失敗とみなすこと（動いても NG）

- スクリプトが入れていないスキルを消したり、上書きしたりする
  - 対象：`~/.claude/skills/synced/`（claude.ai からの自動同期）、Agent Skill Ninja が入れたもの、手で入れたもの
- スキルのフォルダの中に退避ファイル（`*.bak-日付`）を作る
  - 退避したフォルダも `SKILL.md` を含むので、同じスキルが二重に読み込まれてしまう
- 管理者権限や sudo が必要になる
- 今の dotfiles の install（scoop・フォント・設定ファイル）の動きが変わる

## 3. 前提と制約

- 仕事PC：Windows 11、VS Code ＋ GitHub Copilot、GitHub Copilot アプリ
- ノートPC：Windows 11、Claude デスクトップアプリ、VS Code ＋ Claude Code 拡張
- miniPC：Linux（画面なし）だと推測。Claude Code を使い、スマホから Remote Control で操作する
- Roze は PowerShell・Python・bat が得意。Linux も学びたい

### 今の dotfiles の作り（読んで確認した）

- `install.ps1`（Windows）と `install.sh`（Linux）の 2 本立て。逆方向の `sync.ps1` / `sync.sh` もある
- **コピー方式**：シンボリックリンクを使わず、設定ファイルをコピーで配置する
  - 理由（README より）：特別な権限が要らず、どのPCでも確実に動くため
- 既存ファイルは `*.bak-日付` の名前で同じ場所に退避してから上書きする
- `-DryRun`（Linux は `--dry-run`）で予行演習ができる。`-SkipScoop`・`-SkipFonts` で一部を飛ばせる
- 知らないオプションはエラーにする（打ち間違いで本番が動かないように）
- コメントやログは日本語。初心者にも読めるように丁寧に書いてある
- `claude/CLAUDE.md` だけを Claude Code 用に管理している。`.credentials.json` には触らない
- 公開リポジトリ。`dotfiles/skills/` に置く自作スキルも公開になるが、Roze が了承済み

### 各ツールが読む「個人用」スキルの置き場所（公式ドキュメントで確認済み）

| ツール | 置き場所 |
|---|---|
| Claude Code（CLI・アプリ・VS Code 拡張） | `~/.claude/skills/` |
| VS Code の Copilot | `~/.copilot/skills/` |
| GitHub Copilot アプリ・Copilot CLI | `~/.copilot/skills/`、`~/.agents/skills/` |

- Claude Code と Copilot の両方が読むフォルダは存在しない。なので 2 か所に置く
- `~/.agents/skills/` には置かない。Copilot アプリが直接読むので、`~/.copilot/skills/` と二重に見えるおそれがある

## 4. Roze が決めたこと

- スキルは GitHub で管理する。管理の仕組みは dotfiles に組み込む
- インストールはスクリプトで行う
- 公開スキルの取得には npx skills を使う
- 置き先は `~/.claude/skills/` と `~/.copilot/skills/`
- 全PC同じセットでいい。実行時に選べるとなおよい
- 台帳は構造のある形式にする（リンクなども入れたいため）。少なくとも CSV か TSV
- dotfiles は公開のままでよい。自作スキルが公開されても構わない

## 5. 構成

### 5.1 dotfiles に足すもの

```
dotfiles/
├─ （今あるもの：nvim/ powershell/ vscode/ claude/ ...）
├─ skills/                 ← 新規
│   ├─ skills.tsv          ← 台帳（見出しつき TSV）
│   └─ <スキル名>/          ← 自作スキル（1 フォルダ = 1 スキル）
│       └─ SKILL.md
├─ skills.ps1 / skills.sh  ← 新規：スキル専用（単体でも動く）
├─ install.ps1 / install.sh  ← 最後に skills.ps1 / skills.sh を呼ぶ行を足す
└─ README.md               ← 「スキル」の節を足す
```

- `install.ps1` / `install.sh` には `-SkipSkills`（Linux は `--skip-skills`）を足す
- スキルだけ入れ直したいときは `.\skills.ps1` / `bash skills.sh` を直接実行する

### 5.2 台帳（skills/skills.tsv）

1 行目が見出し（列名）の TSV（タブ区切り）。1 行 = 1 スキル。

| 列 | 必須 | 中身 |
|---|---|---|
| `type` | 必須 | `own`（自作スキル。本体は `skills/<name>/`）か `npx`（公開スキル） |
| `name` | 必須 | スキル名。自作スキルではフォルダ名と同じにする |
| `source` | `npx` のとき必須 | npx skills に渡すリポジトリ（`owner/repo`）。`own` では空欄 |
| `targets` | 必須 | 出す先。`claude`・`copilot` をカンマでつなぐ。スキルごとに決められる |
| `url` | 任意 | 参考リンク（skills.sh や GitHub のページなど） |
| `note` | 任意 | メモ。選択メニューに表示する |

例（実際の区切りはタブ。見やすさのために表で示す）：

| type | name | source | targets | url | note |
|---|---|---|---|---|---|
| own | rust-tutor | | claude,copilot | | Rust 学習 |
| npx | find-skills | vercel-labs/skills | claude,copilot | https://skills.sh/vercel-labs/skills/find-skills | スキル検索 |
| own | server-setup | | claude | | miniPC のサーバ構築 |

- 列は「見出しの名前」で読む。列の順番に頼らない
  - 後から列を足しても（例：`added` に追加日）、今あるスクリプトが壊れないようにするため
- 空欄は「値なし」として扱う。値の中にタブは入れない
- 見出しの次から、`#` で始まる行と空行は読み飛ばす
- `claude` → `~/.claude/skills`（npx の agent 名は `claude-code`）、`copilot` → `~/.copilot/skills`（`github-copilot`）の対応表は、各スクリプトの先頭 1 か所に書く
  - 将来 Claude Code が `~/.agents/skills` に対応したら、そこを書き換えるだけで済むようにする

### 5.3 skills.ps1 / skills.sh の流れ

1. 必要なものを確認する：（`npx` の行があれば）Node.js と npx
2. 台帳を読む
3. 入れるスキルを決める（5.4）
4. 自作スキル：出す先のフォルダへ **コピー** する（dotfiles と同じコピー方式）
5. 公開スキル：npx skills を呼ぶ
   - 例：`npx skills add vercel-labs/skills --skill find-skills -g -a claude-code -a github-copilot -y`
6. 片付け（5.5）
7. 結果を表示する：追加・更新・削除・スキップの件数と名前（ログの見た目は今の install に合わせる）

### 5.4 選択式

- ふだんは全部入れる（前回選んだ内容があれば、それに従う）
- `-Select`（Linux は `--select`）を付けると、番号で ON/OFF を切り替えるメニューを出す

```
入れるスキルを選んでください（番号で切り替え、Enter で決定）
 [x] 1. rust-tutor     Rust 学習
 [x] 2. find-skills    スキル検索
 [ ] 3. server-setup   miniPC のサーバ構築
```

- 選んだ結果はマシンごとに保存する（`~/.dotfiles-skills/excluded.txt`。リポジトリには入れない）
- 保存するのは「外したスキル」の一覧。台帳に後から増えたスキルは、自動で入る側になる
- 文字だけの番号式にする。スマホから SSH で miniPC につないだときでも使える

### 5.5 片付け（消すとき）

- 次の 2 つは、実行のたびに各PCから消す
  - 台帳から消えたスキル
  - 選択で外したスキル
- 消してよいのは、このスクリプトが入れたものだけ
  - 入れたものの記録を `~/.dotfiles-skills/installed.txt` に残し、そこに載っているものだけを消す
- 自作スキル：コピーしたフォルダを消す
- 公開スキル：`npx skills remove` で消す

### 5.6 オプション（dotfiles の書き方に合わせる）

| Windows | Linux | 意味 |
|---|---|---|
| `-DryRun` | `--dry-run` | 何が起きるか表示するだけ |
| `-Select` | `--select` | 入れるスキルを選ぶメニューを出す |
| `-Update` | `--update` | 最後に `npx skills update` も実行する |
| `-SkipSkills`（install 側） | `--skip-skills`（install 側） | install のときにスキルを飛ばす |

## 6. 僕（Claude）が決めたこと（読むときに確認してほしい）

- **スクリプトは ps1 と sh の 2 本にする**
  - 前回は「PowerShell 7 一本」をすすめたが、dotfiles がすでに 2 本立てで動いているので、それに合わせる
- **自作スキルはリンクではなくコピーで置く**
  - dotfiles がコピー方式なので合わせる
  - おまけの利点：「VS Code がリンク越しにスキルを読むか分からない」問題と、「リンクを消すとリンク先まで消える」事故の心配がなくなる
  - 代わりに、自作スキルはリポジトリ側（`dotfiles/skills/`）で編集し、編集したら実行し直す
- **台帳は CSV ではなく TSV にする**（どちらかにする、は Roze の希望）
  - `targets` の値（`claude,copilot`）やメモにカンマが入るので、CSV だと引用符で囲む必要が出る。bash で引用符つきの CSV を正しく読むのは難しい
  - TSV なら、PowerShell は `Import-Csv -Delimiter "`t"`、bash は `IFS=$'\t' read` で、追加の道具なしに読める
  - JSON や YAML は、bash で読むのに jq や Python が要るので見送る
- 初版では、スキルを sync（PC → リポジトリ）の対象にしない
  - スキルの編集はリポジトリ側でやる前提。必要になったら後で足す
- 同じ名前のフォルダがすでにあり、それがスクリプト管理外なら、触らずに警告だけ出す
  - npx skills で入れる前にも同じ確認をする（npx に上書きさせない）
- 管理下のスキルを上書きするときは、退避を作らずにそのまま置き換える（本体は Git にあるため）
- マシンごとの記録は `~/.dotfiles-skills/` に置く（リポジトリの外）
- Node.js がないマシンでは、公開スキルだけを飛ばして警告を出す（自作スキルは入れる）
- 台帳にあるのに `skills/` にフォルダがない自作スキルは、そのスキルだけエラーにして残りを続ける
- 台帳の書き方が間違っている行は、行番号つきでエラーにして、その行だけ飛ばす
- `-Update` の `npx skills update` は、台帳の外で npx skills を使って入れたスキルも更新する。これは許容する

## 7. 作る人に任せること・注意

### 任せること

- エラー表示の細かい文言や色（今の install の書き方に合わせる）
- README の「スキル」の節の書き方（今の README の図や表の雰囲気に合わせる）
- テストの書き方

### 注意

- 今の install の `Deploy` 関数は、既存ファイルを同じ場所に `*.bak-日付` で退避する。スキルにはこれを使わないこと（第 2 章「失敗とみなすこと」）
- npx skills の `-g` が裏で `~/.agents/skills` を使うかは公式に書かれていない。最初の確認（第 9 章）で調べる
- 今の `install.ps1` は Windows PowerShell 5.1 でも動く書き方になっている。`skills.ps1` も 5.1 で動くようにする
- `skills.tsv` は UTF-8（BOM なし）・改行 LF で保存する
  - BOM があると、bash で読んだときに 1 列目の見出しが `type` と一致しなくなる
  - PowerShell 5.1 で BOM なしの日本語を読むには `-Encoding UTF8` を付ける
  - 改行は `.gitattributes` の既定（`* text=auto eol=lf`）で LF になる
- エディタがタブを空白に変えると台帳が壊れる。VS Code の設定（`vscode/settings.json`）で TSV だけ `"editor.insertSpaces": false` にすることを検討する
- 台帳の読み込みでは、見出しに必須の列（`type`・`name`・`targets`）がなければ、何も変更せずにエラーで止める

## 8. Roze に聞くこと

なし（すべて解決済み）。

### 解決済み

- スクリプトの言語 → dotfiles に合わせて ps1 と sh の 2 本（第 6 章）
- miniPC の OS → dotfiles が画面なしの Linux に対応しているので、Linux と推測。ディストリビューションは設計に影響しない
- 自作スキルの公開 → dotfiles は公開のままでよい（Roze 了承）
- 台帳の形式 → 見出しつき TSV（Roze の希望を受けて CSV と比べて決定。第 6 章）

## 9. 最初に確かめること（本格運用の前）

- [ ] VS Code の Copilot と Copilot アプリが、`~/.copilot/skills` にコピーしたスキルを読めるか
- [ ] Claude Code が、`~/.claude/skills` にコピーしたスキルを読めるか
- [x] npx skills の `-g` が、どのフォルダにどう置くか（コピーかリンクか、`~/.agents/skills` を使うか）→ 下の「調査結果」
- [ ] GitHub Copilot アプリで、同じスキルが二重に見えないか
- [ ] 今の install（scoop・フォント・設定ファイル）の動きが変わっていないか（`-DryRun` の出力を前後で比べる）

### 調査結果：npx skills の置き方（2026-11-16、npx skills 1.8.1、Windows で一時ホームを使って確認）

- フラグ
  - 追加：`add <owner/repo> -s|--skill <name> -g -a|--agent <agent> -y [--copy]`
  - 削除：`remove <name> -g -a <agent> -y`
  - 更新：`update [skills...] -g -y`
- 既定（リンク方式）で `-a claude-code -a github-copilot` を付けた場合
  - 実体を `~/.agents/skills/<name>` に置く
  - Claude Code には `~/.claude/skills/<name>` をジャンクション（Windows）で張る
  - GitHub Copilot は「universal」扱いで `~/.agents/skills` をそのまま使う。`~/.copilot/skills` は作らない
- `--copy` を付けた場合：`~/.agents/skills/<name>` と `~/.claude/skills/<name>` の両方にコピーする。`~/.copilot/skills` は作らない
- `-a claude-code --copy` だけの場合：`~/.claude/skills/<name>` にだけコピーする（`~/.agents` フォルダはできるが、スキルは置かれない）。`remove` で消える
- つまり `github-copilot` を指定すると、必ず `~/.agents/skills` を使う。設計の前提（`~/.agents/skills` に置かない）と食い違う
  - VS Code の Copilot は、公式ドキュメント上 `~/.agents/skills` を読まない（Copilot アプリと Copilot CLI は読む）
- テレメトリ：インストール時に利用状況を送る。環境変数 `DISABLE_TELEMETRY` か `DO_NOT_TRACK` で止められる（パッケージのコードで確認）
- 判断：Roze に相談中

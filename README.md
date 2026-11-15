# dotfiles

Windows と Linux の両方で、同じ設定ファイルを使い回すためのリポジトリ。

新しいPCでは **クローン → スクリプトを1回実行** するだけで、
nvim・PowerShell・VSCode・scoop・フォント・エージェントスキルの環境が揃う。

---

## 管理しているもの

| フォルダ | 中身 | 配置先（Windows） | 配置先（Linux） |
|---|---|---|---|
| `nvim/` | Neovim の設定（LazyVim） | `%XDG_CONFIG_HOME%\nvim` | `~/.config/nvim` |
| `powershell/` | PowerShell プロファイル | `Documents\WindowsPowerShell\profile.ps1`（5.1用）<br>`Documents\PowerShell\profile.ps1`（7用・pwsh があるPCだけ） | `~/.config/powershell/profile.ps1` |
| `vscode/` | VSCode の `settings.json` | `%APPDATA%\Code\User\settings.json` | `~/.config/Code/User/settings.json` |
| `scoop/` | scoop で入れるアプリ一覧 | （install.ps1 が読んで一括インストール） | — |
| `wterminal/` | Windows Terminal の `settings.json` | `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_*\LocalState\` | —（Windows 専用） |
| `psmux/` | `psmux.conf` | `%XDG_CONFIG_HOME%\psmux\` | `~/.config/psmux/` |
| `claude/` | Claude Code の `CLAUDE.md` | `~\.claude\CLAUDE.md` | `~/.claude/CLAUDE.md` |
| `skills/` | エージェントスキルの台帳と自作スキル（Claude Code・Copilot 用） | `~\.claude\skills`・`~\.agents\skills` | `~/.claude/skills`・`~/.agents/skills` |
| `bash/` | `.bashrc` | — | `~/.bashrc` |

---

## ディレクトリ構成

```
dotfiles/
├─ nvim/                 ← Windows / Linux 共通でそのまま使う
│   ├─ init.lua
│   ├─ lazy-lock.json    ← プラグインのバージョン固定ファイル
│   └─ lua/
│       ├─ config/
│       └─ plugins/
├─ powershell/
│   └─ profile.ps1
├─ vscode/
│   └─ settings.json
├─ scoop/
│   └─ scoop-apps.json
├─ wterminal/            ← Windows 専用
│   └─ settings.json
├─ psmux/
│   └─ psmux.conf
├─ claude/
│   └─ CLAUDE.md
├─ skills/               ← エージェントスキル
│   ├─ skills.tsv        ← 台帳（1 行 = 1 スキル、タブ区切り）
│   └─ dotfiles-skills/  ← 自作スキル（1 フォルダ = 1 スキル）
├─ bash/                 ← Linux 専用
│   └─ .bashrc
│
├─ install.ps1 / install.sh   ← リポジトリ → PC へ配置する
├─ sync.ps1    / sync.sh      ← PC → リポジトリ へ取り込む
└─ skills.ps1  / skills.sh    ← スキルだけを配置する（install の最後からも呼ばれる）
```

---

## 仕組み（コピー方式）

このリポジトリは **シンボリックリンクではなくコピー** で設定を配置する。
特別な権限が要らず、どのPCでも確実に動く代わりに、
**設定を編集したら `sync` で取り込む** というひと手間が必要。

```
   ┌────────────────────┐                   ┌────────────────────┐
   │  dotfiles リポジトリ │                   │   実際に使う場所     │
   │                    │  ── install ──▶   │                    │
   │  nvim/init.lua     │                   │ ~/.config/nvim/... │
   │  powershell/...    │  ◀──  sync  ──    │ Documents/...      │
   │  vscode/...        │                   │ %APPDATA%/Code/... │
   └────────────────────┘                   └────────────────────┘
            │                                          ▲
            │ git push / git pull                      │ ここを編集する
            ▼                                          │
        GitHub ────────────────── 他のPCへ ────────────┘
```

**日常の流れ:**

```
設定を編集  →  sync で取り込む  →  git commit → git push
                                                    │
他のPCで                                            ▼
git pull  →  install で配置  ←────────────────── GitHub
```

---

## 使い方

### 新しいPCをセットアップする

**Windows:**

```powershell
git clone https://github.com/capypara20/dotfiles.git "$HOME\dotfiles"
cd "$HOME\dotfiles"
.\install.ps1
```

やること:
1. `XDG_CONFIG_HOME` を `~\.config` に設定（未設定の場合のみ）
2. scoop が無ければインストール → git が無ければ先に入れる → バケット追加 → アプリを一括インストール
   （バケット追加には git が必要なため、この順番にしている）
3. `RobotoMono Nerd Font` が無ければダウンロードしてインストール（管理者権限は不要）
4. 設定ファイルを各アプリの場所へコピー
5. スキル（`skills/skills.tsv` に書いたもの）を配置（`skills.ps1`。詳しくは「スキル」の節）

**Linux:**

```bash
git clone https://github.com/capypara20/dotfiles.git ~/dotfiles
cd ~/dotfiles
bash install.sh
```

やること:
1. `RobotoMono Nerd Font` が無ければ `~/.local/share/fonts` にインストール
   （fontconfig が無い＝画面を持たない環境では飛ばす）
2. 設定ファイルを各アプリの場所へコピー
3. スキルを配置（`skills.sh`。公開スキルを入れるには Node.js を先に入れておく）

### 設定を変更したあと（リポジトリに取り込む）

```powershell
cd "$HOME\dotfiles"
.\sync.ps1          # PC 側の設定をリポジトリへコピー
git diff            # 何が変わったか確認
git add -A
git commit -m "nvim のキーマップを追加"
git push
```

Linux なら `bash sync.sh`。

### 他のPCで最新に追いつく

```powershell
cd "$HOME\dotfiles"
git pull
.\install.ps1 -SkipScoop    # 設定ファイルの配置だけやり直す
```

---

## オプション

| オプション | 意味 |
|---|---|
| `.\install.ps1 -DryRun` | 何が起きるか表示するだけ（実際には変更しない） |
| `.\install.ps1 -SkipScoop` | scoop 関連を飛ばす（フォントは入っていなければ入れる） |
| `.\install.ps1 -SkipFonts` | フォントのインストールを飛ばす |
| `.\sync.ps1 -DryRun` | 同上（取り込みの予行演習） |
| `bash install.sh --dry-run` | Linux 版の予行演習 |
| `bash install.sh --skip-fonts` | Linux 版でフォントのインストールを飛ばす |
| `.\install.ps1 -SkipSkills` | スキルの配置を飛ばす |
| `.\skills.ps1 -DryRun` | スキルの配置の予行演習 |
| `.\skills.ps1 -Select` | 入れるスキルを番号で選ぶ |
| `.\skills.ps1 -Update` | 最後に公開スキルの更新（`npx skills update`）もする |
| `bash install.sh --skip-skills` | Linux 版でスキルの配置を飛ばす |
| `bash skills.sh --dry-run` / `--select` / `--update` | Linux 版のスキル配置（意味は上と同じ） |

---

## フォントの自動インストール

Windows Terminal の設定は `RobotoMono Nerd Font` を使っている。
フォントが無いPCではアイコンが □ になるので、install スクリプトが自動で入れる。

```
install.ps1 / install.sh
   │
   ├─ RobotoMono Nerd Font はもう入っている？ ── はい ──▶ 何もしない
   │                 │
   │               いいえ
   │                 ▼
   │   GitHub（ryanoasis/nerd-fonts）の最新リリースから
   │   RobotoMono.tar.xz（約4MB）をダウンロード
   │   ※ Windows で tar が xz 非対応なら RobotoMono.zip（約50MB）
   │                 ▼
   │   通常版 RobotoMonoNerdFont-*.ttf だけを取り出す（12ファイル）
   │   （Mono版・Propo版は入れない）
   │                 ▼
   └─ このユーザー専用の場所にインストール（管理者権限・sudo 不要）
        Windows : %LOCALAPPDATA%\Microsoft\Windows\Fonts + レジストリ(HKCU)に登録
        Linux   : ~/.local/share/fonts + fc-cache
```

- **フォントを増やしたいとき** は、`install.ps1` の `$Fonts` と
  `install.sh` の `install_font` の行に1行ずつ足す。
  名前は [Nerd Fonts のリリース](https://github.com/ryanoasis/nerd-fonts/releases) にあるファイル名を使う
- ダウンロードに失敗しても警告を出すだけで、設定ファイルの配置は続ける
- 入れたあとは **Windows Terminal を再起動** すると新しいフォントで表示される

---

## スキル（Claude Code・Copilot 用）

エージェントスキル（`SKILL.md`）を、台帳 `skills/skills.tsv` で管理している。
台帳に書いたスキルが、Claude Code と Copilot の両方に入る。

```
 skills/skills.tsv（台帳）
        │  skills.ps1 / skills.sh が読む
        ├─ 自作スキル（type = own）… skills/<名前>/ をコピーする
        └─ 公開スキル（type = npx）… npx skills が GitHub から取ってくる
        ▼
 ~/.claude/skills   … Claude Code が読む
 ~/.agents/skills   … VS Code の Copilot・Copilot アプリ・Codex が読む
```

### 台帳の書き方

1 行目は見出し。区切りは**タブ**。列は名前で読むので、順番は入れ替えてもよい。

| 列 | 必須 | 中身 |
|---|---|---|
| `type` | 必須 | `own`（自作スキル）か `npx`（公開スキル） |
| `name` | 必須 | スキル名。自作スキルはフォルダ名と同じにする（英数字と `.` `_` `-`） |
| `source` | `npx` のとき必須 | npx skills に渡すリポジトリ（`owner/repo`） |
| `targets` | 必須 | 出す先。`claude`・`agents` をカンマでつなぐ |
| `url` | 任意 | 参考リンク |
| `note` | 任意 | メモ。選択メニューに表示される |

### スキルを増やす・減らす

```powershell
# 1. 台帳に 1 行足す（減らすときは行を消す）。自作なら skills/<名前>/SKILL.md も作る
# 2. 予行演習してから本番
.\skills.ps1 -DryRun
.\skills.ps1
# 3. コミットして push
git add skills
git commit -m "スキル xxx を追加"
git push
```

他のPCでは `git pull` → `.\skills.ps1`（Linux は `bash skills.sh`）。

### 入れるスキルを選ぶ

ふだんは台帳のスキルを全部入れる。`.\skills.ps1 -Select` で、入れるものを番号で選べる。

```
入れるスキルを選んでください（番号で切り替え、Enter で決定）
 [x] 1. dotfiles-skills  スキル台帳の使い方
 [ ] 2. find-skills      スキル検索
番号:
```

- 選んだ結果は PC ごとに `~/.dotfiles-skills/excluded.txt` に残り、次からはそれに従う
- 残すのは「外したスキル」なので、台帳に新しく足したスキルは何もしなくても入る

### しくみと注意

- 入れたものは `~/.dotfiles-skills/installed.txt` に記録する。消すのはここに載っているものだけで、
  `synced/`（claude.ai からの同期）や手で入れたスキルには触らない
- 置き先に同じ名前の管理外フォルダがあると、警告を出して飛ばす
- 台帳にタブ区切りでない行があると、その行は警告して飛ばす。そういう回は、安全のためスキルを削除しない
- スキルの中身はリポジトリ側（`skills/<名前>/`）で編集する。置き先を直接編集しても次の実行で上書きされる。
  sync の対象ではない
- 公開スキルには Node.js が必要（Windows は scoop の `nodejs-lts`）。npx skills は `--copy` を付け、
  利用状況の送信を止める `DISABLE_TELEMETRY=1` をつけて呼んでいる
- Claude Code は今のところ `~/.agents/skills` を読まないので、`~/.claude/skills` にも置いている

---

## このPCだけの設定を書きたいとき

全PCで共通にしたくない設定（会社PCのプロキシ、そのPCにしか無いパスなど）は、
**`profile.local.ps1`** に書く。`.gitignore` 済みなので Git には入らない。

- 置き場所: `~/.config/powershell/profile.local.ps1`（5.1 用と 7 用で共通の1か所）
- `profile.ps1` の最後で自動的に読み込まれる

### PowerShell プロファイルが2枚ある理由

Windows PowerShell 5.1 と PowerShell 7 (pwsh) では `$PROFILE` の場所が違うため、
両方の `CurrentUserAllHosts`（= `profile.ps1`）に同じものを配る。

```
 dotfiles/powershell/profile.ps1      ← 編集するのはここだけ（Git 管理）
        │ install.ps1 がコピー
        ├──────────────────────┐
 Documents\WindowsPowerShell\    Documents\PowerShell\
      profile.ps1                     profile.ps1
        =                              =
  Windows PowerShell 5.1          PowerShell 7 (pwsh)
                                  ※ pwsh があるPCだけ
```

- 実体が2枚あるので、片方を直接編集したら `sync.ps1` → `install.ps1` の順に流して
  両方を揃えること。`sync.ps1` は**更新日時が新しい方**を取り込み、
  2枚の中身が違うときは警告を出す
- ファイル名を `profile.ps1`（AllHosts）にしているので、VSCode の PowerShell 拡張など
  コンソール以外のホストからも読まれる。色付き3行プロンプトの部分だけは
  `$Host.Name -eq 'ConsoleHost'` で囲ってあり、ISE などでは無効になる

### プロンプトの見かた

```
14:41:44 DESKTOP-0HEJ4UD@10.152.100.214 100%+ pwsh7.6
C:\Users\capypara20\.config\nvim  (main*)
(ｯ･ω･)ｯ
```

| 場所 | 意味 |
|---|---|
| 1行目 | 時刻 / マシン名@IP / バッテリー残量（`+` は充電中） |
| 1行目の末尾 | 今の PowerShell の種類。`pwsh7.6` = PowerShell 7（青）、`PS5.1` = Windows PowerShell（橙） |
| 2行目 | 今いるフォルダ / Git リポジトリなら `(ブランチ名)`。`*` は未コミットの変更あり |
| 3行目 | 顔文字。直前のコマンドが失敗したときだけ赤くなる |

---

## 注意点

- **上書き前のファイルは消していない。** `install` は既存ファイルを
  `settings.json.bak-20260810-153000` のような名前で同じ場所に残す。
- **`sync` はフォルダを一度消してからコピーする。** nvim のように
  フォルダごと扱うものは、PC 側で消したファイルがリポジトリからも消える。
  Git 管理下なので `git checkout` で戻せる。
- **scoop のアプリ一覧はバージョンを含めない。** 新しいPCでは常に最新版が入る。
  グローバルインストール（管理者権限が必要なもの）は一覧から除外している。
- **フォントは scoop で管理しない。** install スクリプトが GitHub から直接入れる
  （`-SkipScoop` を付けても入る）。詳しくは「フォントの自動インストール」を参照。
- **Windows Terminal は開いたまま install すると設定が戻ることがある。**
  終了時に、起動中に保持していた内容で書き戻されるため。
  反映されないときは Windows Terminal を再起動する。
- **Claude Code は `CLAUDE.md` だけを管理している。**
  同じ `~/.claude/` にある `.credentials.json` は認証情報なので、
  スクリプトは意図的に触らない。GitHub にも上げてはいけない。

# スキル管理（dotfiles 組み込み）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dotfiles の install を 1 回実行すれば、台帳（`skills/skills.tsv`）に書いたスキルが Claude Code と Copilot の両方に入る仕組みを作る。

**Architecture:** スキル専用の `skills.ps1`（Windows）と `skills.sh`（Linux）を足し、既存の `install.ps1` / `install.sh` の最後から呼ぶ。台帳を読む → 除外リストを当てる → 「足す・更新・消す・衝突」を計算する → 自作スキルはコピー、公開スキルは npx skills で実行する、の順に処理する。消すのは自分が入れた記録（`installed.txt`）にあるものだけ。

**Tech Stack:** PowerShell（5.1 と 7 の両対応）、bash、Pester 5（ps1 のテスト）、素の bash で書いたテスト、npx skills（vercel-labs/skills）

**Spec:** `docs/superpowers/specs/2026-11-15-skills-manager-design.md`

## Global Constraints

- 置き先の対応表（各スクリプトの先頭 1 か所に書く）：`claude` → `~/.claude/skills`（npx の agent 名 `claude-code`）、`agents` → `~/.agents/skills`（`github-copilot`）。`~/.copilot/skills` には置かない（2026-11-16 に変更。設計メモ第 9 章）
- npx skills の呼び方（Task 1 で確認済み）：追加 `add <owner/repo> --skill <name> -g -a <agent>... -y --copy`、削除 `remove <name> -g -a <agent> -y`、更新 `update -g -y`。どれも環境変数 `DISABLE_TELEMETRY=1` をつけて呼ぶ
- 台帳：`skills/skills.tsv`。1 行目は見出し。列は `type`・`name`・`source`・`targets`・`url`・`note`。必須は `type`・`name`・`targets`（`npx` のときは `source` も）
- 台帳は UTF-8（BOM なし）・LF。読むときは BOM と行末の `\r` を取り除く
- マシンごとの記録：`~/.dotfiles-skills/excluded.txt`（外したスキル名を 1 行 1 つ）、`~/.dotfiles-skills/installed.txt`（`target<TAB>name<TAB>type`、見出しなし）
- オプション：`-DryRun` / `--dry-run`、`-Select` / `--select`、`-Update` / `--update`、install 側の `-SkipSkills` / `--skip-skills`
- テスト用の差し替え（環境変数）：`DOTFILES_SKILLS_HOME`（ホームの代わり）、`DOTFILES_SKILLS_REPO`（リポジトリの代わり）、`DOTFILES_SKILLS_NPX`（npx コマンドの代わり。ps1 と sh の両方）
- `skills.ps1` は Windows PowerShell 5.1 でも動く書き方にする（`?:`・`??`・`&&` を使わない）
- `.ps1` は UTF-8 **BOM 付き**・CRLF で保存する。保存後に `$p='skills.ps1'; [IO.File]::WriteAllText((Resolve-Path $p), (Get-Content $p -Raw), [Text.UTF8Encoding]::new($true))` で BOM を付ける（テストの `.ps1` も同じ）
- `.sh` は LF（`.gitattributes` で固定済み）
- 管理者権限・sudo を使わない
- スクリプト管理外のフォルダ（`synced/`、Ninja や手で入れたもの）を消さない・上書きしない。スキルのフォルダの中に `*.bak-日付` を作らない
- ログの見た目は今の install に合わせる：`[見出し]`・`  OK   ...`・`  --   ...`・`  ...`。文言は日本語
- sh は知らないオプションを `知らないオプションです: <arg>` と出して `exit 1`
- コミットメッセージ：タイトル 50 文字以内・空行・本文は 72 文字で改行（日本語）

## Review Focus

1. **台帳のタブが空白になっている／列が足りない行**：その行だけ行番号つきで警告して飛ばす。さらに、台帳に 1 行でも不正があった回は「消す」処理を一切しない（全行が読めずに「台帳が空」と誤解して全部消す事故を防ぐ）→ Task 4・Task 6 にテストを追加
2. **BOM 付き・CRLF の台帳**（Windows のメモ帳などで保存）：PowerShell も bash も同じように読める → Task 2・Task 6
3. **スキル名に `..` や `/` が入っている**：コピーや削除が置き先の外に及ぶ。名前は `^[A-Za-z0-9][A-Za-z0-9._-]*$` に合うものだけ受け付け、それ以外は不正な行として扱う → Task 2・Task 6
4. **記録にあるのに、フォルダが手で消されている**：エラーにせず、記録からだけ消す → Task 5・Task 6
5. **パスに空白が入っている**（ユーザー名に空白がある PC など）：bash の変数を必ず `"..."` で囲む → Task 6（空白入りの一時フォルダでテスト）

---

### Task 1: npx skills の置き方を調べる（スパイク・コードなし）

設計の前提（`~/.agents/skills` を使わない）が npx skills の動きで崩れないかを、実装の前に確かめる。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-15-skills-manager-design.md`（第 9 章に結果を書く）

**Interfaces:**
- Produces: npx skills の `add`・`remove`・`update` の正確なフラグ（Task 5・Task 6 が使う）。予想は `add <owner/repo> --skill <name> -g -a <agent> -y`、`remove <name> -g -a <agent> -y`、`update -g -y`

- [ ] **Step 1: Node.js があるか確かめる**

Run: `node --version`（Windows）と `wsl bash -lc "node --version"`（WSL の Ubuntu）
Expected: どちらかでバージョンが出る。どちらにもなければ止めて、Roze に入れてもらう（方法は Roze が選ぶ。Windows なら scoop で入っている nvm、または scoop の `nodejs-lts`）

- [ ] **Step 2: フラグを確かめる**

Run: `npx -y skills add --help`、`npx -y skills remove --help`、`npx -y skills update --help`
Expected: `-g`（グローバル）、`-a`（agent 指定）、`-y`（確認なし）、`--skill` に当たるフラグが表示される。名前が予想と違えば、表示された名前を使う。コピーとリンクを選ぶフラグ（`--copy` など）があればメモする

- [ ] **Step 3: 本物のホームを汚さずに 1 個入れてみる**

WSL の場合：
```bash
export HOME="$(mktemp -d)"
npx -y skills add vercel-labs/skills --skill find-skills -g -a claude-code -a github-copilot -y
find "$HOME" -maxdepth 4 \( -name SKILL.md -o -type l \) -exec ls -ld {} +
```
Windows の場合：`$env:USERPROFILE` を一時フォルダに変えた子プロセス（`pwsh -NoProfile -Command`）で同じことをする

Expected: `~/.claude/skills/find-skills/SKILL.md` と `~/.copilot/skills/find-skills/SKILL.md` ができる。`~/.agents/skills` ができるか、リンク（`l`）になっているかを記録する

- [ ] **Step 4: 判断する**

- `~/.agents/skills` を使わない → このまま進む
- `~/.agents/skills` を使う → **止めて Roze に報告する**（Copilot アプリで二重に見えるおそれ。Step 2 でコピー用のフラグがあれば、それを使う案を添える）

- [ ] **Step 5: 結果を設計メモ第 9 章に書いてコミット**

```bash
git add docs/superpowers/specs/2026-11-15-skills-manager-design.md
git commit -m "設計メモに npx skills の置き方の調査結果を追記" -m "add/remove/update のフラグと、-g で置かれる場所を記録した。"
```

---

### Task 2: 台帳を読む（skills.ps1 の土台とテストの準備）

**Files:**
- Create: `skills.ps1`
- Create: `tests/skills.Tests.ps1`

**Interfaces:**
- Produces:
  - `$TargetMap`：`@{ claude = @{ Dir = '.claude/skills'; Agent = 'claude-code' }; agents = @{ Dir = '.agents/skills'; Agent = 'github-copilot' } }`
  - `Get-SkillsHome` → `[string]`：`$env:DOTFILES_SKILLS_HOME` があればそれ、なければ `$HOME`
  - `Get-SkillsRepo` → `[string]`：`$env:DOTFILES_SKILLS_REPO` があればそれ、なければ `$PSScriptRoot`
  - `Get-TargetDirs -HomeDir [string]` → `[hashtable]`：`@{ claude = '<home>/.claude/skills'; agents = '<home>/.agents/skills' }`
  - `Read-SkillLedger -Path [string]` → `[pscustomobject] @{ Skills = [pscustomobject[]]; HasErrors = [bool] }`。各スキルは `Type`・`Name`・`Source`・`Targets`（`[string[]]`）・`Url`・`Note`・`Line`（`[int]`、ファイル上の行番号）
- `skills.ps1` の先頭に `param([switch]$DryRun, [switch]$Select, [switch]$Update)` を置き、末尾は `if ($MyInvocation.InvocationName -ne '.') { Invoke-SkillsMain -DryRun:$DryRun -Select:$Select -Update:$Update }`（`Invoke-SkillsMain` は Task 5 で作る。それまでは末尾の行をコメントにしておく）

- [ ] **Step 1: Pester 5 を入れる**

Run: `Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck`（pwsh で 1 回、`powershell.exe` でも 1 回）
Expected: `Get-Module -ListAvailable Pester` に 5.5 以上が出る（今は 3.4.0 しかない）

- [ ] **Step 2: 失敗するテストを書く**

`tests/skills.Tests.ps1` の先頭で `. "$PSScriptRoot/../skills.ps1"` を読み込み、`TestDrive:` に台帳を書く補助関数 `New-TestLedger -Lines [string[]] [-Bom] [-Crlf]` を用意する。テスト：

```powershell
Describe 'Read-SkillLedger' {
  It '見出しの名前で列を読む（列の順番に頼らない）' {
    $p = New-TestLedger "name`ttype`ttargets`tsource`turl`tnote", "rust-tutor`town`tclaude,agents`t`t`tRust 学習"
    $r = Read-SkillLedger -Path $p
    $r.Skills[0].Name    | Should -Be 'rust-tutor'
    $r.Skills[0].Targets | Should -Be @('claude','agents')
    $r.Skills[0].Note    | Should -Be 'Rust 学習'
    $r.HasErrors         | Should -BeFalse
  }
  It '# の行と空行を飛ばし、Line はファイル上の行番号になる'      # 3 行目のスキルの Line が 3
  It '知らない列は無視する'                                      # 見出しに added 列があっても読める
  It '必須の列がないと止まる' {
    $p = New-TestLedger "type`tname", "own`tx"
    { Read-SkillLedger -Path $p } | Should -Throw '*必須の列がありません: targets*'
  }
  It 'BOM 付き・CRLF でも読める'                                 # -Bom -Crlf で書いて、Targets の最後が 'agents'（\r なし）
  It '不正な行は警告して飛ばし、HasErrors を立てる' -TestCases @(
    @{ Row = "cursor-only`town`tcursor`t`t`t";        Why = '知らない出す先' }
    @{ Row = "x`tnpx`tclaude`t`t`t";                  Why = 'npx なのに source がない' }
    @{ Row = "../evil`town`tclaude`t`t`t";            Why = '名前に使えない文字' }
    @{ Row = "x`tplugin`tclaude`t`t`t";               Why = '知らない type' }
    @{ Row = "x own claude";                          Why = 'タブではなく空白' }
  ) {
    # 見出しは "name`ttype`ttargets`tsource`turl`tnote"
    $r = Read-SkillLedger -Path (New-TestLedger "name`ttype`ttargets`tsource`turl`tnote", $Row) -WarningVariable w -WarningAction SilentlyContinue
    $r.Skills.Count | Should -Be 0
    $r.HasErrors    | Should -BeTrue
    $w -join ''     | Should -Match '2 行目'
  }
  It '同じ名前の 2 行目は不正として扱う'
}
```

- [ ] **Step 3: テストが失敗することを確かめる**

Run: `Invoke-Pester tests/skills.Tests.ps1 -Output Detailed`
Expected: FAIL（`Read-SkillLedger` が見つからない）

- [ ] **Step 4: `skills.ps1` に上の Interfaces を実装する**

ファイル冒頭のコメントは `install.ps1` と同じ形（やること・使い方）。`Import-Csv` は空欄や `#` 行の扱いが合わないので使わず、`[IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false))` で読んで、見出し行から「列名 → 位置」の表を作る。保存後に BOM を付ける（Global Constraints）

- [ ] **Step 5: テストが通ることを確かめる**

Run: `Invoke-Pester tests/skills.Tests.ps1 -Output Detailed` と `powershell.exe -NoProfile -Command "Invoke-Pester tests/skills.Tests.ps1 -Output Detailed"`
Expected: どちらも PASS

- [ ] **Step 6: コミット**

```bash
git add skills.ps1 tests/skills.Tests.ps1
git commit -m "スキル台帳を読む skills.ps1 の土台を追加" -m "見出しつき TSV を列名で読み、不正な行は行番号つきで警告する。" -m "Pester 5 のテストも追加した。"
```

---

### Task 3: 除外リストと記録ファイル（skills.ps1）

**Files:**
- Modify: `skills.ps1`
- Modify: `tests/skills.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 のスキル（`Name`・`Note`）
- Produces:
  - `Get-ExcludedSkills -StateDir [string]` → `[string[]]`（ファイルがなければ空）
  - `Save-ExcludedSkills -StateDir [string] -Names [string[]]`
  - `Switch-SkillExclusion -Skills [pscustomobject[]] -Excluded [string[]] -Answer [string]` → `[string[]]`：`Answer` の番号（空白かカンマ区切り、1 始まり）のスキルの除外を ON/OFF する
  - `Show-SkillMenu -Skills [pscustomobject[]] -Excluded [string[]]` → `[string[]]`：設計メモ 5.4 の画面を出し、空の Enter まで `Switch-SkillExclusion` をくり返す（テストしない薄い部分）
  - `Get-InstalledState -StateDir [string]` → `[pscustomobject[]]`（`Target`・`Name`・`Type`）
  - `Save-InstalledState -StateDir [string] -Entries [pscustomobject[]]`
  - どちらのファイルも UTF-8（BOM なし）・LF で書く。`StateDir` がなければ作る

- [ ] **Step 1: 失敗するテストを書く**

```powershell
Describe 'Switch-SkillExclusion' {
  BeforeAll { $s = @([pscustomobject]@{Name='a'},[pscustomobject]@{Name='b'},[pscustomobject]@{Name='c'}) }
  It '番号で外す'           { Switch-SkillExclusion -Skills $s -Excluded @() -Answer '2'       | Should -Be @('b') }
  It 'もう一度で戻す'       { Switch-SkillExclusion -Skills $s -Excluded @('b') -Answer '2'    | Should -Be @() }
  It '複数をまとめて'       { Switch-SkillExclusion -Skills $s -Excluded @() -Answer '1, 3'    | Should -Be @('a','c') }
  It '範囲外と文字は無視'   { Switch-SkillExclusion -Skills $s -Excluded @() -Answer '0 9 x 2' -WarningAction SilentlyContinue | Should -Be @('b') }
}
Describe '記録ファイル' {
  It '除外リストを保存して読み直せる'       # Save → Get で同じ配列
  It '除外リストがなければ空'               # 存在しない StateDir で @()
  It 'installed を保存して読み直せる'       # Target/Name/Type が一致
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `Invoke-Pester tests/skills.Tests.ps1 -Output Detailed`
Expected: FAIL（関数が見つからない）

- [ ] **Step 3: 上の Interfaces を実装する**

- [ ] **Step 4: 通ることを確かめる**

Run: Task 2 Step 5 と同じ 2 コマンド
Expected: どちらも PASS

- [ ] **Step 5: コミット**

```bash
git add skills.ps1 tests/skills.Tests.ps1
git commit -m "スキルの除外リストと導入記録の読み書きを追加" -m "番号で ON/OFF する選択メニューと、マシンごとの記録ファイルを扱う。"
```

---

### Task 4: 足す・消すの計算（Get-SkillPlan）

安全の要になる部分。ファイルには触らず、何をするかだけを返す。

**Files:**
- Modify: `skills.ps1`
- Modify: `tests/skills.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 のスキル、Task 3 の除外リストと記録
- Produces: `Get-SkillPlan -Skills [pscustomobject[]] -Excluded [string[]] -Installed [pscustomobject[]] -TargetDirs [hashtable] -SkipRemovals [bool]` → `[pscustomobject[]]`（`Action`・`Type`・`Name`・`Target`・`Source`）
  - 入れたい組（除外されていないスキル × その `Targets`）ごとに：記録にある → `Update`、記録になく置き先に同名フォルダがある → `Conflict`、どちらでもない → `Add`
  - 記録にあるのに入れたい組にない → `Remove`。ただし `-SkipRemovals $true` なら `Remove` を出さない

- [ ] **Step 1: 失敗するテストを書く**

```powershell
Describe 'Get-SkillPlan' {
  BeforeEach { $dirs = Get-TargetDirs -HomeDir (Join-Path $TestDrive 'home') }
  It '初めてなら Add'                                   # 記録なし・フォルダなし → claude と agents の Add が 2 件
  It '記録にあれば Update'
  It '管理外の同名フォルダがあれば Conflict'             # TestDrive に <claude>/x を作っておく → Action が Conflict
  It '台帳から消えたら Remove'
  It '除外したら Remove'
  It '出す先から agents を外したら agents だけ Remove'
  It '記録にないフォルダ（synced など）は Remove しない' # <claude>/synced を作っても計画に出てこない
  It 'SkipRemovals のときは Remove を出さない' {
    $plan = Get-SkillPlan -Skills @() -Excluded @() -Installed @([pscustomobject]@{Target='claude';Name='x';Type='own'}) -TargetDirs $dirs -SkipRemovals $true
    $plan | Where-Object Action -eq 'Remove' | Should -BeNullOrEmpty
  }
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `Invoke-Pester tests/skills.Tests.ps1 -Output Detailed`
Expected: FAIL（`Get-SkillPlan` が見つからない）

- [ ] **Step 3: `Get-SkillPlan` を実装する**

- [ ] **Step 4: 通ることを確かめる**

Run: Task 2 Step 5 と同じ 2 コマンド
Expected: どちらも PASS

- [ ] **Step 5: コミット**

```bash
git add skills.ps1 tests/skills.Tests.ps1
git commit -m "スキルの追加・削除を計算する Get-SkillPlan を追加" -m "記録にあるものだけを消す。台帳に不正な行がある回は消さない。"
```

---

### Task 5: 実行と入口（skills.ps1 の完成）

**Files:**
- Modify: `skills.ps1`（末尾の `Invoke-SkillsMain` 呼び出しのコメントを外す）
- Modify: `tests/skills.Tests.ps1`

**Interfaces:**
- Consumes: Task 1 のフラグ、Task 2〜4 の関数
- Produces:
  - `Test-NpxAvailable` → `[bool]`（`Get-Command npx`）
  - `Invoke-NpxSkills -Arguments [string[]]` → `[int]`（`$env:DISABLE_TELEMETRY = '1'` にしてから `& <npx> @Arguments` を呼び、終了コードを返す。`<npx>` は `$env:DOTFILES_SKILLS_NPX` があればそれ、なければ `npx`）
  - `Invoke-SkillPlan -Plan [pscustomobject[]] -RepoDir [string] -TargetDirs [hashtable] -Installed [pscustomobject[]] [-DryRun]` → `[pscustomobject] @{ Installed = [pscustomobject[]]; Counts = @{ Add; Update; Remove; Skip; Error } }`
  - `Invoke-SkillsMain [-DryRun] [-Select] [-Update]`：台帳を読む → `-Select` なら `Show-SkillMenu` と保存 → 計画（`-SkipRemovals` は台帳の `HasErrors`）→ 実行 → `-Update` なら `npx skills update` → 記録を保存（`-DryRun` では保存しない）→ 結果表示
- 実行のきまり：
  - `own` の `Add`/`Update`：`Update` は置き先の管理済みフォルダを消してから、`<repo>/skills/<name>` を `Copy-Item -Recurse` でコピー。退避は作らない。元フォルダがなければ、そのスキルだけ `Error` にして続ける
  - `npx` の `Add`：スキルごとに 1 回、`Add` の出す先ぶんだけ `-a <agent>` を並べて `Invoke-NpxSkills` を呼ぶ。`npx` の `Update` は何もしない（更新は `-Update` に任せる）
  - `Remove`：`own` はフォルダを消す。フォルダがすでになければ、記録から消すだけ。`npx` は `remove` を呼ぶ
  - `Conflict`：触らずに `Write-Warning`（「管理外の同名フォルダがあるので飛ばします」）、`Skip` に数える
  - npx がない：`npx` の行だけ警告して飛ばし、その記録はそのまま残す
  - 台帳ファイル（`<repo>/skills/skills.tsv`）がない：`台帳がないので飛ばします` と `Skip` を出して、何も変えずに正常終了する（台帳を作る前の dotfiles でも install が止まらないように）

- [ ] **Step 1: 失敗するテストを書く**

`BeforeEach` で `TestDrive` に一時リポジトリ（`skills/skills.tsv` と `skills/hello/SKILL.md`）と一時ホームを作り、`$env:DOTFILES_SKILLS_REPO`・`$env:DOTFILES_SKILLS_HOME` を向ける（`AfterEach` で消す）。`Mock Invoke-NpxSkills { 0 }`、`Mock Test-NpxAvailable { $true }`。

```powershell
Describe 'Invoke-SkillsMain' {
  It '自作スキルを両方の置き先にコピーし、記録する'      # <home>/.claude/skills/hello/SKILL.md と .agents 側がある・installed.txt に 2 行
  It '台帳から消すと、次の実行で消える'
  It '管理外の同名フォルダには触らない'                  # 事前に置いたファイルの中身が変わらない
  It 'DryRun では何も変わらない'                         # 置き先も installed.txt も作られない
  It '公開スキルは npx を正しいフラグで呼ぶ' {
    Should -Invoke Invoke-NpxSkills -ParameterFilter {
      ($Arguments -join ' ') -eq 'add vercel-labs/skills --skill find-skills -g -a claude-code -a github-copilot -y --copy'
    }
  }
  It 'Invoke-NpxSkills はテレメトリを止めて npx を呼ぶ'  # DOTFILES_SKILLS_NPX を「$env:DISABLE_TELEMETRY と引数をファイルに書く偽 .ps1」に向け、'1 add x' のように記録される
  It 'npx がなくても自作スキルは入る'                    # Mock Test-NpxAvailable { $false }
  It '記録にあるフォルダが手で消されていても止まらない'   # Review Focus 4：エラーなしで installed.txt から消える
  It '台帳に不正な行があると何も消さない'                # Review Focus 1
  It '更新しても置き先に .bak を作らない'                # 2 回実行して <claude> に hello 以外のフォルダが増えない
  It '台帳に増えたスキルは、除外リストがあっても入る'     # excluded.txt に別の名前だけがある状態で、新しい行が Add される
  It '公開スキルを台帳から消すと npx remove を呼ぶ'      # Should -Invoke で remove のフラグを確認（Task 1 の結果に合わせる）
  It '-Update のとき npx update を呼ぶ'
  It 'skills/ にフォルダがない自作スキルはエラーにして続ける'  # 別の自作スキルは入る・Counts.Error が 1
  It '台帳がなければ何もせずに終わる'                    # skills.tsv を消しておく → 例外なし・置き先が作られない
}
```

- [ ] **Step 2: 失敗を確かめる**

Run: `Invoke-Pester tests/skills.Tests.ps1 -Output Detailed`
Expected: FAIL

- [ ] **Step 3: 上の Interfaces と実行のきまりを実装する**

- [ ] **Step 4: 通ることを確かめる**

Run: Task 2 Step 5 と同じ 2 コマンド
Expected: どちらも PASS

- [ ] **Step 5: 5.1 で単体実行できるか確かめる**

Run: `$env:DOTFILES_SKILLS_HOME = (New-Item -ItemType Directory "$env:TEMP\skills-smoke" -Force).FullName; powershell.exe -NoProfile -File .\skills.ps1 -DryRun; Remove-Item Env:DOTFILES_SKILLS_HOME`
Expected: 文字化けせずに `[...]` の見出しと `台帳がないので飛ばします` が表示され、エラーが出ない（台帳は Task 8 で作る）

- [ ] **Step 6: コミット**

```bash
git add skills.ps1 tests/skills.Tests.ps1
git commit -m "skills.ps1 にコピーと npx 呼び出しの実行部分を追加" -m "-DryRun・-Select・-Update に対応し、単体で実行できるようにした。"
```

---

### Task 6: Linux 版 skills.sh

`skills.ps1` と同じ動きを bash で作る。テストは追加の道具なしの bash で、スクリプトを外から実行して確かめる。

**Files:**
- Create: `skills.sh`
- Create: `tests/skills.test.sh`

**Interfaces:**
- Consumes: Task 1 のフラグ。動きのきまりは Task 2〜5 と同じ（台帳の検査・計画・実行・記録ファイルの形式）
- Produces: `bash skills.sh [--dry-run] [--select] [--update]`。環境変数 `DOTFILES_SKILLS_HOME`・`DOTFILES_SKILLS_REPO`・`DOTFILES_SKILLS_NPX`（既定 `npx`）。末尾は `if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi`
- 見出しは `declare -A` で「列名 → 位置」を作って読む（bash 4 以上）

- [ ] **Step 1: 失敗するテストを書く**

`tests/skills.test.sh` に小さな確認関数（`assert_exists`・`assert_not_exists`・`assert_contains`）を書き、失敗が 1 つでもあれば最後に `exit 1`。各テストは **空白を含む一時フォルダ**（`mktemp -d "/tmp/skills test.XXXX"`）に一時リポジトリとホームを作る。偽の npx は、受け取った引数をファイルに 1 行で書くだけのスクリプトにして `DOTFILES_SKILLS_NPX` に渡す。テスト：

- `own_copied_to_both_targets`：`.claude/skills/hello/SKILL.md` と `.agents/skills/hello/SKILL.md` があり、`installed.txt` に 2 行
- `removed_from_ledger_is_removed`
- `unmanaged_folder_untouched`：事前に置いた `.claude/skills/hello/mine.txt` が残る
- `dry_run_changes_nothing`
- `npx_called_with_flags`：偽 npx のログが `1 add vercel-labs/skills --skill find-skills -g -a claude-code -a github-copilot -y --copy`（先頭の `1` は偽 npx が書いた `$DISABLE_TELEMETRY`）
- `missing_npx_still_installs_own`：`DOTFILES_SKILLS_NPX=no-such-command`
- `invalid_row_warns_and_skips_removals`：空白区切りの行で、出力に `2 行目`、既存の管理済みスキルが残る（Review Focus 1）
- `bom_and_crlf_ledger`：`printf '\xEF\xBB\xBF...\r\n'` で書いた台帳が読める（Review Focus 2）
- `bad_name_rejected`：`../evil` の行で、ホームの外に何もできない（Review Focus 3）
- `missing_folder_dropped_from_state`（Review Focus 4）
- `select_excludes_by_number`：`printf '1\n\n' | bash skills.sh --select` で 1 番が入らず、`excluded.txt` に名前が入る
- `update_creates_no_bak`：2 回実行しても `.claude/skills` に `hello` 以外のフォルダが増えない
- `missing_ledger_skips`：`skills.tsv` がないと `台帳がないので飛ばします` を出して終了コード 0
- `unknown_option_fails`：`bash skills.sh --dryrun` が終了コード 1 で `知らないオプションです: --dryrun`

- [ ] **Step 2: 失敗を確かめる**

Run: `& "$HOME\scoop\apps\git\current\bin\bash.exe" tests/skills.test.sh`
Expected: FAIL（`skills.sh` がない）

- [ ] **Step 3: `skills.sh` を実装する**

冒頭のコメントとログ関数（`info`・`step`・`ok`・`skip`）は `install.sh` と同じ形。`set -eu`。BOM は 1 行目の先頭の `$'\xEF\xBB\xBF'` を、`\r` は各行末から取り除く

- [ ] **Step 4: Git Bash と WSL の両方で通ることを確かめる**

Run: `& "$HOME\scoop\apps\git\current\bin\bash.exe" tests/skills.test.sh` と `wsl bash tests/skills.test.sh`
Expected: どちらも全テスト PASS、終了コード 0

- [ ] **Step 5: コミット**

```bash
git add skills.sh tests/skills.test.sh
git commit -m "Linux 版のスキル管理スクリプト skills.sh を追加" -m "skills.ps1 と同じ台帳・記録ファイルを使い、同じ動きをする。" -m "テストは追加の道具なしの bash で書いた。"
```

---

### Task 7: install.ps1 / install.sh に組み込む

**Files:**
- Modify: `install.ps1`（冒頭コメントの使い方・`param`・最後の「完了メッセージ」の前に新しい節）
- Modify: `install.sh`（冒頭コメント・オプションの `case`・`deploy "CLAUDE.md"` の後に新しい節）

**Interfaces:**
- Consumes: `skills.ps1`（Task 5）、`skills.sh`（Task 6）
- Produces: `.\install.ps1 -SkipSkills`、`bash install.sh --skip-skills`

- [ ] **Step 1: 変更前の DryRun 出力を保存する**

Run: `.\install.ps1 -DryRun -SkipScoop -SkipFonts | Out-File "$env:TEMP\install-before.txt"`
Expected: ファイルができる

- [ ] **Step 2: install.ps1 に節を足す**

`[switch]$SkipSkills` を足し、`Step "スキルを配置"` の節で、`-SkipSkills` なら `Skip`、そうでなければ `& (Join-Path $DotDir "skills.ps1") -DryRun:$DryRun`。冒頭の使い方に `.\install.ps1 -SkipSkills   # スキルの配置を飛ばす` を足す

- [ ] **Step 3: 既存の動きが変わっていないことを確かめる**

Run: `.\install.ps1 -DryRun -SkipScoop -SkipFonts -SkipSkills | Out-File "$env:TEMP\install-after.txt"; Compare-Object (Get-Content "$env:TEMP\install-before.txt" | Where-Object { $_ -notmatch '\.bak-\d{8}-\d{6}' }) (Get-Content "$env:TEMP\install-after.txt" | Where-Object { $_ -notmatch '\.bak-\d{8}-\d{6}' })`
Expected: 差分は「スキルを配置」の見出しと飛ばした行だけ

- [ ] **Step 4: install.sh に同じものを足す**

`--skip-skills` を `case` に足し、節で `bash "$DOTDIR/skills.sh"`（DryRun なら `--dry-run` を付ける）

- [ ] **Step 5: Linux 側を確かめる**

Run: `wsl bash install.sh --dry-run --skip-fonts --skip-skills` と `wsl bash install.sh --dry-run --skip-fonts`
Expected: 前者は「スキルを配置」で飛ばしたと表示、後者は skills.sh の DryRun 出力が続く。どちらもエラーなし

- [ ] **Step 6: コミット**

```bash
git add install.ps1 install.sh
git commit -m "install の最後でスキルを配置するようにした" -m "-SkipSkills（Linux は --skip-skills）で飛ばせる。" -m "既存の配置処理の動きは変えていない。"
```

---

### Task 8: 台帳の初期内容・最初の自作スキル・README

**Files:**
- Create: `skills/skills.tsv`
- Create: `skills/dotfiles-skills/SKILL.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 5〜7 の使い方とオプション

- [ ] **Step 1: 台帳を作る**

見出しと 2 行（区切りはタブ・UTF-8 BOM なし・LF）：

| type | name | source | targets | url | note |
|---|---|---|---|---|---|
| own | dotfiles-skills | | claude,agents | | スキル台帳の使い方 |
| npx | find-skills | vercel-labs/skills | claude,agents | https://skills.sh/vercel-labs/skills/find-skills | スキル検索 |

- [ ] **Step 2: 最初の自作スキルを作る**

`skills/dotfiles-skills/SKILL.md`。`description` は「スキルを追加・削除したい、スキル台帳を編集したいと言われたときに使う」。本文は、dotfiles の `skills/skills.tsv` に 1 行足す（または消す）→ 自作なら `skills/<name>/SKILL.md` を作る → `skills.ps1` / `skills.sh` を実行する、という手順と、列の意味（設計メモ 5.2 の表）

- [ ] **Step 3: 台帳が読めることを確かめる**

Run: `.\skills.ps1 -DryRun`
Expected: 2 件とも計画に出る（このPCでは `~/.claude/skills/find-skills` が管理外にあるので、claude 側は `Conflict` の警告になる）。不正な行の警告は出ない

- [ ] **Step 4: README に「スキル」の節を足す**

今の README の書き方に合わせて足す：「管理しているもの」の表に `skills/` の行、ディレクトリ構成の図に `skills/` と `skills.ps1 / skills.sh`、「スキルを増やす・減らす」の手順（台帳に 1 行 → push → 他のPCで pull と `.\skills.ps1`）、オプションの表に 4 つ（Global Constraints のもの）、公開スキルには Node.js が必要なこと、選択メニューの画面例（設計メモ 5.4）、注意点（管理外のスキルには触らない・スキルの編集はリポジトリ側でやる・sync の対象ではない）

- [ ] **Step 5: コミット**

```bash
git add skills/skills.tsv skills/dotfiles-skills/SKILL.md README.md
git commit -m "スキル台帳の初期内容と使い方を追加" -m "台帳の使い方を教える自作スキル dotfiles-skills と、" -m "公開スキル find-skills を登録し、README に手順を書いた。"
```

---

### Task 9: 実機での確認（設計メモ第 9 章）

自動テストでは確かめられない「各ツールが本当に読むか」を見る。Roze に画面を見てもらう手順を含む。

**Files:**
- Modify: `docs/superpowers/specs/2026-11-15-skills-manager-design.md`（第 9 章のチェックを埋める）

- [ ] **Step 1: ノートPC（Windows）で本番実行**

Run: `.\skills.ps1`
Expected: `~/.claude/skills/dotfiles-skills/SKILL.md` と `~/.agents/skills/dotfiles-skills/SKILL.md` ができる。`find-skills` は、管理外の同名フォルダがある置き先（このPCでは少なくとも `~/.claude/skills`）では警告して飛ばし、ほかの置き先には入る

- [ ] **Step 2: 各ツールで見えるか確かめる（Roze に確認してもらう）**

- Claude Code：新しいセッションで `dotfiles-skills` がスキル一覧に出る
- VS Code の Copilot：チャットの「Configure Skills」に `dotfiles-skills` が出る
- GitHub Copilot アプリ：`dotfiles-skills` と `find-skills` が 1 つずつだけ見える（二重になっていない）

- [ ] **Step 3: 選択と片付けを確かめる**

Run: `.\skills.ps1 -Select` で `dotfiles-skills` を外す → 両方の置き先から消える → もう一度 `-Select` で戻す → 両方に戻る
Expected: そのとおりになり、`~/.claude/skills/synced/` などは変わらない

- [ ] **Step 4: WSL（Linux）で本番実行**

Run: `wsl bash skills.sh`
Expected: WSL 側のホームに 2 か所とも置かれる

- [ ] **Step 5: 結果を設計メモに書いてコミット**

```bash
git add docs/superpowers/specs/2026-11-15-skills-manager-design.md
git commit -m "スキル管理の実機確認の結果を設計メモに記録" -m "Claude Code・VS Code・Copilot アプリで読めるかを確かめた。"
```

---
name: dotfiles-skills
description: dotfiles のスキル台帳（skills/skills.tsv）でスキルを管理する手順。スキルを追加したい・削除したい・入れ直したい、スキル台帳を編集したいと言われたときに使う。
---

# dotfiles のスキル台帳の使い方

スキルは dotfiles リポジトリの `skills/skills.tsv`（台帳）で管理している。
台帳を書き換えてから配置スクリプトを実行すると、次の 2 か所にスキルが入る。

- `~/.claude/skills` … Claude Code が読む
- `~/.agents/skills` … VS Code の Copilot・Copilot アプリ・Codex が読む

## 手順

1. dotfiles リポジトリの場所を確かめる（`skills.ps1` と `skills/skills.tsv` があるフォルダ。例：`~/dotfiles`、`~/Developer/dotfiles`）
2. 台帳 `skills/skills.tsv` に 1 行足す（減らすときは行を消す）。区切りは**タブ**にする
3. 自作スキルなら `skills/<name>/SKILL.md` を作る
4. 配置スクリプトを実行する。まず予行演習で確かめてから本番を実行すると安全
   - Windows：`.\skills.ps1 -DryRun` → `.\skills.ps1`
   - Linux：`bash skills.sh --dry-run` → `bash skills.sh`
5. 変更をコミットして push する。ほかのPCでは `git pull` のあと、同じスクリプトを実行する

入れるスキルを選びたいときは `.\skills.ps1 -Select`（Linux は `bash skills.sh --select`）。
公開スキルを最新にしたいときは `-Update`（Linux は `--update`）を付ける。

## 台帳の列

1 行目は見出し。列は名前で読むので、順番は入れ替えてもよい。

| 列 | 必須 | 中身 |
|---|---|---|
| `type` | 必須 | `own`（自作スキル）か `npx`（公開スキル） |
| `name` | 必須 | スキル名。自作スキルはフォルダ名と同じにする。使える文字は英数字と `.` `_` `-` |
| `source` | `npx` のとき必須 | npx skills に渡すリポジトリ（`owner/repo`） |
| `targets` | 必須 | 出す先。`claude`・`agents` をカンマでつなぐ |
| `url` | 任意 | 参考リンク |
| `note` | 任意 | メモ。選択メニューに表示される |

## 注意

- 区切りがタブでない行は読めずに警告になる。読めない行がある回は、安全のためスキルの削除をしない
- スキルの中身はリポジトリ側（`skills/<name>/`）で編集する。置き先を直接編集しても、次の実行で上書きされる
- このスクリプトが入れていないスキル（`synced/` や手で入れたもの）には触らない。同じ名前のフォルダがあると、警告を出して飛ばす
- 公開スキル（`npx`）を入れるには Node.js が必要

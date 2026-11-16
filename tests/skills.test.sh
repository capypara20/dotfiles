#!/usr/bin/env bash
# ==================================================================
# skills.sh のテスト（追加の道具なしの bash）
#
# 使い方:
#   bash tests/skills.test.sh
#
# 各テストは「空白を含む一時フォルダ」に一時リポジトリとホームを作り、
# 環境変数で skills.sh の向き先を差し替えてから外から実行する。
# npx は、受け取った引数をファイルに書くだけの偽物に差し替える。
# ==================================================================

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../skills.sh"
PASS=0
FAIL=0
CURRENT=""
TEST_OK=1

# ------------------------------------------------------------------
# 小さな確認関数
# ------------------------------------------------------------------
fail()              { echo "  FAIL [$CURRENT] $1"; TEST_OK=0; }
assert_exists()     { [ -e "$1" ] || fail "ありません: $1"; }
assert_not_exists() { [ ! -e "$1" ] || fail "あってはいけません: $1"; }
assert_contains()   { case "$1" in *"$2"*) ;; *) fail "「$2」が含まれていません。出力: $1" ;; esac; }
assert_eq()         { [ "$1" = "$2" ] || fail "期待: '$2' / 実際: '$1'"; }

# 空でない行の数（ファイルがなければ 0）
count_lines() { if [ -f "$1" ]; then grep -c . "$1" || true; else echo 0; fi; }

# ------------------------------------------------------------------
# 準備と後片付け
# ------------------------------------------------------------------
setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/skills test.XXXXXX")"
  REPO="$T/repo"
  H="$T/home"
  mkdir -p "$REPO/skills/hello" "$REPO/skills/world" "$H"
  printf -- '---\nname: hello\n---\n' > "$REPO/skills/hello/SKILL.md"
  printf -- '---\nname: world\n---\n' > "$REPO/skills/world/SKILL.md"

  # 偽の npx：「DISABLE_TELEMETRY の値 と 受け取った引数」を 1 行で書く
  FAKE="$T/fake npx"
  printf '#!/usr/bin/env bash\necho "${DISABLE_TELEMETRY:-} $*" >> "$NPX_LOG"\nexit 0\n' > "$FAKE"
  chmod +x "$FAKE"
  export NPX_LOG="$T/npx.log"

  export DOTFILES_SKILLS_REPO="$REPO"
  export DOTFILES_SKILLS_HOME="$H"
  export DOTFILES_SKILLS_NPX="$FAKE"
  CLAUDE="$H/.claude/skills"
  AGENTS="$H/.agents/skills"
  STATE="$H/.dotfiles-skills"
}

teardown() { rm -rf "$T"; }

# 台帳を書く（見出し + 引数の各行）
ledger() {
  {
    printf 'type\tname\ttargets\tsource\turl\tnote\n'
    for row in "$@"; do printf '%s\n' "$row"; done
  } > "$REPO/skills/skills.tsv"
}

# skills.sh を実行して、出力を OUT・終了コードを CODE に入れる
run() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  CODE=$?
}

# ------------------------------------------------------------------
# テスト
# ------------------------------------------------------------------
t_own_copied_to_both_targets() {
  ledger $'own\thello\tclaude,agents\t\t\t'
  run
  assert_eq "$CODE" 0
  assert_exists "$CLAUDE/hello/SKILL.md"
  assert_exists "$AGENTS/hello/SKILL.md"
  assert_eq "$(count_lines "$STATE/installed.txt")" 2
}

t_removed_from_ledger_is_removed() {
  ledger $'own\thello\tclaude,agents\t\t\t'
  run
  ledger
  run
  assert_eq "$CODE" 0
  assert_not_exists "$CLAUDE/hello"
  assert_not_exists "$AGENTS/hello"
  assert_eq "$(count_lines "$STATE/installed.txt")" 0
}

t_unmanaged_folder_untouched() {
  mkdir -p "$CLAUDE/hello"
  echo mine > "$CLAUDE/hello/mine.txt"
  ledger $'own\thello\tclaude\t\t\t'
  run
  assert_eq "$(cat "$CLAUDE/hello/mine.txt")" mine
  assert_not_exists "$CLAUDE/hello/SKILL.md"
  assert_contains "$OUT" "管理外の同名フォルダ"
  assert_eq "$(count_lines "$STATE/installed.txt")" 0
}

t_dry_run_changes_nothing() {
  ledger $'own\thello\tclaude,agents\t\t\t'
  run --dry-run
  assert_eq "$CODE" 0
  assert_not_exists "$CLAUDE"
  assert_not_exists "$AGENTS"
  assert_not_exists "$STATE"
}

t_npx_called_with_flags() {
  ledger $'npx\tfind-skills\tclaude,agents\tvercel-labs/skills\t\t'
  run
  assert_eq "$CODE" 0
  assert_eq "$(cat "$NPX_LOG")" "1 -y skills add vercel-labs/skills --skill find-skills -g -a claude-code -a github-copilot -y --copy"
  assert_eq "$(count_lines "$STATE/installed.txt")" 2
}

# 公開スキルを消すときは npx remove を呼ばない（記録にないフォルダまで消すため）
t_npx_remove_does_not_call_npx() {
  ledger $'npx\tfind-skills\tclaude,agents\tvercel-labs/skills\t\t'
  run
  ledger
  run
  case "$(cat "$NPX_LOG")" in *remove*) fail "npx remove が呼ばれました" ;; esac
  assert_eq "$(count_lines "$STATE/installed.txt")" 0
}

t_npx_removal_works_without_npx() {
  ledger $'npx\tfind-skills\tclaude,agents\tvercel-labs/skills\t\t'
  run
  mkdir -p "$CLAUDE/find-skills" "$AGENTS/find-skills"
  export DOTFILES_SKILLS_NPX="no-such-command-for-skills-test"
  ledger
  run
  assert_not_exists "$CLAUDE/find-skills"
  assert_not_exists "$AGENTS/find-skills"
  assert_eq "$(count_lines "$STATE/installed.txt")" 0
}

# 記録ファイルのおかしな行（名前が空・..・知らない置き先）があっても、何も消さない
t_bad_state_lines_delete_nothing() {
  mkdir -p "$CLAUDE/keep" "$CLAUDE/hello" "$STATE"
  echo mine > "$H/.claude/CLAUDE.md"
  printf 'claude\t\town\nclaude\t..\town\ncopilot\tx\town\nclaude\thello\town\n' > "$STATE/installed.txt"
  ledger
  run
  assert_eq "$CODE" 0
  assert_exists "$CLAUDE/keep"
  assert_exists "$CLAUDE/hello"
  assert_exists "$H/.claude/CLAUDE.md"
}

t_empty_ledger_stops() {
  ledger $'own\thello\tclaude\t\t\t'
  run
  : > "$REPO/skills/skills.tsv"
  run
  [ "$CODE" -ne 0 ] || fail "空の台帳なのに終了コードが 0 でした"
  assert_contains "$OUT" "台帳が空です"
  assert_exists "$CLAUDE/hello/SKILL.md"
}

t_copy_failure_continues_and_records() {
  printf 'not a folder' > "$H/.agents"
  ledger $'own\thello\tclaude,agents\t\t\t'
  run
  assert_eq "$CODE" 0
  assert_exists "$CLAUDE/hello/SKILL.md"
  assert_eq "$(cat "$STATE/installed.txt")" "$(printf 'claude\thello\town')"
  assert_contains "$OUT" "失敗"
}

t_npx_partial_failure_records_created_folder() {
  FAKE2="$T/half npx"
  printf '#!/usr/bin/env bash\nmkdir -p "$DOTFILES_SKILLS_HOME/.agents/skills/find-skills"\nexit 1\n' > "$FAKE2"
  chmod +x "$FAKE2"
  export DOTFILES_SKILLS_NPX="$FAKE2"
  ledger $'npx\tfind-skills\tagents\tvercel-labs/skills\t\t'
  run
  assert_eq "$(cat "$STATE/installed.txt")" "$(printf 'agents\tfind-skills\tnpx')"
}

t_npx_remove_also_deletes_leftover_folders() {
  ledger $'npx\tfind-skills\tclaude,agents\tvercel-labs/skills\t\t'
  run
  # npx が入れたフォルダの代わり（偽の npx は何も作らないので手で作る）
  mkdir -p "$CLAUDE/find-skills" "$AGENTS/find-skills"
  ledger
  run
  assert_not_exists "$CLAUDE/find-skills"
  assert_not_exists "$AGENTS/find-skills"
}

# --update は、記録にある公開スキルを、記録した出す先だけに入れ直す（npx update は使わない）
t_update_readds_recorded_targets() {
  ledger $'npx\tfind-skills\tagents\tvercel-labs/skills\t\t'
  run
  run --update
  assert_eq "$CODE" 0
  assert_eq "$(sed -n 2p "$NPX_LOG")" "1 -y skills add vercel-labs/skills --skill find-skills -g -a github-copilot -y --copy"
  case "$(cat "$NPX_LOG")" in *" update"*) fail "npx update が呼ばれました" ;; esac
}

t_missing_npx_still_installs_own() {
  export DOTFILES_SKILLS_NPX="no-such-command-for-skills-test"
  ledger $'own\thello\tclaude\t\t\t' $'npx\tfind-skills\tclaude\tvercel-labs/skills\t\t'
  run
  assert_eq "$CODE" 0
  assert_exists "$CLAUDE/hello/SKILL.md"
  assert_contains "$OUT" "npx が見つからない"
}

# WSL などで「npx は見えるが node がない」ときは、公開スキルを入れない
# （Windows 側の npx が見えてしまい、Windows のホームに入れてしまう事故を防ぐ）
t_npx_without_node_is_skipped() {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho called >> "$NPX_LOG"\n' > "$T/bin/npx"
  chmod +x "$T/bin/npx"
  if PATH="$T/bin:/usr/bin:/bin" command -v node >/dev/null 2>&1; then
    echo "  (skip: このPCには /usr/bin に node があるので確かめられない)"
    return 0
  fi
  unset DOTFILES_SKILLS_NPX
  ledger $'own\thello\tclaude\t\t\t' $'npx\tfind-skills\tclaude\tvercel-labs/skills\t\t'
  OUT="$(PATH="$T/bin:/usr/bin:/bin" bash "$SCRIPT" 2>&1)"
  CODE=$?
  assert_eq "$CODE" 0
  assert_not_exists "$NPX_LOG"
  assert_contains "$OUT" "npx が見つからない"
  assert_exists "$CLAUDE/hello/SKILL.md"
}

t_invalid_row_warns_and_skips_removals() {
  ledger $'own\thello\tclaude\t\t\t'
  run
  ledger 'x own claude'
  run
  assert_contains "$OUT" "2 行目"
  assert_exists "$CLAUDE/hello/SKILL.md"
  assert_eq "$(count_lines "$STATE/installed.txt")" 1
}

t_bom_and_crlf_ledger() {
  printf '\xEF\xBB\xBFtype\tname\ttargets\tsource\turl\tnote\r\nown\thello\tclaude,agents\t\t\tメモ\r\n' > "$REPO/skills/skills.tsv"
  run
  assert_eq "$CODE" 0
  assert_exists "$CLAUDE/hello/SKILL.md"
  assert_exists "$AGENTS/hello/SKILL.md"
}

t_bad_name_rejected() {
  ledger $'own\t../evil\tclaude\t\t\t'
  run
  assert_contains "$OUT" "2 行目"
  assert_not_exists "$H/.claude/evil"
  assert_not_exists "$T/evil"
  assert_eq "$(count_lines "$STATE/installed.txt")" 0
}

t_missing_folder_dropped_from_state() {
  ledger $'own\thello\tclaude\t\t\t'
  run
  rm -rf "$CLAUDE/hello"
  ledger
  run
  assert_eq "$CODE" 0
  assert_eq "$(count_lines "$STATE/installed.txt")" 0
}

t_select_excludes_by_number() {
  ledger $'own\thello\tclaude\t\t\t' $'own\tworld\tclaude\t\t\t'
  OUT="$(printf '1\n\n' | bash "$SCRIPT" --select 2>&1)"
  CODE=$?
  assert_eq "$CODE" 0
  assert_not_exists "$CLAUDE/hello"
  assert_exists "$CLAUDE/world/SKILL.md"
  assert_eq "$(cat "$STATE/excluded.txt")" hello
}

t_update_creates_no_bak() {
  ledger $'own\thello\tclaude\t\t\t'
  run
  run
  assert_eq "$(ls -A "$CLAUDE")" hello
}

t_missing_ledger_skips() {
  rm -f "$REPO/skills/skills.tsv"
  run
  assert_eq "$CODE" 0
  assert_contains "$OUT" "台帳がないので飛ばします"
  assert_not_exists "$CLAUDE"
}

t_unknown_option_fails() {
  ledger
  run --dryrun
  assert_eq "$CODE" 1
  assert_contains "$OUT" "知らないオプションです: --dryrun"
}

# ------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------
TESTS=(
  t_own_copied_to_both_targets
  t_removed_from_ledger_is_removed
  t_unmanaged_folder_untouched
  t_dry_run_changes_nothing
  t_npx_called_with_flags
  t_npx_remove_does_not_call_npx
  t_npx_removal_works_without_npx
  t_npx_remove_also_deletes_leftover_folders
  t_bad_state_lines_delete_nothing
  t_empty_ledger_stops
  t_copy_failure_continues_and_records
  t_npx_partial_failure_records_created_folder
  t_update_readds_recorded_targets
  t_missing_npx_still_installs_own
  t_npx_without_node_is_skipped
  t_invalid_row_warns_and_skips_removals
  t_bom_and_crlf_ledger
  t_bad_name_rejected
  t_missing_folder_dropped_from_state
  t_select_excludes_by_number
  t_update_creates_no_bak
  t_missing_ledger_skips
  t_unknown_option_fails
)

for t in "${TESTS[@]}"; do
  CURRENT="$t"
  TEST_OK=1
  setup
  "$t"
  teardown
  if [ "$TEST_OK" -eq 1 ]; then
    echo "  PASS $t"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]

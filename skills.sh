#!/usr/bin/env bash
# ==================================================================
# Linux 用 スキル配置スクリプト（コピー方式）
#
# やること:
#   (1) 台帳（skills/skills.tsv）を読む
#   (2) 自作スキル（skills/<名前>/）を、各ツールが読む場所へ「コピー」する
#   (3) 公開スキルを npx skills で入れる
#   (4) 台帳から消したスキル・選択で外したスキルを片付ける
#       （消すのは、このスクリプトが入れたものだけ）
#
# 置き先:
#   claude : ~/.claude/skills   … Claude Code が読む
#   agents : ~/.agents/skills   … VS Code の Copilot・Copilot アプリ・Codex が読む
#
# 使い方:
#   bash skills.sh             # 台帳どおりに配置する
#   bash skills.sh --select    # 入れるスキルを番号で選ぶ
#   bash skills.sh --update    # 最後に公開スキルの更新（npx skills update）もする
#   bash skills.sh --dry-run   # 何が起きるか表示するだけ
#
# install.sh の最後からも呼ばれる（--skip-skills で飛ばせる）。
# Windows 版の skills.ps1 と同じ台帳・同じ記録ファイルを使う。
# ==================================================================

set -eu

# ==================================================================
# 置き先の対応表
#   台帳の targets 列に書く名前 → ホームからの場所 と npx skills の agent 名
#   将来 Claude Code が ~/.agents/skills を読むようになったら、claude を外すだけでよい
# ==================================================================
TARGET_KEYS=(claude agents)
declare -A TARGET_DIR=([claude]=".claude/skills" [agents]=".agents/skills")
declare -A TARGET_AGENT=([claude]="claude-code" [agents]="github-copilot")

# スキル名に使える文字（../ などで置き先の外に出られないようにする）
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# npx の source（owner/repo）
SOURCE_RE='^[^/[:space:]]+/[^/[:space:]]+$'

# ------------------------------------------------------------------
# 場所（テストのときは環境変数で差し替えられる）
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${DOTFILES_SKILLS_REPO:-$SCRIPT_DIR}"
HOME_DIR="${DOTFILES_SKILLS_HOME:-$HOME}"
NPX="${DOTFILES_SKILLS_NPX:-npx}"
LEDGER="$REPO/skills/skills.tsv"
STATE_DIR="$HOME_DIR/.dotfiles-skills"

DRYRUN=0
SELECT=0
UPDATE=0

info() { echo "  $1"; }
step() { echo ""; echo "[$1]"; }
ok()   { echo "  OK   $1"; }
skip() { echo "  --   $1"; }
warn() { echo "  !!   $1" >&2; }

# 前後の空白を取る
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

target_dir() { printf '%s/%s' "$HOME_DIR" "${TARGET_DIR[$1]}"; }

# ==================================================================
# 台帳を読む
#
#   1 行目は見出し（列名）。列は名前で探すので、順番が変わっても、
#   知らない列が増えても読める。
#   おかしな行は「何行目がなぜダメか」を警告して飛ばし、LEDGER_ERRORS を立てる。
#   （LEDGER_ERRORS のときは、片付け＝削除をしない。全部消える事故を防ぐため）
#
#   結果は SK_TYPE / SK_NAME / SK_SOURCE / SK_TARGETS（カンマ区切り）/ SK_NOTE に入る
# ==================================================================
SK_TYPE=(); SK_NAME=(); SK_SOURCE=(); SK_TARGETS=(); SK_NOTE=()
LEDGER_ERRORS=0
declare -A COL=()

# タブで区切る。空の欄も残すため、タブを「空白扱いされない区切り文字」に置き換えてから分ける
split_tabs() {
  local line="${1//$'\t'/$'\x1f'}"
  IFS=$'\x1f' read -r -a FIELDS <<< "$line" || true
}

field() {
  local name="$1"
  if [ -z "${COL[$name]+x}" ]; then return 0; fi
  local idx="${COL[$name]}"
  if [ "$idx" -ge "${#FIELDS[@]}" ]; then return 0; fi
  trim "${FIELDS[$idx]}"
}

read_ledger() {
  local lineno=0 line type name source targets_raw note reason t
  local -A seen=()
  FIELDS=()

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"

    # 見出し行：BOM を取り、「列名 → 位置」の表を作る
    if [ "$lineno" -eq 1 ]; then
      line="${line#$'\xEF\xBB\xBF'}"
      split_tabs "$line"
      local i col
      for i in "${!FIELDS[@]}"; do
        col="$(trim "${FIELDS[$i]}")"
        if [ -n "$col" ] && [ -z "${COL[$col]+x}" ]; then COL[$col]=$i; fi
      done
      for col in type name targets; do
        if [ -z "${COL[$col]+x}" ]; then
          echo "台帳の見出しに必須の列がありません: $col" >&2
          return 1
        fi
      done
      continue
    fi

    # 空行と # の行は読み飛ばす
    local stripped
    stripped="$(trim "$line")"
    if [ -z "$stripped" ] || [ "${stripped:0:1}" = "#" ]; then continue; fi

    split_tabs "$line"
    type="$(field type)"
    name="$(field name)"
    source="$(field source)"
    note="$(field note)"

    # targets：カンマで分け、空白を取り、空のものを捨てる
    local -a targets=()
    targets_raw="$(field targets)"
    local -a parts=()
    IFS=',' read -r -a parts <<< "$targets_raw" || true
    for t in "${parts[@]+"${parts[@]}"}"; do
      t="$(trim "$t")"
      if [ -n "$t" ]; then targets+=("$t"); fi
    done

    reason=""
    if [ "$type" != "own" ] && [ "$type" != "npx" ]; then
      reason="type は own か npx にしてください（今は '$type'）"
    elif ! [[ "$name" =~ $NAME_RE ]]; then
      reason="name に使えない文字があります（'$name'）"
    elif [ "${#targets[@]}" -eq 0 ]; then
      reason="targets が空です"
    elif [ "$type" = "npx" ] && ! [[ "$source" =~ $SOURCE_RE ]]; then
      reason="npx の行には source（owner/repo）が必要です"
    elif [ -n "${seen[$name]+x}" ]; then
      reason="同じ名前のスキルが ${seen[$name]} 行目にもあります（'$name'）"
    else
      for t in "${targets[@]}"; do
        if [ -z "${TARGET_DIR[$t]+x}" ]; then
          reason="知らない出す先です（'$t'）。使えるのは ${TARGET_KEYS[*]}"
          break
        fi
      done
    fi

    if [ -n "$reason" ]; then
      warn "台帳 $lineno 行目: $reason。この行は飛ばします"
      LEDGER_ERRORS=1
      continue
    fi

    seen[$name]=$lineno
    SK_TYPE+=("$type")
    SK_NAME+=("$name")
    SK_SOURCE+=("$source")
    SK_TARGETS+=("$(IFS=','; echo "${targets[*]}")")
    SK_NOTE+=("$note")
  done < "$LEDGER"
}

# ==================================================================
# マシンごとの記録（~/.dotfiles-skills/）
#   excluded.txt  : 選択で外したスキル名（1 行に 1 つ）
#   installed.txt : このスクリプトが入れたもの（置き先<TAB>名前<TAB>種類）
#   skills.ps1 と同じファイルを読み書きする（BOM なし UTF-8・改行 LF）
# ==================================================================
EXCLUDED=()
IN_TARGET=(); IN_NAME=(); IN_TYPE=()

load_state() {
  local line f
  if [ -f "$STATE_DIR/excluded.txt" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="$(trim "${line%$'\r'}")"
      if [ -n "$line" ]; then EXCLUDED+=("$line"); fi
    done < "$STATE_DIR/excluded.txt"
  fi
  if [ -f "$STATE_DIR/installed.txt" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      if [ -z "$line" ]; then continue; fi
      split_tabs "$line"
      if [ "${#FIELDS[@]}" -lt 3 ]; then continue; fi
      IN_TARGET+=("${FIELDS[0]}")
      IN_NAME+=("${FIELDS[1]}")
      IN_TYPE+=("${FIELDS[2]}")
    done < "$STATE_DIR/installed.txt"
  fi
}

save_excluded() {
  mkdir -p "$STATE_DIR"
  if [ "${#EXCLUDED[@]}" -gt 0 ]; then
    printf '%s\n' "${EXCLUDED[@]}" > "$STATE_DIR/excluded.txt"
  else
    : > "$STATE_DIR/excluded.txt"
  fi
}

is_excluded() {
  local n
  for n in "${EXCLUDED[@]+"${EXCLUDED[@]}"}"; do
    if [ "$n" = "$1" ]; then return 0; fi
  done
  return 1
}

# ==================================================================
# 選択メニュー
#   番号（1 始まり。空白かカンマ区切りで複数可）で「外す／戻す」を切り替え、
#   空の Enter で決定する。保存するのは「外したスキル」の一覧。
# ==================================================================
toggle_excluded() {
  local name="$1" n
  local -a kept=()
  if is_excluded "$name"; then
    for n in "${EXCLUDED[@]}"; do
      if [ "$n" != "$name" ]; then kept+=("$n"); fi
    done
    EXCLUDED=("${kept[@]+"${kept[@]}"}")
  else
    EXCLUDED+=("$name")
  fi
}

show_menu() {
  local answer token i mark count="${#SK_NAME[@]}"
  while true; do
    echo ""
    echo "入れるスキルを選んでください（番号で切り替え、Enter で決定）"
    for i in "${!SK_NAME[@]}"; do
      mark="x"
      if is_excluded "${SK_NAME[$i]}"; then mark=" "; fi
      printf ' [%s] %d. %-16s %s\n' "$mark" "$((i + 1))" "${SK_NAME[$i]}" "${SK_NOTE[$i]}"
    done
    printf '番号: '
    if ! IFS= read -r answer; then echo ""; break; fi
    answer="$(trim "${answer%$'\r'}")"
    if [ -z "$answer" ]; then break; fi
    for token in ${answer//,/ }; do
      if [[ "$token" =~ ^[0-9]+$ ]] && [ "$token" -ge 1 ] && [ "$token" -le "$count" ]; then
        toggle_excluded "${SK_NAME[$((token - 1))]}"
      else
        warn "番号 '$token' は使えません（1〜$count で入力してください）"
      fi
    done
  done
}

# ==================================================================
# 何をするかの計算（skills.ps1 の Get-SkillPlan と同じきまり）
#   入れたい組ごとに: 記録にある → Update / 同名フォルダがある → Conflict / ほか → Add
#   記録にあるのに入れたい組にない → Remove（台帳に不正な行がある回は出さない）
#   消す候補は「記録にあるもの」だけ。synced/ や手で入れたものは出てこない。
# ==================================================================
PL_ACTION=(); PL_TYPE=(); PL_NAME=(); PL_TARGET=(); PL_SOURCE=()

add_plan() {
  PL_ACTION+=("$1"); PL_TYPE+=("$2"); PL_NAME+=("$3"); PL_TARGET+=("$4"); PL_SOURCE+=("$5")
}

make_plan() {
  local -A installed=() wanted=()
  local i j key t action
  for i in "${!IN_NAME[@]}"; do installed["${IN_TARGET[$i]}"$'\t'"${IN_NAME[$i]}"]=1; done

  for i in "${!SK_NAME[@]}"; do
    if is_excluded "${SK_NAME[$i]}"; then continue; fi
    local -a ts=()
    IFS=',' read -r -a ts <<< "${SK_TARGETS[$i]}" || true
    for t in "${ts[@]}"; do
      key="$t"$'\t'"${SK_NAME[$i]}"
      wanted[$key]=1
      action="Add"
      if [ -n "${installed[$key]+x}" ]; then
        action="Update"
      elif [ -e "$(target_dir "$t")/${SK_NAME[$i]}" ]; then
        action="Conflict"
      fi
      add_plan "$action" "${SK_TYPE[$i]}" "${SK_NAME[$i]}" "$t" "${SK_SOURCE[$i]}"
    done
  done

  if [ "$LEDGER_ERRORS" -eq 1 ]; then return 0; fi
  for j in "${!IN_NAME[@]}"; do
    key="${IN_TARGET[$j]}"$'\t'"${IN_NAME[$j]}"
    if [ -z "${wanted[$key]+x}" ]; then
      add_plan "Remove" "${IN_TYPE[$j]}" "${IN_NAME[$j]}" "${IN_TARGET[$j]}" ""
    fi
  done
}

# ==================================================================
# 計画を実行する
# ==================================================================
declare -A NEW_STATE=()
NEW_ORDER=()
C_ADD=0; C_UPDATE=0; C_REMOVE=0; C_SKIP=0; C_ERROR=0

state_set() {
  local key="$1"$'\t'"$2"
  if [ -z "${NEW_STATE[$key]+x}" ]; then NEW_ORDER+=("$key"); fi
  NEW_STATE[$key]="$3"
}
state_unset() { unset 'NEW_STATE['"$1"$'\t'"$2"']'; }

count_action() {
  case "$1" in
    Add)    C_ADD=$((C_ADD + 1)) ;;
    Update) C_UPDATE=$((C_UPDATE + 1)) ;;
    Remove) C_REMOVE=$((C_REMOVE + 1)) ;;
  esac
}

# 管理しているスキルのフォルダを消す（リンクならリンクだけを消す）
remove_skill_dir() {
  if [ -L "$1" ]; then
    rm -f -- "$1"
  elif [ -d "$1" ]; then
    rm -rf -- "$1"
  fi
}

# npx skills を呼ぶ（テレメトリを止める）。終了コードを返す
run_npx() {
  local code=0
  DISABLE_TELEMETRY=1 "$NPX" -y skills "$@" || code=$?
  return "$code"
}

npx_available() {
  if [ -n "${DOTFILES_SKILLS_NPX:-}" ]; then
    # テストなどで npx を差し替えたときは、それがあるかだけを見る
    command -v "$NPX" >/dev/null 2>&1
  else
    # WSL では Windows 側の npx が見えてしまうことがある。
    # それを使うと Windows のホームに入ってしまうので、Linux の node もあるときだけ使う
    command -v npx >/dev/null 2>&1 && command -v node >/dev/null 2>&1
  fi
}

run_plan() {
  local i j key dst src label
  for i in "${!IN_NAME[@]}"; do state_set "${IN_TARGET[$i]}" "${IN_NAME[$i]}" "${IN_TYPE[$i]}"; done

  # --- 管理外の同名フォルダ：触らない ---
  for i in "${!PL_ACTION[@]}"; do
    if [ "${PL_ACTION[$i]}" = "Conflict" ]; then
      warn "${PL_NAME[$i]}（${PL_TARGET[$i]}）: 管理外の同名フォルダがあるので飛ばします: $(target_dir "${PL_TARGET[$i]}")/${PL_NAME[$i]}"
      C_SKIP=$((C_SKIP + 1))
    fi
  done

  # --- 自作スキル ---
  for i in "${!PL_ACTION[@]}"; do
    if [ "${PL_TYPE[$i]}" != "own" ] || [ "${PL_ACTION[$i]}" = "Conflict" ]; then continue; fi
    dst="$(target_dir "${PL_TARGET[$i]}")/${PL_NAME[$i]}"
    label="${PL_NAME[$i]}（${PL_TARGET[$i]}）"

    if [ "${PL_ACTION[$i]}" = "Remove" ]; then
      info "削除: $label"
      if [ "$DRYRUN" -eq 0 ]; then remove_skill_dir "$dst"; fi
      state_unset "${PL_TARGET[$i]}" "${PL_NAME[$i]}"
      count_action Remove
      continue
    fi

    src="$REPO/skills/${PL_NAME[$i]}"
    if [ ! -d "$src" ]; then
      warn "$label: リポジトリに $src がないので飛ばします"
      C_ERROR=$((C_ERROR + 1))
      continue
    fi
    if [ "${PL_ACTION[$i]}" = "Add" ]; then info "追加: $label -> $dst"; else info "更新: $label -> $dst"; fi
    if [ "$DRYRUN" -eq 0 ]; then
      remove_skill_dir "$dst"
      mkdir -p "$(dirname "$dst")"
      cp -R "$src" "$dst"
    fi
    state_set "${PL_TARGET[$i]}" "${PL_NAME[$i]}" own
    count_action "${PL_ACTION[$i]}"
  done

  # --- 公開スキル（スキルごとに、出す先をまとめて 1 回呼ぶ） ---
  local -A done_group=()
  local ready=""
  local action name gkey
  for i in "${!PL_ACTION[@]}"; do
    action="${PL_ACTION[$i]}"
    name="${PL_NAME[$i]}"
    if [ "${PL_TYPE[$i]}" != "npx" ]; then continue; fi
    if [ "$action" != "Add" ] && [ "$action" != "Remove" ]; then continue; fi
    gkey="$action"$'\t'"$name"
    if [ -n "${done_group[$gkey]+x}" ]; then continue; fi
    done_group[$gkey]=1

    local -a members=() agent_args=() targets_txt=()
    for j in "${!PL_ACTION[@]}"; do
      if [ "${PL_TYPE[$j]}" = "npx" ] && [ "${PL_ACTION[$j]}" = "$action" ] && [ "${PL_NAME[$j]}" = "$name" ]; then
        members+=("$j")
        agent_args+=(-a "${TARGET_AGENT[${PL_TARGET[$j]}]}")
        targets_txt+=("${PL_TARGET[$j]}")
      fi
    done
    label="$name（$(IFS=','; echo "${targets_txt[*]}" | sed 's/,/, /g')）"

    if [ -z "$ready" ]; then
      if npx_available; then ready=1; else ready=0; fi
    fi
    if [ "$ready" -eq 0 ]; then
      warn "$label: npx が見つからないので公開スキルを飛ばします（Node.js を入れてください）"
      C_SKIP=$((C_SKIP + ${#members[@]}))
      continue
    fi

    local -a args=()
    if [ "$action" = "Add" ]; then
      args=(add "${PL_SOURCE[$i]}" --skill "$name" -g "${agent_args[@]}" -y --copy)
      info "追加（npx）: $label"
    else
      args=(remove "$name" -g "${agent_args[@]}" -y)
      info "削除（npx）: $label"
    fi

    if [ "$DRYRUN" -eq 1 ]; then
      info "       npx skills ${args[*]}"
    else
      local code=0
      run_npx "${args[@]}" || code=$?
      if [ "$code" -ne 0 ]; then
        warn "$label: npx skills が失敗しました（終了コード $code）"
        C_ERROR=$((C_ERROR + ${#members[@]}))
        continue
      fi
    fi

    for j in "${members[@]}"; do
      if [ "$action" = "Add" ]; then
        state_set "${PL_TARGET[$j]}" "$name" npx
      else
        state_unset "${PL_TARGET[$j]}" "$name"
      fi
      count_action "$action"
    done
  done
}

save_installed() {
  mkdir -p "$STATE_DIR"
  : > "$STATE_DIR/installed.txt"
  local key
  for key in "${NEW_ORDER[@]+"${NEW_ORDER[@]}"}"; do
    if [ -n "${NEW_STATE[$key]+x}" ]; then
      printf '%s\t%s\n' "$key" "${NEW_STATE[$key]}" >> "$STATE_DIR/installed.txt"
    fi
  done
}

# ==================================================================
# 入口
# ==================================================================
main() {
  # オプションを読む（打ち間違いで本番が動かないよう、知らないものはエラーにする）
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRYRUN=1 ;;
      --select)  SELECT=1 ;;
      --update)  UPDATE=1 ;;
      *) echo "知らないオプションです: $arg" >&2; exit 1 ;;
    esac
  done

  step "スキルを配置"
  if [ "$DRYRUN" -eq 1 ]; then info "*** DryRun モード: 実際には何も変更しません ***"; fi
  if [ ! -f "$LEDGER" ]; then
    skip "台帳がないので飛ばします（$LEDGER）"
    return 0
  fi

  # (1) 台帳を読む
  read_ledger
  if [ "$LEDGER_ERRORS" -eq 1 ]; then
    warn "台帳に読めない行があったので、今回は片付け（削除）をしません"
  fi

  # (2) 入れるスキルを決める
  load_state
  if [ "$SELECT" -eq 1 ]; then
    if [ "${#SK_NAME[@]}" -eq 0 ]; then
      skip "台帳にスキルがないので、選ぶものがありません"
    else
      show_menu
      if [ "$DRYRUN" -eq 0 ]; then save_excluded; fi
    fi
  fi

  # (3) 何をするか計算して、実行する
  make_plan
  run_plan

  # (4) 公開スキルの更新（--update のときだけ）
  if [ "$UPDATE" -eq 1 ]; then
    step "公開スキルを更新"
    if ! npx_available; then
      warn "npx が見つからないので更新を飛ばします（Node.js を入れてください）"
    elif [ "$DRYRUN" -eq 1 ]; then
      info "npx skills update -g -y"
    else
      local code=0
      run_npx update -g -y || code=$?
      if [ "$code" -ne 0 ]; then warn "npx skills update が失敗しました（終了コード $code）"; else ok "公開スキルを更新しました"; fi
    fi
  fi

  # (5) 記録を保存して、結果を表示する
  if [ "$DRYRUN" -eq 0 ]; then save_installed; fi
  ok "追加 $C_ADD / 更新 $C_UPDATE / 削除 $C_REMOVE / スキップ $C_SKIP / エラー $C_ERROR"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

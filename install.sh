#!/usr/bin/env bash
# ==================================================================
# Linux 用 dotfiles インストーラ（コピー方式）
#
# やること:
#   リポジトリ内の設定ファイルを、各アプリが見る場所へ「コピー」する。
#
# 使い方:
#   git clone https://github.com/capypara20/dotfiles.git ~/dotfiles
#   cd ~/dotfiles
#   bash install.sh               # 配置する
#   bash install.sh --skip-fonts  # フォントのインストールを飛ばす
#   bash install.sh --dry-run     # 何が起きるか表示するだけ
#
# 逆方向（今のPCの設定をリポジトリに取り込む）は sync.sh を使う。
# ==================================================================

set -eu

# このスクリプトが置かれている場所 = リポジトリの場所
DOTDIR="$(cd "$(dirname "$0")" && pwd)"

# 設定ファイルの置き場所（Windows 側と揃える）
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# オプションを読む
#   --dry-run    : 実際の変更はしない（表示だけ）
#   --skip-fonts : フォントのインストールを飛ばす
# 打ち間違い（--dryrun など）で本当に実行されないよう、知らないものはエラーにする
DRYRUN=0
SKIPFONTS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRYRUN=1 ;;
    --skip-fonts) SKIPFONTS=1 ;;
    *) echo "知らないオプションです: $arg" >&2; exit 1 ;;
  esac
done
if [ "$DRYRUN" -eq 1 ]; then
  echo "*** DryRun モード: 実際には何も変更しません ***"
fi

info() { echo "  $1"; }
step() { echo ""; echo "[$1]"; }
ok()   { echo "  OK   $1"; }
skip() { echo "  --   $1"; }

# ------------------------------------------------------------------
# 既存ファイルを日付つきの名前に退避してから、コピーで上書きする
# 引数: 表示名 コピー元 コピー先
# ------------------------------------------------------------------
deploy() {
  label="$1"; src="$2"; dst="$3"

  if [ ! -e "$src" ]; then
    skip "$label : リポジトリに $src が無いので飛ばします"
    return
  fi

  info "$label : $src"
  info "       -> $dst"

  # 既存を退避
  if [ -e "$dst" ]; then
    backup="$dst.bak-$(date +%Y%m%d-%H%M%S)"
    info "退避: $dst -> $backup"
    [ "$DRYRUN" -eq 0 ] && mv "$dst" "$backup"
  fi

  if [ "$DRYRUN" -eq 0 ]; then
    mkdir -p "$(dirname "$dst")"
    # -r はフォルダ用。ファイルでもそのまま使える。
    cp -r "$src" "$dst"
  fi
  ok "$label"
}

# ==================================================================
# フォント（Nerd Font）
#   入っていなければ Nerd Fonts 公式の GitHub リリースから取ってきて
#   ~/.local/share/fonts に入れる（このユーザー専用なので sudo 不要）。
#
#   fontconfig（fc-list）が無い = 画面を持たない Linux なので飛ばす。
#   ※ WSL の画面は Windows Terminal が描くので、WSL で効くのは
#     Windows 側のフォント（install.ps1 が入れる）の方。
# ==================================================================
FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"
FONT_ADDED=0

# URL のファイルを保存する（curl が無ければ wget を使う）
download() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    echo "  !!   curl も wget も無いのでダウンロードできません" >&2
    return 1
  fi
}

# フォントを1種類入れる
# 引数: フォント名 アーカイブ名(拡張子なし) 取り出すファイル(* 可)
install_font() {
  family="$1"; archive="$2"; pattern="$3"
  url="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$archive.tar.xz"

  # fc-list は "RobotoMono Nerd Font,RobotoMono NF" のように別名を
  # カンマ区切りで出すので、1行1名前にばらしてから完全一致で探す
  if fc-list : family | tr ',' '\n' | grep -qxF "$family"; then
    skip "$family : インストール済み"
    return 0
  fi

  info "$family : 見つからないのでインストールします"
  info "       <- $url"
  if [ "$DRYRUN" -eq 1 ]; then
    ok "$family"
    return 0
  fi

  tmp="$(mktemp -d)"
  if download "$url" "$tmp/$archive.tar.xz" && tar -xJf "$tmp/$archive.tar.xz" -C "$tmp"; then
    mkdir -p "$FONT_DIR"
    count=0
    while IFS= read -r f; do
      cp "$f" "$FONT_DIR/"
      count=$((count + 1))
    done < <(find "$tmp" -type f -name "$pattern")

    if [ "$count" -gt 0 ]; then
      FONT_ADDED=1
      ok "$family（$count ファイル）"
    else
      echo "  !!   アーカイブの中に $pattern が見つかりません" >&2
    fi
  else
    # フォントが入らなくても、設定ファイルの配置は続ける
    echo "  !!   $family のインストールに失敗しました" >&2
    echo "       手動で入れる場合はここから: $url" >&2
  fi
  rm -rf "$tmp"
}

step "フォント（Nerd Font）"
if [ "$SKIPFONTS" -eq 1 ]; then
  skip "--skip-fonts が指定されたので飛ばします"
elif ! command -v fc-list >/dev/null 2>&1; then
  skip "fontconfig（fc-list）が無いので飛ばします（画面を持たない Linux では不要）"
else
  # 入れたいフォントの一覧。増やすときはここに1行足す。
  #   使うのは通常版の RobotoMonoNerdFont-*（Mono版 / Propo版は入れない）
  install_font "RobotoMono Nerd Font" "RobotoMono" "RobotoMonoNerdFont-*.ttf"

  if [ "$FONT_ADDED" -eq 1 ]; then
    fc-cache -f "$FONT_DIR" >/dev/null
    ok "フォントの一覧（キャッシュ）を更新しました"
  fi
fi

# ==================================================================
# nvim
# ==================================================================
step "nvim の設定を配置"
deploy "nvim" "$DOTDIR/nvim" "$CONFIG_HOME/nvim"

# WSL では IME を切るのに Windows の zenhan.exe を呼ぶ。
# Linux 側へコピーされた exe は実行権限が落ちていることがあるので付け直す。
if [ "$DRYRUN" -eq 0 ] && [ -d "$CONFIG_HOME/nvim/bin" ]; then
  chmod +x "$CONFIG_HOME"/nvim/bin/*.exe 2>/dev/null || true
  ok "zenhan.exe に実行権限を付与"
fi

# ==================================================================
# bash
# ==================================================================
step "bash の設定を配置"
deploy ".bashrc" "$DOTDIR/bash/.bashrc" "$HOME/.bashrc"

# ==================================================================
# PowerShell（Linux に pwsh を入れている場合だけ）
# ==================================================================
step "PowerShell プロファイルを配置"
if command -v pwsh >/dev/null 2>&1; then
  # Windows 側と同じく CurrentUserAllHosts（= profile.ps1）に置く
  deploy "PowerShell profile" \
    "$DOTDIR/powershell/profile.ps1" \
    "$CONFIG_HOME/powershell/profile.ps1"
else
  skip "pwsh が入っていないので飛ばします"
fi

# ==================================================================
# VSCode（インストール済みの場合だけ）
# ==================================================================
step "VSCode の設定を配置"
if [ -d "$CONFIG_HOME/Code/User" ]; then
  deploy "VSCode settings.json" "$DOTDIR/vscode/settings.json" "$CONFIG_HOME/Code/User/settings.json"
else
  skip "VSCode が見つからないので飛ばします"
fi

# ==================================================================
# psmux
# ==================================================================
step "psmux の設定を配置"
deploy "psmux.conf" "$DOTDIR/psmux/psmux.conf" "$CONFIG_HOME/psmux/psmux.conf"

# ==================================================================
# Claude Code の指示書
# ==================================================================
step "Claude Code の指示書を配置"
deploy "CLAUDE.md" "$DOTDIR/claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"

# Windows Terminal は Windows 専用のため、ここでは扱わない。

# ==================================================================
# 完了メッセージ
# ==================================================================
echo ""
echo "=== 完了 ==="
echo "・上書き前のファイルは *.bak-日付 という名前で同じ場所に残しています"
echo "・新しいターミナルを開くと設定が反映されます"
echo "・設定を変更したあとは  bash sync.sh  でリポジトリに取り込んでください"

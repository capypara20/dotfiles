# ==================================================================
# Windows 用 dotfiles インストーラ（コピー方式）
#
# やること:
#   (1) XDG_CONFIG_HOME を設定（未設定なら ~\.config）
#   (2) scoop 本体を入れる（未導入なら）→ git → バケット追加 → アプリ一括install
#   (3) Nerd Font が入っていなければダウンロードして入れる
#   (4) リポジトリ内の設定ファイルを、各アプリが見る場所へ「コピー」する
#
# 使い方:
#   git clone https://github.com/capypara20/dotfiles.git "$HOME\dotfiles"
#   cd "$HOME\dotfiles"
#   .\install.ps1              # 全部やる
#   .\install.ps1 -SkipScoop   # scoop 関連を飛ばす
#   .\install.ps1 -SkipFonts   # フォントのインストールを飛ばす
#   .\install.ps1 -DryRun      # 何が起きるか表示するだけ（実際には変更しない）
#
# 逆方向（今のPCの設定をリポジトリに取り込む）は sync.ps1 を使う。
# ==================================================================

param(
  [switch]$SkipScoop,   # scoop 関連をまるごと飛ばす
  [switch]$SkipFonts,   # フォントのインストールを飛ばす
  [switch]$DryRun       # 予行演習（表示するだけ）
)

$ErrorActionPreference = "Stop"

# このスクリプトが置かれている場所 = リポジトリの場所
$DotDir = $PSScriptRoot

# 見やすいログ用の小さな関数
function Info($msg) { Write-Host "  $msg" }
function Step($msg) { Write-Host "`n[$msg]" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  OK   $msg" -ForegroundColor Green }
function Skip($msg) { Write-Host "  --   $msg" -ForegroundColor DarkGray }

if ($DryRun) {
  Write-Host "*** DryRun モード: 実際には何も変更しません ***" -ForegroundColor Yellow
}

# ==================================================================
# (1) XDG_CONFIG_HOME
#     Linux と同じ「~/.config」に設定ファイルを集めるための環境変数。
#     nvim はこれを見て設定を探すので、Win/Linux で同じ場所に置ける。
# ==================================================================
Step "XDG_CONFIG_HOME の確認"

if ($env:XDG_CONFIG_HOME) {
  Skip "設定済み: $env:XDG_CONFIG_HOME"
} else {
  $xdg = Join-Path $HOME ".config"
  Info "未設定なので $xdg を設定します（ユーザー環境変数）"
  if (-not $DryRun) {
    [Environment]::SetEnvironmentVariable("XDG_CONFIG_HOME", $xdg, "User")
    $env:XDG_CONFIG_HOME = $xdg   # 今のセッションにも反映
  }
  Ok "XDG_CONFIG_HOME = $xdg"
  Info "※ 新しく開くターミナルから有効になります"
}

$ConfigHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }

# ==================================================================
# (2) scoop（パッケージマネージャ）
# ==================================================================
if ($SkipScoop) {
  Step "scoop"
  Skip "-SkipScoop が指定されたので飛ばします"
} else {
  Step "scoop 本体"
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Skip "インストール済み"
  } else {
    Info "見つからないのでインストールします..."
    if (-not $DryRun) {
      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
      Invoke-RestMethod get.scoop.sh | Invoke-Expression
    }
    Ok "scoop を導入しました"
  }

  # バケットの追加（scoop bucket add）は裏で git clone しているので、git が必須。
  # git が無いまま進むとバケット追加で詰まるため、先に git だけ入れておく。
  #   git は scoop に最初から付いてくる main バケットにあるので、git 無しでも入れられる。
  #   （展開に使う 7zip も scoop が自動で一緒に入れる）
  #
  #     scoop 本体 ──▶ git ──▶ バケット追加 ──▶ アプリ一括インストール
  #                    ↑ ここを先にやる
  Step "git（バケット追加に必要）"
  if (Get-Command git -ErrorAction SilentlyContinue) {
    Skip "インストール済み"
  } else {
    Info "見つからないので scoop で先に入れます"
    if (-not $DryRun) { scoop install git }
    Ok "git"
  }

  Step "scoop バケット + アプリ"
  $AppsJson = Join-Path $DotDir "scoop\scoop-apps.json"
  if (-not (Test-Path $AppsJson)) {
    Skip "scoop-apps.json が無いので飛ばします"
  } else {
    # バケット（アプリの取り寄せ先リポジトリ）を先に追加しておく
    $data = Get-Content $AppsJson -Raw | ConvertFrom-Json
    $installed = @(scoop bucket list | ForEach-Object { $_.Name })
    foreach ($b in $data.buckets) {
      if ($installed -contains $b.Name) {
        Skip "bucket $($b.Name)"
      } else {
        Info "bucket 追加: $($b.Name)"
        if (-not $DryRun) { scoop bucket add $b.Name $b.Source }
      }
    }
    # アプリ一括インストール（入っているものは scoop 側でスキップされる）
    Info "アプリを一括インストールします（時間がかかります）"
    if (-not $DryRun) { scoop import $AppsJson }
    Ok "scoop アプリの処理が終わりました"
  }
}

# ==================================================================
# (3) フォント（Nerd Font）
#     Windows Terminal の設定は "RobotoMono Nerd Font" を使うので、
#     入っていなければ Nerd Fonts 公式の GitHub リリースから取ってきて入れる。
#
#     入れる先は「このユーザー専用」のフォント置き場なので、管理者権限は不要。
#       ファイル : %LOCALAPPDATA%\Microsoft\Windows\Fonts\
#       登録     : HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts
#     （エクスプローラーで .ttf を右クリック →「インストール」と同じ結果になる）
# ==================================================================

# 入れたいフォントの一覧。増やすときはここに1行足す。
#   Family  : フォントの名前（Windows Terminal の "face" に書く名前）
#   Archive : https://github.com/ryanoasis/nerd-fonts/releases のファイル名（拡張子なし）
#   Files   : 取り出すファイル（* はワイルドカード）
#             アーカイブには3種類入っているが、使うのは通常版だけ。
#               RobotoMonoNerdFont-*      … 通常版（= "RobotoMono Nerd Font"）← これ
#               RobotoMonoNerdFontMono-*  … アイコンも1文字幅に縮めた版
#               RobotoMonoNerdFontPropo-* … 文字幅がバラバラな版
$Fonts = @(
  @{ Family = "RobotoMono Nerd Font"; Archive = "RobotoMono"; Files = "RobotoMonoNerdFont-*.ttf" }
)

$UserFontDir = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$UserFontReg = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"

# そのフォントがもう入っているか、Windows に名前で問い合わせる。
# （管理者が全ユーザー向けに入れたフォントも、ここで見つかる）
function Test-FontInstalled($family) {
  Add-Type -AssemblyName System.Drawing
  $names = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
  return ($names -contains $family)
}

# .ttf 1枚を「このユーザー専用」にインストールする
function Install-UserFont($family, $file) {
  # (a) ユーザー用フォントフォルダへコピー
  $dst = Join-Path $UserFontDir $file.Name
  if (-not (Test-Path $UserFontDir)) { New-Item -ItemType Directory -Force -Path $UserFontDir | Out-Null }
  if (-not (Test-Path $dst)) { Copy-Item -Path $file.FullName -Destination $dst }

  # (b) レジストリに登録（次回ログオン以降も読み込まれるように）
  #     例: RobotoMonoNerdFont-BoldItalic.ttf → "RobotoMono Nerd Font BoldItalic (TrueType)"
  $style = ($file.BaseName -split '-', 2)[1]
  if (-not (Test-Path $UserFontReg)) { New-Item -Path $UserFontReg -Force | Out-Null }
  New-ItemProperty -Path $UserFontReg -Name "$family $style (TrueType)" -Value $dst -PropertyType String -Force | Out-Null

  # (c) 今のログオン中にもすぐ使えるよう、Windows に読み込ませる
  [void][DotfilesFont.Native]::AddFontResourceW($dst)
}

if ($SkipFonts) {
  Step "フォント"
  Skip "-SkipFonts が指定されたので飛ばします"
} else {
  Step "フォント（Nerd Font）"

  # tar.exe（Windows 10 1803 以降に標準搭載）が xz を扱えるなら
  # 小さい .tar.xz（約4MB）を、無理なら .zip（約50MB）を使う。
  $TarExe = Get-Command tar.exe -ErrorAction SilentlyContinue
  $UseXz  = $TarExe -and ((& $TarExe.Source --version) -match 'liblzma')
  $Ext    = if ($UseXz) { ".tar.xz" } else { ".zip" }

  # Windows API を PowerShell から呼ぶための準備（2回目以降は定義済みなので飛ばす）
  #   AddFontResourceW   : フォントを今のログオン中に読み込む
  #   SendMessageTimeoutW: 「フォントが増えたよ」と起動中のアプリへ知らせる
  if (-not ('DotfilesFont.Native' -as [type])) {
    Add-Type -Namespace DotfilesFont -Name Native -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern int AddFontResourceW(string lpFileName);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
  }

  # ダウンロードを速くする（進捗バーの描画が遅いため）＋ 古い PC 向けに TLS1.2 を有効化
  $ProgressPreference = "SilentlyContinue"
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $FontAdded = $false
  foreach ($font in $Fonts) {
    if (Test-FontInstalled $font.Family) {
      Skip "$($font.Family) : インストール済み"
      continue
    }

    $url = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$($font.Archive)$Ext"
    Info "$($font.Family) : 見つからないのでインストールします"
    Info "       <- $url"
    if ($DryRun) { Ok $font.Family; continue }

    # 作業用の一時フォルダ（終わったら必ず消す）
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dotfiles-font-" + [guid]::NewGuid())
    try {
      New-Item -ItemType Directory -Path $tmp | Out-Null
      $archive = Join-Path $tmp "$($font.Archive)$Ext"
      $outDir  = Join-Path $tmp "out"
      New-Item -ItemType Directory -Path $outDir | Out-Null

      Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
      if ($UseXz) {
        & $TarExe.Source -xf $archive -C $outDir
        if ($LASTEXITCODE -ne 0) { throw "tar での展開に失敗しました" }
      } else {
        Expand-Archive -Path $archive -DestinationPath $outDir
      }

      $files = @(Get-ChildItem -Path $outDir -Recurse -File | Where-Object { $_.Name -like $font.Files })
      if ($files.Count -eq 0) { throw "アーカイブの中に $($font.Files) が見つかりません" }

      foreach ($f in $files) { Install-UserFont $font.Family $f }
      $FontAdded = $true
      Ok "$($font.Family)（$($files.Count) ファイル）"
    } catch {
      # フォントが入らなくても、設定ファイルのコピーは続ける
      Write-Warning "$($font.Family) のインストールに失敗しました: $_"
      Write-Warning "  手動で入れる場合はここから: $url"
    } finally {
      Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  if ($FontAdded) {
    # 起動中のアプリへ WM_FONTCHANGE を一斉送信（固まったアプリは1秒で諦める）
    $result = [UIntPtr]::Zero
    [void][DotfilesFont.Native]::SendMessageTimeoutW([IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero, 0x0002, 1000, [ref]$result)
    Info "※ Windows Terminal などは再起動すると新しいフォントが使えます"
  }
}

# ==================================================================
# (4) 設定ファイルのコピー
# ==================================================================

# --- 配置先のパスを決める --------------------------------------------
# nvim: XDG_CONFIG_HOME\nvim
$NvimDst = Join-Path $ConfigHome "nvim"

# PowerShell プロファイル:
#   Windows PowerShell 5.1 と PowerShell 7 では $PROFILE の場所が違うので、
#   両方の CurrentUserAllHosts（= profile.ps1）に同じものをコピーする。
#
#     dotfiles\powershell\profile.ps1     ← 編集するのはここだけ
#            ├─────────────────────┐
#     Documents\WindowsPowerShell\   Documents\PowerShell\
#          profile.ps1                    profile.ps1
#       = Windows PowerShell 5.1       = PowerShell 7 (pwsh)
#
#   Documents は OneDrive に移動されている場合があるので、決め打ちせず
#   Windows に「本当の Documents はどこ？」と聞く。
$Docs = [Environment]::GetFolderPath("MyDocuments")

# Windows PowerShell 5.1 は Windows に最初から入っているので必ず配置する。
$ProfileTargets = @( (Join-Path $Docs "WindowsPowerShell\profile.ps1") )

# PowerShell 7 (pwsh) は入っていないPCもあるので、あるときだけ配置する。
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
  $ProfileTargets += (Join-Path $Docs "PowerShell\profile.ps1")
}

# VSCode
$VscodeDst = Join-Path $env:APPDATA "Code\User\settings.json"

# Windows Terminal:
#   Store版・Preview版・非Store版で場所が違うので、候補を順に調べて
#   「実際にフォルダがある版」に配置する。
$WtCandidates = @(
  (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json")
  (Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json")
  (Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json")
)

# psmux（ターミナル分割ツール）
$PsmuxDst = Join-Path $ConfigHome "psmux\psmux.conf"

# Claude Code の指示書
$ClaudeDst = Join-Path $HOME ".claude\CLAUDE.md"

# --- コピー用の共通処理 ----------------------------------------------
# 既存ファイルは消さずに、日付つきの名前へ退避してから上書きする。
function Backup-IfExists($path) {
  if (Test-Path $path) {
    $stamp  = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$path.bak-$stamp"
    Info "退避: $path -> $backup"
    if (-not $DryRun) { Move-Item -Path $path -Destination $backup -Force }
  }
}

function Deploy($label, $src, $dst, $isDir) {
  if (-not (Test-Path $src)) {
    Skip "$label : リポジトリに $src が無いので飛ばします"
    return
  }
  Info "$label : $src"
  Info "       -> $dst"
  Backup-IfExists $dst
  if (-not $DryRun) {
    $parent = Split-Path -Parent $dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if ($isDir) {
      Copy-Item -Path $src -Destination $dst -Recurse -Force
    } else {
      Copy-Item -Path $src -Destination $dst -Force
    }
  }
  Ok $label
}

Step "nvim の設定を配置"
Deploy "nvim" (Join-Path $DotDir "nvim") $NvimDst $true

Step "PowerShell プロファイルを配置"

# (a) 5.1 用 / 7 用の profile.ps1 へ同じものをコピーする。
#     リポジトリ側は UTF-8 BOM付き（.gitattributes で固定）なので、
#     そのままコピーすれば 5.1 でも日本語コメントが化けない。
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
  Skip "pwsh が無いので PowerShell 7 用は飛ばします"
}
foreach ($t in $ProfileTargets) {
  Deploy "PowerShell profile" (Join-Path $DotDir "powershell\profile.ps1") $t $false
}

# (b) 旧構成（本体1枚＋スタブ2枚）の後片付け。
#     残したままだと profile.ps1 と一緒に二重に読み込まれてしまう。
$OldStubs = @(
  (Join-Path $Docs "PowerShell\Microsoft.PowerShell_profile.ps1")
  (Join-Path $Docs "WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
)
foreach ($old in $OldStubs) {
  if (-not (Test-Path $old)) { continue }
  $raw = Get-Content -Path $old -Raw -ErrorAction SilentlyContinue
  if ($raw -match '\$SharedProfile') {
    # install.ps1 が昔つくったスタブ。退避してよい
    Info "旧スタブを退避します: $old"
    Backup-IfExists $old
  } else {
    # 手書きの設定が入っているかもしれないので触らない
    Write-Warning "自動生成でないファイルが残っています。中身を確認して手で消してください: $old"
  }
}

# 旧本体（~\.config\powershell\profile.ps1）も退避する。
# ※ 同じフォルダの profile.local.ps1（このPC専用の設定）には絶対に触らない。
$OldMain = Join-Path $ConfigHome "powershell\profile.ps1"
if (Test-Path $OldMain) {
  Info "旧本体を退避します: $OldMain"
  Backup-IfExists $OldMain
}

Step "VSCode の設定を配置"
if (Test-Path (Split-Path -Parent $VscodeDst)) {
  Deploy "VSCode settings.json" (Join-Path $DotDir "vscode\settings.json") $VscodeDst $false
} else {
  Skip "VSCode が見つからないので飛ばします（$VscodeDst）"
}

Step "Windows Terminal の設定を配置"
# 判定は「settings.json が実際にあるか」で行う。
# フォルダの有無で判定すると、WSL のプロファイル断片が置かれる
# 「Local\Microsoft\Windows Terminal」を誤って版と見なしてしまうため。
$wtTargets = @($WtCandidates | Where-Object { Test-Path $_ })

if ($wtTargets.Count -eq 0) {
  # 一度も起動していないPCには settings.json が無い。
  # その場合は Store 版のフォルダがあれば、そこに新規作成する。
  $wtStoreDir = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState"
  if (Test-Path $wtStoreDir) {
    $wtTargets = @((Join-Path $wtStoreDir "settings.json"))
  }
}

foreach ($wt in $wtTargets) {
  Deploy "Windows Terminal settings.json" (Join-Path $DotDir "wterminal\settings.json") $wt $false
}

if ($wtTargets.Count -eq 0) {
  Skip "Windows Terminal が見つからないので飛ばします"
} else {
  Info "※ Windows Terminal を開いたままだと、閉じるときに古い設定へ戻ることがあります"
  Info "   反映されないときは Windows Terminal を再起動してください"
}

Step "psmux の設定を配置"
Deploy "psmux.conf" (Join-Path $DotDir "psmux\psmux.conf") $PsmuxDst $false

Step "Claude Code の指示書を配置"
Deploy "CLAUDE.md" (Join-Path $DotDir "claude\CLAUDE.md") $ClaudeDst $false

# ==================================================================
# 完了メッセージ
# ==================================================================
Write-Host "`n=== 完了 ===" -ForegroundColor Cyan
Write-Host "・上書き前のファイルは *.bak-日付 という名前で同じ場所に残しています"
Write-Host "・新しいターミナルを開くと設定が反映されます"
Write-Host "・設定を変更したあとは  .\sync.ps1  でリポジトリに取り込んでください"

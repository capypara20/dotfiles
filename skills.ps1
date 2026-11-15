# ==================================================================
# Windows 用 スキル配置スクリプト（コピー方式）
#
# やること:
#   (1) 台帳（skills\skills.tsv）を読む
#   (2) 自作スキル（skills\<名前>\）を、各ツールが読む場所へ「コピー」する
#   (3) 公開スキルを npx skills で入れる
#   (4) 台帳から消したスキル・選択で外したスキルを片付ける
#       （消すのは、このスクリプトが入れたものだけ）
#
# 置き先:
#   claude : ~\.claude\skills   … Claude Code が読む
#   agents : ~\.agents\skills   … VS Code の Copilot・Copilot アプリ・Codex が読む
#
# 使い方:
#   .\skills.ps1            # 台帳どおりに配置する
#   .\skills.ps1 -Select    # 入れるスキルを番号で選ぶ
#   .\skills.ps1 -Update    # 最後に公開スキルの更新（npx skills update）もする
#   .\skills.ps1 -DryRun    # 何が起きるか表示するだけ（実際には変更しない）
#
# install.ps1 の最後からも呼ばれる（-SkipSkills で飛ばせる）。
# ==================================================================

param(
  [switch]$DryRun,   # 予行演習（表示するだけ）
  [switch]$Select,   # 入れるスキルを選ぶメニューを出す
  [switch]$Update    # 最後に npx skills update も実行する
)

# ==================================================================
# 置き先の対応表
#   台帳の targets 列に書く名前 → ホームからの場所 と npx skills の agent 名
#   将来 Claude Code が ~/.agents/skills を読むようになったら、claude を外すだけでよい
# ==================================================================
$TargetMap = [ordered]@{
  claude = @{ Dir = '.claude/skills'; Agent = 'claude-code' }
  agents = @{ Dir = '.agents/skills'; Agent = 'github-copilot' }
}

# 台帳の列
$RequiredColumns = @('type', 'name', 'targets')
$SkillTypes      = @('own', 'npx')

# スキル名に使える文字（../ などで置き先の外に出られないようにする）
$NamePattern   = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
# npx の source（owner/repo）
$SourcePattern = '^[^/\s]+/[^/\s]+$'

# ------------------------------------------------------------------
# ホームとリポジトリの場所（テストのときは環境変数で差し替えられる）
# ------------------------------------------------------------------
function Get-SkillsHome {
  if ($env:DOTFILES_SKILLS_HOME) { return $env:DOTFILES_SKILLS_HOME }
  return $HOME
}

function Get-SkillsRepo {
  if ($env:DOTFILES_SKILLS_REPO) { return $env:DOTFILES_SKILLS_REPO }
  return $PSScriptRoot
}

# 置き先の名前 → 実際のフォルダ
function Get-TargetDirs {
  param([Parameter(Mandatory)][string]$HomeDir)
  $dirs = [ordered]@{}
  foreach ($key in $TargetMap.Keys) {
    $dirs[$key] = Join-Path $HomeDir $TargetMap[$key].Dir
  }
  return $dirs
}

# ==================================================================
# 台帳を読む
#
#   1 行目は見出し（列名）。列は名前で探すので、順番が変わっても、
#   知らない列が増えても読める。
#   おかしな行は「何行目がなぜダメか」を警告して飛ばし、HasErrors を立てる。
#   （HasErrors のときは、片付け＝削除をしない。全部消える事故を防ぐため）
# ==================================================================
function Read-SkillLedger {
  param([Parameter(Mandatory)][string]$Path)

  # BOM なし UTF-8 として読む（BOM があっても .NET が取り除く）。
  # 改行は LF / CRLF のどちらでも 1 行ずつに分かれる。
  $lines = [IO.File]::ReadAllLines($Path, (New-Object Text.UTF8Encoding($false)))
  if ($lines.Count -eq 0) { throw "台帳が空です: $Path" }

  # 見出し行 → 「列名 → 位置」の表
  $headerLine = $lines[0].TrimStart([char]0xFEFF).TrimEnd("`r")
  $columns = @{}
  $names = $headerLine -split "`t"
  for ($i = 0; $i -lt $names.Count; $i++) {
    $col = $names[$i].Trim()
    if ($col -and -not $columns.ContainsKey($col)) { $columns[$col] = $i }
  }
  foreach ($col in $RequiredColumns) {
    if (-not $columns.ContainsKey($col)) { throw "台帳の見出しに必須の列がありません: $col" }
  }

  $skills    = New-Object System.Collections.Generic.List[object]
  $seen      = @{}
  $hasErrors = $false

  for ($i = 1; $i -lt $lines.Count; $i++) {
    $lineNo = $i + 1
    $line   = $lines[$i].TrimEnd("`r")
    if ($line.Trim() -eq '' -or $line.TrimStart().StartsWith('#')) { continue }

    $fields = $line -split "`t"
    $get = {
      param($name)
      if (-not $columns.ContainsKey($name)) { return '' }
      $idx = $columns[$name]
      if ($idx -ge $fields.Count) { return '' }
      return $fields[$idx].Trim()
    }

    $type    = & $get 'type'
    $name    = & $get 'name'
    $source  = & $get 'source'
    $targets = @((& $get 'targets') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    $reason = $null
    if ($SkillTypes -notcontains $type) {
      $reason = "type は own か npx にしてください（今は '$type'）"
    } elseif ($name -notmatch $NamePattern) {
      $reason = "name に使えない文字があります（'$name'）"
    } elseif ($targets.Count -eq 0) {
      $reason = "targets が空です"
    } elseif ($type -eq 'npx' -and $source -notmatch $SourcePattern) {
      $reason = "npx の行には source（owner/repo）が必要です"
    } elseif ($seen.ContainsKey($name)) {
      $reason = "同じ名前のスキルが $($seen[$name]) 行目にもあります（'$name'）"
    } else {
      $unknown = @($targets | Where-Object { -not $TargetMap.Contains($_) })
      if ($unknown.Count -gt 0) {
        $reason = "知らない出す先です（'$($unknown -join ',')'）。使えるのは $($TargetMap.Keys -join ', ')"
      }
    }

    if ($reason) {
      Write-Warning "台帳 $lineNo 行目: $reason。この行は飛ばします"
      $hasErrors = $true
      continue
    }

    $seen[$name] = $lineNo
    $skills.Add([pscustomobject]@{
      Type    = $type
      Name    = $name
      Source  = $source
      Targets = [string[]]$targets
      Url     = & $get 'url'
      Note    = & $get 'note'
      Line    = [int]$lineNo
    })
  }

  return [pscustomobject]@{
    Skills    = @($skills.ToArray())
    HasErrors = $hasErrors
  }
}

# ==================================================================
# 入口（Task 5 で作る）
#   . で読み込まれたとき（テストなど）は何もしない
# ==================================================================
# if ($MyInvocation.InvocationName -ne '.') { Invoke-SkillsMain -DryRun:$DryRun -Select:$Select -Update:$Update }

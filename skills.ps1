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
# マシンごとの記録（~/.dotfiles-skills/）
#   excluded.txt  : 選択で外したスキル名（1 行に 1 つ）
#   installed.txt : このスクリプトが入れたもの（置き先<TAB>名前<TAB>種類）
#
#   リポジトリには入れない。bash 版と同じファイルを読み書きするので、
#   BOM なし UTF-8・改行 LF で書く。
# ==================================================================
function Read-StateLines {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @([IO.File]::ReadAllLines($Path, (New-Object Text.UTF8Encoding($false))) |
    ForEach-Object { $_.TrimEnd("`r") } |
    Where-Object { $_.Trim() -ne '' })
}

function Write-StateLines {
  param(
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$FileName,
    [string[]]$Lines = @()
  )
  if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
  $text = ''
  if ($Lines.Count -gt 0) { $text = ($Lines -join "`n") + "`n" }
  [IO.File]::WriteAllText((Join-Path $Dir $FileName), $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-ExcludedSkills {
  param([Parameter(Mandatory)][string]$StateDir)
  return Read-StateLines -Path (Join-Path $StateDir 'excluded.txt')
}

function Save-ExcludedSkills {
  param([Parameter(Mandatory)][string]$StateDir, [string[]]$Names = @())
  Write-StateLines -Dir $StateDir -FileName 'excluded.txt' -Lines $Names
}

function Get-InstalledState {
  param([Parameter(Mandatory)][string]$StateDir)
  foreach ($line in (Read-StateLines -Path (Join-Path $StateDir 'installed.txt'))) {
    $f = $line -split "`t"
    if ($f.Count -lt 3) { continue }
    [pscustomobject]@{ Target = $f[0]; Name = $f[1]; Type = $f[2] }
  }
}

function Save-InstalledState {
  param([Parameter(Mandatory)][string]$StateDir, [object[]]$Entries = @())
  $lines = @($Entries | Where-Object { $_ } | ForEach-Object { "{0}`t{1}`t{2}" -f $_.Target, $_.Name, $_.Type })
  Write-StateLines -Dir $StateDir -FileName 'installed.txt' -Lines $lines
}

# ==================================================================
# 選択メニュー
#   番号（1 始まり。空白かカンマ区切りで複数可）のスキルの「外す／戻す」を切り替える。
#   返すのは「外したスキル」の一覧。台帳に後から増えたスキルは外れていない側になる。
# ==================================================================
function Switch-SkillExclusion {
  param(
    [Parameter(Mandatory)][object[]]$Skills,
    [string[]]$Excluded = @(),
    [string]$Answer = ''
  )
  $set = New-Object System.Collections.Generic.List[string]
  foreach ($n in @($Excluded)) { if ($n -and -not $set.Contains($n)) { $set.Add($n) } }

  foreach ($token in @($Answer -split '[\s,]+' | Where-Object { $_ })) {
    $num = 0
    if (-not [int]::TryParse($token, [ref]$num) -or $num -lt 1 -or $num -gt $Skills.Count) {
      Write-Warning "番号 '$token' は使えません（1〜$($Skills.Count) で入力してください）"
      continue
    }
    $name = $Skills[$num - 1].Name
    if ($set.Contains($name)) { [void]$set.Remove($name) } else { $set.Add($name) }
  }
  return $set.ToArray()
}

# 画面に一覧を出し、空の Enter が押されるまで切り替えをくり返す（テストしない薄い部分）
function Show-SkillMenu {
  param([Parameter(Mandatory)][object[]]$Skills, [string[]]$Excluded = @())
  $current = @($Excluded)
  while ($true) {
    Write-Host ""
    Write-Host "入れるスキルを選んでください（番号で切り替え、Enter で決定）"
    for ($i = 0; $i -lt $Skills.Count; $i++) {
      $mark = 'x'
      if ($current -contains $Skills[$i].Name) { $mark = ' ' }
      Write-Host (" [{0}] {1}. {2,-16} {3}" -f $mark, ($i + 1), $Skills[$i].Name, $Skills[$i].Note)
    }
    $answer = Read-Host "番号"
    if ([string]::IsNullOrWhiteSpace($answer)) { break }
    $current = @(Switch-SkillExclusion -Skills $Skills -Excluded $current -Answer $answer)
  }
  return $current
}

# ==================================================================
# 何をするかの計算（ファイルには触らない）
#
#   入れたい組（外していないスキル × その出す先）ごとに:
#     記録にある                    → Update（入れ直す）
#     記録になく、同名フォルダがある → Conflict（管理外なので触らない）
#     どちらでもない                → Add
#   記録にあるのに入れたい組にない  → Remove
#     ただし SkipRemovals（台帳に不正な行があった回）は Remove を出さない
#
#   消す候補は「記録（installed.txt）にあるもの」だけ。
#   synced/ や手で入れたスキルは記録にないので、ここには絶対に出てこない。
# ==================================================================
function Get-SkillPlan {
  param(
    [object[]]$Skills = @(),
    [string[]]$Excluded = @(),
    [object[]]$Installed = @(),
    [Parameter(Mandatory)]$TargetDirs,
    [bool]$SkipRemovals = $false
  )

  $installedKeys = @{}
  foreach ($e in @($Installed | Where-Object { $_ })) { $installedKeys["$($e.Target)`t$($e.Name)"] = $e }

  $wanted = @{}
  foreach ($s in @($Skills | Where-Object { $_ })) {
    if (@($Excluded) -contains $s.Name) { continue }
    foreach ($t in @($s.Targets)) {
      $key = "$t`t$($s.Name)"
      $wanted[$key] = $true
      $action = 'Add'
      if ($installedKeys.ContainsKey($key)) {
        $action = 'Update'
      } elseif (Test-Path -LiteralPath (Join-Path $TargetDirs[$t] $s.Name)) {
        $action = 'Conflict'
      }
      [pscustomobject]@{ Action = $action; Type = $s.Type; Name = $s.Name; Target = $t; Source = $s.Source }
    }
  }

  if ($SkipRemovals) { return }
  foreach ($e in @($Installed | Where-Object { $_ })) {
    if ($wanted.ContainsKey("$($e.Target)`t$($e.Name)")) { continue }
    [pscustomobject]@{ Action = 'Remove'; Type = $e.Type; Name = $e.Name; Target = $e.Target; Source = '' }
  }
}

# ==================================================================
# 見やすいログ用の小さな関数（install.ps1 と同じ見た目）
# ==================================================================
function Info($msg) { Write-Host "  $msg" }
function Step($msg) { Write-Host "`n[$msg]" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  OK   $msg" -ForegroundColor Green }
function Skip($msg) { Write-Host "  --   $msg" -ForegroundColor DarkGray }

# ==================================================================
# npx skills の呼び出し
#   - テレメトリ（利用状況の送信）を止めるため DISABLE_TELEMETRY=1 をつける
#   - テストのときは DOTFILES_SKILLS_NPX で偽物の npx に差し替えられる
# ==================================================================
function Get-NpxCommand {
  if ($env:DOTFILES_SKILLS_NPX) { return $env:DOTFILES_SKILLS_NPX }
  return 'npx'
}

function Test-NpxAvailable {
  return [bool](Get-Command (Get-NpxCommand) -ErrorAction SilentlyContinue)
}

function Invoke-NpxSkills {
  param([Parameter(Mandatory)][string[]]$Arguments)
  $old = $env:DISABLE_TELEMETRY
  $env:DISABLE_TELEMETRY = '1'
  try {
    & (Get-NpxCommand) -y skills @Arguments
    if ($null -eq $LASTEXITCODE) { return 0 }
    return [int]$LASTEXITCODE
  } finally {
    if ($null -eq $old) { Remove-Item Env:DISABLE_TELEMETRY -ErrorAction SilentlyContinue } else { $env:DISABLE_TELEMETRY = $old }
  }
}

# 管理しているスキルのフォルダを消す。
# リンク（ジャンクション）だった場合は、リンクだけを消してリンク先には触らない。
function Remove-SkillFolder {
  param([Parameter(Mandatory)][string]$Path)
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $item) { return }
  if ($item.LinkType) {
    [IO.Directory]::Delete($item.FullName, $false)
  } else {
    Remove-Item -LiteralPath $item.FullName -Recurse -Force
  }
}

# ==================================================================
# 計画を実行する
#   自作スキル（own）: リポジトリの skills\<名前>\ を置き先へコピー（退避は作らない）
#   公開スキル（npx）: npx skills add / remove を呼ぶ（--copy でコピーして置いてもらう）
#   返すのは、実行後の記録（Installed）と件数（Counts）
# ==================================================================
function Invoke-SkillPlan {
  param(
    [object[]]$Plan = @(),
    [Parameter(Mandatory)][string]$RepoDir,
    [Parameter(Mandatory)]$TargetDirs,
    [object[]]$Installed = @(),
    [switch]$DryRun
  )

  $counts = [ordered]@{ Add = 0; Update = 0; Remove = 0; Skip = 0; Error = 0 }
  $state  = [ordered]@{}
  foreach ($e in @($Installed | Where-Object { $_ })) { $state["$($e.Target)`t$($e.Name)"] = $e }
  $actions = @($Plan | Where-Object { $_ })

  # --- 管理外の同名フォルダ：触らない -------------------------------
  foreach ($a in @($actions | Where-Object Action -eq 'Conflict')) {
    Write-Warning "$($a.Name)（$($a.Target)）: 管理外の同名フォルダがあるので飛ばします: $(Join-Path $TargetDirs[$a.Target] $a.Name)"
    $counts.Skip++
  }

  # --- 自作スキル ---------------------------------------------------
  foreach ($a in @($actions | Where-Object { $_.Type -eq 'own' -and $_.Action -ne 'Conflict' })) {
    $key = "$($a.Target)`t$($a.Name)"
    $dst = Join-Path $TargetDirs[$a.Target] $a.Name
    $label = "$($a.Name)（$($a.Target)）"

    if ($a.Action -eq 'Remove') {
      Info "削除: $label"
      if (-not $DryRun) { Remove-SkillFolder -Path $dst }
      $state.Remove($key)
      $counts.Remove++
      continue
    }

    $src = Join-Path (Join-Path $RepoDir 'skills') $a.Name
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
      Write-Warning "${label}: リポジトリに $src がないので飛ばします"
      $counts.Error++
      continue
    }

    Info "$(if ($a.Action -eq 'Add') { '追加' } else { '更新' }): $label -> $dst"
    if (-not $DryRun) {
      Remove-SkillFolder -Path $dst
      $parent = Split-Path -Parent $dst
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
    }
    $state[$key] = [pscustomobject]@{ Target = $a.Target; Name = $a.Name; Type = 'own' }
    $counts[$a.Action]++
  }

  # --- 公開スキル（スキルごとに、出す先をまとめて 1 回呼ぶ） --------
  $npxActions = @($actions | Where-Object { $_.Type -eq 'npx' -and $_.Action -in @('Add', 'Remove') })
  $npxReady = $null
  foreach ($group in @($npxActions | Group-Object Action, Name)) {
    $first  = $group.Group[0]
    $agents = @($group.Group | ForEach-Object { $TargetMap[$_.Target].Agent })
    $label  = "$($first.Name)（$(@($group.Group | ForEach-Object Target) -join ', ')）"

    if ($null -eq $npxReady) { $npxReady = Test-NpxAvailable }
    if (-not $npxReady) {
      Write-Warning "${label}: npx が見つからないので公開スキルを飛ばします（Node.js を入れてください）"
      $counts.Skip += $group.Count
      continue
    }

    $agentArgs = @($agents | ForEach-Object { '-a'; $_ })
    if ($first.Action -eq 'Add') {
      $npxArgs = @('add', $first.Source, '--skill', $first.Name, '-g') + $agentArgs + @('-y', '--copy')
      Info "追加（npx）: $label"
    } else {
      $npxArgs = @('remove', $first.Name, '-g') + $agentArgs + @('-y')
      Info "削除（npx）: $label"
    }
    if ($DryRun) {
      Info "       npx skills $($npxArgs -join ' ')"
    } else {
      $code = Invoke-NpxSkills -Arguments $npxArgs
      if ($code -ne 0) {
        Write-Warning "${label}: npx skills が失敗しました（終了コード $code）"
        $counts.Error += $group.Count
        continue
      }
    }
    foreach ($a in $group.Group) {
      $key = "$($a.Target)`t$($a.Name)"
      if ($a.Action -eq 'Add') {
        $state[$key] = [pscustomobject]@{ Target = $a.Target; Name = $a.Name; Type = 'npx' }
      } else {
        $state.Remove($key)
      }
      $counts[$a.Action]++
    }
  }

  return [pscustomobject]@{
    Installed = @($state.Values)
    Counts    = $counts
  }
}

# ==================================================================
# 入口
# ==================================================================
function Invoke-SkillsMain {
  param([switch]$DryRun, [switch]$Select, [switch]$Update)
  $ErrorActionPreference = "Stop"

  $repo    = Get-SkillsRepo
  $homeDir = Get-SkillsHome
  $ledgerPath = Join-Path (Join-Path $repo 'skills') 'skills.tsv'
  $stateDir   = Join-Path $homeDir '.dotfiles-skills'

  Step "スキルを配置"
  if ($DryRun) { Info "*** DryRun モード: 実際には何も変更しません ***" }
  if (-not (Test-Path -LiteralPath $ledgerPath)) {
    Skip "台帳がないので飛ばします（$ledgerPath）"
    return
  }

  # (1) 台帳を読む
  $ledger = Read-SkillLedger -Path $ledgerPath
  if ($ledger.HasErrors) {
    Write-Warning "台帳に読めない行があったので、今回は片付け（削除）をしません"
  }

  # (2) 入れるスキルを決める（-Select ならメニューで選ぶ）
  $excluded = @(Get-ExcludedSkills -StateDir $stateDir)
  if ($Select) {
    if ($ledger.Skills.Count -eq 0) {
      Skip "台帳にスキルがないので、選ぶものがありません"
    } else {
      $excluded = @(Show-SkillMenu -Skills $ledger.Skills -Excluded $excluded)
      if (-not $DryRun) { Save-ExcludedSkills -StateDir $stateDir -Names $excluded }
    }
  }

  # (3) 何をするか計算して、実行する
  $installed = @(Get-InstalledState -StateDir $stateDir)
  $dirs = Get-TargetDirs -HomeDir $homeDir
  $plan = @(Get-SkillPlan -Skills $ledger.Skills -Excluded $excluded -Installed $installed -TargetDirs $dirs -SkipRemovals $ledger.HasErrors)
  $result = Invoke-SkillPlan -Plan $plan -RepoDir $repo -TargetDirs $dirs -Installed $installed -DryRun:$DryRun

  # (4) 公開スキルの更新（-Update のときだけ）
  if ($Update) {
    Step "公開スキルを更新"
    if (-not (Test-NpxAvailable)) {
      Write-Warning "npx が見つからないので更新を飛ばします（Node.js を入れてください）"
    } elseif ($DryRun) {
      Info "npx skills update -g -y"
    } else {
      $code = Invoke-NpxSkills -Arguments @('update', '-g', '-y')
      if ($code -ne 0) { Write-Warning "npx skills update が失敗しました（終了コード $code）" } else { Ok "公開スキルを更新しました" }
    }
  }

  # (5) 記録を保存して、結果を表示する
  if (-not $DryRun) { Save-InstalledState -StateDir $stateDir -Entries $result.Installed }
  $c = $result.Counts
  Ok ("追加 {0} / 更新 {1} / 削除 {2} / スキップ {3} / エラー {4}" -f $c.Add, $c.Update, $c.Remove, $c.Skip, $c.Error)
  return $result
}

# . で読み込まれたとき（テストなど）は何もしない
if ($MyInvocation.InvocationName -ne '.') {
  [void](Invoke-SkillsMain -DryRun:$DryRun -Select:$Select -Update:$Update)
}

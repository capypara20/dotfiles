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
#   .\skills.ps1 -Update    # 最後に公開スキルを入れ直して最新にする（記録した出す先だけ）
#   .\skills.ps1 -DryRun    # 何が起きるか表示するだけ（実際には変更しない）
#
# install.ps1 の最後からも呼ばれる（-SkipSkills で飛ばせる）。
# ==================================================================

param(
  [switch]$DryRun,   # 予行演習（表示するだけ）
  [switch]$Select,   # 入れるスキルを選ぶメニューを出す
  [switch]$Update    # 最後に公開スキルを入れ直して最新にする
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

# 記録（installed.txt）を読む。
#   この記録は「消してよいもの」の一覧なので、1 行ずつ厳しく確かめる。
#   置き先が対応表にない・名前が使えない文字を含む（空や .. など）・種類が own/npx でない行は、
#   警告して無視する（呼び出し側は -WarningVariable で受け取り、その回は片付けをしない）
function Get-InstalledState {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$StateDir)
  $n = 0
  foreach ($line in (Read-StateLines -Path (Join-Path $StateDir 'installed.txt'))) {
    $n++
    $f = $line -split "`t"
    $valid = ($f.Count -ge 3) -and $TargetMap.Contains($f[0]) -and ($f[1] -match $NamePattern) -and ($SkillTypes -contains $f[2])
    if (-not $valid) {
      Write-Warning "記録ファイル（installed.txt）の $n 行目が読めないので無視します: '$line'"
      continue
    }
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
    # npx の出力は画面に流す（戻り値に混ざると、終了コードが正しく判定できないため）
    & (Get-NpxCommand) -y skills @Arguments | Out-Host
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

  # --- 片付け：自作も公開も、記録にあるフォルダを自分で消す ---------
  #   npx skills remove は、記録にない場所（~/.copilot/skills など）まで消すことがあるので使わない
  foreach ($a in @($actions | Where-Object Action -eq 'Remove')) {
    $key   = "$($a.Target)`t$($a.Name)"
    $dst   = Join-Path $TargetDirs[$a.Target] $a.Name
    $label = "$($a.Name)（$($a.Target)）"
    Info "削除: $label"
    if (-not $DryRun) {
      try {
        Remove-SkillFolder -Path $dst
      } catch {
        Write-Warning "${label}: 削除に失敗しました（次の実行でもう一度試します）: $($_.Exception.Message)"
        $counts.Error++
        continue
      }
    }
    $state.Remove($key)
    $counts.Remove++
  }

  # --- 自作スキルの追加・更新 ---------------------------------------
  foreach ($a in @($actions | Where-Object { $_.Type -eq 'own' -and $_.Action -in @('Add', 'Update') })) {
    $key   = "$($a.Target)`t$($a.Name)"
    $dst   = Join-Path $TargetDirs[$a.Target] $a.Name
    $label = "$($a.Name)（$($a.Target)）"
    $entry = [pscustomobject]@{ Target = $a.Target; Name = $a.Name; Type = 'own' }

    $src = Join-Path (Join-Path $RepoDir 'skills') $a.Name
    if (-not (Test-Path -LiteralPath $src -PathType Container)) {
      Write-Warning "${label}: リポジトリに $src がないので飛ばします"
      $counts.Error++
      continue
    }

    Info "$(if ($a.Action -eq 'Add') { '追加' } else { '更新' }): $label -> $dst"
    if (-not $DryRun) {
      try {
        Remove-SkillFolder -Path $dst
        $parent = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
      } catch {
        Write-Warning "${label}: コピーに失敗しました: $($_.Exception.Message)"
        $counts.Error++
        # 計画の時点では無かったフォルダ（Add）が残っていれば、自分が作ったものとして記録する。
        # 記録しないと、次から「管理外」扱いになって更新も削除もできなくなるため
        if ($a.Action -eq 'Add' -and (Test-Path -LiteralPath $dst)) { $state[$key] = $entry }
        continue
      }
    }
    $state[$key] = $entry
    $counts[$a.Action]++
  }

  # --- 公開スキルの追加（スキルごとに、出す先をまとめて 1 回呼ぶ） --------
  $npxReady = $null
  foreach ($group in @($actions | Where-Object { $_.Type -eq 'npx' -and $_.Action -eq 'Add' } | Group-Object Name)) {
    $first   = $group.Group[0]
    $targets = @($group.Group | ForEach-Object Target)
    $label   = "$($first.Name)（$($targets -join ', ')）"

    if ($null -eq $npxReady) { $npxReady = Test-NpxAvailable }
    if (-not $npxReady) {
      Write-Warning "${label}: npx が見つからないので公開スキルを飛ばします（Node.js を入れてください）"
      $counts.Skip += $group.Count
      continue
    }

    $npxArgs = New-NpxAddArguments -Source $first.Source -Name $first.Name -Targets $targets
    Info "追加（npx）: $label"
    $ok = $true
    if ($DryRun) {
      Info "       npx skills $($npxArgs -join ' ')"
    } else {
      $code = Invoke-NpxSafely -Arguments $npxArgs
      if ($code -ne 0) {
        Write-Warning "${label}: npx skills が失敗しました（終了コード $code）"
        $ok = $false
      }
    }
    foreach ($a in $group.Group) {
      $key   = "$($a.Target)`t$($a.Name)"
      $entry = [pscustomobject]@{ Target = $a.Target; Name = $a.Name; Type = 'npx' }
      if ($ok) {
        $state[$key] = $entry
        $counts.Add++
      } else {
        $counts.Error++
        # 途中までコピーされたフォルダがあれば、自分が作ったものとして記録する
        if (Test-Path -LiteralPath (Join-Path $TargetDirs[$a.Target] $a.Name)) { $state[$key] = $entry }
      }
    }
  }

  return [pscustomobject]@{
    Installed = @($state.Values)
    Counts    = $counts
  }
}

# npx skills add の引数（出す先ごとに -a <agent> を並べる。--copy でコピーして置いてもらう）
function New-NpxAddArguments {
  param([string]$Source, [string]$Name, [string[]]$Targets)
  $agentArgs = @($Targets | ForEach-Object { '-a'; $TargetMap[$_].Agent })
  return @('add', $Source, '--skill', $Name, '-g') + $agentArgs + @('-y', '--copy')
}

# npx を呼ぶ。npx 自体が起動できないなどの例外も「失敗（終了コード 1）」として返す
function Invoke-NpxSafely {
  param([Parameter(Mandatory)][string[]]$Arguments)
  try {
    return Invoke-NpxSkills -Arguments $Arguments
  } catch {
    Write-Warning "npx skills を実行できませんでした: $($_.Exception.Message)"
    return 1
  }
}

# 公開スキルの更新（-Update）
#   npx skills update は、台帳の出す先を無視して見つけたツール全部に入れ直すので使わない。
#   記録にある公開スキルを、記録した出す先だけを指定して add し直す（add は上書きで更新される）
function Update-NpxSkills {
  param([object[]]$Installed = @(), [object[]]$Skills = @(), [switch]$DryRun)
  Step "公開スキルを更新"
  $groups = @($Installed | Where-Object { $_ -and $_.Type -eq 'npx' } | Group-Object Name)
  if ($groups.Count -eq 0) {
    Skip "更新する公開スキルはありません"
    return
  }
  if (-not (Test-NpxAvailable)) {
    Write-Warning "npx が見つからないので更新を飛ばします（Node.js を入れてください）"
    return
  }
  foreach ($g in $groups) {
    $skill = @($Skills | Where-Object { $_.Name -eq $g.Name -and $_.Type -eq 'npx' }) | Select-Object -First 1
    if (-not $skill) {
      Skip "$($g.Name): 台帳に見つからないので更新を飛ばします"
      continue
    }
    $targets = @($g.Group | ForEach-Object Target)
    $npxArgs = New-NpxAddArguments -Source $skill.Source -Name $g.Name -Targets $targets
    Info "更新（npx）: $($g.Name)（$($targets -join ', ')）"
    if ($DryRun) {
      Info "       npx skills $($npxArgs -join ' ')"
      continue
    }
    $code = Invoke-NpxSafely -Arguments $npxArgs
    if ($code -ne 0) { Write-Warning "$($g.Name): 更新に失敗しました（終了コード $code）" } else { Ok "$($g.Name) を更新しました" }
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

  # (1) 台帳を読む（空の台帳や、必須の列がない台帳はここで止まる）
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

  # (3) 記録を読む（読めない行があれば、その回は片付けをしない）
  $stateWarnings = $null
  $installed = @(Get-InstalledState -StateDir $stateDir -WarningVariable stateWarnings)
  $stateHasErrors = @($stateWarnings).Count -gt 0
  if ($stateHasErrors) {
    Write-Warning "記録ファイルに読めない行があったので、今回は片付け（削除）をしません"
  }

  # (4) 何をするか計算して、実行する
  $dirs = Get-TargetDirs -HomeDir $homeDir
  $plan = @(Get-SkillPlan -Skills $ledger.Skills -Excluded $excluded -Installed $installed -TargetDirs $dirs -SkipRemovals ($ledger.HasErrors -or $stateHasErrors))
  $result = Invoke-SkillPlan -Plan $plan -RepoDir $repo -TargetDirs $dirs -Installed $installed -DryRun:$DryRun

  # (5) 公開スキルの更新（-Update のときだけ）
  if ($Update) { Update-NpxSkills -Installed $result.Installed -Skills $ledger.Skills -DryRun:$DryRun }

  # (6) 記録を保存して、結果を表示する
  if (-not $DryRun) { Save-InstalledState -StateDir $stateDir -Entries $result.Installed }
  $c = $result.Counts
  Ok ("追加 {0} / 更新 {1} / 削除 {2} / スキップ {3} / エラー {4}" -f $c.Add, $c.Update, $c.Remove, $c.Skip, $c.Error)
  return $result
}
# . で読み込まれたとき（テストなど）は何もしない
if ($MyInvocation.InvocationName -ne '.') {
  [void](Invoke-SkillsMain -DryRun:$DryRun -Select:$Select -Update:$Update)
}

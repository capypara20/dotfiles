# ==================================================================
# skills.ps1 のテスト（Pester 5 / 6 で動く書き方）
#
# 使い方:
#   Invoke-Pester tests/skills.Tests.ps1 -Output Detailed
#   powershell.exe -NoProfile -Command "Invoke-Pester tests/skills.Tests.ps1 -Output Detailed"
#
# skills.ps1 は「. で読み込んだときは関数を定義するだけ」なので、
# ここで読み込んでも本番の処理は動かない。
# ==================================================================

BeforeAll {
  . "$PSScriptRoot/../skills.ps1"

  # TestDrive（テストごとの一時フォルダ）に台帳を書いて、そのパスを返す
  function New-TestLedger {
    param(
      [string[]]$Lines,
      [switch]$Bom,     # 先頭に BOM を付ける（Windows のメモ帳などで保存した状態）
      [switch]$Crlf     # 改行を CRLF にする
    )
    $path = Join-Path $TestDrive 'skills.tsv'
    $nl = if ($Crlf) { "`r`n" } else { "`n" }
    $text = ($Lines -join $nl) + $nl
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($Bom.IsPresent)))
    return $path
  }

  $Header = "name`ttype`ttargets`tsource`turl`tnote"
}

Describe 'Get-SkillsHome / Get-TargetDirs' {
  AfterEach { Remove-Item Env:DOTFILES_SKILLS_HOME -ErrorAction SilentlyContinue }

  It 'DOTFILES_SKILLS_HOME があればそれをホームとして使う' {
    $env:DOTFILES_SKILLS_HOME = 'C:\fake-home'
    Get-SkillsHome | Should -Be 'C:\fake-home'
  }

  It 'なければ本物のホームを使う' {
    Get-SkillsHome | Should -Be $HOME
  }

  It '置き先は claude と agents の 2 つ' {
    $dirs = Get-TargetDirs -HomeDir 'C:\h'
    @($dirs.Keys | Sort-Object) | Should -Be @('agents', 'claude')
    $dirs.claude | Should -BeLike 'C:\h*.claude*skills'
    $dirs.agents | Should -BeLike 'C:\h*.agents*skills'
  }
}

Describe 'Read-SkillLedger' {
  It '見出しの名前で列を読む（列の順番に頼らない）' {
    $p = New-TestLedger $Header, "rust-tutor`town`tclaude,agents`t`t`tRust 学習"
    $r = Read-SkillLedger -Path $p
    $r.Skills[0].Name    | Should -Be 'rust-tutor'
    $r.Skills[0].Type    | Should -Be 'own'
    $r.Skills[0].Targets | Should -Be @('claude', 'agents')
    $r.Skills[0].Note    | Should -Be 'Rust 学習'
    $r.HasErrors         | Should -BeFalse
  }

  It '# の行と空行を飛ばし、Line はファイル上の行番号になる' {
    $p = New-TestLedger $Header, '# メモの行', "a`town`tclaude`t`t`t", '', "b`town`tagents`t`t`t"
    $r = Read-SkillLedger -Path $p
    $r.Skills.Count   | Should -Be 2
    $r.Skills[0].Line | Should -Be 3
    $r.Skills[1].Line | Should -Be 5
  }

  It '知らない列は無視し、ない任意の列は空になる' {
    $p = New-TestLedger "type`tname`ttargets`tadded", "own`ta`tclaude`t2026-11-16"
    $r = Read-SkillLedger -Path $p
    $r.Skills[0].Name | Should -Be 'a'
    $r.Skills[0].Url  | Should -Be ''
    $r.HasErrors      | Should -BeFalse
  }

  It '必須の列がないと止まる' {
    $p = New-TestLedger "type`tname", "own`tx"
    { Read-SkillLedger -Path $p } | Should -Throw '*必須の列がありません: targets*'
  }

  It 'BOM 付き・CRLF でも読める' {
    $p = New-TestLedger -Lines "type`tname`ttargets`tsource`turl`tnote", "own`ta`tclaude,agents`t`t`tメモ" -Bom -Crlf
    $r = Read-SkillLedger -Path $p
    $r.Skills[0].Type         | Should -Be 'own'
    $r.Skills[0].Targets[-1]  | Should -Be 'agents'
    $r.Skills[0].Note         | Should -Be 'メモ'
  }

  It '不正な行は警告して飛ばし、HasErrors を立てる（<Why>）' -TestCases @(
    @{ Row = "cursor-only`town`tcursor`t`t`t"; Why = '知らない出す先' }
    @{ Row = "x`tnpx`tclaude`t`t`t";           Why = 'npx なのに source がない' }
    @{ Row = "../evil`town`tclaude`t`t`t";     Why = '名前に使えない文字' }
    @{ Row = "x`tplugin`tclaude`t`t`t";        Why = '知らない type' }
    @{ Row = "x own claude";                   Why = 'タブではなく空白' }
    @{ Row = "x`town`t`t`t`t";                 Why = 'targets が空' }
  ) {
    $r = Read-SkillLedger -Path (New-TestLedger $Header, $Row) -WarningVariable w -WarningAction SilentlyContinue
    $r.Skills.Count | Should -Be 0
    $r.HasErrors    | Should -BeTrue
    ($w -join ' ')  | Should -Match '2 行目'
  }

  It '同じ名前の 2 行目は不正として扱う' {
    $p = New-TestLedger $Header, "a`town`tclaude`t`t`t", "a`town`tagents`t`t`t"
    $r = Read-SkillLedger -Path $p -WarningVariable w -WarningAction SilentlyContinue
    $r.Skills.Count      | Should -Be 1
    $r.Skills[0].Targets | Should -Be @('claude')
    $r.HasErrors         | Should -BeTrue
    ($w -join ' ')       | Should -Match '3 行目'
  }

  It '正しい npx の行は source を持つ' {
    $p = New-TestLedger $Header, "find-skills`tnpx`tclaude,agents`tvercel-labs/skills`thttps://skills.sh/x`tスキル検索"
    $r = Read-SkillLedger -Path $p
    $r.Skills[0].Source | Should -Be 'vercel-labs/skills'
    $r.Skills[0].Url    | Should -Be 'https://skills.sh/x'
    $r.HasErrors        | Should -BeFalse
  }
}

Describe 'Switch-SkillExclusion' {
  BeforeAll {
    $s = @(
      [pscustomobject]@{ Name = 'a' }
      [pscustomobject]@{ Name = 'b' }
      [pscustomobject]@{ Name = 'c' }
    )
  }

  It '番号で外す' {
    @(Switch-SkillExclusion -Skills $s -Excluded @() -Answer '2') | Should -Be @('b')
  }

  It 'もう一度で戻す' {
    @(Switch-SkillExclusion -Skills $s -Excluded @('b') -Answer '2').Count | Should -Be 0
  }

  It '複数をまとめて切り替える（空白・カンマ区切り）' {
    @(Switch-SkillExclusion -Skills $s -Excluded @() -Answer '1, 3') | Should -Be @('a', 'c')
  }

  It '範囲外の番号と文字は無視する' {
    @(Switch-SkillExclusion -Skills $s -Excluded @() -Answer '0 9 x 2' -WarningAction SilentlyContinue) | Should -Be @('b')
  }
}

Describe '記録ファイル' {
  It '除外リストを保存して読み直せる' {
    $dir = Join-Path $TestDrive 'state1'
    Save-ExcludedSkills -StateDir $dir -Names @('a', 'b')
    @(Get-ExcludedSkills -StateDir $dir) | Should -Be @('a', 'b')
  }

  It '除外リストがなければ空' {
    @(Get-ExcludedSkills -StateDir (Join-Path $TestDrive 'no-such-dir')).Count | Should -Be 0
  }

  It 'installed を保存して読み直せる' {
    $dir = Join-Path $TestDrive 'state2'
    $entries = @(
      [pscustomobject]@{ Target = 'claude'; Name = 'hello'; Type = 'own' }
      [pscustomobject]@{ Target = 'agents'; Name = 'find-skills'; Type = 'npx' }
    )
    Save-InstalledState -StateDir $dir -Entries $entries
    $got = @(Get-InstalledState -StateDir $dir)
    $got.Count     | Should -Be 2
    $got[1].Target | Should -Be 'agents'
    $got[1].Name   | Should -Be 'find-skills'
    $got[1].Type   | Should -Be 'npx'
  }

  It 'installed がなければ空' {
    @(Get-InstalledState -StateDir (Join-Path $TestDrive 'no-such-dir')).Count | Should -Be 0
  }

  It '記録ファイルは BOM なし・LF で書く（先頭は BOM でなく、CR がない）' {
    $dir = Join-Path $TestDrive 'state3'
    Save-ExcludedSkills -StateDir $dir -Names @('a', 'b')
    $bytes = [IO.File]::ReadAllBytes((Join-Path $dir 'excluded.txt'))
    $bytes[0]                  | Should -Not -Be 0xEF
    ($bytes -contains 13)      | Should -BeFalse
  }
}

Describe 'Get-SkillPlan' {
  BeforeAll {
    function New-Skill([string]$Name, [string[]]$Targets, [string]$Type = 'own', [string]$Source = '') {
      [pscustomobject]@{ Type = $Type; Name = $Name; Source = $Source; Targets = $Targets; Url = ''; Note = ''; Line = 2 }
    }
    function New-Entry([string]$Target, [string]$Name, [string]$Type = 'own') {
      [pscustomobject]@{ Target = $Target; Name = $Name; Type = $Type }
    }
  }
  BeforeEach {
    $dirs = Get-TargetDirs -HomeDir (Join-Path $TestDrive ('home' + [guid]::NewGuid().ToString('N')))
  }

  It '初めてなら Add' {
    $plan = @(Get-SkillPlan -Skills @(New-Skill 'hello' @('claude', 'agents')) -TargetDirs $dirs)
    $plan.Count | Should -Be 2
    @($plan | ForEach-Object { "$($_.Action):$($_.Target):$($_.Name)" }) | Should -Be @('Add:claude:hello', 'Add:agents:hello')
  }

  It '記録にあれば Update' {
    $plan = @(Get-SkillPlan -Skills @(New-Skill 'hello' @('claude', 'agents')) -Installed @(New-Entry 'claude' 'hello') -TargetDirs $dirs)
    @($plan | ForEach-Object { "$($_.Action):$($_.Target)" }) | Should -Be @('Update:claude', 'Add:agents')
  }

  It '管理外の同名フォルダがあれば Conflict' {
    New-Item -ItemType Directory -Force -Path (Join-Path $dirs.claude 'hello') | Out-Null
    $plan = @(Get-SkillPlan -Skills @(New-Skill 'hello' @('claude')) -TargetDirs $dirs)
    $plan[0].Action | Should -Be 'Conflict'
  }

  It '台帳から消えたら Remove' {
    $plan = @(Get-SkillPlan -Skills @() -Installed @(New-Entry 'claude' 'hello' 'npx') -TargetDirs $dirs)
    $plan.Count     | Should -Be 1
    $plan[0].Action | Should -Be 'Remove'
    $plan[0].Type   | Should -Be 'npx'
    $plan[0].Name   | Should -Be 'hello'
  }

  It '除外したら Remove' {
    $plan = @(Get-SkillPlan -Skills @(New-Skill 'hello' @('claude')) -Excluded @('hello') -Installed @(New-Entry 'claude' 'hello') -TargetDirs $dirs)
    @($plan | ForEach-Object { "$($_.Action):$($_.Target)" }) | Should -Be @('Remove:claude')
  }

  It '除外していて記録にもなければ何もしない' {
    @(Get-SkillPlan -Skills @(New-Skill 'hello' @('claude')) -Excluded @('hello') -TargetDirs $dirs).Count | Should -Be 0
  }

  It '出す先から agents を外したら agents だけ Remove' {
    $plan = @(Get-SkillPlan -Skills @(New-Skill 'hello' @('claude')) -Installed @((New-Entry 'claude' 'hello'), (New-Entry 'agents' 'hello')) -TargetDirs $dirs)
    @($plan | ForEach-Object { "$($_.Action):$($_.Target)" }) | Should -Be @('Update:claude', 'Remove:agents')
  }

  It '記録にないフォルダ（synced など）は Remove しない' {
    New-Item -ItemType Directory -Force -Path (Join-Path $dirs.claude 'synced') | Out-Null
    @(Get-SkillPlan -Skills @() -TargetDirs $dirs).Count | Should -Be 0
  }

  It 'SkipRemovals のときは Remove を出さない' {
    $plan = @(Get-SkillPlan -Skills @() -Excluded @() -Installed @(New-Entry 'claude' 'x') -TargetDirs $dirs -SkipRemovals $true)
    @($plan | Where-Object Action -eq 'Remove').Count | Should -Be 0
  }

  It '公開スキルの Add は Source を持つ' {
    $plan = @(Get-SkillPlan -Skills @(New-Skill 'find-skills' @('agents') 'npx' 'vercel-labs/skills') -TargetDirs $dirs)
    $plan[0].Type   | Should -Be 'npx'
    $plan[0].Source | Should -Be 'vercel-labs/skills'
  }
}

Describe 'Invoke-SkillsMain' {
  BeforeAll {
    $LedgerHeader = "type`tname`ttargets`tsource`turl`tnote"
    function Set-Ledger([string[]]$Rows = @()) {
      $text = (@($LedgerHeader) + $Rows) -join "`n"
      [IO.File]::WriteAllText((Join-Path $script:Repo 'skills\skills.tsv'), $text + "`n", (New-Object Text.UTF8Encoding($false)))
    }
    function Get-InstalledLines {
      $f = Join-Path $script:HomeDir '.dotfiles-skills\installed.txt'
      if (-not (Test-Path $f)) { return @() }
      return @(Get-Content $f | Where-Object { $_ })
    }
  }

  BeforeEach {
    $id = [guid]::NewGuid().ToString('N')
    $script:Repo    = Join-Path $TestDrive "repo-$id"
    $script:HomeDir = Join-Path $TestDrive "home-$id"
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Repo 'skills\hello') | Out-Null
    New-Item -ItemType Directory -Force -Path $script:HomeDir | Out-Null
    Set-Content -LiteralPath (Join-Path $script:Repo 'skills\hello\SKILL.md') -Value "---`nname: hello`n---"
    $env:DOTFILES_SKILLS_REPO = $script:Repo
    $env:DOTFILES_SKILLS_HOME = $script:HomeDir
    $script:Claude = Join-Path $script:HomeDir '.claude\skills'
    $script:Agents = Join-Path $script:HomeDir '.agents\skills'
    Mock Invoke-NpxSkills { 0 }
    Mock Test-NpxAvailable { $true }
  }

  AfterEach {
    Remove-Item Env:DOTFILES_SKILLS_REPO, Env:DOTFILES_SKILLS_HOME, Env:DOTFILES_SKILLS_NPX -ErrorAction SilentlyContinue
  }

  It '自作スキルを両方の置き先にコピーし、記録する' {
    Set-Ledger "own`thello`tclaude,agents`t`t`t"
    Invoke-SkillsMain | Out-Null
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
    Join-Path $script:Agents 'hello\SKILL.md' | Should -Exist
    @(Get-InstalledLines).Count | Should -Be 2
  }

  It '台帳から消すと、次の実行で消える' {
    Set-Ledger "own`thello`tclaude,agents`t`t`t"
    Invoke-SkillsMain | Out-Null
    Set-Ledger
    Invoke-SkillsMain | Out-Null
    Join-Path $script:Claude 'hello' | Should -Not -Exist
    Join-Path $script:Agents 'hello' | Should -Not -Exist
    @(Get-InstalledLines).Count | Should -Be 0
  }

  It '管理外の同名フォルダには触らない' {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Claude 'hello') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:Claude 'hello\mine.txt') -Value 'mine'
    Set-Ledger "own`thello`tclaude`t`t`t"
    Invoke-SkillsMain -WarningAction SilentlyContinue | Out-Null
    Get-Content (Join-Path $script:Claude 'hello\mine.txt') | Should -Be 'mine'
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Not -Exist
    @(Get-InstalledLines).Count | Should -Be 0
  }

  It 'DryRun では何も変わらない' {
    Set-Ledger "own`thello`tclaude,agents`t`t`t"
    Invoke-SkillsMain -DryRun | Out-Null
    $script:Claude | Should -Not -Exist
    $script:Agents | Should -Not -Exist
    Join-Path $script:HomeDir '.dotfiles-skills' | Should -Not -Exist
  }

  It '公開スキルは npx を正しいフラグで呼ぶ' {
    Set-Ledger "npx`tfind-skills`tclaude,agents`tvercel-labs/skills`t`t"
    Invoke-SkillsMain | Out-Null
    Should -Invoke Invoke-NpxSkills -Times 1 -Exactly -ParameterFilter {
      ($Arguments -join ' ') -eq 'add vercel-labs/skills --skill find-skills -g -a claude-code -a github-copilot -y --copy'
    }
    @(Get-InstalledLines) | Should -Be @("claude`tfind-skills`tnpx", "agents`tfind-skills`tnpx")
  }

  It 'npx がなくても自作スキルは入る' {
    Mock Test-NpxAvailable { $false }
    Set-Ledger "own`thello`tclaude`t`t`t", "npx`tfind-skills`tclaude`tvercel-labs/skills`t`t"
    { Invoke-SkillsMain -WarningAction SilentlyContinue | Out-Null } | Should -Not -Throw
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
    Should -Invoke Invoke-NpxSkills -Times 0 -Exactly
  }

  It '記録にあるフォルダが手で消されていても止まらない' {
    Set-Ledger "own`thello`tclaude`t`t`t"
    Invoke-SkillsMain | Out-Null
    Remove-Item -LiteralPath (Join-Path $script:Claude 'hello') -Recurse -Force
    Set-Ledger
    { Invoke-SkillsMain | Out-Null } | Should -Not -Throw
    @(Get-InstalledLines).Count | Should -Be 0
  }

  It '台帳に不正な行があると何も消さない' {
    Set-Ledger "own`thello`tclaude`t`t`t"
    Invoke-SkillsMain | Out-Null
    Set-Ledger "x own claude"
    Invoke-SkillsMain -WarningAction SilentlyContinue | Out-Null
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
    @(Get-InstalledLines).Count | Should -Be 1
  }

  It '更新しても置き先に .bak を作らない' {
    Set-Ledger "own`thello`tclaude`t`t`t"
    Invoke-SkillsMain | Out-Null
    Invoke-SkillsMain | Out-Null
    @(Get-ChildItem -LiteralPath $script:Claude -Force | ForEach-Object Name) | Should -Be @('hello')
  }

  It '台帳に増えたスキルは、除外リストがあっても入る' {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:HomeDir '.dotfiles-skills') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:HomeDir '.dotfiles-skills\excluded.txt') -Value 'other'
    Set-Ledger "own`thello`tclaude`t`t`t"
    Invoke-SkillsMain | Out-Null
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
  }

  It '公開スキルを台帳から消すときは npx remove を呼ばない（記録にないフォルダまで消すため）' {
    Set-Ledger "npx`tfind-skills`tclaude,agents`tvercel-labs/skills`t`t"
    Invoke-SkillsMain | Out-Null
    Set-Ledger
    Invoke-SkillsMain | Out-Null
    Should -Invoke Invoke-NpxSkills -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'remove' }
    @(Get-InstalledLines).Count | Should -Be 0
  }

  It '公開スキルの片付けは npx がなくてもできる' {
    Set-Ledger "npx`tfind-skills`tclaude,agents`tvercel-labs/skills`t`t"
    Invoke-SkillsMain | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Claude 'find-skills'), (Join-Path $script:Agents 'find-skills') | Out-Null
    Mock Test-NpxAvailable { $false }
    Set-Ledger
    Invoke-SkillsMain -WarningAction SilentlyContinue | Out-Null
    Join-Path $script:Claude 'find-skills' | Should -Not -Exist
    Join-Path $script:Agents 'find-skills' | Should -Not -Exist
    @(Get-InstalledLines).Count | Should -Be 0
  }

  It '記録ファイルのおかしな行では何も消さない（名前が空・..・知らない置き先）' {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Claude 'keep'), (Join-Path $script:Claude 'hello'), (Join-Path $script:HomeDir '.dotfiles-skills') | Out-Null
    Set-Content -LiteralPath (Join-Path $script:HomeDir '.claude\CLAUDE.md') -Value 'mine'
    [IO.File]::WriteAllText((Join-Path $script:HomeDir '.dotfiles-skills\installed.txt'), "claude`t`town`nclaude`t..`town`ncopilot`tx`town`nclaude`thello`town`n", (New-Object Text.UTF8Encoding($false)))
    Set-Ledger
    { Invoke-SkillsMain -WarningAction SilentlyContinue | Out-Null } | Should -Not -Throw
    Join-Path $script:Claude 'keep'               | Should -Exist
    Join-Path $script:Claude 'hello'              | Should -Exist
    Join-Path $script:HomeDir '.claude\CLAUDE.md' | Should -Exist
  }

  It '空の台帳なら止まって、何も消さない' {
    Set-Ledger "own`thello`tclaude`t`t`t"
    Invoke-SkillsMain | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:Repo 'skills\skills.tsv'), '')
    { Invoke-SkillsMain | Out-Null } | Should -Throw '*台帳が空です*'
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
  }

  It '途中でコピーに失敗しても止まらず、できた分は記録する' {
    Set-Content -LiteralPath (Join-Path $script:HomeDir '.agents') -Value 'not a folder'
    Set-Ledger "own`thello`tclaude,agents`t`t`t"
    $r = $null
    { $script:r = Invoke-SkillsMain -WarningAction SilentlyContinue } | Should -Not -Throw
    $script:r.Counts.Error | Should -Be 1
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
    @(Get-InstalledLines) | Should -Be @("claude`thello`town")
  }

  It '公開スキルの追加が失敗しても、できたフォルダは記録する' {
    Mock Invoke-NpxSkills {
      New-Item -ItemType Directory -Force -Path (Join-Path $env:DOTFILES_SKILLS_HOME '.agents\skills\find-skills') | Out-Null
      1
    }
    Set-Ledger "npx`tfind-skills`tagents`tvercel-labs/skills`t`t"
    Invoke-SkillsMain -WarningAction SilentlyContinue | Out-Null
    @(Get-InstalledLines) | Should -Be @("agents`tfind-skills`tnpx")
  }

  It '公開スキルを台帳から消すと、npx が残したフォルダも消す' {
    Set-Ledger "npx`tfind-skills`tclaude,agents`tvercel-labs/skills`t`t"
    Invoke-SkillsMain | Out-Null
    # npx が入れたフォルダの代わり（Mock は何も作らないので手で作る）
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Claude 'find-skills'), (Join-Path $script:Agents 'find-skills') | Out-Null
    Set-Ledger
    Invoke-SkillsMain | Out-Null
    Join-Path $script:Claude 'find-skills' | Should -Not -Exist
    Join-Path $script:Agents 'find-skills' | Should -Not -Exist
  }

  It '-Update は、記録にある公開スキルを、記録した出す先だけに入れ直す（npx update は使わない）' {
    Set-Ledger "npx`tfind-skills`tagents`tvercel-labs/skills`t`t"
    Invoke-SkillsMain | Out-Null
    Invoke-SkillsMain -Update | Out-Null
    Should -Invoke Invoke-NpxSkills -Times 2 -Exactly -ParameterFilter {
      ($Arguments -join ' ') -eq 'add vercel-labs/skills --skill find-skills -g -a github-copilot -y --copy'
    }
    Should -Invoke Invoke-NpxSkills -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'update' }
  }

  It 'skills/ にフォルダがない自作スキルはエラーにして続ける' {
    Set-Ledger "own`tghost`tclaude`t`t`t", "own`thello`tclaude`t`t`t"
    $r = Invoke-SkillsMain -WarningAction SilentlyContinue
    $r.Counts.Error | Should -Be 1
    Join-Path $script:Claude 'hello\SKILL.md' | Should -Exist
    Join-Path $script:Claude 'ghost' | Should -Not -Exist
  }

  It '台帳がなければ何もせずに終わる' {
    Remove-Item -LiteralPath (Join-Path $script:Repo 'skills\skills.tsv') -ErrorAction SilentlyContinue
    { Invoke-SkillsMain | Out-Null } | Should -Not -Throw
    $script:Claude | Should -Not -Exist
  }
}

Describe 'Invoke-NpxSkills' {
  AfterEach { Remove-Item Env:DOTFILES_SKILLS_NPX -ErrorAction SilentlyContinue }

  It 'テレメトリを止めて npx -y skills を呼び、終わったら元に戻す' {
    $log  = Join-Path $TestDrive 'npx-log.txt'
    $fake = Join-Path $TestDrive 'fake-npx.ps1'
    Set-Content -LiteralPath $fake -Value "`"`$env:DISABLE_TELEMETRY `$(`$args -join ' ')`" | Set-Content -LiteralPath '$log'; exit 0"
    $env:DOTFILES_SKILLS_NPX = $fake
    Remove-Item Env:DISABLE_TELEMETRY -ErrorAction SilentlyContinue
    $code = Invoke-NpxSkills -Arguments @('add', 'x')
    $code | Should -Be 0
    Get-Content $log | Should -Be '1 -y skills add x'
    $env:DISABLE_TELEMETRY | Should -BeNullOrEmpty
  }

  It 'npx が画面に何か出力しても、返すのは終了コードだけ' {
    $fake = Join-Path $TestDrive 'chatty-npx.ps1'
    Set-Content -LiteralPath $fake -Value "Write-Output 'Installing...'; Write-Output 'Done!'; exit 0"
    $env:DOTFILES_SKILLS_NPX = $fake
    $code = Invoke-NpxSkills -Arguments @('add', 'x')
    @($code).Count | Should -Be 1
    $code          | Should -Be 0
  }

  It 'npx の終了コードを返す' {
    $fake = Join-Path $TestDrive 'fail-npx.ps1'
    Set-Content -LiteralPath $fake -Value 'exit 3'
    $env:DOTFILES_SKILLS_NPX = $fake
    Invoke-NpxSkills -Arguments @('add', 'x') | Should -Be 3
  }
}
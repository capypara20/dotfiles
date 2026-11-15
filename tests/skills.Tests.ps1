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

  It '記録ファイルは BOM なし・LF で書く' {
    $dir = Join-Path $TestDrive 'state3'
    Save-ExcludedSkills -StateDir $dir -Names @('a', 'b')
    $bytes = [IO.File]::ReadAllBytes((Join-Path $dir 'excluded.txt'))
    $bytes[0]                  | Should -Not -Be 0xEF
    ($bytes -contains 13)      | Should -BeFalse
  }
}

param([string]$Mode = 'hook', [string]$Transcript = '')   # hook: SessionEnd 훅 진입 / window: 리뷰 창 프로세스(내부용)

# ── 설정 ─────────────────────────────────────────────
$Model       = 'sonnet'   # 분석에 쓸 모델
$MaxLogChars = 60000      # 분석에 넘길 대화 기록 최대 길이 (넘치면 앞 1/4 + 뒤 3/4만 사용)
$TimeoutSec  = 300        # 분석 최대 대기 시간
$Background  = '#1F1E1C'  # 창 배경
$Surface     = '#2A2926'  # 본문 카드 배경
$TextMain    = '#F4F3EE'
$TextDim     = '#A8A69E'
$Accent      = '#D97757'
$Good        = '#7FB685'  # '잘한 점' 섹션 색
$Warn        = '#E5A84B'  # '개선할 점' 섹션 색
# ─────────────────────────────────────────────────────

# ── 훅 진입: 창 프로세스를 분리 실행하고 즉시 반환 (Claude Code 종료를 막지 않도록) ──
if ($Mode -eq 'hook') {
    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $d = try { [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { $null }
    if ($d.transcript_path -and (Test-Path $d.transcript_path)) {
        Start-Process pwsh -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-File', "`"$PSCommandPath`"", 'window', "`"$($d.transcript_path)`""
    }
    exit 0
}

# ═════════════════ 리뷰 창 프로세스 (Mode = window) ═════════════════

function Cut([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n) + '…(생략)' } else { $s } }

# transcript(JSONL) → 사람이 읽을 수 있는 대화 기록
$cwd = ''; $startedAt = $null; $promptCount = 0
$log = foreach ($line in [IO.File]::ReadLines($Transcript)) {
    $o = try { $line | ConvertFrom-Json } catch { continue }
    if (-not $cwd -and $o.cwd) { $cwd = $o.cwd }
    if (-not $startedAt -and $o.timestamp) { $startedAt = ([DateTimeOffset]$o.timestamp).LocalDateTime }
    if ($o.isMeta -or $o.isSidechain) { continue }
    $c = $o.message.content
    if ($o.type -eq 'user') {
        # 도구 결과(tool_result)는 제외하고 사용자가 직접 쓴 텍스트만
        $t = if ($c -is [string]) { $c } else { ($c | Where-Object type -eq 'text' | ForEach-Object text) -join "`n" }
        if ($t -and $t -notmatch '^\s*<(command-|local-command|system-reminder)' -and $t -notlike '`[Request interrupted*') {
            $promptCount++
            "[사용자] $t"
        }
    } elseif ($o.type -eq 'assistant') {
        foreach ($p in $c) {
            if ($p.type -eq 'text' -and $p.text.Trim()) { '[Claude] ' + (Cut $p.text 800) }
            elseif ($p.type -eq 'tool_use') { "[도구:$($p.name)] " + (Cut ($p.input | ConvertTo-Json -Compress -Depth 3) 200) }
        }
    }
}
if ($promptCount -eq 0) { exit 0 }   # 질문 없이 끝난 세션은 창을 띄우지 않는다

$log = $log -join "`n`n"
if ($log.Length -gt $MaxLogChars) {
    $head = [int]($MaxLogChars / 4)
    $log = $log.Substring(0, $head) + "`n`n…(중간 생략)…`n`n" + $log.Substring($log.Length - ($MaxLogChars - $head))
}

$instruction = @"
아래는 Claude Code 세션의 대화 기록이다. 도구를 사용하지 말고 기록만 보고 답하라.
사용자가 한눈에 읽을 수 있게 짧고 쉬운 한국어로 쓴다. 전문 용어는 꼭 필요할 때만 쓴다.
서론·맺음말·표·이모지 없이 아래 형식만 출력한다. 각 항목은 한 줄(40자 안팎)을 넘기지 않는다.

## 한 줄 요약
- 이 세션에서 무엇을 했는지 한 문장

## 한 일
- 핵심 작업 2~4개 (바뀐 파일이 있으면 파일명만 괄호로)

## 잘한 점
- 사용자의 질문·요청 방식에서 좋았던 점 1~3개

## 개선할 점
- 질문·요청에서 아쉬웠던 점 1~3개. 없으면 "없음" 한 줄만
  - 예: 이렇게 물으면 더 좋다는 짧은 질문 예시 (개선할 점마다 하나)

## 다음엔 이렇게
- 다음 세션에 바로 써먹을 팁 1~2개

===== 대화 기록 =====
$log
"@

# ── 분석 시작 전 확인 알림창: 실행 여부와 모델을 사용자가 고른다 (분석은 토큰을 소모하므로) ──
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$c = { param($hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }

$modelKeys   = @('sonnet', 'opus', 'haiku')
$modelLabels = @('Sonnet  -  균형형 (기본)', 'Opus  -  가장 정확, 토큰 가장 많이 소모', 'Haiku  -  가장 빠르고 저렴')
$script:go = $false

$ask = New-Object System.Windows.Forms.Form
$ask.Text = 'Claude Code 세션 리뷰'
$ask.ClientSize = New-Object System.Drawing.Size(460, 388)
$ask.StartPosition = 'CenterScreen'; $ask.FormBorderStyle = 'FixedDialog'; $ask.MaximizeBox = $false; $ask.MinimizeBox = $false
$ask.BackColor = & $c $Background
$ask.Font = New-Object System.Drawing.Font('Malgun Gothic', 10)

function New-AskLabel($text, $font, $color, $y, $h) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = & $c $color
    $l.Location = New-Object System.Drawing.Point(24, $y); $l.Size = New-Object System.Drawing.Size(412, $h)
    $l
}
$lblQ    = New-AskLabel '세션 리뷰를 실행할까요?' (New-Object System.Drawing.Font('Malgun Gothic', 14, [System.Drawing.FontStyle]::Bold)) $TextMain 20 30
$lblDesc = New-AskLabel "방금 끝난 세션(질문 ${promptCount}개)을 AI가 읽고`n① 한 일 요약  ② 질문 피드백을 정리해 줘요." (New-Object System.Drawing.Font('Malgun Gothic', 10)) $TextDim 58 48
$lblM    = New-AskLabel '분석에 사용할 모델' (New-Object System.Drawing.Font('Malgun Gothic', 9.5, [System.Drawing.FontStyle]::Bold)) $TextMain 118 22

$combo = New-Object System.Windows.Forms.ComboBox
$combo.DropDownStyle = 'DropDownList'; $combo.FlatStyle = 'Flat'
$combo.BackColor = & $c $Surface; $combo.ForeColor = & $c $TextMain
$combo.Location = New-Object System.Drawing.Point(24, 144); $combo.Size = New-Object System.Drawing.Size(412, 30)
$combo.Items.AddRange($modelLabels)
$combo.SelectedIndex = [Math]::Max(0, [Array]::IndexOf($modelKeys, $Model))

# 주의 문구: 흰 바탕에 어두운 글씨, 핵심 구절은 굵게+밑줄, '주의'만 빨간색
$warnBox = New-Object System.Windows.Forms.RichTextBox
$warnBox.ReadOnly = $true; $warnBox.BorderStyle = 'None'; $warnBox.TabStop = $false; $warnBox.ScrollBars = 'None'
$warnBox.BackColor = [System.Drawing.Color]::White
$warnBox.Location = New-Object System.Drawing.Point(24, 204); $warnBox.Size = New-Object System.Drawing.Size(412, 104)
$warnDark = & $c '#1F1E1C'
$null = $warnBox.Handle   # 핸들이 있어야 서식(굵게·밑줄)이 적용된다
function Add-Warn($text, [bool]$key = $false, [single]$size = 10, $color = $warnDark) {
    # key: 주의할 핵심 구절 → 굵게 + 밑줄 / 그 외는 보통 굵기
    $style = [System.Drawing.FontStyle]::Regular
    if ($key) { $style = [System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Underline }
    $warnBox.SelectionStart = $warnBox.TextLength; $warnBox.SelectionLength = 0
    $warnBox.SelectionFont = New-Object System.Drawing.Font('Malgun Gothic', $size, $style)
    $warnBox.SelectionColor = $color
    $warnBox.SelectedText = $text
}
# 창이 표시된 뒤(Shown)에 채워야 서식이 유지된다
function Fill-Warn {
    $warnBox.Clear()
    Add-Warn '⚠ ' $false 11.5; Add-Warn "주의`n" $false 11.5 (& $c '#D32F2F')   # '주의' 두 글자만 빨간색
    Add-Warn '분석하면 '; Add-Warn '토큰이 소모됩니다' $true; Add-Warn " (대화 약 $($log.Length.ToString('N0'))자 전송).`n"
    Add-Warn '모델별 소모량: '; Add-Warn 'Opus > Sonnet > Haiku' $true; Add-Warn " 순`n"
    Add-Warn '사용량 한도에 영향을 줄 수 있어요.'
    $warnBox.Select(0, 0)
}

function New-AskButton($text, [bool]$primary, $x) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Size = New-Object System.Drawing.Size(120, 36); $b.Location = New-Object System.Drawing.Point($x, 332)
    $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'; $b.ForeColor = & $c $TextMain
    $b.BackColor = & $c $(if ($primary) { $Accent } else { $Background })
    $b.FlatAppearance.BorderColor = & $c $(if ($primary) { $Accent } else { '#4A4843' })
    $b
}
$btnGo   = New-AskButton '분석 시작' $true 316
$btnSkip = New-AskButton '건너뛰기' $false 188
$btnGo.Add_Click({ $script:go = $true; $ask.Close() })
$btnSkip.Add_Click({ $ask.Close() })
$ask.Controls.AddRange(@($lblQ, $lblDesc, $lblM, $combo, $warnBox, $btnSkip, $btnGo))
# -WindowStyle Hidden 으로 시작된 프로세스는 첫 ShowWindow 가 '숨김'으로 바뀌므로 Hide/Show 로 되살린다 (모달 대신 Run 사용: Hide 시 모달이 닫히기 때문)
$ask.Add_Shown({ $ask.Hide(); $ask.Show(); $ask.TopMost = $true; $ask.Activate(); Fill-Warn })
[System.Windows.Forms.Application]::Run($ask)

if (-not $script:go) { exit 0 }
$Model = $modelKeys[$combo.SelectedIndex]

# 분석은 백그라운드 job에서 실행 (창이 먼저 뜨고 결과를 기다린다)
# disableAllHooks: 분석용 claude 세션에서 이 훅과 다른 훅(알림창 등)이 다시 실행되지 않도록
$job = Start-Job -ArgumentList $instruction, $Model -ScriptBlock {
    param($text, $model)
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $OutputEncoding = [Text.Encoding]::UTF8
    Set-Location $env:TEMP
    $text | claude -p --model $model --no-session-persistence --settings '{"disableAllHooks":true}' 2>&1
}

Add-Type -Namespace '' -Name Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);'
$c = { param($hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }
$fontName = 'Malgun Gothic'
$F = @{
    Title   = New-Object System.Drawing.Font($fontName, 16, [System.Drawing.FontStyle]::Bold)
    Meta    = New-Object System.Drawing.Font($fontName, 9)
    Section = New-Object System.Drawing.Font($fontName, 12, [System.Drawing.FontStyle]::Bold)
    Body    = New-Object System.Drawing.Font($fontName, 10.5)
    Bold    = New-Object System.Drawing.Font($fontName, 10.5, [System.Drawing.FontStyle]::Bold)
    Small   = New-Object System.Drawing.Font($fontName, 9.5)
}

$endedAt = Get-Date
$project = Split-Path $cwd -Leaf
$meta = "$project   ·   $($startedAt.ToString('MM/dd HH:mm')) ~ $($endedAt.ToString('HH:mm'))   ·   질문 ${promptCount}개"
$script:raw = ''   # 저장용 원문(마크다운)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code 세션 리뷰'
$form.ClientSize = New-Object System.Drawing.Size(640, 680)
$form.MinimumSize = New-Object System.Drawing.Size(480, 400)
$form.StartPosition = 'CenterScreen'
$form.BackColor = & $c $Background
$form.Font = $F.Body
$form.Padding = New-Object System.Windows.Forms.Padding(24, 20, 24, 16)

# ── 상단: 제목 + 세션 정보 ──
$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Top'; $top.Height = 64
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '세션 리뷰'; $lblTitle.Font = $F.Title; $lblTitle.ForeColor = & $c $TextMain
$lblTitle.AutoSize = $true; $lblTitle.Location = New-Object System.Drawing.Point(0, 0)
$lblMeta = New-Object System.Windows.Forms.Label
$lblMeta.Text = $meta; $lblMeta.Font = $F.Meta; $lblMeta.ForeColor = & $c $TextDim
$lblMeta.AutoSize = $true; $lblMeta.Location = New-Object System.Drawing.Point(2, 38)
$top.Controls.AddRange(@($lblTitle, $lblMeta))

# ── 본문: 카드 안의 RichTextBox ──
$card = New-Object System.Windows.Forms.Panel
$card.Dock = 'Fill'; $card.BackColor = & $c $Surface
$card.Padding = New-Object System.Windows.Forms.Padding(20, 16, 8, 16)
$box = New-Object System.Windows.Forms.RichTextBox
$box.Dock = 'Fill'; $box.ReadOnly = $true; $box.BorderStyle = 'None'; $box.TabStop = $false
$box.BackColor = & $c $Surface; $box.ForeColor = & $c $TextMain; $box.Font = $F.Body
$box.ScrollBars = 'Vertical'; $box.DetectUrls = $false
$card.Controls.Add($box)

# 현재 커서 위치에 서식을 지정해 텍스트를 덧붙인다
function Add-Text($text, $font, $color, [int]$indent = 0, [int]$hang = 0) {
    $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0
    $box.SelectionFont = $font; $box.SelectionColor = & $c $color
    $box.SelectionIndent = $indent; $box.SelectionHangingIndent = $hang
    $box.SelectedText = $text
}
# **굵게** 를 처리하며 한 줄을 출력
function Add-Inline($text, $color, [int]$indent, [int]$hang) {
    $parts = [regex]::Split($text, '\*\*(.+?)\*\*')
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i]) { Add-Text $parts[$i] ($(if ($i % 2) { $F.Bold } else { $F.Body })) $color $indent $hang }
    }
    Add-Text "`n" $F.Body $color $indent $hang
}
# 분석 결과(마크다운 일부: ##, -, 들여쓴 -, **)를 서식 있는 텍스트로 렌더링
function Show-Review([string]$md) {
    $box.Clear()
    $secColor = $Accent; $first = $true
    foreach ($line in $md -split "`r?`n") {
        if ($line -match '^#{1,3}\s+(.+)') {
            $name = $Matches[1].Trim()
            $secColor = if ($name -match '잘한') { $Good } elseif ($name -match '개선|아쉬') { $Warn } else { $Accent }
            if (-not $first) { Add-Text "`n" $F.Small $TextMain }
            Add-Text '▍ ' $F.Section $secColor
            Add-Text "$name`n" $F.Section $TextMain
            Add-Text "`n" $F.Small $TextMain
            $first = $false
        } elseif ($line -match '^\s{2,}[-*]\s+(.+)') {
            Add-Text '└ ' $F.Small $TextDim 22 18
            Add-Inline $Matches[1] $TextDim 22 18
        } elseif ($line -match '^[-*]\s+(.+)') {
            Add-Text '•  ' $F.Bold $secColor 4 18
            Add-Inline $Matches[1] $TextMain 4 18
        } elseif ($line.Trim()) {
            Add-Inline $line.Trim() $TextMain 4 0
        }
    }
    $box.Select(0, 0)
    [void][Win32]::SendMessage($box.Handle, 0x115, [IntPtr]6, [IntPtr]::Zero)   # WM_VSCROLL / SB_TOP: 맨 위로 스크롤
    $form.ActiveControl = $btnClose   # 본문에 포커스(커서·선택 표시)가 가지 않도록
}

# ── 하단: 상태 표시 + 버튼 ──
$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Bottom'; $bottom.Height = 56
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Font = $F.Meta; $lblStatus.ForeColor = & $c $TextDim
$lblStatus.AutoSize = $true; $lblStatus.Location = New-Object System.Drawing.Point(2, 24)

function New-Button($text, [bool]$primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Size = New-Object System.Drawing.Size(96, 34); $b.FlatStyle = 'Flat'
    $b.Font = $F.Small; $b.Cursor = 'Hand'; $b.Anchor = 'Top, Right'
    $b.ForeColor = & $c $TextMain
    $b.BackColor = & $c $(if ($primary) { $Accent } else { $Background })
    $b.FlatAppearance.BorderColor = & $c $(if ($primary) { $Accent } else { '#4A4843' })
    $b.FlatAppearance.MouseOverBackColor = & $c $(if ($primary) { '#E08A6D' } else { '#35332F' })
    $b
}
$btnClose = New-Button '닫기' $false
$btnSave  = New-Button '저장' $true
$btnSave.Enabled = $false   # 분석이 끝난 뒤 활성화
$btnSave.BackColor = & $c '#3A3935'; $btnSave.FlatAppearance.BorderColor = & $c '#3A3935'   # 비활성 동안은 회색
$btnClose.Location = New-Object System.Drawing.Point(($bottom.Width - 96), 16)
$btnSave.Location  = New-Object System.Drawing.Point(($bottom.Width - 200), 16)
$btnClose.Add_Click({ $form.Close() })
$btnSave.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $dlg.FileName = Get-Date -Format 'yyyyMMdd_HHmm'
    $dlg.DefaultExt = 'txt'
    $dlg.Filter = '텍스트 (*.txt)|*.txt|모든 파일 (*.*)|*.*'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        # 마크다운 기호(##, **)는 txt 에서 지저분하므로 걷어낸다
        $body = ($script:raw -replace '(?m)^#+\s*', '■ ') -replace '\*\*', ''
        $doc = "Claude Code 세션 리뷰`r`n프로젝트: $cwd`r`n시간: $($startedAt.ToString('yyyy-MM-dd HH:mm')) ~ $($endedAt.ToString('HH:mm'))`r`n질문 수: $promptCount`r`n`r`n" + ($body -replace "`r?`n", "`r`n")
        [IO.File]::WriteAllText($dlg.FileName, $doc, (New-Object Text.UTF8Encoding $false))
        $lblStatus.Text = "저장됨: $($dlg.FileName)"
    }
})
$bottom.Controls.AddRange(@($lblStatus, $btnSave, $btnClose))

# Dock 순서: Fill 을 먼저 추가해야 Top/Bottom 이 공간을 먼저 차지한다
$form.Controls.Add($card)
$form.Controls.Add($top)
$form.Controls.Add($bottom)

Add-Text "분석 중입니다…`n" $F.Section $TextMain
Add-Text "대화 기록을 읽고 요약하고 있어요. 보통 30초~1분 걸립니다." $F.Body $TextDim

$t0 = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    $sec = [int]((Get-Date) - $t0).TotalSeconds
    $timedOut = $sec -gt $TimeoutSec
    if ($job.State -eq 'Running' -and -not $timedOut) { $lblStatus.Text = "분석 중… ${sec}초"; return }
    $timer.Stop()
    $out = if ($timedOut) { Stop-Job $job; "## 오류`n- 분석 시간이 초과되었습니다 (${TimeoutSec}초)." } else { (Receive-Job $job | Out-String).Trim() }
    if (-not $out) { $out = "## 오류`n- 분석 결과가 비어 있습니다. 터미널에서 claude -p 가 동작하는지 확인하세요." }
    $script:raw = $out
    Show-Review $out
    $lblStatus.Text = "분석 완료 (${sec}초 · $Model)"
    $btnSave.Enabled = $true
    $btnSave.BackColor = & $c $Accent; $btnSave.FlatAppearance.BorderColor = & $c $Accent
})
# -WindowStyle Hidden 으로 시작된 프로세스는 첫 ShowWindow 호출이 '숨김'으로 바뀌므로, 한 번 더 Show 해서 보이게 한다
# 터미널이 닫힌 뒤에도 앞에 보이도록 한 번 끌어올린다
$form.Add_Shown({ $form.Hide(); $form.Show(); $form.TopMost = $true; $form.Activate(); $form.TopMost = $false; $timer.Start() })
$form.Add_FormClosed({ Remove-Job $job -Force -ErrorAction SilentlyContinue })

[System.Windows.Forms.Application]::Run($form)

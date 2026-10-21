<#
.SYNOPSIS
  MailHawk - Inbox triage GUI
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Grok', 'GenAi')]
    [string]$Profile = 'Auto',
    [ValidateSet('COM', 'Graph')]
    [string]$Provider = 'COM',
    [switch]$ConsoleOnly,
    [int]$MaxEmails = 40,
    [int]$DaysBack = 14
)

# Continue by default so UI event code does not become unhandled WinForms dialogs
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }

# Force STA for WinForms
if (-not $ConsoleOnly) {
    $apt = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apt -ne 'STA') {
        Write-Host "[!] ApartmentState=$apt - re-launching under powershell.exe -STA ..." -ForegroundColor Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoLogo', '-STA', '-File', $MyInvocation.MyCommand.Path)
        if ($Profile) { $argList += @('-Profile', $Profile) }
        if ($Provider) { $argList += @('-Provider', $Provider) }
        if ($MaxEmails) { $argList += @('-MaxEmails', $MaxEmails) }
        if ($DaysBack) { $argList += @('-DaysBack', $DaysBack) }
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $Root -PassThru -Wait
        exit $p.ExitCode
    }
}

# --- env ---
$envFile = Join-Path $Root 'Config\mailhawk.env'
if (Test-Path -LiteralPath $envFile) {
    Get-Content -LiteralPath $envFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -match '^\s*#' -or $line -eq '') { return }
        if ($line -match '^\s*([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim().Trim('"').Trim("'")
            if ($k) { Set-Item -Path "Env:$k" -Value $v -Force }
        }
    }
    Write-Host 'Loaded Config\mailhawk.env' -ForegroundColor DarkGray
}
if ($env:MAILHAWK_LLM_PROFILE -and $Profile -eq 'Auto') { $Profile = $env:MAILHAWK_LLM_PROFILE }
if ($env:MAILHAWK_PROVIDER) { $Provider = $env:MAILHAWK_PROVIDER }

# --- modules ---
. (Join-Path $Root 'Private\ArcBridge.ps1')
. (Join-Path $Root 'Private\MailHawkLogging.ps1')
. (Join-Path $Root 'Private\MailHawkLlm.ps1')
. (Join-Path $Root 'Private\MailHawkStore.ps1')
. (Join-Path $Root 'Private\Get-OutlookMailSummary.ps1')
. (Join-Path $Root 'Private\MailHawkGraph.ps1')
. (Join-Path $Root 'Private\MailHawkDraft.ps1')
. (Join-Path $Root 'Public\Invoke-MailHawkInboxAnalysis.ps1')

Write-Host '[*] MailHawk modules loaded' -ForegroundColor DarkGray
Write-MailHawkLog -Level INFO -Message 'MailHawk GUI/console starting' -Root $Root

function ConvertTo-MailHawkAscii {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, '[^\x09\x0A\x0D\x20-\x7E]', '')
}

function Save-MailHawkReport {
    param([string]$Text)
    $logDir = Join-Path $Root 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Join-Path $logDir "MailHawkReport_$stamp.md"
    $clean = ConvertTo-MailHawkAscii -Text $Text
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $clean, $utf8NoBom)
    return $path
}

# ========================= CONSOLE =========================
if ($ConsoleOnly) {
    Write-Host ''
    Write-Host '=== MailHawk (Console) ===' -ForegroundColor Cyan
    $result = Invoke-MailHawkInboxAnalysis -Profile $Profile -Provider $Provider -MaxEmails $MaxEmails -DaysBack $DaysBack -Root $Root
    if (-not $result.Success) {
        Write-Host $result.Message -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host (ConvertTo-MailHawkAscii $result.Report)
    Write-Host ''
    Write-Host '--- Must Reply ---' -ForegroundColor Cyan
    $result.MustReply | Format-Table Index, Urgency, From, Subject -AutoSize
    $saved = Save-MailHawkReport -Text $result.Report
    Write-Host "Report saved: $saved" -ForegroundColor DarkGray
    return
}

# ========================= GUI =========================
Write-Host '[*] Starting GUI (WinForms)...' -ForegroundColor Cyan
Write-Host ("    ApartmentState={0}" -f [System.Threading.Thread]::CurrentThread.GetApartmentState()) -ForegroundColor DarkGray

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

# C# UI exception guard - does NOT use PowerShell scriptblocks (those caused the loop)
$logDir = Join-Path $Root 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$uiErrorLog = Join-Path $logDir 'mailhawk-error.log'
try {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Windows.Forms;
public static class MailHawkUiGuard {
    public static string LogPath;
    private static bool _armed;
    public static void Arm(string path) {
        if (_armed) return;
        _armed = true;
        LogPath = path;
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += OnThreadException;
        AppDomain.CurrentDomain.UnhandledException += OnDomainException;
    }
    private static void OnThreadException(object sender, System.Threading.ThreadExceptionEventArgs e) {
        Log("UI-THREAD", e.Exception);
    }
    private static void OnDomainException(object sender, UnhandledExceptionEventArgs e) {
        Log("DOMAIN", e.ExceptionObject as Exception);
    }
    private static void Log(string kind, Exception ex) {
        try {
            string msg = (ex != null) ? ex.ToString() : "(null exception)";
            string block = DateTime.Now.ToString("o") + " [" + kind + "]`r`n" + msg + "`r`n`r`n";
            if (!string.IsNullOrEmpty(LogPath)) {
                File.AppendAllText(LogPath, block);
            }
            MessageBox.Show(
                (ex != null ? ex.Message : "Unknown error") + "\n\nLogged to mailhawk-error.log",
                "MailHawk",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        } catch { }
    }
}
"@ -ReferencedAssemblies System.Windows.Forms.dll, System.Drawing.dll
    [MailHawkUiGuard]::Arm($uiErrorLog)
    Write-Host '[*] UI exception guard armed' -ForegroundColor DarkGray
} catch {
    Write-Host "[!] UI guard not armed: $($_.Exception.Message)" -ForegroundColor Yellow
}

$script:LastResult = $null
$script:CurrentDraftEntryID = $null
$script:Store = $null
try {
    $script:Store = Get-MailHawkStore -Root $Root
} catch {
    Write-Host "[!] Store load failed: $($_.Exception.Message)" -ForegroundColor Yellow
    $script:Store = [pscustomobject]@{ Version = 1; Dismissals = @(); Checklist = @() }
}

Write-Host '[*] Building window...' -ForegroundColor DarkGray

$form = New-Object System.Windows.Forms.Form
$form.Text = 'MailHawk'
$form.Width = 1200
$form.Height = 820
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.0)

# Toolbar
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = [System.Windows.Forms.DockStyle]::Top
$panelTop.Height = 48
$panelTop.BackColor = [System.Drawing.Color]::FromArgb(0, 99, 177)
$form.Controls.Add($panelTop)

$btnAnalyze = New-Object System.Windows.Forms.Button
$btnAnalyze.Text = 'Analyze Inbox'
$btnAnalyze.SetBounds(10, 10, 120, 28)
$btnAnalyze.BackColor = [System.Drawing.Color]::White
$panelTop.Controls.Add($btnAnalyze)

$lblProf = New-Object System.Windows.Forms.Label
$lblProf.Text = 'LLM:'
$lblProf.ForeColor = [System.Drawing.Color]::White
$lblProf.SetBounds(145, 14, 40, 20)
$panelTop.Controls.Add($lblProf)

$cmbProfile = New-Object System.Windows.Forms.ComboBox
$cmbProfile.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cmbProfile.Items.Add('Auto')
[void]$cmbProfile.Items.Add('GenAi')
[void]$cmbProfile.Items.Add('Grok')
$cmbProfile.SelectedIndex = 0
try {
    $idx = $cmbProfile.Items.IndexOf($Profile)
    if ($idx -ge 0) { $cmbProfile.SelectedIndex = $idx }
} catch {}
$cmbProfile.SetBounds(185, 11, 80, 24)
$panelTop.Controls.Add($cmbProfile)

$lblProv = New-Object System.Windows.Forms.Label
$lblProv.Text = 'Provider:'
$lblProv.ForeColor = [System.Drawing.Color]::White
$lblProv.SetBounds(280, 14, 60, 20)
$panelTop.Controls.Add($lblProv)

$cmbProvider = New-Object System.Windows.Forms.ComboBox
$cmbProvider.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cmbProvider.Items.Add('COM')
[void]$cmbProvider.Items.Add('Graph')
$cmbProvider.SelectedIndex = 0
try {
    $idx = $cmbProvider.Items.IndexOf($Provider)
    if ($idx -ge 0) { $cmbProvider.SelectedIndex = $idx }
} catch {}
$cmbProvider.SetBounds(345, 11, 70, 24)
$panelTop.Controls.Add($cmbProvider)

$lblMax = New-Object System.Windows.Forms.Label
$lblMax.Text = 'Max:'
$lblMax.ForeColor = [System.Drawing.Color]::White
$lblMax.SetBounds(430, 14, 40, 20)
$panelTop.Controls.Add($lblMax)

$numMax = New-Object System.Windows.Forms.NumericUpDown
$numMax.Minimum = 5
$numMax.Maximum = 100
$numMax.Value = [decimal]$MaxEmails
$numMax.SetBounds(470, 11, 50, 24)
$panelTop.Controls.Add($numMax)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Ready'
$lblStatus.ForeColor = [System.Drawing.Color]::White
$lblStatus.SetBounds(540, 14, 400, 20)
$panelTop.Controls.Add($lblStatus)

# Status strip first (dock bottom) before Fill content
$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$statusLabel.Text = 'Ready - click Analyze Inbox'
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)

# Tab control
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$form.Controls.Add($tabs)

$tabReport = New-Object System.Windows.Forms.TabPage
$tabReport.Text = 'Report'
$tabs.TabPages.Add($tabReport)

$tabCheck = New-Object System.Windows.Forms.TabPage
$tabCheck.Text = 'Checklist'
$tabs.TabPages.Add($tabCheck)

$tabDraft = New-Object System.Windows.Forms.TabPage
$tabDraft.Text = 'Draft'
$tabs.TabPages.Add($tabDraft)

$tabDismiss = New-Object System.Windows.Forms.TabPage
$tabDismiss.Text = 'Dismissals'
$tabs.TabPages.Add($tabDismiss)

# Report
$txtReport = New-Object System.Windows.Forms.TextBox
$txtReport.Multiline = $true
$txtReport.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$txtReport.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtReport.Font = New-Object System.Drawing.Font('Consolas', 10.0)
$txtReport.ReadOnly = $true
$txtReport.WordWrap = $true
$txtReport.Text = "Click 'Analyze Inbox' to begin.`r`n`r`nTabs: Report | Checklist | Draft | Dismissals"
$tabReport.Controls.Add($txtReport)

# Checklist
$panelCheckBtns = New-Object System.Windows.Forms.Panel
$panelCheckBtns.Dock = [System.Windows.Forms.DockStyle]::Top
$panelCheckBtns.Height = 40
$tabCheck.Controls.Add($panelCheckBtns)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Text = 'Open in Outlook'
$btnOpen.SetBounds(8, 6, 120, 28)
$panelCheckBtns.Controls.Add($btnOpen)

$btnDraftSel = New-Object System.Windows.Forms.Button
$btnDraftSel.Text = 'Draft Reply'
$btnDraftSel.SetBounds(135, 6, 100, 28)
$panelCheckBtns.Controls.Add($btnDraftSel)

$btnDone = New-Object System.Windows.Forms.Button
$btnDone.Text = 'Mark Done'
$btnDone.SetBounds(245, 6, 100, 28)
$panelCheckBtns.Controls.Add($btnDone)

$btnDismiss = New-Object System.Windows.Forms.Button
$btnDismiss.Text = 'False Positive / Dismiss'
$btnDismiss.SetBounds(355, 6, 160, 28)
$btnDismiss.BackColor = [System.Drawing.Color]::FromArgb(180, 80, 40)
$btnDismiss.ForeColor = [System.Drawing.Color]::White
$panelCheckBtns.Controls.Add($btnDismiss)

$btnRefreshCheck = New-Object System.Windows.Forms.Button
$btnRefreshCheck.Text = 'Refresh'
$btnRefreshCheck.SetBounds(530, 6, 80, 28)
$panelCheckBtns.Controls.Add($btnRefreshCheck)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = [System.Windows.Forms.DockStyle]::Fill
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$grid.RowHeadersVisible = $false
$grid.AutoGenerateColumns = $false
# Explicit columns (avoids DataTable binding quirks in PS)
foreach ($pair in @(
    @('Status', 80),
    @('Urgency', 70),
    @('From', 120),
    @('Subject', 240),
    @('Why', 200),
    @('Key', 40),
    @('EntryID', 40)
)) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $pair[0]
    $col.HeaderText = $pair[0]
    $col.DataPropertyName = $pair[0]
    $col.MinimumWidth = [int]$pair[1]
    if ($pair[0] -eq 'Key' -or $pair[0] -eq 'EntryID') { $col.Visible = $false }
    [void]$grid.Columns.Add($col)
}
$tabCheck.Controls.Add($grid)

# Draft
$txtDraftMeta = New-Object System.Windows.Forms.Label
$txtDraftMeta.Dock = [System.Windows.Forms.DockStyle]::Top
$txtDraftMeta.Height = 32
$txtDraftMeta.Text = 'Select an item on Checklist, then click Draft Reply.'
$tabDraft.Controls.Add($txtDraftMeta)

$panelDraftBtns = New-Object System.Windows.Forms.Panel
$panelDraftBtns.Dock = [System.Windows.Forms.DockStyle]::Bottom
$panelDraftBtns.Height = 44
$tabDraft.Controls.Add($panelDraftBtns)

$btnCopyDraft = New-Object System.Windows.Forms.Button
$btnCopyDraft.Text = 'Copy to Clipboard'
$btnCopyDraft.SetBounds(8, 8, 140, 28)
$panelDraftBtns.Controls.Add($btnCopyDraft)

$btnOpenDraft = New-Object System.Windows.Forms.Button
$btnOpenDraft.Text = 'Open as Outlook Reply'
$btnOpenDraft.SetBounds(160, 8, 160, 28)
$btnOpenDraft.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnOpenDraft.ForeColor = [System.Drawing.Color]::White
$panelDraftBtns.Controls.Add($btnOpenDraft)

$txtDraft = New-Object System.Windows.Forms.TextBox
$txtDraft.Multiline = $true
$txtDraft.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtDraft.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtDraft.Font = New-Object System.Drawing.Font('Segoe UI', 10.0)
$tabDraft.Controls.Add($txtDraft)

# Dismissals
$lblDismissHelp = New-Object System.Windows.Forms.Label
$lblDismissHelp.Dock = [System.Windows.Forms.DockStyle]::Top
$lblDismissHelp.Height = 36
$lblDismissHelp.Text = 'False positives / no-action items. Excluded from future Must Reply.'
$tabDismiss.Controls.Add($lblDismissHelp)

$gridDismiss = New-Object System.Windows.Forms.DataGridView
$gridDismiss.Dock = [System.Windows.Forms.DockStyle]::Fill
$gridDismiss.ReadOnly = $true
$gridDismiss.AllowUserToAddRows = $false
$gridDismiss.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$gridDismiss.MultiSelect = $false
$gridDismiss.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$gridDismiss.RowHeadersVisible = $false
$gridDismiss.AutoGenerateColumns = $false
foreach ($name in @('Subject', 'From', 'Reason', 'DismissedAt', 'Key')) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $name
    $col.HeaderText = $name
    $col.DataPropertyName = $name
    if ($name -eq 'Key') { $col.Visible = $false }
    [void]$gridDismiss.Columns.Add($col)
}
$tabDismiss.Controls.Add($gridDismiss)

function Safe-Status {
    param([string]$Text)
    try { $script:statusLabelRef.Text = $Text } catch {}
    try { $script:lblStatusRef.Text = $Text } catch {}
}

$script:statusLabelRef = $statusLabel
$script:lblStatusRef = $lblStatus

function Refresh-ChecklistGrid {
    try {
        $script:Store = Get-MailHawkStore -Root $Root
        $grid.Rows.Clear()
        $count = 0
        foreach ($r in @($script:Store.Checklist)) {
            if ($null -eq $r) { continue }
            $status = ''
            $urg = ''
            $from = ''
            $subj = ''
            $why = ''
            $key = ''
            $eid = ''
            try { if ($null -ne $r.Status)  { $status = [string]$r.Status } } catch {}
            try { if ($null -ne $r.Urgency) { $urg = [string]$r.Urgency } } catch {}
            try { if ($null -ne $r.From)    { $from = [string]$r.From } } catch {}
            try { if ($null -ne $r.Subject) { $subj = [string]$r.Subject } } catch {}
            try { if ($null -ne $r.Why)     { $why = [string]$r.Why } } catch {}
            try { if ($null -ne $r.Key)     { $key = [string]$r.Key } } catch {}
            try { if ($null -ne $r.EntryID) { $eid = [string]$r.EntryID } } catch {}
            [void]$grid.Rows.Add($status, $urg, $from, $subj, $why, $key, $eid)
            $count++
        }
        Write-MailHawkLog -Level DEBUG -Message ("Checklist grid rows={0}" -f $count) -Root $Root
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'Refresh-ChecklistGrid' -Root $Root } catch {}
        Safe-Status "Checklist refresh error: $($_.Exception.Message)"
    }
}

function Refresh-DismissGrid {
    try {
        $script:Store = Get-MailHawkStore -Root $Root
        $gridDismiss.Rows.Clear()
        foreach ($d in @($script:Store.Dismissals)) {
            if ($null -eq $d) { continue }
            $subj = ''; $from = ''; $reason = ''; $at = ''; $key = ''
            try { if ($null -ne $d.Subject)     { $subj = [string]$d.Subject } } catch {}
            try { if ($null -ne $d.From)        { $from = [string]$d.From } } catch {}
            try { if ($null -ne $d.Reason)      { $reason = [string]$d.Reason } } catch {}
            try { if ($null -ne $d.DismissedAt) { $at = [string]$d.DismissedAt } } catch {}
            try { if ($null -ne $d.Key)         { $key = [string]$d.Key } } catch {}
            [void]$gridDismiss.Rows.Add($subj, $from, $reason, $at, $key)
        }
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'Refresh-DismissGrid' -Root $Root } catch {}
    }
}

function Get-SelectedChecklistRow {
    try {
        if ($grid.SelectedRows.Count -lt 1) { return $null }
        $row = $grid.SelectedRows[0]
        if ($null -eq $row) { return $null }
        $get = {
            param($r, $i)
            try {
                if ($null -eq $r.Cells -or $r.Cells.Count -le $i) { return '' }
                $v = $r.Cells[$i].Value
                if ($null -eq $v) { return '' }
                return [string]$v
            } catch { return '' }
        }
        return [pscustomobject]@{
            Status  = & $get $row 0
            Urgency = & $get $row 1
            From    = & $get $row 2
            Subject = & $get $row 3
            Why     = & $get $row 4
            Key     = & $get $row 5
            EntryID = & $get $row 6
        }
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'Get-SelectedChecklistRow' -Root $Root } catch {}
        return $null
    }
}

$btnAnalyze.Add_Click({
    try {
        $btnAnalyze.Enabled = $false
        Safe-Status 'Working...'
        $txtReport.Text = "Collecting Outlook data and calling AI...`r`nThis may take 30-90 seconds."
        $tabs.SelectedTab = $tabReport
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        Write-MailHawkLog -Level INFO -Message 'Analyze button clicked' -Root $Root

        $selectedProfile = 'Auto'
        try { if ($cmbProfile.SelectedItem) { $selectedProfile = [string]$cmbProfile.SelectedItem } } catch {}
        $selectedProvider = 'COM'
        try { if ($cmbProvider.SelectedItem) { $selectedProvider = [string]$cmbProvider.SelectedItem } } catch {}
        $max = 40
        try { $max = [int]$numMax.Value } catch {}

        $result = Invoke-MailHawkInboxAnalysis -Profile $selectedProfile -Provider $selectedProvider -MaxEmails $max -DaysBack $DaysBack -Root $Root
        $script:LastResult = $result
        if ($null -ne $result.Store) { $script:Store = $result.Store }

        $reportLen = 0
        try { if ($result.Report) { $reportLen = $result.Report.Length } } catch {}
        $mrCount = 0
        try { $mrCount = @($result.MustReply).Count } catch {}
        Write-MailHawkLog -Level INFO -Message ("Analyze returned Success={0} ReportLen={1} MustReply={2}" -f $result.Success, $reportLen, $mrCount) -Root $Root

        if (-not $result.Success) {
            $txtReport.Text = [string]$result.Message
            Safe-Status 'No emails'
        } else {
            $header = @"
MailHawk Report
Generated : $($result.GeneratedAt)
Profile   : $($result.Profile)  |  Model: $($result.Model)  |  Provider: $($result.Provider)
Analyzed  : $($result.AnalyzedCount) emails
Skipped   : $($result.SkippedCount) (sensitive heuristic)
Dismissed : $($result.DismissedCount) (user false-positive / no-action)
Must-reply extracted: $mrCount

================================================================================

"@
            $body = ''
            try { $body = [string]$result.Report } catch {}
            $body = ($body -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
            $full = ConvertTo-MailHawkAscii ($header + $body)
            $txtReport.Text = $full
            try {
                $txtReport.SelectionStart = 0
                $txtReport.ScrollToCaret()
            } catch {}
            $saved = Save-MailHawkReport -Text $full
            Safe-Status "Done - saved $saved | Must-reply: $mrCount"
            Refresh-ChecklistGrid
            Refresh-DismissGrid
            if ($mrCount -gt 0) {
                $tabs.SelectedTab = $tabCheck
            } else {
                $tabs.SelectedTab = $tabReport
            }
        }
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'AnalyzeInbox' -Root $Root } catch {}
        $txtReport.Text = "ERROR:`r`n$($_.Exception.Message)`r`n`r`nSee Logs\mailhawk-error.log"
        $tabs.SelectedTab = $tabReport
        Safe-Status 'Error'
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "Analyze failed:`n$($_.Exception.Message)`n`nDetails: Logs\mailhawk-error.log",
                'MailHawk Error')
        } catch {}
    } finally {
        try { $btnAnalyze.Enabled = $true } catch {}
    }
})

$btnOpen.Add_Click({
    try {
        $sel = Get-SelectedChecklistRow
        if ($null -eq $sel) {
            [System.Windows.Forms.MessageBox]::Show('Select a checklist row first.')
            return
        }
        if ([string]::IsNullOrWhiteSpace($sel.EntryID)) {
            [System.Windows.Forms.MessageBox]::Show('No EntryID for this item.')
            return
        }
        Open-MailHawkMailItem -EntryID $sel.EntryID
        Safe-Status "Opened: $($sel.Subject)"
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'OpenMail' -Root $Root } catch {}
        [System.Windows.Forms.MessageBox]::Show("Open failed: $($_.Exception.Message)")
    }
})

$btnDraftSel.Add_Click({
    try {
        $sel = Get-SelectedChecklistRow
        if ($null -eq $sel) {
            [System.Windows.Forms.MessageBox]::Show('Select a checklist row first.')
            return
        }
        $email = $null
        if ($script:LastResult -and $script:LastResult.Summary -and $script:LastResult.Summary.Emails) {
            $email = @(
                $script:LastResult.Summary.Emails |
                    Where-Object { $_.Fingerprint -eq $sel.Key -or $_.EntryID -eq $sel.EntryID }
            ) | Select-Object -First 1
        }
        if (-not $email) {
            $email = [pscustomobject]@{
                EntryID     = $sel.EntryID
                FromName    = $sel.From
                FromEmail   = ''
                Received    = ''
                Subject     = $sel.Subject
                BodyPreview = $sel.Why
            }
        }
        Safe-Status 'Drafting...'
        $form.Refresh()
        $prof = 'Auto'
        try { if ($cmbProfile.SelectedItem) { $prof = [string]$cmbProfile.SelectedItem } } catch {}
        $draft = New-MailHawkDraftReply -Email $email -Profile $prof
        $txtDraft.Text = [string]$draft.Draft
        $txtDraftMeta.Text = "Draft for: $($sel.Subject)  |  From: $($sel.From)"
        $script:CurrentDraftEntryID = $sel.EntryID
        $tabs.SelectedTab = $tabDraft
        Safe-Status 'Draft ready'
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'DraftReply' -Root $Root } catch {}
        [System.Windows.Forms.MessageBox]::Show("Draft failed: $($_.Exception.Message)")
        Safe-Status 'Draft error'
    }
})

$btnDone.Add_Click({
    try {
        $sel = Get-SelectedChecklistRow
        if ($null -eq $sel -or [string]::IsNullOrWhiteSpace($sel.Key)) { return }
        $script:Store = Set-MailHawkChecklistStatus -Store $script:Store -Key $sel.Key -Status 'done' -Root $Root
        Refresh-ChecklistGrid
        Safe-Status "Marked done: $($sel.Subject)"
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'MarkDone' -Root $Root } catch {}
        [System.Windows.Forms.MessageBox]::Show("Mark done failed: $($_.Exception.Message)")
    }
})

$btnDismiss.Add_Click({
    try {
        $sel = Get-SelectedChecklistRow
        if ($null -eq $sel -or [string]::IsNullOrWhiteSpace($sel.Key)) {
            [System.Windows.Forms.MessageBox]::Show('Select a checklist row first.')
            return
        }
        $reason = 'false positive / no action needed'
        try {
            $input = [Microsoft.VisualBasic.Interaction]::InputBox(
                'Why dismiss this item?', 'False Positive / Dismiss', $reason)
            if (-not [string]::IsNullOrWhiteSpace($input)) { $reason = $input }
        } catch {}
        $script:Store = Add-MailHawkDismissal -Store $script:Store -Key $sel.Key -Subject $sel.Subject -From $sel.From -Reason $reason -Root $Root
        $script:Store = Set-MailHawkChecklistStatus -Store $script:Store -Key $sel.Key -Status 'dismissed' -Notes $reason -Root $Root
        Refresh-ChecklistGrid
        Refresh-DismissGrid
        Safe-Status "Dismissed: $($sel.Subject)"
        [System.Windows.Forms.MessageBox]::Show(
            "Dismissed. Future runs will treat this as no-action.`n`nReason: $reason",
            'MailHawk')
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'Dismiss' -Root $Root } catch {}
        [System.Windows.Forms.MessageBox]::Show("Dismiss failed: $($_.Exception.Message)")
    }
})

$btnRefreshCheck.Add_Click({
    try { Refresh-ChecklistGrid; Refresh-DismissGrid } catch {}
})

$btnCopyDraft.Add_Click({
    try {
        if ($txtDraft.Text) {
            [System.Windows.Forms.Clipboard]::SetText($txtDraft.Text)
            Safe-Status 'Draft copied'
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Copy failed: $($_.Exception.Message)")
    }
})

$btnOpenDraft.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($script:CurrentDraftEntryID)) {
            [System.Windows.Forms.MessageBox]::Show('Draft from Checklist first.')
            return
        }
        $prov = 'COM'
        try { if ($cmbProvider.SelectedItem) { $prov = [string]$cmbProvider.SelectedItem } } catch {}
        if ($prov -eq 'Graph') {
            [System.Windows.Forms.MessageBox]::Show('Open-as-reply requires COM provider.')
            return
        }
        New-MailHawkOutlookReplyDraft -EntryID $script:CurrentDraftEntryID -Body $txtDraft.Text -Display | Out-Null
        Safe-Status 'Outlook reply opened (not sent)'
    } catch {
        try { Write-MailHawkError -ErrorRecord $_ -Context 'OpenDraft' -Root $Root } catch {}
        [System.Windows.Forms.MessageBox]::Show("Could not create reply: $($_.Exception.Message)")
    }
})

Write-Host '[*] Refreshing checklist...' -ForegroundColor DarkGray
Refresh-ChecklistGrid
Refresh-DismissGrid
Write-Host '[*] Opening MailHawk window...' -ForegroundColor Green
Write-MailHawkLog -Level INFO -Message 'Showing main form' -Root $Root
try {
    $form.Add_Shown({
        try {
            $form.Activate()
            $form.BringToFront()
        } catch {}
    })
} catch {}
[void]$form.ShowDialog()
Write-Host '[*] Window closed.' -ForegroundColor DarkGray

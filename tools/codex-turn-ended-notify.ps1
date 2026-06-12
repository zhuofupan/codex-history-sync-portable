[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Title,
    [string]$Message,
    [string]$MessageBase64,
    [int]$Seconds = 12,
    [string]$ForwardBase64,
    [switch]$SelfTest,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function ConvertFrom-Utf8Base64 {
    param([Parameter(Mandatory)][string]$Value)

    return $utf8.GetString([Convert]::FromBase64String($Value))
}

function Shorten-Text {
    param(
        [AllowNull()][string]$Text,
        [int]$Max = 52
    )

    if ($null -eq $Text) { return '' }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -le $Max) { return $clean }
    return $clean.Substring(0, [Math]::Max(0, $Max - 1)) + '...'
}

function Get-PropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $Object) { return '' }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return ''
}

function Get-NestedPropertyValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    $direct = Get-PropertyValue -Object $Object -Names $Names
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return $direct }

    foreach ($childName in @('payload', 'event', 'data')) {
        $child = $null
        if ($Object -and $Object.PSObject.Properties[$childName]) {
            $child = $Object.PSObject.Properties[$childName].Value
        }
        $value = Get-PropertyValue -Object $child -Names $Names
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ''
}

function Get-NotifyMessageFromJsonObject {
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return '' }

    $provider = Get-NestedPropertyValue $Object @('model_provider', 'modelProvider', 'provider', 'account', 'accountName')
    $cwd = Get-NestedPropertyValue $Object @('cwd', 'working_directory', 'workingDirectory', 'workspace', 'directory')
    $thread = Get-NestedPropertyValue $Object @('thread_id', 'threadId', 'session_id', 'sessionId', 'conversation_id', 'conversationId', 'turn_id', 'turnId')
    $task = Get-NestedPropertyValue $Object @('last_user_message', 'lastUserMessage', 'user_message', 'userMessage', 'prompt', 'input', 'message', 'summary')

    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = ConvertFrom-Utf8Base64 '5pyq55+l6LSm5Y+3'
    }
    $cwdLabel = ''
    if (-not [string]::IsNullOrWhiteSpace($cwd)) {
        try { $cwdLabel = Split-Path -Leaf $cwd } catch { $cwdLabel = $cwd }
    }
    if ([string]::IsNullOrWhiteSpace($cwdLabel)) {
        $cwdLabel = ConvertFrom-Utf8Base64 '5pyq55+l55uu5b2V'
    }
    if ([string]::IsNullOrWhiteSpace($thread)) {
        $thread = ConvertFrom-Utf8Base64 '5b2T5YmN5Lya6K+d'
    }
    elseif ($thread.Length -gt 8) {
        $thread = $thread.Substring(0, 8)
    }
    if ([string]::IsNullOrWhiteSpace($task) -or $task.Trim().StartsWith('{')) {
        $task = ConvertFrom-Utf8Base64 '5b2T5YmN5Lu75Yqh5bey5a6M5oiQ'
    }

    $accountLabel = ConvertFrom-Utf8Base64 '6LSm5Y+377ya'
    $threadLabel = ConvertFrom-Utf8Base64 '6IGK5aSp77ya'
    $taskLabel = ConvertFrom-Utf8Base64 '5Lu75Yqh77ya'
    return "$accountLabel$(Shorten-Text $provider 18) | $(Shorten-Text $cwdLabel 24)`r`n$threadLabel$(Shorten-Text $thread 18)`r`n$taskLabel$(Shorten-Text $task 52)"
}

function Get-NotifyMessageFromArgs {
    param([AllowNull()][string[]]$Args)

    foreach ($arg in @($Args)) {
        if ([string]::IsNullOrWhiteSpace($arg)) { continue }
        $text = $arg.Trim()
        if (-not ($text.StartsWith('{') -or $text.StartsWith('['))) { continue }
        try {
            $obj = $text | ConvertFrom-Json
            $message = Get-NotifyMessageFromJsonObject $obj
            if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
        }
        catch {
            continue
        }
    }
    return ''
}

if ([string]::IsNullOrWhiteSpace($Title)) {
    $Title = ConvertFrom-Utf8Base64 'Q29kZXgg5Lya6K+d5bey57uT5p2f'
}
if (-not [string]::IsNullOrWhiteSpace($MessageBase64)) {
    $Message = ConvertFrom-Utf8Base64 $MessageBase64
}
elseif ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    $argMessage = Get-NotifyMessageFromArgs $RemainingArgs
    if (-not [string]::IsNullOrWhiteSpace($argMessage)) {
        $Message = $argMessage
    }
}
if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = ConvertFrom-Utf8Base64 'Q29kZXgg5bey5a6M5oiQ5b2T5YmN5Lya6K+d44CC'
}

function Invoke-ForwardNotify {
    param(
        [AllowNull()][string]$EncodedCommand,
        [AllowNull()][string[]]$ExtraArgs
    )

    if ([string]::IsNullOrWhiteSpace($EncodedCommand)) { return }

    try {
        $json = $utf8.GetString([Convert]::FromBase64String($EncodedCommand))
        $command = @($json | ConvertFrom-Json)
        if ($command.Count -eq 0) { return }

        $filePath = [string]$command[0]
        if ([string]::IsNullOrWhiteSpace($filePath)) { return }

        $arguments = @()
        if ($command.Count -gt 1) {
            for ($i = 1; $i -lt $command.Count; $i++) {
                $arguments += [string]$command[$i]
            }
        }
        foreach ($arg in @($ExtraArgs)) {
            if ($null -ne $arg) { $arguments += [string]$arg }
        }

        Start-Process -FilePath $filePath -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
    catch {
        return
    }
}

if ($SelfTest) {
    Write-Output 'Notifier SelfTest OK.'
    return
}

Invoke-ForwardNotify -EncodedCommand $ForwardBase64 -ExtraArgs $RemainingArgs

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class CodexNotifyNative {
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const int SW_SHOWNORMAL = 1;
    public const int SW_RESTORE = 9;
    public const UInt32 SWP_NOSIZE = 0x0001;
    public const UInt32 SWP_NOMOVE = 0x0002;
    public const UInt32 SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, UInt32 uFlags);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int nLeftRect, int nTopRect, int nRightRect, int nBottomRect, int nWidthEllipse, int nHeightEllipse);

    [DllImport("user32.dll")]
    public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

function Play-NotifySound {
    try {
        [System.Media.SystemSounds]::Asterisk.Play()
        Start-Sleep -Milliseconds 120
        [System.Media.SystemSounds]::Exclamation.Play()
        [Console]::Beep(880, 120)
        [Console]::Beep(1175, 160)
    }
    catch {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { return }
    }
}

$screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$width = 420
$height = 154
$margin = 18

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.StartPosition = 'Manual'
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Size = New-Object System.Drawing.Size($width, $height)
$form.Location = New-Object System.Drawing.Point(($screen.Right - $width - $margin), ($screen.Bottom - $height - $margin))
$form.BackColor = [System.Drawing.Color]::White

$accentPanel = New-Object System.Windows.Forms.Panel
$accentPanel.Location = New-Object System.Drawing.Point(0, 0)
$accentPanel.Size = New-Object System.Drawing.Size(7, $height)
$accentPanel.BackColor = [System.Drawing.Color]::FromArgb(34, 111, 245)
$form.Controls.Add($accentPanel)

$iconPanel = New-Object System.Windows.Forms.Panel
$iconPanel.Location = New-Object System.Drawing.Point(22, 22)
$iconPanel.Size = New-Object System.Drawing.Size(44, 44)
$iconPanel.BackColor = [System.Drawing.Color]::FromArgb(34, 111, 245)
$form.Controls.Add($iconPanel)

$iconLabel = New-Object System.Windows.Forms.Label
$iconLabel.Text = 'OK'
$iconLabel.ForeColor = [System.Drawing.Color]::White
$iconLabel.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$iconLabel.Location = New-Object System.Drawing.Point(0, 0)
$iconLabel.Size = New-Object System.Drawing.Size(44, 44)
$iconLabel.TextAlign = 'MiddleCenter'
$iconPanel.Controls.Add($iconLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = $Title
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(25, 31, 40)
$titleLabel.Location = New-Object System.Drawing.Point(78, 22)
$titleLabel.Size = New-Object System.Drawing.Size(($width - 118), 28)
$titleLabel.TextAlign = 'MiddleLeft'
$form.Controls.Add($titleLabel)

$messageLabel = New-Object System.Windows.Forms.Label
$messageLabel.Text = $Message
$messageLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$messageLabel.ForeColor = [System.Drawing.Color]::FromArgb(68, 76, 88)
$messageLabel.Location = New-Object System.Drawing.Point(80, 50)
$messageLabel.Size = New-Object System.Drawing.Size(($width - 104), 62)
$messageLabel.TextAlign = 'TopLeft'
$form.Controls.Add($messageLabel)

$topLine = New-Object System.Windows.Forms.Panel
$topLine.Location = New-Object System.Drawing.Point(7, 0)
$topLine.Size = New-Object System.Drawing.Size(($width - 7), 1)
$topLine.BackColor = [System.Drawing.Color]::FromArgb(229, 234, 242)
$form.Controls.Add($topLine)

$bottomLine = New-Object System.Windows.Forms.Panel
$bottomLine.Location = New-Object System.Drawing.Point(7, ($height - 1))
$bottomLine.Size = New-Object System.Drawing.Size(($width - 7), 1)
$bottomLine.BackColor = [System.Drawing.Color]::FromArgb(229, 234, 242)
$form.Controls.Add($bottomLine)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = ConvertFrom-Utf8Base64 '55+l6YGT5LqG'
$closeButton.Location = New-Object System.Drawing.Point(($width - 98), 116)
$closeButton.Size = New-Object System.Drawing.Size(78, 26)
$closeButton.FlatStyle = 'Flat'
$closeButton.FlatAppearance.BorderSize = 0
$closeButton.BackColor = [System.Drawing.Color]::FromArgb(34, 111, 245)
$closeButton.ForeColor = [System.Drawing.Color]::White
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$closeX = New-Object System.Windows.Forms.Label
$closeX.Text = 'x'
$closeX.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$closeX.ForeColor = [System.Drawing.Color]::FromArgb(114, 124, 140)
$closeX.Location = New-Object System.Drawing.Point(($width - 30), 12)
$closeX.Size = New-Object System.Drawing.Size(18, 18)
$closeX.TextAlign = 'MiddleCenter'
$closeX.Cursor = [System.Windows.Forms.Cursors]::Hand
$closeX.Add_Click({ $form.Close() })
$form.Controls.Add($closeX)

$keepTopTimer = New-Object System.Windows.Forms.Timer
$keepTopTimer.Interval = 700
$keepTopTimer.Add_Tick({
        $form.TopMost = $true
        [void][CodexNotifyNative]::SetWindowPos(
            $form.Handle,
            [CodexNotifyNative]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [CodexNotifyNative]::SWP_NOMOVE -bor [CodexNotifyNative]::SWP_NOSIZE -bor [CodexNotifyNative]::SWP_SHOWWINDOW
        )
    })

$closeTimer = New-Object System.Windows.Forms.Timer
$closeTimer.Interval = [Math]::Max(3, $Seconds) * 1000
$closeTimer.Add_Tick({
        $closeTimer.Stop()
        $form.Close()
    })

$soundTimer = New-Object System.Windows.Forms.Timer
$soundTimer.Interval = 140
$soundTimer.Add_Tick({
        $soundTimer.Stop()
        Play-NotifySound
    })

$form.Add_Shown({
        $region = [CodexNotifyNative]::CreateRoundRectRgn(0, 0, $form.Width + 1, $form.Height + 1, 14, 14)
        [void][CodexNotifyNative]::SetWindowRgn($form.Handle, $region, $true)
        $form.TopMost = $true
        [void][CodexNotifyNative]::ShowWindow($form.Handle, [CodexNotifyNative]::SW_RESTORE)
        [void][CodexNotifyNative]::ShowWindow($form.Handle, [CodexNotifyNative]::SW_SHOWNORMAL)
        $form.Activate()
        [void][CodexNotifyNative]::SetForegroundWindow($form.Handle)
        [void][CodexNotifyNative]::SetWindowPos(
            $form.Handle,
            [CodexNotifyNative]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [CodexNotifyNative]::SWP_NOMOVE -bor [CodexNotifyNative]::SWP_NOSIZE -bor [CodexNotifyNative]::SWP_SHOWWINDOW
        )
        $keepTopTimer.Start()
        $closeTimer.Start()
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        $soundTimer.Start()
    })

$form.Add_FormClosed({
        $keepTopTimer.Stop()
        $closeTimer.Stop()
        $soundTimer.Stop()
        $keepTopTimer.Dispose()
        $closeTimer.Dispose()
        $soundTimer.Dispose()
        $form.Dispose()
    })

[void][System.Windows.Forms.Application]::Run($form)

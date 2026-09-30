# Modo Enfoque - bloqueador de distracciones para Windows
# Uso: doble clic en "Modo Enfoque.bat" (pide permisos de administrador).
# Mientras esta encendido:
#   - Chrome, Edge y Brave solo abren Gemini, WhatsApp Web, Drive/Docs, Meet y Zoom.
#   - Firefox, Opera, Steam, Discord, etc. se cierran solos apenas se abren.
#   - Se apaga automaticamente al llegar la fecha limite (por defecto, el sabado).
param([switch]$Watchdog)

$ErrorActionPreference = 'SilentlyContinue'

$InstallDir = Join-Path $env:ProgramData 'BloqueadorEnfoque'
$InstalledScript = Join-Path $InstallDir 'Bloqueador.ps1'
$ConfigFile = Join-Path $InstallDir 'config.json'
$TaskName = 'BloqueadorEnfoque'
$UnlockPhrase = 'QUIERO DISTRAERME'

# Sitios permitidos (incluye subdominios)
$Allowed = @(
    'gemini.google.com',
    'accounts.google.com', 'accounts.youtube.com', 'consent.google.com', 'ogs.google.com',
    'web.whatsapp.com',
    'drive.google.com', 'docs.google.com', 'drive.usercontent.google.com',
    'meet.google.com',
    'zoom.us', 'zoom.com',
    'about:blank'
)

# Programas que se cierran automaticamente (nombre del proceso, sin .exe)
$KillList = @(
    'firefox', 'opera', 'opera_gx', 'vivaldi', 'waterfox', 'librewolf', 'tor', 'iexplore', 'chromium', 'yandex', 'arc',
    'steam', 'steamwebhelper', 'EpicGamesLauncher', 'Battle.net', 'RiotClientServices', 'LeagueClient', 'GalaxyClient', 'EADesktop', 'XboxPcApp',
    'Discord', 'Telegram', 'Spotify', 'Netflix', 'TikTok', 'Instagram', 'Messenger', 'Twitch'
)

$Browsers = @(
    @{ Key = 'HKLM:\SOFTWARE\Policies\Google\Chrome';        Private = 'IncognitoModeAvailability' },
    @{ Key = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge';       Private = 'InPrivateModeAvailability' },
    @{ Key = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';  Private = 'IncognitoModeAvailability' }
)
$StartUrl = 'https://gemini.google.com/app'
$PolicyValues = @('RestoreOnStartup', 'HomepageLocation', 'NewTabPageLocation', 'HomepageIsNewTabPage', 'TorDisabled',
                  'IncognitoModeAvailability', 'InPrivateModeAvailability', 'BrowserGuestModeEnabled')
$PolicyLists = @('URLBlocklist', 'URLAllowlist', 'RestoreOnStartupURLs')

function Set-ListKey($path, [string[]]$items) {
    Remove-Item $path -Recurse -Force
    New-Item $path -Force | Out-Null
    for ($i = 0; $i -lt $items.Count; $i++) {
        New-ItemProperty $path -Name ($i + 1) -Value $items[$i] -PropertyType String -Force | Out-Null
    }
}

function Test-Policies {
    foreach ($b in $Browsers) {
        $block = Get-ItemProperty "$($b.Key)\URLBlocklist"
        if ($block.'1' -ne '*') { return $false }
    }
    return $true
}

function Set-Policies {
    foreach ($b in $Browsers) {
        New-Item $b.Key -Force | Out-Null
        Set-ListKey "$($b.Key)\URLBlocklist" @('*')
        Set-ListKey "$($b.Key)\URLAllowlist" $Allowed
        Set-ListKey "$($b.Key)\RestoreOnStartupURLs" @($StartUrl)
        New-ItemProperty $b.Key -Name 'RestoreOnStartup' -Value 4 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $b.Key -Name 'HomepageLocation' -Value $StartUrl -PropertyType String -Force | Out-Null
        New-ItemProperty $b.Key -Name 'NewTabPageLocation' -Value $StartUrl -PropertyType String -Force | Out-Null
        New-ItemProperty $b.Key -Name 'HomepageIsNewTabPage' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $b.Key -Name 'BrowserGuestModeEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $b.Key -Name $b.Private -Value 1 -PropertyType DWord -Force | Out-Null
        if ($b.Key -like '*Brave*') { New-ItemProperty $b.Key -Name 'TorDisabled' -Value 1 -PropertyType DWord -Force | Out-Null }
    }
}

function Remove-Policies {
    foreach ($b in $Browsers) {
        foreach ($l in $PolicyLists) { Remove-Item "$($b.Key)\$l" -Recurse -Force }
        foreach ($v in $PolicyValues) { Remove-ItemProperty $b.Key -Name $v -Force }
        # Borra la clave solo si quedo vacia (no toca politicas ajenas)
        $k = Get-Item $b.Key
        if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item $b.Key -Force }
    }
}

function Restart-Browsers {
    Get-Process -Name 'chrome', 'msedge', 'brave' | Stop-Process -Force
}

function Get-Config {
    if (Test-Path $ConfigFile) { return Get-Content $ConfigFile -Raw | ConvertFrom-Json }
    return $null
}

function Get-Deadline {
    $cfg = Get-Config
    if ($cfg) { return [datetime]::ParseExact($cfg.deadline, 's', $null) }
    return $null
}

function Test-Active {
    $d = Get-Deadline
    return ($d -and (Get-Date) -lt $d -and (Get-ScheduledTask -TaskName $TaskName))
}

$GeminiShortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Gemini.lnk'
$PanelShortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Modo Enfoque.lnk'

function New-Shortcut($path, $target, $arguments, $icon) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($path)
    $s.TargetPath = $target
    $s.Arguments = $arguments
    if ($icon) { $s.IconLocation = $icon }
    $s.Save()
}

function Disable-Block([switch]$FromWatchdog) {
    Remove-Policies
    Remove-Item $ConfigFile -Force
    Remove-Item $GeminiShortcut -Force
    Restart-Browsers
    if (-not $FromWatchdog) { Stop-ScheduledTask -TaskName $TaskName }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# ---------------------------------------------------------------- Watchdog (corre como SYSTEM)
if ($Watchdog) {
    $tick = 0
    while ($true) {
        $deadline = Get-Deadline
        if (-not $deadline -or (Get-Date) -ge $deadline) {
            Disable-Block -FromWatchdog
            break
        }
        if (($tick % 10) -eq 0 -and -not (Test-Policies)) {
            Set-Policies
            Restart-Browsers
        }
        Get-Process -Name $KillList | Stop-Process -Force
        $tick++
        Start-Sleep -Seconds 3
    }
    exit
}

# ---------------------------------------------------------------- Panel (GUI)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    exit
}

function Enable-Block([datetime]$deadline) {
    New-Item $InstallDir -ItemType Directory -Force | Out-Null
    if ($PSCommandPath -ne $InstalledScript) { Copy-Item $PSCommandPath $InstalledScript -Force }
    # Solo SYSTEM y administradores pueden modificar el script que corre como SYSTEM
    icacls $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
    @{ deadline = $deadline.ToString('s') } | ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8

    Set-Policies
    Restart-Browsers

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`" -Watchdog"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    $edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
    New-Shortcut $GeminiShortcut $edge "--app=$StartUrl" $null
    New-Shortcut $PanelShortcut 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstalledScript`"" "$env:SystemRoot\System32\shell32.dll,47"
}

function Get-NextSaturday {
    $d = (Get-Date).Date.AddDays(1)
    while ($d.DayOfWeek -ne [DayOfWeek]::Saturday) { $d = $d.AddDays(1) }
    return $d
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

$bg = [System.Drawing.Color]::FromArgb(17, 20, 24)
$fg = [System.Drawing.Color]::FromArgb(236, 238, 240)
$muted = [System.Drawing.Color]::FromArgb(150, 156, 164)
$green = [System.Drawing.Color]::FromArgb(46, 204, 113)
$red = [System.Drawing.Color]::FromArgb(231, 76, 60)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Modo Enfoque'
$form.Size = New-Object System.Drawing.Size(420, 470)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = $bg
$form.ForeColor = $fg
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Modo Enfoque'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$title.AutoSize = $false; $title.TextAlign = 'MiddleCenter'
$title.SetBounds(0, 18, 404, 44)
$form.Controls.Add($title)

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $false; $status.TextAlign = 'MiddleCenter'
$status.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$status.SetBounds(0, 62, 404, 26)
$form.Controls.Add($status)

$button = New-Object System.Windows.Forms.Button
$button.SetBounds(122, 100, 160, 160)
$button.FlatStyle = 'Flat'
$button.FlatAppearance.BorderSize = 0
$button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
$button.ForeColor = [System.Drawing.Color]::White
$button.Cursor = 'Hand'
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddEllipse(0, 0, 160, 160)
$button.Region = New-Object System.Drawing.Region($path)
$form.Controls.Add($button)

$countdown = New-Object System.Windows.Forms.Label
$countdown.AutoSize = $false; $countdown.TextAlign = 'MiddleCenter'
$countdown.Font = New-Object System.Drawing.Font('Consolas', 18)
$countdown.SetBounds(0, 272, 404, 34)
$form.Controls.Add($countdown)

$pickLabel = New-Object System.Windows.Forms.Label
$pickLabel.Text = 'Bloquear hasta:'
$pickLabel.ForeColor = $muted
$pickLabel.SetBounds(40, 318, 120, 24)
$form.Controls.Add($pickLabel)

$picker = New-Object System.Windows.Forms.DateTimePicker
$picker.Format = 'Custom'
$picker.CustomFormat = 'dddd dd/MM HH:mm'
$picker.SetBounds(160, 315, 200, 28)
$picker.Value = Get-NextSaturday
$form.Controls.Add($picker)

$info = New-Object System.Windows.Forms.Label
$info.Text = "Permitido: Gemini, WhatsApp, Drive, Meet y Zoom.`nEl resto de la web y los juegos quedan bloqueados."
$info.ForeColor = $muted
$info.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$info.AutoSize = $false; $info.TextAlign = 'MiddleCenter'
$info.SetBounds(0, 360, 404, 50)
$form.Controls.Add($info)

function Update-State {
    $script:deadline = if (Test-Active) { Get-Deadline } else { $null }
}

function Update-View {
    if ($script:deadline -and (Get-Date) -ge $script:deadline) { $script:deadline = $null }
    if ($script:deadline) {
        $left = $script:deadline - (Get-Date)
        $status.Text = 'ENCENDIDO - hasta el ' + $script:deadline.ToString('dddd dd/MM HH:mm')
        $status.ForeColor = $green
        $button.Text = 'APAGAR'
        $button.BackColor = $red
        $countdown.Text = '{0}d {1:00}:{2:00}:{3:00}' -f $left.Days, $left.Hours, $left.Minutes, $left.Seconds
        $picker.Enabled = $false
    } else {
        $status.Text = 'APAGADO'
        $status.ForeColor = $muted
        $button.Text = 'ENCENDER'
        $button.BackColor = $green
        $countdown.Text = '--'
        $picker.Enabled = $true
    }
}

$button.Add_Click({
    Update-State
    if ($script:deadline) {
        $answer = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Todavia no es la fecha. Si de verdad queres apagarlo, escribi:`n`n$UnlockPhrase", 'Apagar Modo Enfoque', '')
        if ($answer -ceq $UnlockPhrase) { Disable-Block }
    } else {
        if ($picker.Value -le (Get-Date)) {
            [System.Windows.Forms.MessageBox]::Show('Elegi una fecha en el futuro.', 'Modo Enfoque') | Out-Null
            return
        }
        $ok = [System.Windows.Forms.MessageBox]::Show(
            "Se van a cerrar Chrome, Edge y Brave y quedan bloqueados hasta el $($picker.Value.ToString('dddd dd/MM HH:mm')).`n`nGuarda lo que tengas abierto. Seguimos?",
            'Encender Modo Enfoque', 'YesNo', 'Question')
        if ($ok -eq 'Yes') { Enable-Block $picker.Value }
    }
    Update-State
    Update-View
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Update-View })
$timer.Start()

Update-State
Update-View
[void]$form.ShowDialog()

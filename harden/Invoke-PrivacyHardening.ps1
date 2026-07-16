<#
.SYNOPSIS
    Privacy / de-bloat hardening for a Windows 11 DEVELOPER box (VM or the Acer). Runs either
    standalone (elevated, for testing) or automatically at install time via SetupComplete.cmd
    (as SYSTEM, before first logon - the ideal moment for machine-wide + Default-user settings).

.DESCRIPTION
    Every change is grouped and gated by a toggle in $H below - flip one to $false to skip that
    category. Nothing here is hidden; read the toggle table and you know exactly what runs.

    DESIGN RULES (this is a DEV box, not a kiosk):
      * KEEP working: Windows Update, Microsoft Defender, Remote Desktop, Time service, winget /
        App Installer, the Store, Windows Terminal, WebView2, and the VCLibs / UI.Xaml / .NET
        framework packages. The appx debloat has an explicit KEEP guard so these can never be
        removed even if a remove-pattern would otherwise match.
      * Per-user settings are written into the DEFAULT user hive (C:\Users\Default\NTUSER.DAT),
        so every NEW profile inherits them. When run standalone after you already have a profile,
        pass -AlsoCurrentUser to also apply them to HKCU.
      * Idempotent and non-fatal per item: one failed tweak logs a warning and the rest continue.

    AGGRESSIVE NETWORK HARDENING (LLMNR / mDNS / NetBIOS) is included but DEFAULT OFF - it can
    break local name discovery that dev workflows sometimes rely on. Turn it on knowingly.

.PARAMETER AlsoCurrentUser
    Also apply per-user settings to the CURRENTLY logged-on user (HKCU), not just the Default
    hive. Use when running standalone on an already-set-up box. Ignored under SYSTEM.

.PARAMETER LogPath
    Transcript path. Default C:\ProgramData\PrivacyHardening\hardening_<stamp>.log.

.EXAMPLE
    # Test on a real Windows box, elevated:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-PrivacyHardening.ps1 -AlsoCurrentUser
.EXAMPLE
    # Baked into media: SetupComplete.cmd calls this as SYSTEM. No parameters.

.NOTES
    Version : 1.0.0
    Project : server2025-servicing (companion to unattend/autounattend-Win11.xml)
    License : MIT
    Windows PowerShell 5.1 (in-box). Run elevated. Reboot afterwards.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$AlsoCurrentUser,
    [string]$LogPath,
    [switch]$Force        # re-run even if the "already applied" marker is present
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.4.0'

# =====================================================================================
#  TOGGLES - the whole control surface. Each entry is an ACTION this script performs.
#
#     $true  = DO IT  -> apply the hardening (turn the Windows feature OFF / remove it)
#     $false = SKIP   -> leave the Windows default; this script changes NOTHING for it
#
#  Read the key name as the action. e.g.
#     DisableTelemetry = $true   -> telemetry is turned OFF
#     DisableTelemetry = $false  -> telemetry left at Windows default (untouched)
#     DebloatAppx      = $true   -> the listed consumer apps are removed
#     NetworkHardening = $false  -> LLMNR/mDNS/NetBIOS left at Windows default
# =====================================================================================
$H = @{
    DisableTelemetry            = $true    # DiagTrack service + AllowTelemetry=0 + CEIP tasks off
    DisableAdvertisingAndTips   = $true    # advertising ID, tailored experiences, Start/lock-screen suggestions
    DisableActivityHistory      = $true    # Timeline / activity feed upload off
    DisableCopilotAndRecall     = $true    # Windows Copilot off + Recall (DisableAIDataAnalysis) off  <-- Acer/Copilot+
    DisableWebSearchAndCortana  = $true    # Bing/web results in Start off, Cortana off
    DisableSearchAccounts       = $true    # Windows Search "find my content" across MSA + Work/School accounts off
    DisableWidgets              = $true    # Widgets / News & Interests off
    DisableLocationSpeechInking = $true    # location, online speech, inking/typing personalization off
    DisableConsumerFeatures     = $true    # "suggested"/auto-installed consumer apps off
    DisableStartRecommendations = $true    # Start "Recommended" section + tips/shortcuts recommendations off
    ShowFullAppsList            = $true    # Start "All apps" as a FLAT LIST, not the categorised grid
    DisableProxyAutoDetect      = $true    # "Automatically detect settings" / WPAD auto-proxy off
    DisableEdgeNags             = $true    # Edge first-run, startup boost, personalization telemetry off
    RemoveOneDrive              = $true    # stop OneDrive auto-install for new users + policy off
    DebloatAppx                 = $true    # remove consumer bloat (KEEP guard protects dev-critical)
    DisableSMB1                 = $true    # remove the SMB1 protocol (safe + recommended, even on dev)
    DisableDefenderSampleSubmission = $true # Defender: never auto-submit samples (keeps real-time protection ON)
    NeuterEdge                  = $true    # disable Edge background/telemetry/feedback + kill MSN new-tab feed
    HardenFirefox               = $true    # Mozilla enterprise policy: telemetry/Pocket/studies/sponsored OFF (LibreWolf-like)
    InstallFirefox              = $true    # silently install the baked-in offline installer if present (no network)
    EnableRemoteDesktop         = $true    # turn RDP ON (fDenyTSConnections=0) + firewall rule + require NLA
    SetNetworkPrivate           = $true    # treat UNIDENTIFIED networks as Private (not Public) by policy

    # ---- Cloud-delivered protection. You explicitly asked for this OFF. It REDUCES protection
    #      on a box that runs downloaded code - Defender real-time scanning itself stays ON, but
    #      cloud lookups + MAPS reporting are turned off. Flip to $false to keep cloud protection.
    DisableCloudDeliveredProtection = $true # MAPS/cloud-delivered protection + auto-sample submission off

    # ---- OFF by default: aggressive, can affect local dev discovery. Flip on knowingly. ----
    NetworkHardening            = $false   # LLMNR off, mDNS off, NetBIOS-over-TCP/IP off

    # ---- OFF by default: Defender exclusions for project dirs (edit the list below first). ----
    DefenderDevExclusions       = $false
}

# Folders to exclude from Defender scanning IF $H.DefenderDevExclusions is on. EXCLUSIONS REDUCE
# PROTECTION - list only trusted build/output trees, never your whole user profile.
$DefenderExcludePaths = @(
    # 'C:\src', 'C:\build'
)

# Where New-DeployableIso.ps1 bakes the offline Firefox installer. $H.InstallFirefox runs it /S if
# it exists; if not (e.g. standalone run on an existing box), it's a no-op and you install Firefox
# yourself - the Mozilla policy ($H.HardenFirefox) applies regardless.
$FirefoxInstaller = 'C:\Windows\Setup\Files\FirefoxSetup.exe'

# =====================================================================================
#  Helpers (defined before any use)
# =====================================================================================
function Get-TS { '{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::Now }
function Info ($m) { Write-Host  "$(Get-TS)  $m" }
function Warn ($m) { Write-Warning "$(Get-TS)  $m" }

# Set a registry value, creating the key path if needed. Never throws - logs and moves on.
function Set-Reg {
    param([string]$Path, [string]$Name, [Object]$Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        Info "  reg  $Path :: $Name = $Value"
    } catch { Warn "  reg FAILED $Path :: $Name - $($_.Exception.Message)" }
}

# Run a scriptblock with the Default user hive loaded at HKU\PH_Default. Inside the block,
# write to 'Registry::HKEY_USERS\PH_Default\...'. Used so NEW profiles inherit per-user tweaks.
function Invoke-WithDefaultHive {
    param([scriptblock]$Script)
    $dat = 'C:\Users\Default\NTUSER.DAT'
    if (-not (Test-Path $dat)) { Warn "Default hive not found ($dat) - skipping per-user (Default) settings."; return }
    try {
        & reg.exe load 'HKU\PH_Default' $dat | Out-Null
        & $Script
    } catch { Warn "Default-hive block failed: $($_.Exception.Message)" }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()   # release handles or unload fails
        & reg.exe unload 'HKU\PH_Default' | Out-Null
    }
}

# Apply a per-user tweak to the Default hive AND, when asked, to the current user (HKCU).
# $RelPath is the path UNDER the user hive root, e.g. 'Software\Microsoft\...'.
function Set-UserReg {
    param([string]$RelPath, [string]$Name, [Object]$Value, [string]$Type = 'DWord', [switch]$CurrentToo)
    Set-Reg -Path "Registry::HKEY_USERS\PH_Default\$RelPath" -Name $Name -Value $Value -Type $Type
    if ($CurrentToo) { Set-Reg -Path "Registry::HKEY_CURRENT_USER\$RelPath" -Name $Name -Value $Value -Type $Type }
}

function Disable-Task {
    param([string]$Path, [string]$Name)
    try {
        $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
        if ($t) { Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null; Info "  task disabled  $Path$Name" }
    } catch { Warn "  task FAILED $Path$Name - $($_.Exception.Message)" }
}

function Disable-Svc {
    param([string]$Name)
    try {
        $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($s) {
            Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
            Set-Service  -Name $Name -StartupType Disabled -ErrorAction Stop
            Info "  service disabled  $Name"
        }
    } catch { Warn "  service FAILED $Name - $($_.Exception.Message)" }
}

# =====================================================================================
#  Logging
# =====================================================================================
if (-not $LogPath) {
    $dir = 'C:\ProgramData\PrivacyHardening'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $LogPath = Join-Path $dir ("hardening_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
}
Start-Transcript -Path $LogPath -Append | Out-Null
Info "===== Privacy hardening v$ScriptVersion ====="
$whoami = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { 'unknown' }
Info "Running as: $whoami   AlsoCurrentUser: $AlsoCurrentUser"
Info "Toggles ON: $(($H.GetEnumerator() | Where-Object Value | ForEach-Object Key | Sort-Object) -join ', ')"

# Idempotency marker: this script can be triggered by more than one mechanism (specialize
# RunSynchronousCommand AND SetupComplete.cmd), so the first run drops a marker and later runs
# no-op. -Force overrides. This makes belt-and-braces triggering safe.
$AppliedMarker = 'C:\ProgramData\PrivacyHardening\.applied'
if ((Test-Path $AppliedMarker) -and -not $Force) {
    Info "Already applied ($AppliedMarker present). Use -Force to re-run. Exiting."
    try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
    exit 0
}

# =====================================================================================
#  1. Telemetry & diagnostics
# =====================================================================================
if ($H.DisableTelemetry) {
    Info '[DisableTelemetry] diagnostics off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Disable-Svc 'DiagTrack'
    Disable-Svc 'dmwappushservice'
    Disable-Task '\Microsoft\Windows\Application Experience\' 'Microsoft Compatibility Appraiser'
    Disable-Task '\Microsoft\Windows\Application Experience\' 'ProgramDataUpdater'
    Disable-Task '\Microsoft\Windows\Autochk\' 'Proxy'
    Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'Consolidator'
    Disable-Task '\Microsoft\Windows\Customer Experience Improvement Program\' 'UsbCeip'
    Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClient'
    Disable-Task '\Microsoft\Windows\Feedback\Siuf\' 'DmClientOnScenarioDownload'
}

# =====================================================================================
#  2. Advertising ID, tailored experiences, Start/lock-screen suggestions
# =====================================================================================
if ($H.DisableAdvertisingAndTips) {
    Info '[DisableAdvertisingAndTips] ad ID + suggestions off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Invoke-WithDefaultHive {
        $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in 'SubscribedContent-338387Enabled','SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353698Enabled','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled') {
            Set-Reg "Registry::HKEY_USERS\PH_Default\$cdm" $n 0
        }
        Set-Reg "Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0
        Set-Reg "Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    }
    if ($AlsoCurrentUser) {
        $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled') {
            Set-Reg "Registry::HKEY_CURRENT_USER\$cdm" $n 0
        }
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    }
}

# =====================================================================================
#  3. Activity history / Timeline
# =====================================================================================
if ($H.DisableActivityHistory) {
    Info '[DisableActivityHistory] timeline upload off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
}

# =====================================================================================
#  4. Copilot + Recall  (matters most on the Copilot+ Acer)
# =====================================================================================
if ($H.DisableCopilotAndRecall) {
    Info '[DisableCopilotAndRecall] Copilot off, Recall data analysis off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1   # Recall
    Invoke-WithDefaultHive {
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    }
    if ($AlsoCurrentUser) {
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    }
}

# =====================================================================================
#  5. Web search / Cortana in Start
# =====================================================================================
if ($H.DisableWebSearchAndCortana) {
    Info '[DisableWebSearchAndCortana] Bing/web results + Cortana off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Invoke-WithDefaultHive {
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    }
    if ($AlsoCurrentUser) {
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
    }
}

# =====================================================================================
#  5b. Windows Search "find my content" across cloud accounts (MSA + Work/School) off
# =====================================================================================
# Settings > Privacy & security > Searching Windows > "Cloud content search":
#   IsMSACloudSearchEnabled  -> the "Microsoft account" toggle
#   IsAADCloudSearchEnabled  -> the "Work or School account" toggle
# Both are per-user (SearchSettings), so they go into the Default hive for new profiles.
if ($H.DisableSearchAccounts) {
    Info '[DisableSearchAccounts] cloud content search (MSA + Work/School) off'
    Invoke-WithDefaultHive {
        $ss = 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
        Set-Reg $ss 'IsMSACloudSearchEnabled' 0
        Set-Reg $ss 'IsAADCloudSearchEnabled' 0
        Set-Reg $ss 'IsDeviceSearchHistoryEnabled' 0
    }
    if ($AlsoCurrentUser) {
        $ss = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
        Set-Reg $ss 'IsMSACloudSearchEnabled' 0
        Set-Reg $ss 'IsAADCloudSearchEnabled' 0
        Set-Reg $ss 'IsDeviceSearchHistoryEnabled' 0
    }
}

# =====================================================================================
#  6. Widgets / News & Interests
# =====================================================================================
if ($H.DisableWidgets) {
    Info '[DisableWidgets] widgets off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
}

# =====================================================================================
#  7. Location, online speech, inking/typing personalization
# =====================================================================================
if ($H.DisableLocationSpeechInking) {
    Info '[DisableLocationSpeechInking] location + online speech + inking personalization off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
    Invoke-WithDefaultHive {
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
        # "Custom inking and typing dictionary" (Settings > Privacy > Inking & typing personalization)
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Input\TIPC' 'Enabled' 0   # inking/typing telemetry
    }
    if ($AlsoCurrentUser) {
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Input\TIPC' 'Enabled' 0
    }
}

# =====================================================================================
#  8. Consumer features (suggested / auto-installed apps)
# =====================================================================================
if ($H.DisableConsumerFeatures) {
    Info '[DisableConsumerFeatures] suggested/auto-installed apps off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 1
}

# =====================================================================================
#  8b. Start menu "Recommended" section + tips/shortcut recommendations off
# =====================================================================================
# The "Recommended" band (recent files / suggested apps) at the bottom of Start. On Pro the
# Explorer policy alone historically didn't stick, so we also set the PolicyManager device node
# (the MDM-backed path that Pro honours) plus the per-user Iris/Track values in the Default hive.
if ($H.DisableStartRecommendations) {
    Info '[DisableStartRecommendations] Start "Recommended" section + tips off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecommendedSection' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'HideRecommendedSection' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education' 'IsEducationEnvironment' 1
    Invoke-WithDefaultHive {
        $adv = 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Set-Reg $adv 'Start_IrisRecommendations' 0   # "recommendations for tips, shortcuts, new apps"
        Set-Reg $adv 'Start_TrackDocs' 0             # recently opened items in Start/Jump lists
        Set-Reg $adv 'Start_TrackProgs' 0
    }
    if ($AlsoCurrentUser) {
        $adv = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Set-Reg $adv 'Start_IrisRecommendations' 0
        Set-Reg $adv 'Start_TrackDocs' 0
        Set-Reg $adv 'Start_TrackProgs' 0
    }
}

# =====================================================================================
#  8c. Start "All apps" as a FLAT LIST, not the new categorised grid
# =====================================================================================
# 24H2/25H2 groups "All apps" into category folders. HideCategoryView=1 restores the plain
# alphabetical list. Machine policy under Explorer - applies to every user.
if ($H.ShowFullAppsList) {
    Info '[ShowFullAppsList] Start All-apps = flat list (category grid off)'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideCategoryView' 1
}

# =====================================================================================
#  8d. Proxy auto-detect (WPAD) off - "Automatically detect settings"
# =====================================================================================
# The WPAD auto-discovery is both a privacy/telemetry vector and a known LAN attack surface.
# DisableWpad neuters the auto-detect behaviour engine-wide while KEEPING WinHttpAutoProxySvc
# running (the supported way - killing the service breaks other WinHTTP consumers). DisableAutoProxy
# stops the DNS-based WPAD lookups. This is the robust, machine-wide disable.
if ($H.DisableProxyAutoDetect) {
    Info '[DisableProxyAutoDetect] WPAD / auto-detect proxy off (service kept running)'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' 'DisableWpad' 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'DisableAutoProxy' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' 'EnableAutoProxyResultCache' 0
}

# =====================================================================================
#  9. Edge nags
# =====================================================================================
if ($H.DisableEdgeNags) {
    Info '[DisableEdgeNags] first-run + startup boost + personalization telemetry off'
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'HideFirstRunExperience' 1
    Set-Reg $edge 'StartupBoostEnabled' 0
    Set-Reg $edge 'PersonalizationReportingEnabled' 0
    Set-Reg $edge 'EdgeShoppingAssistantEnabled' 0
    Set-Reg $edge 'ShowRecommendationsEnabled' 0
}

# =====================================================================================
# 10. OneDrive - stop auto-install for new users (you use NextCloud)
# =====================================================================================
if ($H.RemoveOneDrive) {
    Info '[RemoveOneDrive] auto-install off for new profiles + sync policy off'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Invoke-WithDefaultHive {
        try { Remove-ItemProperty -Path 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -ErrorAction SilentlyContinue; Info '  removed Default-user OneDriveSetup Run entry' } catch {}
    }
}

# =====================================================================================
# 11. Appx debloat  (KEEP guard protects dev-critical packages)
# =====================================================================================
if ($H.DebloatAppx) {
    Info '[DebloatAppx] removing consumer bloat (dev-critical protected)'

    # Remove if the package name contains ANY of these...
    $removeMatch = @(
        'BingNews','BingWeather','BingSearch','Bing.Search',
        'GamingApp','Xbox','ZuneMusic','ZuneVideo',
        'windowscommunicationsapps','People','SolitaireCollection',
        'Clipchamp','Todos','PowerAutomateDesktop','MicrosoftOfficeHub',
        'GetHelp','Getstarted','Teams','MSTeams','Copilot','549981C3F5F10',
        'MixedReality.Portal','WindowsMaps','YourPhone','Microsoft.Phone',
        'WindowsFeedbackHub','OutlookForWindows','QuickAssist','Wallet',
        'Microsoft.Windows.Ai.Copilot.Provider',
        # Third-party promoted stubs that ship pre-provisioned / arrive via ContentDeliveryManager
        # (the LinkedIn / WhatsApp / etc. tiles you saw). Match on vendor + common promo apps:
        'LinkedIn','WhatsApp','Facebook','Instagram','SpotifyAB.Spotify','SpotifyMusic',
        'Disney','PrimeVideo','Amazon.com.Amazon','TikTok','Netflix','Dolby','DevHome',
        'Family','Microsoft.Windows.DevHome'
    )
    # ...UNLESS the name contains ANY of these. Dev-critical + generally-useful in-box tools.
    $keepMatch = @(
        'DesktopAppInstaller','WindowsStore','StorePurchaseApp','WindowsTerminal',
        'WebView','VCLibs','UI.Xaml','NET.Native','DotNet',
        'WindowsCalculator','WindowsNotepad','Paint','ScreenSketch','SnippingTool',
        'SecHealthUI','WindowsCamera','Winget'
    )

    # (a) Provisioned packages -> stops them landing in every NEW profile.
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    foreach ($p in $prov) {
        $name = $p.DisplayName
        $wantRemove = $removeMatch | Where-Object { $name -like "*$_*" }
        $mustKeep   = $keepMatch   | Where-Object { $name -like "*$_*" }
        if ($wantRemove -and -not $mustKeep) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                Info "  removed (provisioned)  $name"
            } catch { Warn "  remove FAILED  $name - $($_.Exception.Message)" }
        } elseif ($mustKeep) {
            Info "  KEEP  $name"
        }
    }
    # (b) Already-INSTALLED copies for all users -> cleans the profile that already exists (e.g. the
    # local Admin created during OOBE, or your current box when run with -Force). Provisioned removal
    # alone does NOT touch a profile that's already been created, which is why bloat can survive the
    # specialize pass. KEEP guard applies here too.
    $inst = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    foreach ($a in $inst) {
        $name = $a.Name
        $wantRemove = $removeMatch | Where-Object { $name -like "*$_*" }
        $mustKeep   = $keepMatch   | Where-Object { $name -like "*$_*" }
        if ($wantRemove -and -not $mustKeep) {
            try {
                Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction Stop
                Info "  removed (installed)  $name"
            } catch { Warn "  remove FAILED (installed)  $name - $($_.Exception.Message)" }
        }
    }
}

# =====================================================================================
# 12. SMB1 - remove the legacy protocol (safe, recommended even on dev)
# =====================================================================================
if ($H.DisableSMB1) {
    Info '[DisableSMB1] removing SMB1 protocol'
    try { Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -ErrorAction Stop | Out-Null; Info '  SMB1 disabled' }
    catch { Warn "  SMB1 disable FAILED - $($_.Exception.Message)" }
}

# =====================================================================================
# 13. Aggressive network hardening  (DEFAULT OFF - can break local dev discovery)
# =====================================================================================
if ($H.NetworkHardening) {
    Info '[NetworkHardening] LLMNR / mDNS / NetBIOS off  (aggressive)'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0            # LLMNR
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'EnableMDNS' 0            # mDNS
    # NetBIOS over TCP/IP off on every current interface (NetbiosOptions = 2):
    try {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction Stop |
            ForEach-Object { Set-Reg $_.PSPath 'NetbiosOptions' 2 }
    } catch { Warn "  NetBIOS off FAILED - $($_.Exception.Message)" }
}

# =====================================================================================
# 14. Defender exclusions for dev folders  (DEFAULT OFF - reduces protection)
# =====================================================================================
if ($H.DefenderDevExclusions -and $DefenderExcludePaths.Count -gt 0) {
    Info '[DefenderDevExclusions] adding folder exclusions (protection reduced for these paths)'
    foreach ($path in $DefenderExcludePaths) {
        try { Add-MpPreference -ExclusionPath $path -ErrorAction Stop; Info "  excluded  $path" }
        catch { Warn "  exclusion FAILED  $path - $($_.Exception.Message)" }
    }
}

# =====================================================================================
# 15. Defender - never AUTO-SUBMIT samples (keeps real-time + cloud protection ON)
# =====================================================================================
# This does NOT disable Defender or cloud-delivered protection (you run downloaded code - that
# protection is worth keeping). It stops the automatic upload of sample FILES to Microsoft,
# which is the real data-exfiltration concern. SubmitSamplesConsent: 2 = Never Send.
if ($H.DisableDefenderSampleSubmission) {
    Info '[DisableDefenderSampleSubmission] never auto-submit samples (real-time + cloud stay ON)'
    try { Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop; Info '  SubmitSamplesConsent = NeverSend (2)' }
    catch { Warn "  Set-MpPreference failed (Defender not ready at this phase?): $($_.Exception.Message)" }
    # Persist/enforce via policy too, so it survives and can't be silently flipped back:
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 2
    # To ALSO stop MAPS/cloud telemetry (further reduces exfil AND cloud protection), uncomment:
    #   Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting' 0
}

# =====================================================================================
# 16. Neuter Microsoft Edge (background, telemetry, feedback, recommendations)
# =====================================================================================
# NOTE: fully UNINSTALLING Edge Stable is only officially supported in the EEA. Outside it, these
# policies stop Edge phoning home / running in the background / nagging. Firefox is your browser
# (installed + policy-hardened separately - see docs/PRIVACY-HARDENING.md).
if ($H.NeuterEdge) {
    Info '[NeuterEdge] Edge background/telemetry/feedback/recommendations off'
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-Reg $edge 'BackgroundModeEnabled' 0
    Set-Reg $edge 'StartupBoostEnabled' 0
    Set-Reg $edge 'MetricsReportingEnabled' 0
    Set-Reg $edge 'UserFeedbackAllowed' 0
    Set-Reg $edge 'PersonalizationReportingEnabled' 0
    Set-Reg $edge 'SpotlightExperiencesAndRecommendationsEnabled' 0
    Set-Reg $edge 'ShowRecommendationsEnabled' 0
    Set-Reg $edge 'EdgeCollectionsEnabled' 0
    Set-Reg $edge 'WebWidgetAllowed' 0
    Set-Reg $edge 'HubsSidebarEnabled' 0
    Set-Reg $edge 'EdgeShoppingAssistantEnabled' 0
    Set-Reg $edge 'DiagnosticData' 0
    # ---- Kill the MSN "Times Square" new-tab page: no news feed, no MSN content, no top sites ----
    Set-Reg $edge 'NewTabPageContentEnabled' 0        # no MSN news/content on the new tab page
    Set-Reg $edge 'NewTabPageHideDefaultTopSites' 1   # hide the promoted default top-site tiles
    Set-Reg $edge 'NewTabPageQuickLinksEnabled' 0     # no quick-links row
    Set-Reg $edge 'NewTabPageAllowedBackgroundTypes' 3 # 3 = no background image/branding
    Set-Reg $edge 'ShowMicrosoftRewards' 0
    Set-Reg $edge 'EdgeFollowEnabled' 0
    Set-Reg $edge 'DefaultBrowserSettingEnabled' 0    # stop Edge nagging to be default (Firefox is)
}

# =====================================================================================
# 17. Firefox install -> RUN-ONCE first-logon task that SELF-DESTRUCTS
# =====================================================================================
# We do NOT install Firefox here (specialize is too early - app installers are happier once the
# OS is fully settled). Instead we register a scheduled task that fires at the FIRST logon,
# installs Firefox silently from the BAKED-IN offline installer (no network - good for the Acer
# before wifi/USB-ethernet is up), then removes both the task and its own helper script.
# No-op if the installer isn't present (the Mozilla policy still applies once Firefox lands).
$FirefoxTaskName   = 'PrivacyHardening-InstallFirefox'
$FirefoxRunOnce    = 'C:\Windows\Setup\Scripts\FirstLogon-InstallFirefox.ps1'
if ($H.InstallFirefox) {
    if (Test-Path $FirefoxInstaller) {
        Info "[InstallFirefox] registering run-once first-logon task '$FirefoxTaskName' (self-destructs)"
        # The helper the task runs. SINGLE-QUOTED here-string: nothing below is expanded now - it
        # is written verbatim and evaluated when the task runs. Keep the installer path + task name
        # here in sync with $FirefoxInstaller / $FirefoxTaskName above (both are fixed system paths).
        $helper = @'
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\PrivacyHardening\firefox_install.log'
"$([DateTime]::Now.ToString('s')) run-once Firefox install starting" | Out-File $log -Append
$installer = 'C:\Windows\Setup\Files\FirefoxSetup.exe'
if (Test-Path $installer) {
    try {
        $p = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
        "$([DateTime]::Now.ToString('s')) installer exit $($p.ExitCode)" | Out-File $log -Append
    } catch { "$([DateTime]::Now.ToString('s')) FAILED $($_.Exception.Message)" | Out-File $log -Append }
} else {
    "$([DateTime]::Now.ToString('s')) installer missing - nothing to do" | Out-File $log -Append
}
# Self-destruct: remove the task, then this script.
Unregister-ScheduledTask -TaskName 'PrivacyHardening-InstallFirefox' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
'@
        try {
            $rd = Split-Path $FirefoxRunOnce -Parent
            if (-not (Test-Path $rd)) { New-Item -ItemType Directory -Path $rd -Force | Out-Null }
            Set-Content -Path $FirefoxRunOnce -Value $helper -Encoding UTF8

            $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $FirefoxRunOnce)
            $trg = New-ScheduledTaskTrigger -AtLogOn
            $prn = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest
            $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $FirefoxTaskName -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
            Info "  task registered - installs Firefox at first logon, then removes itself"
        } catch { Warn "  could not register Firefox run-once task: $($_.Exception.Message)" }
    } else {
        Info "[InstallFirefox] no offline installer at $FirefoxInstaller - skipping (policy still applies once Firefox is installed)"
    }
}

# =====================================================================================
# 18. Harden Firefox (Mozilla enterprise policy - applies once Firefox is installed)
# =====================================================================================
# Firefox honours policies from HKLM\SOFTWARE\Policies\Mozilla\Firefox, so we can set them NOW -
# before Firefox exists - and they take effect the moment it's installed (winget install
# Mozilla.Firefox; see the doc - install needs network so do it at first logon, not here). This
# is the LibreWolf-style baseline: telemetry, Pocket, Studies, sponsored content all OFF.
if ($H.HardenFirefox) {
    Info '[HardenFirefox] Mozilla policy: telemetry/Pocket/studies/sponsored off'
    $ff = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
    Set-Reg $ff 'DisableTelemetry'            1
    Set-Reg $ff 'DisablePocket'               1
    Set-Reg $ff 'DisableFirefoxStudies'       1
    Set-Reg $ff 'DisableDefaultBrowserAgent'  1
    Set-Reg $ff 'DontCheckDefaultBrowser'     1
    Set-Reg $ff 'DisableFeedbackCommands'     1
    Set-Reg $ff 'NoDefaultBookmarks'          1
    Set-Reg $ff 'OfferToSaveLoginsDefault'    0
    Set-Reg "$ff\EnableTrackingProtection" 'Value'         1
    Set-Reg "$ff\EnableTrackingProtection" 'Cryptomining'  1
    Set-Reg "$ff\EnableTrackingProtection" 'Fingerprinting' 1
    Set-Reg "$ff\FirefoxHome" 'Pocket'          0
    Set-Reg "$ff\FirefoxHome" 'SponsoredPocket' 0
    Set-Reg "$ff\FirefoxHome" 'SponsoredTopSites' 0
    Set-Reg "$ff\FirefoxHome" 'Snippets'        0
    Set-Reg "$ff\UserMessaging" 'WhatsNew'                0
    Set-Reg "$ff\UserMessaging" 'ExtensionRecommendations' 0
    Set-Reg "$ff\UserMessaging" 'FeatureRecommendations'   0
    Set-Reg "$ff\UserMessaging" 'SkipOnboarding'           1
    # The FirefoxHome DWORDs above cover the toggles, but the sponsored shortcuts you still saw are
    # also driven by activity-stream prefs. Lock them off directly via the Preferences policy
    # (REG_SZ JSON: {"Value":<v>,"Status":"locked"} - "locked" also greys them out in Settings).
    $pref = "$ff\Preferences"
    Set-Reg $pref 'browser.newtabpage.activity-stream.showSponsoredTopSites' '{"Value":false,"Status":"locked"}' 'String'
    Set-Reg $pref 'browser.newtabpage.activity-stream.showSponsored'         '{"Value":false,"Status":"locked"}' 'String'
    Set-Reg $pref 'browser.newtabpage.activity-stream.feeds.topsites'        '{"Value":false,"Status":"locked"}' 'String'
    Set-Reg $pref 'browser.newtabpage.activity-stream.feeds.section.topstories' '{"Value":false,"Status":"locked"}' 'String'
    Set-Reg $pref 'browser.topsites.contile.enabled'                         '{"Value":false,"Status":"locked"}' 'String'
}

# =====================================================================================
# 19. Remote Desktop - turn ON (with NLA)
# =====================================================================================
# You need RDP-in (the Acer must be Pro for this - Home cannot host RDP). Enable the listener,
# open the firewall group, and REQUIRE Network Level Authentication (don't accept unauthenticated
# pre-connections). fDenyTSConnections = 0 means "allow".
if ($H.EnableRemoteDesktop) {
    Info '[EnableRemoteDesktop] RDP on + firewall rule + NLA required'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1  # NLA
    try {
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop
        Info '  firewall: Remote Desktop group enabled'
    } catch { Warn "  could not enable RDP firewall group (may be pre-network at specialize): $($_.Exception.Message)" }
}

# =====================================================================================
# 20. Treat UNIDENTIFIED networks as Private (not Public)
# =====================================================================================
# The Network List Manager "Unidentified Networks" policy. The signature key + GUID below is the
# fixed value the Local Security Policy editor itself writes for this setting; Category=1 = Private.
# (Verified against the secpol-generated key.) This makes a freshly-seen network land Private, so
# RDP / file sharing work without first flipping the profile by hand.
if ($H.SetNetworkPrivate) {
    Info '[SetNetworkPrivate] unidentified networks -> Private'
    $sig = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\010103000F0000F0010000000F0000F0C967A3643C3AD745950DA7859209176EF5B87C875FA20DF21951640E807D7C24'
    Set-Reg $sig 'Category' 1
}

# =====================================================================================
# 21. Cloud-delivered protection OFF  (you asked for this - it REDUCES protection)
# =====================================================================================
# Defender's real-time engine stays ON, but cloud lookups (MAPS) and automatic sample submission
# are turned off. This is your explicit choice; on a box that runs downloaded code it does lower
# your protection. Runtime via Set-MpPreference AND the enforcing Spynet policy so it survives.
if ($H.DisableCloudDeliveredProtection) {
    Info '[DisableCloudDeliveredProtection] MAPS/cloud lookups + sample submission off (real-time scanning stays ON)'
    try {
        Set-MpPreference -MAPSReporting 0 -SubmitSamplesConsent 2 -ErrorAction Stop
        Info '  MAPSReporting = Disabled (0), SubmitSamplesConsent = NeverSend (2)'
    } catch { Warn "  Set-MpPreference failed (Defender not ready at this phase?): $($_.Exception.Message)" }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SpynetReporting' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' 'SubmitSamplesConsent' 2
}

# ---- Drop the idempotency marker so later triggers no-op --------------------------
try {
    $md = Split-Path $AppliedMarker -Parent
    if (-not (Test-Path $md)) { New-Item -ItemType Directory -Path $md -Force | Out-Null }
    Set-Content -Path $AppliedMarker -Value ("applied {0} v{1}" -f (Get-TS), $ScriptVersion) -ErrorAction Stop
} catch { Warn "Could not write marker $AppliedMarker : $($_.Exception.Message)" }

Info '===== Privacy hardening complete (reboot recommended) ====='
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0

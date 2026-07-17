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
    Version : 1.5.0
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
$ScriptVersion = '1.5.0'   # policy-only at specialize; stateful work moved to Invoke-PostInstall.ps1

# =====================================================================================
#  TOGGLES - the whole control surface. Each entry is an ACTION this script performs.
#
#     $true  = DO IT  -> apply the hardening (turn the Windows feature OFF / remove it)
#     $false = SKIP   -> leave the Windows default; this script changes NOTHING for it
#
#  Read the key name as the action. e.g.
#     DisableTelemetry = $true   -> telemetry is turned OFF
#     DisableTelemetry = $false  -> telemetry left at Windows default (untouched)
#     NeuterEdge       = $true   -> Edge background/telemetry/new-tab feed turned OFF
#     NetworkHardening = $false  -> LLMNR/mDNS/NetBIOS left at Windows default
#
#  NOTE: appx debloat and the app installs (Firefox/Office/Acrobat) are NOT here - they run at
#  first logon via Invoke-PostInstall.ps1. This script is registry/policy only (specialize-safe).
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
    DisableRecommendationsAndOffers = $true # Settings "recommendations & offers" + suggested content off
    DisableLanguageListAccess   = $true    # stop websites reading your language list (HttpAcceptLanguageOptOut)
    ExplorerDevView             = $true    # show file extensions / hidden / system files / full path / run-as-different-user
    ShowFullAppsList            = $true    # Start "All apps" as a FLAT LIST, not the categorised grid
    CleanStartPins              = $true    # replace default Start pins (Xbox/LinkedIn/WhatsApp/...) with a clean layout
    DisableProxyAutoDetect      = $true    # "Automatically detect settings" / WPAD auto-proxy off
    DisableEdgeNags             = $true    # Edge first-run, startup boost, personalization telemetry off
    RemoveOneDrive              = $true    # policy: stop OneDrive auto-install (FULL uninstall runs in post-install)
    DisableSMB1                 = $true    # remove the SMB1 protocol (safe + recommended, even on dev)
    DisableDefenderSampleSubmission = $true # Defender: never auto-submit samples (keeps real-time protection ON)
    NeuterEdge                  = $true    # disable Edge background/telemetry/feedback + kill MSN new-tab feed
    HardenFirefox               = $true    # Mozilla enterprise policy: telemetry/Pocket/sponsored/homepage/weather OFF
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

# NOTE: Firefox/Office/Acrobat INSTALLS and appx debloat no longer run here - they run at first
# logon via harden/Invoke-PostInstall.ps1 (registered by section 17). This script sets only
# registry/policy, which is safe at the specialize pass. The Mozilla policy (section 18) applies
# the moment Firefox is installed.

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

# Default user hive, mounted ONCE at HKU\PH_Default and reused. The old design load/unloaded it in
# every section - and if a SINGLE unload failed to release its handle, every LATER 'reg load' failed
# ("key already loaded") and every subsequent per-user write silently no-op'd. That's the root cause
# of per-user settings (language list, Explorer view, ...) not sticking. Now: mount once, write many,
# Dismount-DefaultHive once at the very end.
$Script:DefaultHiveLoaded = $false
function Mount-DefaultHive {
    if ($Script:DefaultHiveLoaded) { return $true }
    $dat = 'C:\Users\Default\NTUSER.DAT'
    if (-not (Test-Path $dat)) { Warn "Default hive not found ($dat) - per-user (Default) settings skipped."; return $false }
    & reg.exe load 'HKU\PH_Default' $dat 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # A stale mount from a crashed prior run - clear it and retry once.
        & reg.exe unload 'HKU\PH_Default' 2>&1 | Out-Null
        & reg.exe load   'HKU\PH_Default' $dat 2>&1 | Out-Null
    }
    if ($LASTEXITCODE -eq 0) { $Script:DefaultHiveLoaded = $true; return $true }
    Warn "Could not load Default hive (reg load exit $LASTEXITCODE) - per-user (Default) settings skipped."
    return $false
}
function Dismount-DefaultHive {
    if (-not $Script:DefaultHiveLoaded) { return }
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()   # release handles or unload fails
    & reg.exe unload 'HKU\PH_Default' 2>&1 | Out-Null
    $Script:DefaultHiveLoaded = $false
}
# Run a scriptblock with the Default hive mounted (write to 'Registry::HKEY_USERS\PH_Default\...').
# Call sites are unchanged; only the mount lifetime moved (see above).
function Invoke-WithDefaultHive {
    param([scriptblock]$Script)
    if (Mount-DefaultHive) {
        try { & $Script } catch { Warn "Default-hive block failed: $($_.Exception.Message)" }
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
    # The Dsh policy key has a restrictive ACL that blocks even elevated Admin (only SYSTEM can
    # write it - so this succeeds at the SYSTEM-run specialize/post-install, and just warns when
    # you test standalone as Admin). Set-Reg swallows the failure; the per-user TaskbarDa below is
    # the reliable route that removes the Widgets button regardless.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Invoke-WithDefaultHive {
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    }
    if ($AlsoCurrentUser) {
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    }
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
    # NOTE: do NOT set Education\IsEducationEnvironment here - that flips the WHOLE device into an
    # education SKU (SetEduPolicies: Store/search/Start/default-app side effects). HideRecommendedSection
    # above is the correct, targeted control.
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
#  8c2. Strip the default Start PINS (Xbox / LinkedIn / WhatsApp / Solitaire / etc.)
# =====================================================================================
# Those are default *pins*, not just apps - the appx debloat removes the apps but the PINS persist
# (which is why they were still on Start). 24H2+ (KB5062660) added the ConfigureStartPins policy: a
# single-line JSON pinnedList that REPLACES the default layout. Empty list = clean Start; you pin
# what you want after (applyOnce lets your later changes stick). Set on both the Explorer policy and
# the PolicyManager device node so it takes on Pro.
if ($H.CleanStartPins) {
    Info '[CleanStartPins] replacing default Start pins with a clean (empty) layout'
    $pinsJson = '{"pinnedList":[]}'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'ConfigureStartPins' $pinsJson 'String'
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'ConfigureStartPins_ProviderSet' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' $pinsJson 'String'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins_ProviderSet' 1
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
#  8e. Settings "recommendations & offers" + suggested content off
# =====================================================================================
# Privacy & security > Recommendations & offers, and the "suggested content" that Settings shows.
# Per-user (ContentDeliveryManager), so into the Default hive for new profiles.
if ($H.DisableRecommendationsAndOffers) {
    Info '[DisableRecommendationsAndOffers] Settings suggested content + offers off'
    Invoke-WithDefaultHive {
        $cdm = 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in 'SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { Set-Reg $cdm $n 0 }
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_ShowWebRecommendations' 0
    }
    if ($AlsoCurrentUser) {
        $cdm = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in 'SubscribedContent-338393Enabled','SubscribedContent-353694Enabled','SubscribedContent-353696Enabled') { Set-Reg $cdm $n 0 }
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_ShowWebRecommendations' 0
    }
}

# =====================================================================================
#  8f. Stop websites reading your language list
# =====================================================================================
# Privacy & security > General > "Let websites show me locally relevant content by accessing my
# language list." Per-user opt-out flag.
if ($H.DisableLanguageListAccess) {
    Info '[DisableLanguageListAccess] websites cannot read the language list'
    Invoke-WithDefaultHive {
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
    }
    if ($AlsoCurrentUser) {
        Set-Reg 'Registry::HKEY_CURRENT_USER\Control Panel\International\User Profile' 'HttpAcceptLanguageOptOut' 1
    }
}

# =====================================================================================
#  8g. File Explorer - developer-friendly defaults (show extensions/hidden/system/full path)
# =====================================================================================
# You asked for these ON. Per-user (Default hive), plus the machine policy for run-as-different-user.
if ($H.ExplorerDevView) {
    Info '[ExplorerDevView] show file extensions / hidden / system / full path'
    Invoke-WithDefaultHive {
        $adv = 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Set-Reg $adv 'HideFileExt' 0        # show file extensions
        Set-Reg $adv 'Hidden' 1             # show hidden files
        Set-Reg $adv 'ShowSuperHidden' 1    # show protected OS (system) files
        Set-Reg 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1  # full path in title bar
    }
    if ($AlsoCurrentUser) {
        $adv = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        Set-Reg $adv 'HideFileExt' 0
        Set-Reg $adv 'Hidden' 1
        Set-Reg $adv 'ShowSuperHidden' 1
        Set-Reg 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1
    }
    # "Show option to run as different user in Start" - machine policy.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'ShowRunAsDifferentUserInStart' 1
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
        try { Remove-ItemProperty -Path 'Registry::HKEY_USERS\PH_Default\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDriveSetup' -ErrorAction SilentlyContinue; Info '  removed Default-user OneDriveSetup Run entry' } catch { Write-Verbose "no Default-user OneDriveSetup Run entry to remove: $($_.Exception.Message)" }
    }
}

# =====================================================================================
# 11. Appx debloat  -> MOVED to harden/Invoke-PostInstall.ps1 (first logon)
# =====================================================================================
# Appx removal at the specialize pass is unreliable: the Appx subsystem isn't fully up, so
# Remove-AppxPackage / Remove-AppxProvisionedPackage silently no-op and the bloat survives (Xbox /
# LinkedIn / WhatsApp came back every deploy). The debloat now runs in the FIRST-LOGON post-install
# phase, where the Appx stack is settled and removal actually sticks. See Invoke-PostInstall.ps1.

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
    # ---- Edge, hardened to your spec (it stays installed; harden it too) ----
    Set-Reg $edge 'ConfigureDoNotTrack' 1                     # Send "Do Not Track" = ON
    Set-Reg $edge 'ResolveNavigationErrorsUseWebService' 0    # no web service for nav errors / "suggest similar sites"
    Set-Reg $edge 'SearchSuggestEnabled' 0                    # no search/site suggestions or Bing trending
    Set-Reg $edge 'RestoreOnStartup' 1                        # on startup: open tabs from the previous session
    # Default search engine = Google (Edge managed search provider)
    Set-Reg $edge 'DefaultSearchProviderEnabled' 1
    Set-Reg $edge 'DefaultSearchProviderName' 'Google' 'String'
    Set-Reg $edge 'DefaultSearchProviderSearchURL' 'https://www.google.com/search?q={searchTerms}' 'String'
    Set-Reg $edge 'DefaultSearchProviderSuggestURL' 'https://www.google.com/complete/search?client=chrome&q={searchTerms}' 'String'
}

# =====================================================================================
# 17. Register the FIRST-LOGON post-install task
# =====================================================================================
# The STATEFUL work - appx debloat, OneDrive uninstall, and the app installs (Firefox, Office LTSC
# 2024, Acrobat Pro DC) - runs at FIRST LOGON, not here: specialize is too early for appx ops and
# installers (that's why the debloat kept failing). We register a run-once task that runs
# Invoke-PostInstall.ps1 (injected next to THIS script by New-DeployableIso.ps1) as SYSTEM at the
# first logon; that script does the work, then self-destructs. No-op if it isn't on the media.
$PostInstallScript = 'C:\Windows\Setup\Scripts\Invoke-PostInstall.ps1'
$PostInstallTask   = 'PrivacyHardening-PostInstall'
if (Test-Path $PostInstallScript) {
    Info "[PostInstall] registering first-logon task '$PostInstallTask'"
    try {
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f $PostInstallScript)
        $trg = New-ScheduledTaskTrigger -AtLogOn
        $prn = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Hours 3)   # Office online install can be slow
        Register-ScheduledTask -TaskName $PostInstallTask -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
        Info "  task registered - runs debloat + app installs at first logon, then self-destructs"
    } catch { Warn "  could not register post-install task: $($_.Exception.Message)" }
} else {
    Info "[PostInstall] no Invoke-PostInstall.ps1 on the media - skipping (deploy without app installs/debloat)"
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
    # ---- Homepage + new windows = blank; startup RESTORES previous session; new tab = blank ----
    # The supported Homepage policy: URL is the homepage, StartPage 'previous-session' = "open
    # previous windows and tabs" on launch. Locked=0 so you can still change it later.
    Set-Reg "$ff\Homepage" 'URL'       'about:blank'        'String'
    Set-Reg "$ff\Homepage" 'StartPage' 'previous-session'   'String'
    Set-Reg "$ff\Homepage" 'Locked'    0
    Set-Reg $ff 'NewTabPage' 0    # new tab = blank page (no Firefox Home)
    # ---- Locked prefs via the Preferences policy ----
    # *** FORMAT FIX (this is why weather / launch-on-login / sponsored didn't take before): the
    # Preferences policy in the registry is ONE value named 'Preferences' (REG_MULTI_SZ) holding a
    # SINGLE JSON object - NOT a 'Preferences' SUBKEY with a value per pref. Firefox silently
    # ignores the subkey form. JSON must be one line. Covers: sponsored top-sites + stories
    # ("Support Firefox"), the new-tab Weather widget, auto-launch-at-Windows-startup, and
    # credit-card / address autofill ("Save and autofill payment info").
    $prefsJson = '{"browser.newtabpage.activity-stream.showSponsoredTopSites":{"Value":false,"Status":"locked"},"browser.newtabpage.activity-stream.showSponsored":{"Value":false,"Status":"locked"},"browser.newtabpage.activity-stream.feeds.topsites":{"Value":false,"Status":"locked"},"browser.newtabpage.activity-stream.feeds.section.topstories":{"Value":false,"Status":"locked"},"browser.topsites.contile.enabled":{"Value":false,"Status":"locked"},"browser.newtabpage.activity-stream.showWeather":{"Value":false,"Status":"locked"},"browser.newtabpage.activity-stream.system.showWeather":{"Value":false,"Status":"locked"},"browser.startup.windowsLaunchOnLogin.enabled":{"Value":false,"Status":"locked"},"extensions.formautofill.creditCards.enabled":{"Value":false,"Status":"locked"},"extensions.formautofill.addresses.enabled":{"Value":false,"Status":"locked"}}'
    try {
        if (-not (Test-Path $ff)) { New-Item -Path $ff -Force | Out-Null }
        New-ItemProperty -Path $ff -Name 'Preferences' -Value @($prefsJson) -PropertyType MultiString -Force | Out-Null
        Info '  reg  Firefox\Preferences (single REG_MULTI_SZ JSON: weather/launch/sponsored/autofill locked off)'
    } catch { Warn "  Firefox Preferences policy failed: $($_.Exception.Message)" }
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

# ---- Release the Default hive (mounted once, above) --------------------------------
Dismount-DefaultHive

# ---- Drop the idempotency marker so later triggers no-op --------------------------
try {
    $md = Split-Path $AppliedMarker -Parent
    if (-not (Test-Path $md)) { New-Item -ItemType Directory -Path $md -Force | Out-Null }
    Set-Content -Path $AppliedMarker -Value ("applied {0} v{1}" -f (Get-TS), $ScriptVersion) -ErrorAction Stop
} catch { Warn "Could not write marker $AppliedMarker : $($_.Exception.Message)" }

Info '===== Privacy hardening complete (reboot recommended) ====='
try { Stop-Transcript | Out-Null } catch { Write-Verbose 'transcript already stopped' }
exit 0

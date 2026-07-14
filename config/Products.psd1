<#
    Products.psd1 - product profiles for Slipstream-WindowsMedia.ps1

    THIS is the file you edit. You should never have to open the script itself to change
    which media gets built, where it lives, or which editions get patched.

    It is a PowerShell DATA file: it is loaded with Import-PowerShellDataFile, which parses it
    in "restricted language" mode. It cannot contain commands, calls, or variables - only
    literals, hashtables, arrays, $true/$false/$null. That is deliberate: a config file should
    not be able to execute anything, and a typo here cannot corrupt the build logic.

    After ANY edit:
        .\tests\Invoke-QualityGate.ps1                                    # validates this file
        .\scripts\Slipstream-WindowsMedia.ps1 -Product <name> -ListEditions
        .\scripts\Slipstream-WindowsMedia.ps1 -Product <name> -DryRun     # before a 4-hour build

    ---------------------------------------------------------------------------------------
    FIELD REFERENCE

    Label            ISO VOLUME label (what Explorer shows when the ISO is mounted).
                     Max 32 chars (UDF).

    IsoPrefix        Output FILENAME prefix -> <IsoPrefix>_<stamp>.iso

                     *** 'Server2025_Patched' IS LOAD-BEARING. DO NOT CHANGE IT. ***
                     Watch-Server2025Updates.ps1 finds and archives the monthly build by
                     globbing 'Server2025_Patched_*.iso'. Rename it and the scheduled task
                     still "succeeds" - it just archives nothing. Silent failure.

    BasePath         Working + output directory. Needs ~30-40 GB free (more for Win11: the
                     25H2 LCU alone is ~5.4 GB).

    SourceISO        RTM media. Mounted read-only during the build; never modified.

    ArchiveRoot      Where finished ISOs are KEPT - the shared / historical location. After a
                     successful, VERIFIED build the ISO + its .json manifest + the build
                     transcript are copied here, and old builds are pruned to KeepLast.
                     Set to '' to disable archiving (the ISO then just stays in BasePath).

                     A LOCAL folder is simplest - share it afterwards. If you point it at a
                     UNC: the scheduled task runs as SYSTEM and hits the share as the MACHINE
                     account (DOMAIN\HOST$), not as you.

    KeepLast         Historical ISOs to retain in ArchiveRoot for THIS product. Pruning is
                     per-product (it globs <IsoPrefix>_*.iso), so products sharing one
                     ArchiveRoot can never delete each other's builds.

                     *** SIZE THIS DELIBERATELY. *** Server 2025 ISOs are ~8.6 GB, Win11 ~7.9 GB:
                         Server2025  KeepLast 12  ~= 103 GB
                         Win11-25H2  KeepLast  6  ~=  47 GB
                         Win11-24H2  KeepLast  6  ~=  47 GB
                                                    --------
                                                    ~197 GB  on a 256 GB volume - PLUS the
                     30-40 GB working set. The defaults below already crowd D:. Lower them, or
                     point ArchiveRoot at a bigger volume. Minimum 1 (0 would prune the ISO you
                     just built).

    DefaultEditions  Which editions to patch when the caller names none (this is what the
                     scheduled task does). SEE docs/EDITIONS.md BEFORE EDITING.

                     $null  = ALL editions.  <- NOT "none".
                     @(...) = exactly these, matched by EXACT NAME. No wildcards.
                              '*Pro*' here matches NOTHING (it is compared with -eq).
                              Copy names verbatim from -ListEditions output.

                     Server2025 must stay $null: that install.wim is also the
                     DISM /RestoreHealth repair source for every Server 2025 host, so
                     dropping editions here breaks REPAIRS, not builds - and you would not
                     find out until a repair failed.

    PreferRegex      Disambiguates Server vs client packages in the Catalog (the SafeOS and
                     Setup DUs ship in both flavours under similar titles). $null for Win11 -
                     there is nothing to disambiguate, and a stray filter here would match
                     zero results.

    LcuQuery / LcuInclude          Catalog search string + regex the result title must match.
    SafeOsQuery / SafeOsInclude    Same, for the SafeOS Dynamic Update (services WinRE).
    SetupQuery / SetupInclude      Same, for the Setup Dynamic Update (refreshes \sources).
    DotNetQuery / DotNetInclude    Same, for the .NET Framework CU.

                     These are the ONLY place Catalog naming lives. If Microsoft changes a
                     title format, this file is the single fix - not the script.
    ---------------------------------------------------------------------------------------

    Edition layouts VERIFIED by enumerating the actual media (2026-07-13):

      Server 2025 RTM   : 4 editions
         1 Standard                        3 Datacenter
         2 Standard (Desktop Experience)   4 Datacenter (Desktop Experience)

      Win11 24H2 + 25H2 : 10 editions, IDENTICAL index->name layout in both:
         1 Education    2 Education N    3 Enterprise   4 Enterprise N   5 Pro
         6 Pro N        7 Pro Education  8 Pro Education N
         9 Pro for Workstations          10 Pro N for Workstations

    Do not trust those numbers forever - confirm with -ListEditions against YOUR media.
#>

@{

    'Server2025' = @{
        Label           = 'SERVER2025_PATCHED'
        IsoPrefix       = 'Server2025_Patched'   # LOAD-BEARING - see note above
        BasePath        = 'D:\Server2025Patching'
        SourceISO       = 'D:\Server2025RTM\SW_DVD9_Win_Server_STD_CORE_2025_24H2_64Bit_English_DC_STD_MLF_X23-81891.ISO'
        ArchiveRoot     = 'D:\PatchedImages'
        KeepLast        = 12                     # ~103 GB at ~8.6 GB/ISO

        # $null = all 4 editions. The scheduled task relies on this, and so does the repair
        # runbook (this install.wim is the RestoreHealth source). Do not subset it.
        DefaultEditions = $null

        PreferRegex     = 'server operating system'
        LcuQuery        = 'Cumulative Update Microsoft server operating system version 24H2 x64'
        LcuInclude      = 'Cumulative Update for Microsoft server operating system version 24H2'
        SafeOsQuery     = 'Safe OS Dynamic Update Microsoft server operating system version 24H2 x64'
        SafeOsInclude   = 'Safe OS Dynamic Update for (Microsoft server operating system version 24H2|Windows 11,? versions? .*24H2)'
        SetupQuery      = 'Setup Dynamic Update Microsoft server operating system version 24H2 x64'
        SetupInclude    = 'Setup Dynamic Update for (Microsoft server operating system version 24H2|Windows 11,? versions? .*24H2)'
        DotNetQuery     = 'Cumulative Update .NET Framework Microsoft server operating system version 24H2 x64'
        DotNetInclude   = 'Cumulative Update for \.NET Framework .*Microsoft server operating system version 24H2'
    }

    'Win11-25H2' = @{
        Label           = 'WIN11_25H2_PATCHED'
        IsoPrefix       = 'Win11_25H2_Patched'
        BasePath        = 'D:\Win11_25H2_Patching'
        SourceISO       = 'D:\Win11RTM\en-us_windows_11_business_editions_version_25h2_x64_dvd_41c521e7.iso'
        ArchiveRoot     = 'D:\PatchedImages'
        KeepLast        = 6                      # ~47 GB at ~7.9 GB/ISO

        # Exact names, copied from -ListEditions. Indexes shown for orientation only - the
        # match is BY NAME, so a media re-layout cannot silently patch the wrong edition.
        DefaultEditions = @(
            'Windows 11 Enterprise'             # index 3
            'Windows 11 Pro'                    # index 5
            'Windows 11 Pro for Workstations'   # index 9
        )

        PreferRegex     = $null
        LcuQuery        = 'Cumulative Update for Windows 11 version 25H2 x64'
        LcuInclude      = 'Cumulative Update for Windows 11,? version 25H2'
        SafeOsQuery     = 'Safe OS Dynamic Update for Windows 11 version 25H2 x64'
        SafeOsInclude   = 'Safe OS Dynamic Update for Windows 11,? versions? .*25H2'
        SetupQuery      = 'Setup Dynamic Update for Windows 11 version 25H2 x64'
        SetupInclude    = 'Setup Dynamic Update for Windows 11,? versions? .*25H2'
        DotNetQuery     = 'Cumulative Update .NET Framework Windows 11 version 25H2 x64'
        DotNetInclude   = 'Cumulative Update for \.NET Framework .*Windows 11,? version 25H2'
    }

    'Win11-24H2' = @{
        Label           = 'WIN11_24H2_PATCHED'
        IsoPrefix       = 'Win11_24H2_Patched'
        BasePath        = 'D:\Win11_24H2_Patching'
        SourceISO       = 'D:\Win11RTM\en-us_windows_11_business_editions_version_24h2_x64_dvd_59a1851e.iso'
        ArchiveRoot     = 'D:\PatchedImages'
        KeepLast        = 6                      # ~47 GB at ~7.9 GB/ISO

        DefaultEditions = @(
            'Windows 11 Enterprise'             # index 3
            'Windows 11 Pro'                    # index 5
            'Windows 11 Pro for Workstations'   # index 9
        )

        PreferRegex     = $null
        LcuQuery        = 'Cumulative Update for Windows 11 version 24H2 x64'
        LcuInclude      = 'Cumulative Update for Windows 11,? version 24H2'
        SafeOsQuery     = 'Safe OS Dynamic Update for Windows 11 version 24H2 x64'
        SafeOsInclude   = 'Safe OS Dynamic Update for Windows 11,? versions? .*24H2'
        SetupQuery      = 'Setup Dynamic Update for Windows 11 version 24H2 x64'
        SetupInclude    = 'Setup Dynamic Update for Windows 11,? versions? .*24H2'
        DotNetQuery     = 'Cumulative Update .NET Framework Windows 11 version 24H2 x64'
        DotNetInclude   = 'Cumulative Update for \.NET Framework .*Windows 11,? version 24H2'
    }

}

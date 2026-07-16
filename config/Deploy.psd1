<#
    Deploy.psd1 - golden-image deploy profiles for New-DeployableIso.ps1 / Build-GoldenImage.ps1

    THIS is the file you edit to define a golden image. It's the deploy-side companion to
    config\Products.psd1 (which defines how the *media* is patched). Everything that used to be a
    pile of switches on New-DeployableIso.ps1 now lives here as data, so a golden image is
    described once, declaratively, and rebuilt each patch cycle with one command:

        .\scripts\Build-GoldenImage.ps1                 # builds DefaultProfile end-to-end
        .\scripts\New-DeployableIso.ps1                 # just the deploy ISO, DefaultProfile

    It is a PowerShell DATA file (Import-PowerShellDataFile, restricted language: literals only, no
    commands or variables). A typo here can't corrupt the build logic.

    After ANY edit:
        .\tests\Invoke-QualityGate.ps1                  # validates this file too

    ---------------------------------------------------------------------------------------
    TOP-LEVEL KEYS
      DefaultProfile   Name of the profile built when none is named (-DeployProfile overrides).
      Profiles         The hashtable of golden-image profiles (below).

    PROFILE FIELDS
      Product          Source product to build FROM - must be a product defined in Products.psd1.
      EditionName      The ONE edition to keep, by exact ImageName (trim-safe).
      IncludeUnattend  $true bakes the disk-wiping answer file at the ISO root => a fully
                       unattended installer. *** WIPES DISK 0 ON BOOT. *** This is what a golden
                       deploy image wants; leave $false only for an image you attach the answer
                       file to separately.

      Harden           $true injects + runs the privacy hardening (policy at specialize) and the
                       post-install task (first logon).

      Firefox          $true bakes the Firefox offline installer (installed at first logon).
      FirefoxSetup     '' => download the latest x64 en-US installer at build time.
                       Or a LOCAL path to pin a point-in-time installer.

      Office           $true downloads the current Office bits at build time and BAKES them in;
                       Office installs OFFLINE at first logon.
      OfficeOdt        PINNED point-in-time ODT setup.exe (download page id=49117, extract
                       setup.exe, drop it here). This is the "take the point-in-time setup.exe"
                       choice - we don't re-download the ODT each build. Revisit only if it fails.
      OfficeConfig     '' => office\proplus2024.xml (ProPlus 2024 + Visio). Or a path to your own.

      Acrobat          $true embeds the Acrobat ISO in the image; installed OFFLINE at first logon.
      AcrobatIso       Path to AcrobatDC.iso to embed.

      DebloatAppx      $true => post-install removes consumer bloat (KEEP guard protects dev tools).
      RemoveOneDrive   $true => post-install fully uninstalls OneDrive + blocks reinstall.

    A field left out of a profile falls back to the script's built-in default. An explicit switch
    on the command line (e.g. -NoOffice) overrides whatever the profile says, for one-off runs.

    *** SIZE / TIME NOTE ***  With Office + Acrobat baked, the deploy ISO is ~12-13 GB and the build
    downloads ~3 GB of Office each run. That's the cost of a self-contained, point-in-time USB.
    ---------------------------------------------------------------------------------------
#>

@{

    # Profile built when none is named on the command line.
    DefaultProfile = 'Win11-Pro-Golden'

    Profiles = @{

        # The point-in-time golden workstation image: Windows 11 Pro, hardened, Firefox + Office
        # 2024 + Acrobat baked in, disk-wiping unattended installer. Bare `Build-GoldenImage.ps1`
        # produces this.
        'Win11-Pro-Golden' = @{
            Product         = 'Win11-25H2'
            EditionName     = 'Windows 11 Pro'
            IncludeUnattend = $true                 # WIPES DISK 0 on boot - a deploy image

            Harden          = $true

            Firefox         = $true
            FirefoxSetup    = ''                    # '' => download latest at build

            Office          = $true
            OfficeOdt       = 'D:\InstallSoftware\ODT\setup.exe'   # PINNED - put the ODT setup.exe here
            OfficeConfig    = ''                    # '' => office\proplus2024.xml (ProPlus + Visio)

            Acrobat         = $true
            AcrobatIso      = 'D:\InstallSoftware\AcrobatDC.iso'

            DebloatAppx     = $true
            RemoveOneDrive  = $true
        }

        # A lean variant: OS + hardening only (no Office/Acrobat), for a small fast image or testing.
        # Build it with:  .\scripts\Build-GoldenImage.ps1 -DeployProfile 'Win11-Pro-Lean'
        'Win11-Pro-Lean' = @{
            Product         = 'Win11-25H2'
            EditionName     = 'Windows 11 Pro'
            IncludeUnattend = $true
            Harden          = $true
            Firefox         = $true
            FirefoxSetup    = ''
            Office          = $false
            Acrobat         = $false
            DebloatAppx     = $true
            RemoveOneDrive  = $true
        }
    }
}

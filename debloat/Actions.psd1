<#
    Every change the debloat can make, described as data rather than code.

    Keeping it here means the list can be reviewed without reading the engine,
    and the tests can check invariants that matter: that each action says what
    it does, which profile it belongs to, and how to undo it.

    Fields:
      Id        stable identifier, used in reports and in -Only/-Skip
      Type      AppX | Registry | Service | ScheduledTask
      Profile   Minimal | Recommended | Aggressive (the lowest that includes it)
      Summary   one line, shown in the plan
      Reversible  how it can be undone; every action must answer this
      Risk      Low | Medium | High - what breaks if this was the wrong call

    A note on Type = Service: disabling a service is the change most likely to
    cause a problem that shows up weeks later and is hard to trace back here.
    That is why nothing of that type is below the Aggressive profile.
#>
@{
    # ---- Pre-installed apps ---------------------------------------------------
    # AppX removal is per-user unless -AllUsers is given. Everything here can be
    # reinstalled from the Microsoft Store, which is what makes it the safest
    # category to start from.
    AppX      = @(
        @{ Id = 'app.xbox.gamingoverlay'; Package = 'Microsoft.XboxGamingOverlay'; Profile = 'Minimal'
            Summary = 'Xbox Game Bar'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.xbox.identity'; Package = 'Microsoft.XboxIdentityProvider'; Profile = 'Aggressive'
            Summary = 'Xbox sign-in provider'; Reversible = 'Reinstall from the Microsoft Store'
            Risk = 'Medium'; Note = 'Some games need this to sign in'
        }
        @{ Id = 'app.bing.news'; Package = 'Microsoft.BingNews'; Profile = 'Minimal'
            Summary = 'Bing News'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.bing.weather'; Package = 'Microsoft.BingWeather'; Profile = 'Minimal'
            Summary = 'Bing Weather'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.solitaire'; Package = 'Microsoft.MicrosoftSolitaireCollection'; Profile = 'Minimal'
            Summary = 'Solitaire Collection'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.getstarted'; Package = 'Microsoft.Getstarted'; Profile = 'Minimal'
            Summary = 'Get Started / Tips'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.zune.music'; Package = 'Microsoft.ZuneMusic'; Profile = 'Recommended'
            Summary = 'Groove Music / Media Player'; Reversible = 'Reinstall from the Microsoft Store'
            Risk = 'Medium'; Note = 'This is the default media player on Windows 11'
        }
        @{ Id = 'app.people'; Package = 'Microsoft.People'; Profile = 'Recommended'
            Summary = 'People'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.feedback'; Package = 'Microsoft.WindowsFeedbackHub'; Profile = 'Recommended'
            Summary = 'Feedback Hub'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.maps'; Package = 'Microsoft.WindowsMaps'; Profile = 'Recommended'
            Summary = 'Maps'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.clipchamp'; Package = 'Clipchamp.Clipchamp'; Profile = 'Recommended'
            Summary = 'Clipchamp video editor'; Reversible = 'Reinstall from the Microsoft Store'; Risk = 'Low'
        }
        @{ Id = 'app.teams.consumer'; Package = 'MicrosoftTeams'; Profile = 'Recommended'
            Summary = 'Teams (personal, preinstalled)'; Reversible = 'Reinstall from the Microsoft Store'
            Risk = 'Medium'; Note = 'Does not affect Teams installed by the company'
        }
        @{ Id = 'app.quickassist'; Package = 'MicrosoftCorporationII.QuickAssist'; Profile = 'Aggressive'
            Summary = 'Quick Assist'; Reversible = 'Reinstall from the Microsoft Store'
            Risk = 'High'; Note = 'Support desks use this for remote assistance'
        }
    )

    # ---- Telemetry and privacy ------------------------------------------------
    # Registry values only, all of them exported before the change and restored
    # by the generated revert script.
    Registry  = @(
        @{ Id = 'privacy.advertising-id'; Profile = 'Minimal'
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
            Name = 'Enabled'; Value = 0; Kind = 'DWord'
            Summary = 'Turn off the advertising ID'
            Reversible = 'Restore the exported key, or set the value back to 1'; Risk = 'Low'
        }
        @{ Id = 'privacy.telemetry'; Profile = 'Recommended'
            Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
            Name = 'AllowTelemetry'; Value = 0; Kind = 'DWord'
            Summary = 'Set diagnostic data to the minimum'
            Reversible = 'Restore the exported key'; Risk = 'Low'
            Note = 'On Home editions Windows may ignore this policy'
        }
        @{ Id = 'privacy.tips'; Profile = 'Minimal'
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Name = 'SubscribedContent-338389Enabled'; Value = 0; Kind = 'DWord'
            Summary = 'Stop tips and suggestions in the Start menu'
            Reversible = 'Restore the exported key'; Risk = 'Low'
        }
        @{ Id = 'privacy.suggested-apps'; Profile = 'Minimal'
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
            Name = 'SilentInstalledAppsEnabled'; Value = 0; Kind = 'DWord'
            Summary = 'Stop silently installing suggested apps'
            Reversible = 'Restore the exported key'; Risk = 'Low'
        }
        @{ Id = 'ui.widgets'; Profile = 'Recommended'
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            Name = 'TaskbarDa'; Value = 0; Kind = 'DWord'
            Summary = 'Hide the Widgets button from the taskbar'
            Reversible = 'Restore the exported key, or turn it back on in taskbar settings'; Risk = 'Low'
        }
        @{ Id = 'ui.chat'; Profile = 'Recommended'
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            Name = 'TaskbarMn'; Value = 0; Kind = 'DWord'
            Summary = 'Hide the Chat button from the taskbar'
            Reversible = 'Restore the exported key, or turn it back on in taskbar settings'; Risk = 'Low'
        }
        @{ Id = 'ui.copilot'; Profile = 'Recommended'
            Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'
            Name = 'TurnOffWindowsCopilot'; Value = 1; Kind = 'DWord'
            Summary = 'Turn off Windows Copilot'
            Reversible = 'Restore the exported key'; Risk = 'Low'
        }
        @{ Id = 'ui.search-highlights'; Profile = 'Recommended'
            Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'
            Name = 'IsDynamicSearchBoxEnabled'; Value = 0; Kind = 'DWord'
            Summary = 'Turn off search highlights'
            Reversible = 'Restore the exported key'; Risk = 'Low'
        }
        @{ Id = 'ui.web-search'; Profile = 'Aggressive'
            Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
            Name = 'DisableSearchBoxSuggestions'; Value = 1; Kind = 'DWord'
            Summary = 'Remove web results from Start menu search'
            Reversible = 'Restore the exported key'; Risk = 'Medium'
            Note = 'Also removes results some users rely on'
        }
    )

    # ---- Services -------------------------------------------------------------
    # Aggressive only, on purpose: a disabled service breaks things in ways that
    # are hard to trace back to this script weeks later.
    Service   = @(
        @{ Id = 'svc.diagtrack'; Name = 'DiagTrack'; Profile = 'Aggressive'
            Summary = 'Connected User Experiences and Telemetry'
            Reversible = 'Set-Service DiagTrack -StartupType Automatic; Start-Service DiagTrack'
            Risk = 'Medium'; Note = 'Some corporate management tools read this data'
        }
        @{ Id = 'svc.dmwappushservice'; Name = 'dmwappushservice'; Profile = 'Aggressive'
            Summary = 'WAP push message routing'
            Reversible = 'Set-Service dmwappushservice -StartupType Manual'
            Risk = 'Medium'; Note = 'Used by MDM enrolment in some environments'
        }
        @{ Id = 'svc.retail-demo'; Name = 'RetailDemo'; Profile = 'Aggressive'
            Summary = 'Retail demo mode'
            Reversible = 'Set-Service RetailDemo -StartupType Manual'; Risk = 'Low'
        }
    )

    # ---- Scheduled tasks ------------------------------------------------------
    Task      = @(
        @{ Id = 'task.ceip'; Path = '\Microsoft\Windows\Application Experience\'
            Name = 'ProgramDataUpdater'; Profile = 'Aggressive'
            Summary = 'Customer Experience Improvement Program collector'
            Reversible = 'Enable-ScheduledTask on the same path and name'; Risk = 'Low'
        }
        @{ Id = 'task.consolidator'; Path = '\Microsoft\Windows\Customer Experience Improvement Program\'
            Name = 'Consolidator'; Profile = 'Aggressive'
            Summary = 'Sends the collected CEIP data'
            Reversible = 'Enable-ScheduledTask on the same path and name'; Risk = 'Low'
        }
    )
}

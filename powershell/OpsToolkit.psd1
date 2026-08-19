@{
    RootModule        = 'OpsToolkit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd6f2b0c4-8a1e-4c33-9f77-2b5e6a91c0d4'
    Author            = 'Nicolas Mesquita Fernandes'
    Description       = 'Operations scripts for infrastructure and incident work: health checks, reporting, backup and auditing.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-OpsToolkitVersion'
        'Get-OpsToolkitCommand'
        'Invoke-OpsScript'
        'Get-DiskSpaceReport'
        'Test-ServiceHealth'
        'Test-Endpoints'
        'Get-OpenPorts'
        'Get-EventLogErrors'
        'Get-TLSCertExpiry'
        'New-UptimeReport'
        'Invoke-LogRotation'
        'Clear-TempFiles'
        'Get-LocalUserAudit'
        'Backup-Folder'
        'Invoke-BackupRetention'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags         = @('ops', 'noc', 'monitoring', 'backup', 'audit', 'sysadmin')
            LicenseUri   = 'https://github.com/omfgnick/ops-toolkit/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/omfgnick/ops-toolkit'
            ReleaseNotes = 'https://github.com/omfgnick/ops-toolkit/releases'
        }
    }
}

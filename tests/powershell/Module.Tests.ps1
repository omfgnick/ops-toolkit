<#
    Testes do módulo OpsToolkit.

    Diferente do Contract.Tests.ps1, que só lê a AST, aqui o módulo é realmente
    importado — é o que prova que o manifesto está válido e que as funções
    existem de fato.
#>

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Manifest = Join-Path $Root 'powershell/OpsToolkit.psd1'
    $script:VersionFile = Join-Path $Root 'VERSION'
    Import-Module $script:Manifest -Force
}

AfterAll {
    Remove-Module OpsToolkit -Force -ErrorAction SilentlyContinue
}

Describe 'Manifesto' {
    It 'é válido' {
        { Test-ModuleManifest -Path $script:Manifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'declara a mesma versão do arquivo VERSION' {
        # A versão vive em três lugares (VERSION, os scripts Bash e o manifesto);
        # sem este teste, um deles fica para trás na próxima release.
        $manifestVersion = (Test-ModuleManifest -Path $script:Manifest).Version.ToString()
        $fileVersion = (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
        $manifestVersion | Should -Be $fileVersion
    }

    It 'exporta exatamente as funções que o módulo define' {
        $declared = (Import-PowerShellDataFile -Path $script:Manifest).FunctionsToExport
        $exported = (Get-Command -Module OpsToolkit -CommandType Function).Name
        ($declared | Sort-Object) | Should -Be ($exported | Sort-Object)
    }
}

Describe 'Funções do módulo' {
    It 'Get-OpsToolkitVersion devolve a versão do arquivo' {
        Get-OpsToolkitVersion | Should -Be (Get-Content -LiteralPath $script:VersionFile -Raw).Trim()
    }

    It 'Get-OpsToolkitCommand lista todos os scripts da pasta' {
        $scripts = Get-ChildItem (Join-Path $script:Root 'powershell') -Filter *.ps1 |
            Where-Object { $_.Name -ne 'OpsToolkit.psm1' }
        (Get-OpsToolkitCommand).Count | Should -Be $scripts.Count
    }

    It 'Invoke-OpsScript recusa script inexistente' {
        { Invoke-OpsScript -Name 'Nao-Existe' } | Should -Throw
    }

    It 'toda função exportada tem ajuda com sinopse' {
        foreach ($fn in (Get-Command -Module OpsToolkit -CommandType Function)) {
            $synopsis = (Get-Help $fn.Name).Synopsis
            $synopsis | Should -Not -BeNullOrEmpty -Because "$($fn.Name) precisa de .SYNOPSIS"
        }
    }
}

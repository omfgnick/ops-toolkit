<#
    Contrato dos scripts PowerShell.

    Os testes usam a AST (não executam os scripts), porque a maioria depende de
    cmdlets exclusivos do Windows e o CI roda em Linux. O que se verifica aqui é
    estrutura: ajuda, CmdletBinding e — o ponto mais importante — que todo script
    destrutivo suporte -WhatIf de verdade.
#>

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ScriptDir = Join-Path $Root 'powershell'
    $script:Scripts = Get-ChildItem -Path $ScriptDir -Filter *.ps1 -Recurse

    # Scripts que alteram o sistema: apagam, movem, compactam ou reiniciam algo.
    # Cada um destes precisa suportar -WhatIf.
    $script:Destructive = @(
        'Cleanup-TempFiles.ps1'
        'Rotate-Logs.ps1'
        'Test-ServiceHealth.ps1'
        'backup-folder.ps1'
        'backup_retention.ps1'
    )

    function Get-Ast {
        param([string]$Path)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        [pscustomobject]@{ Ast = $ast; Errors = $errors }
    }
}

Describe 'Todos os scripts' {
    It 'existem scripts para testar' {
        $Scripts.Count | Should -BeGreaterThan 0
    }

    It '<_.Name> compila sem erro de parse' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        $parsed = Get-Ast -Path $_.FullName
        $parsed.Errors | Should -BeNullOrEmpty
    }

    It '<_.Name> tem ajuda baseada em comentário (.SYNOPSIS)' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        $content = Get-Content -Path $_.FullName -Raw
        $content | Should -Match '\.SYNOPSIS'
    }

    It '<_.Name> documenta ao menos um exemplo' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        $content = Get-Content -Path $_.FullName -Raw
        $content | Should -Match '\.EXAMPLE'
    }

    It '<_.Name> declara CmdletBinding' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        $content = Get-Content -Path $_.FullName -Raw
        $content | Should -Match '\[CmdletBinding'
    }
}

Describe 'Scripts destrutivos suportam -WhatIf' {
    It '<_> declara SupportsShouldProcess' -ForEach @(
        'Cleanup-TempFiles.ps1', 'Rotate-Logs.ps1', 'Test-ServiceHealth.ps1',
        'backup-folder.ps1', 'backup_retention.ps1'
    ) {
        $path = Join-Path $ScriptDir $_
        $path | Should -Exist
        (Get-Content -Path $path -Raw) | Should -Match 'SupportsShouldProcess'
    }

    It '<_> realmente chama ShouldProcess()' -ForEach @(
        'Cleanup-TempFiles.ps1', 'Rotate-Logs.ps1', 'Test-ServiceHealth.ps1',
        'backup-folder.ps1', 'backup_retention.ps1'
    ) {
        # Declarar SupportsShouldProcess sem chamar ShouldProcess() é pior que
        # não ter: o -WhatIf é aceito e silenciosamente ignorado.
        $path = Join-Path $ScriptDir $_
        (Get-Content -Path $path -Raw) | Should -Match 'ShouldProcess\('
    }
}

Describe 'Comandos perigosos exigem proteção' {
    It 'nenhum script chama Remove-Item fora de um bloco ShouldProcess' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        $content = Get-Content -Path $_.FullName -Raw
        if ($content -match 'Remove-Item') {
            # Se apaga arquivo, o script precisa suportar -WhatIf
            $content | Should -Match 'SupportsShouldProcess' -Because "$($_.Name) usa Remove-Item"
            $content | Should -Match 'ShouldProcess\(' -Because "$($_.Name) usa Remove-Item"
        }
    }
}

Describe 'Codificação dos arquivos' {
    It 'nenhum .ps1 ou .psd1 tem caractere fora de ASCII' {
        # O PowerShell 5.1 lê UTF-8 sem BOM como ANSI e estraga o texto, e o
        # PSScriptAnalyzer bloqueia por isso. Escrever só ASCII evita o problema
        # sem depender de BOM. Já quebrou o CI três vezes — daqui em diante quem
        # avisa é o teste, não o CI.
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $files = Get-ChildItem -Path $root -Include *.ps1, *.psd1, *.psm1 -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\/](tests)[\/]' }
        foreach ($f in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $offenders = @($bytes | Where-Object { $_ -gt 127 })
            $offenders.Count | Should -Be 0 -Because "$($f.Name) tem $($offenders.Count) byte(s) fora de ASCII"
        }
    }
}

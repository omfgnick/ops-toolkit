<#
    Contrato dos scripts PowerShell.

    Os testes usam a AST (não executam os scripts), porque a maioria depende de
    cmdlets exclusivos do Windows. O job Windows do CI executa os scripts de
    verdade; o que se verifica aqui é
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

Describe 'Contrato JSON' {
    It '<_.Name> declara -AsJson' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        # O README prometia "todo relatório fala JSON" quando só 4 de 17 falavam.
        # Agora que todos falam, é este teste que impede a promessa de voltar a
        # ser mentira: script novo sem -AsJson reprova aqui.
        $content = Get-Content -Path $_.FullName -Raw
        $content | Should -Match '\[switch\]\$AsJson' -Because "$($_.Name) precisa aceitar -AsJson"
    }

    It '<_.Name> monta a saída JSON com ConvertTo-Json' -ForEach @( (Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'powershell') -Filter *.ps1) ) {
        # Declarar o parâmetro e ignorá-lo seria pior que não ter: o usuário
        # pede JSON, não recebe erro, e recebe tabela.
        $content = Get-Content -Path $_.FullName -Raw
        $content | Should -Match 'ConvertTo-Json' -Because "$($_.Name) declara -AsJson"
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
        # Compara caminho com caminho, e não regex com separador: no Windows o
        # separador é '' e um padrão escrito com '/' não casa - foi assim que
        # este teste passou no Linux e falhou no primeiro job Windows.
        $testsDir = Join-Path $root 'tests'
        $files = Get-ChildItem -Path $root -Include *.ps1, *.psd1, *.psm1 -Recurse -File |
            Where-Object { -not $_.FullName.StartsWith($testsDir, [StringComparison]::OrdinalIgnoreCase) }
        foreach ($f in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $offenders = @($bytes | Where-Object { $_ -gt 127 })
            $offenders.Count | Should -Be 0 -Because "$($f.Name) tem $($offenders.Count) byte(s) fora de ASCII"
        }
    }
}

Describe 'Menu: politica de execucao' {
    BeforeAll {
        $script:MenuPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Menu.ps1'
        $script:MenuSrc = Get-Content -LiteralPath $script:MenuPath -Raw
    }

    It 'so mexe na politica do PROCESSO, nunca da maquina ou do usuario' {
        # A diferenca entre destravar a propria sessao e afrouxar a maquina de
        # quem rodou o menu. A segunda nao e nossa para tomar.
        $script:MenuSrc | Should -Match 'Set-ExecutionPolicy'
        $script:MenuSrc | Should -Match "Set-ExecutionPolicy\s+-Scope\s+Process"
        $script:MenuSrc | Should -Not -Match "-Scope\s+(LocalMachine|CurrentUser)"
    }

    It 'desbloqueia os arquivos que baixou' {
        # Arquivo vindo da internet carrega a Marca da Web e a politica
        # RemoteSigned o recusa, mesmo com o processo liberado.
        $script:MenuSrc | Should -Match 'Unblock-File'
    }

    It 'le $LASTEXITCODE com guarda' {
        # Script que termina com 'return' nunca define a variavel, e sob
        # Set-StrictMode le-la LANCA. Acontece sempre que -AsJson e usado.
        $script:MenuSrc | Should -Match 'Test-Path\s+Variable:LASTEXITCODE'
    }
}

<#
    Testes de COMPORTAMENTO, com Mock.

    Os outros arquivos de teste olham a AST e o catálogo: verificam que o script
    declara SupportsShouldProcess, que chama ShouldProcess(), que tem ajuda. Isso
    prova estrutura, não conduta — um script pode declarar tudo certo e mesmo
    assim apagar arquivo no modo de simulação.

    Aqui os comandos destrutivos são substituídos por Mock e o teste verifica o
    que o script TENTOU fazer:

      - o modo de simulação não pode chamar Remove-Item nenhuma vez;
      - o modo real tem de chamar;
      - o reparo do Windows Update RENOMEIA o SoftwareDistribution, não apaga —
        se um dia isso virar Remove-Item, o usuário perde o histórico de
        atualizações e não tem volta;
      - -WhatIf não pode parar serviço.

    Só roda em Windows: os cmdlets de serviço não existem em Linux e o Pester
    não teria o que substituir.
#>

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:Dir = Join-Path $script:Root 'powershell'
    $script:IsWin = -not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows)
}

Describe 'Cleanup-TempFiles' -Skip:(-not (-not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows))) {

    BeforeEach {
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("ops-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null
        1..3 | ForEach-Object {
            $f = Join-Path $script:Temp "velho$_.tmp"
            Set-Content -LiteralPath $f -Value 'x' -Encoding ASCII
            # envelhece o arquivo para cair no filtro de dias
            (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddDays(-30)
        }
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:Temp) {
            Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sem -Execute nao apaga arquivo nenhum' {
        # O contrato mais importante deste script. Um relatorio que apaga
        # sozinho e a pior surpresa possivel numa maquina de producao.
        & (Join-Path $script:Dir 'Cleanup-TempFiles.ps1') -Path $script:Temp -OlderThanDays 1 -AsJson | Out-Null

        # Os arquivos continuam no disco: prova direta, sem depender de Mock
        @(Get-ChildItem -LiteralPath $script:Temp -File).Count | Should -Be 3
    }

    It 'sem -Execute o JSON se declara como simulacao' {
        $json = & (Join-Path $script:Dir 'Cleanup-TempFiles.ps1') -Path $script:Temp -OlderThanDays 1 -AsJson | ConvertFrom-Json
        $json.dry_run | Should -BeTrue
        $json.executed | Should -BeFalse
        $json.files | Should -Be 3       # contou os 3, mas nao tocou
    }

    It 'com -Execute apaga de verdade' {
        & (Join-Path $script:Dir 'Cleanup-TempFiles.ps1') -Path $script:Temp -OlderThanDays 1 -Execute -Confirm:$false -AsJson | Out-Null
        @(Get-ChildItem -LiteralPath $script:Temp -File).Count | Should -Be 0
    }

    It 'com -Execute e -WhatIf NAO apaga' {
        # -WhatIf tem de vencer -Execute. Se nao vencesse, quem usa -WhatIf para
        # conferir antes apagaria os arquivos justamente ao conferir.
        & (Join-Path $script:Dir 'Cleanup-TempFiles.ps1') -Path $script:Temp -OlderThanDays 1 -Execute -WhatIf | Out-Null
        @(Get-ChildItem -LiteralPath $script:Temp -File).Count | Should -Be 3
    }
}

Describe 'Repair-CommonIssues' -Skip:(-not (-not ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows))) {

    <#
        Estes testes valem nos DOIS ambientes, e por bom motivo: na minha
        maquina a sessao nao e elevada e o script pula tudo; no runner do CI ela
        E elevada e os caminhos destrutivos rodam de verdade, com os Mocks
        interceptando. Escrever so para um dos casos daria teste verde e vazio
        no outro - foi o que aconteceu na primeira versao.

        'Network' fica de fora de proposito, e isso NAO e detalhe: aquele reparo
        chama 'ipconfig /release', que nao passa por Mock nenhum porque e
        executavel externo. Num runner elevado ele derrubaria a rede do proprio
        job.
    #>

    BeforeEach {
        $script:renomeou = 0
        $script:apagou   = 0
        $script:parou    = 0
        Mock -CommandName Rename-Item   -MockWith { $script:renomeou++ }
        Mock -CommandName Remove-Item   -MockWith { $script:apagou++ }
        Mock -CommandName Stop-Service  -MockWith { $script:parou++ }
        Mock -CommandName Start-Service -MockWith { }
        Mock -CommandName Get-ChildItem -MockWith { @() }
        Mock -CommandName Test-Path     -MockWith { $true }
    }

    It 'o reparo do Windows Update RENOMEIA o SoftwareDistribution, nunca apaga' {
        # Renomear e reversivel; apagar joga fora o historico de atualizacoes sem
        # volta. Uma linha de diferenca no codigo, um estrago permanente na
        # maquina de quem rodou.
        $json = & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair WindowsUpdate -Confirm:$false -AsJson | ConvertFrom-Json
        $r = $json.repairs | Where-Object { $_.repair -eq 'WindowsUpdate' }

        if ($json.as_admin) {
            $r.status | Should -Be 'done' -Because "com privilegio o reparo tem de rodar (detalhe: $($r.detail))"
            $script:renomeou | Should -BeGreaterThan 0 -Because 'a pasta e movida para o lado'
            $script:apagou | Should -Be 0 -Because 'apagar o SoftwareDistribution nao tem volta'
        }
        else {
            $r.status | Should -Be 'skipped'
            $r.detail | Should -Match 'administrator'
            ($script:renomeou + $script:apagou + $script:parou) | Should -Be 0
        }
    }

    It '-WhatIf nao para servico, tenha privilegio ou nao' {
        & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair WindowsUpdate -WhatIf | Out-Null
        $script:parou | Should -Be 0 -Because '-WhatIf so mostra o que faria'
        $script:renomeou | Should -Be 0
    }

    It 'o reparo do Spooler para e religa o servico' {
        $json = & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair Spooler -Confirm:$false -AsJson | ConvertFrom-Json
        $r = $json.repairs | Where-Object { $_.repair -eq 'Spooler' }

        if ($json.as_admin) {
            $script:parou | Should -BeGreaterThan 0 -Because "sem parar o servico a fila nao limpa (status: $($r.status), detalhe: $($r.detail))"
        }
        else {
            $r.status | Should -Be 'skipped'
            $script:parou | Should -Be 0
        }
    }

    It 'o relatorio diz se a sessao era elevada' {
        # Sem isso, quem le o JSON nao sabe distinguir "nao precisou" de "nao pode"
        $json = & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair Spooler -Confirm:$false -AsJson | ConvertFrom-Json
        $json.PSObject.Properties.Name | Should -Contain 'as_admin'
        $json.as_admin | Should -BeOfType [bool]
    }
}

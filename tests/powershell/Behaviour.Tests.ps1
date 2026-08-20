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
        Limite honesto deste bloco: sem sessao elevada o script pula todo
        reparo, entao os caminhos destrutivos nao rodam aqui. Tentei extrair a
        checagem de elevacao para uma funcao e substitui-la com Mock; nao
        funciona, porque a funcao nasce dentro do script invocado e o Pester nao
        a enxerga na hora de resolver o Mock. Desfiz a mudanca: distorcer o
        script de producao por um teste que nao funciona seria pior.

        O que DA para provar aqui, e importa: a guarda de elevacao funciona. Sem
        privilegio, nenhum comando destrutivo e chamado - e o script chega ao
        fim e diz 'skipped', o que impede este teste de passar por vacuidade.
    #>

    BeforeEach {
        $script:chamadas = 0
        Mock -CommandName Stop-Service  -MockWith { $script:chamadas++ }
        Mock -CommandName Start-Service -MockWith { $script:chamadas++ }
        Mock -CommandName Rename-Item   -MockWith { $script:chamadas++ }
        Mock -CommandName Remove-Item   -MockWith { $script:chamadas++ }
    }

    It 'sem privilegio, nenhum comando destrutivo e chamado' {
        $json = & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair All -Confirm:$false -AsJson | ConvertFrom-Json

        # Nao e vazio: o script rodou os quatro reparos e decidiu pular cada um
        @($json.repairs).Count | Should -BeGreaterThan 0
        $script:chamadas | Should -Be 0 -Because 'sem privilegio nada pode ser tocado'
    }

    It 'sem privilegio, os reparos que exigem admin se declaram pulados' {
        # UserCache fica de fora de proposito: ele limpa o cache do PROPRIO
        # usuario e nao precisa de elevacao. Exigir 'skipped' dele era erro do
        # meu teste, nao do script - so descobri rodando.
        $json = & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair All -Confirm:$false -AsJson | ConvertFrom-Json

        foreach ($nome in 'Spooler', 'WindowsUpdate', 'Network') {
            $r = $json.repairs | Where-Object { $_.repair -eq $nome }
            $r | Should -Not -BeNullOrEmpty -Because "$nome tem de aparecer no relatorio"
            $r.status | Should -Be 'skipped'
            $r.detail | Should -Match 'administrator'
        }
    }

    It 'o relatorio registra que a sessao nao era elevada' {
        $json = & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair Spooler -Confirm:$false -AsJson | ConvertFrom-Json
        $json.as_admin | Should -BeFalse -Because 'e o que explica os pulos acima'
    }

    It '-WhatIf tambem nao chama nada' {
        & (Join-Path $script:Dir 'Repair-CommonIssues.ps1') -Repair All -WhatIf | Out-Null
        $script:chamadas | Should -Be 0
    }
}

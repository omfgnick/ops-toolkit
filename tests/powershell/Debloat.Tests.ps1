<#
    Testes do debloat.

    O CI roda em Linux, então não dá para verificar que a remoção funciona — isso
    exige uma máquina Windows. O que dá para verificar, e importa mais, é que as
    regras de segurança valem para TODA entrada do catálogo: que nada seja
    irreversível, que o risco esteja declarado, que serviço só apareça no perfil
    agressivo e que o modo padrão não altere nada.

    É o tipo de invariante que um humano revisando 25 entradas deixa passar.
#>

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:DebloatDir = Join-Path $script:Root 'debloat'
    $script:Script = Join-Path $script:DebloatDir 'Invoke-Debloat.ps1'
    $script:Catalog = Import-PowerShellDataFile -LiteralPath (Join-Path $script:DebloatDir 'Actions.psd1')

    $script:AllActions = foreach ($type in 'AppX', 'Registry', 'Service', 'Task') {
        foreach ($a in $script:Catalog[$type]) {
            [pscustomobject]@{ Type = $type; Entry = $a }
        }
    }
}

Describe 'Catálogo de ações' {
    It 'tem ações para testar' {
        $script:AllActions.Count | Should -BeGreaterThan 0
    }

    It 'toda ação declara Id, Profile, Summary, Reversible e Risk' {
        foreach ($x in $script:AllActions) {
            foreach ($field in 'Id', 'Profile', 'Summary', 'Reversible', 'Risk') {
                $x.Entry[$field] | Should -Not -BeNullOrEmpty -Because "$($x.Type)/$($x.Entry.Id) precisa de $field"
            }
        }
    }

    It 'não repete Id' {
        $ids = $script:AllActions | ForEach-Object { $_.Entry.Id }
        ($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'usa apenas perfis conhecidos' {
        foreach ($x in $script:AllActions) {
            $x.Entry.Profile | Should -BeIn @('Minimal', 'Recommended', 'Aggressive')
        }
    }

    It 'usa apenas níveis de risco conhecidos' {
        foreach ($x in $script:AllActions) {
            $x.Entry.Risk | Should -BeIn @('Low', 'Medium', 'High')
        }
    }

    It 'toda ação de risco Medium ou High explica o porquê numa Note' {
        # Risco declarado sem explicação não ajuda quem decide se aceita
        foreach ($x in $script:AllActions | Where-Object { $_.Entry.Risk -in 'Medium', 'High' }) {
            $x.Entry.Note | Should -Not -BeNullOrEmpty -Because "$($x.Entry.Id) é risco $($x.Entry.Risk)"
        }
    }
}

Describe 'Regras de segurança do catálogo' {
    It 'serviço e tarefa agendada só existem no perfil Aggressive' {
        # Desligar serviço é a mudança que quebra coisas semanas depois, longe
        # de qualquer pista de que este script foi a causa.
        foreach ($x in $script:AllActions | Where-Object { $_.Type -in 'Service', 'Task' }) {
            $x.Entry.Profile | Should -Be 'Aggressive' -Because "$($x.Entry.Id) altera o sistema de forma difícil de rastrear"
        }
    }

    It 'toda entrada de registro diz o caminho, o nome e o tipo do valor' {
        foreach ($x in $script:AllActions | Where-Object { $_.Type -eq 'Registry' }) {
            $x.Entry.Path | Should -Match '^HK(CU|LM):'
            $x.Entry.Name | Should -Not -BeNullOrEmpty
            $x.Entry.Kind | Should -BeIn @('DWord', 'String', 'QWord', 'ExpandString')
        }
    }

    It 'nenhuma ação mexe em caminho de registro fora das áreas esperadas' {
        # Impede que uma entrada nova aponte para algo estrutural do sistema
        foreach ($x in $script:AllActions | Where-Object { $_.Type -eq 'Registry' }) {
            $x.Entry.Path | Should -Not -Match 'CurrentControlSet\\Services' -Because 'serviço se desliga por Set-Service, não por registro'
            $x.Entry.Path | Should -Not -Match 'Winlogon' -Because 'mexer no logon pode impedir a entrada no sistema'
        }
    }
}

Describe 'Comportamento do script' {
    It 'existe e compila' {
        $script:Script | Should -Exist
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:Script, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'declara SupportsShouldProcess com ConfirmImpact alto' {
        $content = Get-Content -LiteralPath $script:Script -Raw
        $content | Should -Match 'SupportsShouldProcess'
        $content | Should -Match "ConfirmImpact\s*=\s*'High'"
    }

    It 'sem -Apply, apenas mostra o plano e não altera nada' {
        $out = & $script:Script -AsJson | ConvertFrom-Json
        $out.mode | Should -Be 'plan'
        $out.applied | Should -BeFalse
    }

    It 'o perfil padrão é o Minimal' {
        $out = & $script:Script -AsJson | ConvertFrom-Json
        $out.profile | Should -Be 'Minimal'
    }

    It 'os perfis são cumulativos' {
        $min = (& $script:Script -Preset Minimal -AsJson | ConvertFrom-Json).actions.Id
        $rec = (& $script:Script -Preset Recommended -AsJson | ConvertFrom-Json).actions.Id
        $agr = (& $script:Script -Preset Aggressive -AsJson | ConvertFrom-Json).actions.Id

        foreach ($id in $min) { $rec | Should -Contain $id }
        foreach ($id in $rec) { $agr | Should -Contain $id }
        $agr.Count | Should -BeGreaterThan $min.Count
    }

    It 'o perfil Minimal não contém nada de risco alto' {
        $min = (& $script:Script -Preset Minimal -AsJson | ConvertFrom-Json).actions
        foreach ($a in $min) { $a.Risk | Should -Not -Be 'High' }
    }

    It '-Skip remove a ação do plano' {
        $all = (& $script:Script -Preset Aggressive -AsJson | ConvertFrom-Json).actions.Id
        $skipped = (& $script:Script -Preset Aggressive -Skip 'svc.diagtrack' -AsJson | ConvertFrom-Json).actions.Id
        $all | Should -Contain 'svc.diagtrack'
        $skipped | Should -Not -Contain 'svc.diagtrack'
    }

    It '-Only restringe o plano ao que foi pedido' {
        $out = (& $script:Script -Preset Aggressive -Only 'app.solitaire' -AsJson | ConvertFrom-Json).actions
        @($out).Count | Should -Be 1
        $out.Id | Should -Be 'app.solitaire'
    }

    It 'todo item do plano informa como reverter' {
        $out = (& $script:Script -Preset Aggressive -AsJson | ConvertFrom-Json).actions
        foreach ($a in $out) { $a.Reversible | Should -Not -BeNullOrEmpty }
    }
}

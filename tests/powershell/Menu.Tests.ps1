<#
    Contrato do menu PowerShell.

    O menu e a porta de entrada de quem nao decora nome de script, entao o que
    interessa aqui e o que ele PROMETE: categoria para todo script, catalogo que
    sai na mesma ordem da tela, e paridade com o menu Bash - porque os dois
    divergirem em silencio ja foi o problema real do -AsJson.

    O catalogo e lido do proprio -Catalog, e nao reimplementado neste arquivo:
    um teste que le os cabecalhos por conta propria so provaria que duas copias
    da mesma leitura concordam.
#>

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:MenuPath = Join-Path $script:Root 'Menu.ps1'
    $script:BashMenu = Join-Path $script:Root 'menu.sh'

    # Chamado no proprio processo, e nao com "powershell -File": um dos jobs de
    # Pester roda em Linux, onde esse executavel nao existe. O 'exit' de dentro
    # do Menu.ps1 encerra so o script chamado, nao a sessao do Pester.
    #
    # O -join importa porque a saida volta como ARRAY de linhas, e manda-la pelo
    # cano entregaria uma linha solta por vez ao ConvertFrom-Json.
    $bruto = & $script:MenuPath -Catalog
    # O ForEach-Object tambem: no PowerShell 5.1 o ConvertFrom-Json entrega o
    # array inteiro como UM item, e um @() em volta so o embrulha de novo.
    $script:Catalog = @((($bruto -join "`n") | ConvertFrom-Json) | ForEach-Object { $_ })

    # A mesma ordem que a tela desenha, e a mesma dos dois lados do toolkit.
    $script:Order = @('Triage', 'Network', 'Services', 'Security', 'Backup', 'Inventory')
}

Describe 'Catalogo' {
    It 'traz uma entrada por script da pasta powershell/' {
        $arquivos = @(Get-ChildItem -Path (Join-Path $script:Root 'powershell') -Filter *.ps1 |
                Where-Object { $_.Name -notlike 'OpsToolkit.*' })
        $script:Catalog.Count | Should -Be $arquivos.Count
    }

    It 'toda entrada tem nome, categoria e resumo' {
        foreach ($e in $script:Catalog) {
            $e.name | Should -Not -BeNullOrEmpty
            $e.category | Should -Not -BeNullOrEmpty
            $e.summary | Should -Not -BeNullOrEmpty -Because "$($e.name) ficou sem resumo"
        }
    }

    It 'nenhuma categoria caiu em Other' {
        # 'Other' e a rede de seguranca para categoria escrita errada. Ela
        # existe para o script nao sumir da tela, nao para ser usada: se alguem
        # aparece ali, e erro de digitacao no cabecalho.
        $orfaos = @($script:Catalog | Where-Object { $_.category -notin $script:Order })
        $orfaos.Count | Should -Be 0 -Because "categoria desconhecida em: $($orfaos.name -join ', ')"
    }

    It 'sai agrupado, e nao intercalado' {
        # A numeracao da tela segue esta ordem. Se o catalogo intercalar
        # categorias, o numero que alguem le nao e o numero que vai digitar.
        $vistas = New-Object System.Collections.Generic.List[string]
        $atual = ''
        foreach ($e in $script:Catalog) {
            if ($e.category -ne $atual) {
                $vistas.Contains($e.category) | Should -BeFalse -Because "$($e.category) aparece em dois blocos"
                $vistas.Add($e.category)
                $atual = $e.category
            }
        }
    }

    It 'as categorias saem na ordem do dia de trabalho' {
        # Triagem primeiro porque e por onde todo chamado comeca.
        $blocos = @($script:Catalog | ForEach-Object { $_.category } | Select-Object -Unique)
        $esperado = @($script:Order | Where-Object { $_ -in $blocos })
        ($blocos -join ',') | Should -Be ($esperado -join ',')
    }

    It 'o resumo do catalogo e a frase inteira, nao a cortada' {
        # O corte e coisa da tela; o -Catalog serve para automacao. O menu Bash
        # faz igual, e as duas saidas precisam concordar.
        $e = $script:Catalog | Where-Object { $_.name -eq 'Get-IncidentTriage' }
        $e | Should -Not -BeNullOrEmpty
        $e.summary.Length | Should -BeGreaterThan 66
        $e.summary | Should -Not -Match '\.\.\.$'
        foreach ($x in $script:Catalog) { $x.summary | Should -Not -Match "`n" }
    }

    It 'toda pergunta declarada tem parametro e rotulo' {
        foreach ($e in $script:Catalog) {
            foreach ($a in @($e.asks)) {
                $a.param | Should -Not -BeNullOrEmpty -Because "$($e.name) tem Ask: sem parametro"
                $a.label | Should -Not -BeNullOrEmpty -Because "$($e.name) tem Ask: sem rotulo"
            }
        }
    }

    It 'toda pergunta aponta para um parametro que o script realmente tem' {
        # Um Ask: com o nome errado perguntaria e depois estouraria no splat.
        foreach ($e in $script:Catalog) {
            $perguntas = @($e.asks)
            if ($perguntas.Count -eq 0) { continue }
            # Pela AST, e nao pelo Get-Command: o segundo abre o arquivo e
            # estoura o limite de 260 caracteres de caminho em checkout fundo.
            $caminho = Join-Path (Join-Path $script:Root 'powershell') "$($e.name).ps1"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($caminho, [ref]$null, [ref]$null)
            $declarados = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($a in $perguntas) {
                $declarados | Should -Contain $a.param -Because "$($e.name) pergunta -$($a.param), que nao existe"
            }
        }
    }
}

Describe 'Paridade com o menu Bash' {
    It 'os dois menus usam o mesmo conjunto de categorias' {
        # Os dois lados divergirem em silencio ja foi o problema real do
        # -AsJson; aqui a divergencia falha o build.
        $padraoBash = Join-Path (Join-Path $script:Root 'bash') '*.sh'
        $doBash = @(Select-String -Path $padraoBash -Pattern '^# Category:\s*(.+)$' |
                ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
                Select-Object -Unique | Sort-Object)
        $doPs = @($script:Catalog | ForEach-Object { $_.category } | Select-Object -Unique | Sort-Object)
        ($doPs -join ',') | Should -Be ($doBash -join ',')
    }

    It 'a ordem das secoes e a mesma declarada no menu Bash' {
        $bashSrc = Get-Content -LiteralPath $script:BashMenu -Raw
        # [regex]::Match, e nao Should -Match: o $Matches do Should nao chega ao
        # escopo do teste, e ler dali daria indice nulo.
        $m = [regex]::Match($bashSrc, 'ORDEM="([^"]+)"')
        $m.Success | Should -BeTrue -Because 'menu.sh precisa declarar ORDEM'
        $ordemBash = @($m.Groups[1].Value.Split(' ') | Where-Object { $_ -and $_ -ne 'Other' })
        ($script:Order -join ',') | Should -Be ($ordemBash -join ',')
    }
}

Describe 'Interface' {
    BeforeAll {
        $script:Src = Get-Content -LiteralPath $script:MenuPath -Raw
    }

    It '-List continua saindo um nome por linha' {
        # Ha automacao apoiada nisso; o -Catalog foi acrescentado ao lado, e nao
        # no lugar.
        $nomes = @(& $script:MenuPath -List)
        $nomes.Count | Should -Be $script:Catalog.Count
        $nomes | Should -Contain 'Get-IncidentTriage'
    }

    It 'a tela oferece filtro, lote e salvar' {
        $script:Src | Should -Match "' filter"
        $script:Src | Should -Match "' several"
        $script:Src | Should -Match "' save"
        $script:Src | Should -Match "' quit"
    }

    It 'a captura da saida nao passa pelo cano' {
        # Os scripts usam Write-Host: redirecionar o fluxo de informacao para um
        # Tee-Object faria a saida perder a cor justamente na tela, que e onde
        # ela e lida. O transcript grava sem tocar no que aparece.
        $script:Src | Should -Match 'Start-Transcript'
        # A busca e pelo USO no cano; a palavra tambem aparece no comentario
        # que explica por que ela nao esta aqui.
        $script:Src | Should -Not -Match '\|\s*Tee-Object'
    }

    It 'sobrevive a entrada invalida e a filtro sem resultado' {
        # Regressao: Get-VisibleEntry devolvia $null quando o filtro nao casava
        # com nada - uma funcao que retorna array VAZIO nao entrega array - e o
        # .Count seguinte lancava sob Set-StrictMode. A tela morria no lugar de
        # dizer "nada encontrado".
        #
        # O executavel e o do proprio host: um dos jobs de Pester roda em Linux,
        # onde 'powershell' nao existe.
        $host_exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $entrada = "99`nabc`n/zzznaoexiste`n/`ns`n`nq"
        $saida = $entrada | & $host_exe -NoProfile -File $script:MenuPath 2>&1

        $texto = ($saida | ForEach-Object { "$_" }) -join "`n"
        $texto | Should -Match 'Out of range: 99'
        $texto | Should -Match 'Not a number: abc'
        $texto | Should -Match 'nothing matches'
        $texto | Should -Match 'Nothing to save yet'
        $texto | Should -Not -Match 'PropertyNotFound|Exception|nao foi encontrada'
    }

    It 'a tela nao fala portugues' {
        # Os resumos, a saida dos scripts, o --help e o README sao todos em
        # ingles; a interface do menu tem de acompanhar. O portugues aqui e do
        # comentario, e nao do que aparece na tela.
        $visiveis = @([regex]::Matches($script:Src, "Write-Host\s+[`"']([^`"']{3,})[`"']") |
                ForEach-Object { $_.Groups[1].Value })
        $suspeitas = @($visiveis | Where-Object {
                $_ -match '(?i)\b(escolha|salvar|sair|voltar|nada|filtrar|varios|precisa|concluido|fora da|nao e)\b'
            })
        $suspeitas.Count | Should -Be 0 -Because "texto em portugues na tela: $($suspeitas -join ' | ')"
    }

    It 'a tela corta o resumo para a lista caber' {
        # Get-IncidentTriage tem a sinopse mais longa do conjunto; sem corte ela
        # sozinha ocupa tres linhas e some com a estrutura de categorias.
        $host_exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $saida = "q" | & $host_exe -NoProfile -File $script:MenuPath 2>&1
        $linhas = @($saida | ForEach-Object { "$_" })
        $linhas | Should -Not -BeNullOrEmpty
        foreach ($l in $linhas) {
            $l.Length | Should -BeLessOrEqual 100 -Because "linha longa demais: $l"
        }
        (($linhas -join "`n")) | Should -Match '\.\.\.'
    }

    It 'limpa a pasta temporaria ao sair' {
        $script:Src | Should -Match 'Remove-Item[^\r\n]*RunDir|RunDir[^\r\n]*Remove-Item'
    }
}

# A5 — Testes e testabilidade

> **Agente:** A5 (Testes e Testabilidade)  
> **Data:** 2026-09-23  
> **Modo:** relatório; nenhum arquivo de produção ou teste foi alterado. O único arquivo escrito por este agente é este relatório.  
> **Escopo lido:** `audit/00-mapa.md` integral; os 13 arquivos de `PapagaioTests/`, os 20 arquivos de teste de `PapagaioCore/Tests/PapagaioCoreTests/`, a fixture e os scripts de teste/validação; e os ViewModels/Core dos cinco fluxos críticos.

## Baseline reconfirmada (não é uma nova contagem de achados)

- **Pipeline:** executei, com scratch isolado,
  `swift test --scratch-path /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/core-build --no-parallel --filter pipelineTraduzAntesDeSalvarEResumir`.
  Resultado: **1 teste, 2 problemas, código de saída 1**, nos dois pontos de identidade do trecho (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/pipeline-focused.log:8-18`). O teste está fazendo a asserção correta; a causa está no produto, em `Segmentacao.agrupar`, que recria o `UUID`; não é uma falha de teste.
- **Modelos reais:** executei o filtro dos quatro testes de Whisper/Qwen. Resultado: **4 testes, 4 ignorados, código de saída 0** (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/models-focused.log:7-15`). A suíte pode ficar verde sem inferência real.
- **App:** executei a forma do CI com `-parallel-testing-enabled NO`, limite externo de 55 s e log em `/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/app-only.log`. A execução reproduziu as seis falhas de localidade (`app-only.log:200-220,250-254,297-312`) e ficou no primeiro teste OAuth, sem linha final (`app-only.log:317-324`). A baseline anterior já tinha medido os dois OAuth pendurados; esta execução não fabrica uma nova contagem de testes concluídos.
- **Scripts:** `python3 -m unittest Scripts.tests.test_scripts` resultou em **8 testes, 3 falhas, código de saída 1** (`/private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/scripts-tests.log:1-29`).
- **FinderInfo:** a execução focada pelo script com `.build` padrão falhou no `codesign` com `resource fork...`; o mesmo código de teste pôde ser executado no scratch isolado. Isso confirma que o runner depende do ambiente de artefatos, não apenas do resultado dos testes.

## Achados

### A5-001: O gate pode ficar pendurado e não tem limite superior confiável
- Severidade: **ALTO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioTests/OAuthGoogleTests.swift:47-83,169-194`; `Papagaio/Integracao/SessaoOAuthGoogle.swift:160-185,416-451`; `.github/workflows/ci.yml:31-42`; `PapagaioTests/EquipesCloudKitTests.swift:404-449`; `PapagaioCore/Tests/PapagaioCoreTests/RefatoracaoCoreTests.swift:7-55`
- Evidência: o teste inicia uma `Task`, dorme 50 ms e espera `try await espera.value` sem `.timeLimit` (`OAuthGoogleTests.swift:49-63`). A implementação combina essa espera com `withCheckedThrowingContinuation` e `accept` bloqueante (`SessaoOAuthGoogle.swift:423-441,484-498`). No log real, os três testes de callback passaram, o teste de cancelamento iniciou e o processo terminou por interrupção externa: `app-only.log:317-324`. O job CI não passa timeout, `timeout-minutes` nem `-test-timeouts-enabled` (`ci.yml:31-42`). Há ainda dois testes com continuações suspensas sem teto: a fila CloudKit (`EquipesCloudKitTests.swift:417-448`) e o ciclo de vida (`RefatoracaoCoreTests.swift:39-54`).
- Cenário de falha: uma regressão de cancelamento, socket ou actor reentrante deixa uma continuação sem retorno; o runner não emite resultado final, não libera o job e mascara todos os testes seguintes. Foi o que aconteceu com os dois casos OAuth da baseline. A mesma estrutura pode travar os testes de fila/ciclo se um sinal não for retomado.
- Como reproduzir: `PAPAGAIO_TEST_MODE=1 xcodebuild test -project Loro.xcodeproj -scheme Loro -destination 'platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -parallel-testing-enabled NO -only-testing:PapagaioTests -derivedDataPath /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/app-derived`, com wrapper de 55 s. Resultado observado: `returncode=-15`, `timed_out=True`, sem linha final. Para as continuações restantes, o experimento é trocar o primeiro sinal por uma barreira armável e confirmar que a continuação só é liberada no cenário esperado.
- O que procurei para refutar: procurei `timeLimit`, `timeout`, `defer`, `parar()` e todos os usos de `withCheckedContinuation`/`withCheckedThrowingContinuation` nos dois diretórios; procurei opções de timeout no workflow e no scheme; li o teste que conecta um cliente silencioso (`OAuthGoogleTests.swift:169-194`) e ele passa porque `accept` já tem uma conexão. Não há auxiliar de timeout global; o `.timeLimit` aparece nos testes de player/modelos, não nos testes de socket/CloudKit/ciclo.
- Causa raiz: o teste depende de um `accept` que não é cancelável pelo caminho testado e não existe uma fronteira de tempo independente da correção de produção. A limpeza também só ocorre depois de `await`; se a espera não retorna, `parar()` não é alcançado.
- Correção sugerida: corrigir primeiro o desbloqueio do socket (A2-001), adicionar timeout por teste e timeout duro no job; nos testes, usar `defer`/limpeza idempotente e uma barreira determinística em vez de depender de `Task.sleep(50ms)`. Impacto: baixo nos testes, bloqueio do gate eliminado; não aplicar nesta auditoria.
- Referência: `audit/02-achados/A2.md:36-80`; `audit/00-mapa.md:386-434`.

### A5-002: Seis testes de contrato estão amarrados à localidade do processo
- Severidade: **MÉDIO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioTests/EquipesCloudKitTests.swift:202-237`; `PapagaioTests/InterfaceTests.swift:41-51`; `PapagaioTests/MidiasDaConversaViewModelTests.swift:9-46`; `Papagaio/Suporte/Localizacao.swift:5-23`
- Evidência: as expectativas comparam literais portugueses (`"participantes ainda não carregados"`, `"proprietário"`, `"Atualize o Ōmu"`, `"Nenhuma fala..."`, `"desbloquear"`, `"acessar"`). A produção, por outro lado, resolve por `NSLocalizedString` e `Locale.autoupdatingCurrent` (`Localizacao.swift:8-23`). Nesta máquina, `defaults read -g AppleLanguages` retorna `en-BR, pt-BR` e `AppleLocale` retorna `en_BR`; a saída real foi inglesa (`app-only.log:200-220,250-254,297-312`). Foram 6 testes/10 expectativas afetados, não uma prova de defeito na lógica de CloudKit ou mídia.
- Cenário de falha: um runner em inglês ou uma máquina com catálogo diferente fica vermelho mesmo com a saída correta; um teste pode ser “corrigido” trocando o literal pelo idioma da máquina e voltar a falhar na outra localidade. O resultado real fica enterrado no mesmo gate dos travamentos.
- Como reproduzir: o comando de A5-001 reproduziu as seis falhas; o resultado de localidade pode ser isolado com `defaults read -g AppleLanguages` e executando os três arquivos afetados. Experimento de refutação: procurei afirmações diretas e afirmações que usam `.localized`; `InterfaceTests.swift:62-75,123-134,189-200` usa a abstração, enquanto os pontos acima comparam texto literal.
- O que procurei para refutar: percorri todos os testes de app/core por `localized`, literais PT/EN, `Locale.current`, `.autoupdatingCurrent` e mensagens de erro; procurei configuração de idioma no scheme/CI. Não há localidade fixada no scheme (`.xcscheme:25-49`) nem no workflow; a tabela de fallback em `TabelaDeStrings` não é usada pelos testes para criar uma expectativa bilíngue.
- Causa raiz: o teste verifica a apresentação final sem declarar o idioma sob teste e sem injetar o provedor de localização; a entrada do processo decide o resultado.
- Correção sugerida: injetar `Locale`/provedor de localização ou tornar a saída um valor de domínio; ter expectativas explícitas para PT-BR e EN e uma matriz de localidades no CI. Não basta trocar os seis literais para inglês.
- Referência: `audit/00-mapa.md:413-430,716-725`.

### A5-003: O pipeline local é coberto com motores falsos e os quatro testes de inferência real são ignorados por padrão
- Severidade: **ALTO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Tests/PapagaioCoreTests/TranscricaoTests.swift:7-20,151-207`; `PapagaioCore/Tests/PapagaioCoreTests/SumarizacaoTests.swift:6-11,148-182`; `PapagaioCore/Tests/PapagaioCoreTests/PipelineTests.swift:6-49`; `PapagaioCore/Tests/PapagaioCoreTests/DiarizacaoTests.swift:5-18`; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:227-239`; `PapagaioCore/Sources/PapagaioCore/Captura/Armazenamento.swift:24-32`
- Evidência: os testes reais procuram exclusivamente `~/Documents/InterviewLab/Models` e `~/Documents/InterviewLab/Audio` (`TranscricaoTests.swift:9-20`, `SumarizacaoTests.swift:6-11`) e usam `.enabled(if:)`; o filtro executado aqui produziu quatro testes ignorados (`models-focused.log:7-15`). O pipeline declara que usa motores falsos e cria arquivos de 64 bytes sem áudio válido (`PipelineTests.swift:6-9,32-49`). A diarização só verifica a organização e a disponibilidade (`DiarizacaoTests.swift:5-12`). Além disso, o teste de dois canais não define `usavaFones`, portanto a condição de AEC `arquivo.usavaFones == false` em `PipelineDeArquivo.swift:232` não é atravessada; a URL ainda é esperada como `microfone` em `PipelineTests.swift:70-79`.
- Cenário de falha: uma mudança no wrapper Whisper/Qwen, Metal, formato de entrada, AEC, diarização real ou no contrato do modelo pode passar toda a suíte disponível; no app, o fluxo crítico fica sem inferência real e o gate pode terminar verde com quatro testes apenas ignorados. A qualidade de transcrição/resumo e a integração AEC/diarização permanecem desconhecidas.
- Como reproduzir: `swift test --scratch-path /private/var/folders/sn/w7gr29yd5d13g3rnpc9jw_gm0000gp/T/opencode/audit-a5/core-build --no-parallel --filter 'transcricaoReal|contextoConcorrente|audioVazio|sumarizacaoReal'` → 4/4 `skipped`. Para testar a hipótese de AEC, o experimento é um caso `usavaFones: false` com áudio válido e uma barreira no decoder; não criei esse teste de auditoria.
- O que procurei para refutar: li os testes de VAD, `Runtime`, `Preflight`, decodificação, pipeline e todos os testes com `@Suite(.serialized)`; procurei qualquer teste real de AEC, `usavaFones`, inferência Whisper/Qwen ou diarização CoreML. O `bench` até mostra a segunda pasta de modelos (`Scripts/bench-papagaio.sh:60-70`), o que confirma a divergência; não há bootstrap de 9 GB de pesos no CI (`ci.yml:16-20`).
- Causa raiz: o contrato de caminho de modelos foi duplicado em uma organização de desenvolvimento antiga, e as fronteiras de teste foram escolhidas para validar ordem/orquestração, não a fronteira de execução. A ausência de modelos é representada por um teste ignorado, não por uma lacuna visível no gate.
- Correção sugerida: centralizar a resolução de modelo/áudio e a origem do ambiente; declarar testes reais como obrigatórios em um job opcional separado (ou falhar explicitamente quando a capacidade foi solicitada); adicionar um teste de fumaça válido para AEC (`usavaFones=false`) e inferência real. Impacto: maior custo/segredo de CI, mas fecha a lacuna do fluxo crítico.
- Referência: `audit/00-mapa.md:376-381,857-884`.

### A5-004: O ViewModel de gravação/importação e a costura que entrega o áudio à Biblioteca não têm teste
- Severidade: **ALTO**
- Confiança: **CONFIRMADO**
- Local: `Papagaio/ViewModels/GravadorViewModel.swift:63-78,145-188,191-235,369-400`; `Papagaio/App/ContentView.swift:462-509`; `PapagaioCore/Tests/PapagaioCoreTests/CapturaTests.swift:7-15`; `PapagaioCore/Sources/PapagaioCore/Captura/AudioBiblioteca.swift:31-70`
- Evidência: o construtor do VM só aceita `Armazenamento.padrao()` (`GravadorViewModel.swift:71-77`), e `iniciar()` instancia diretamente `SessaoGravacao`, pedindo permissão e iniciando `AVAudioRecorder`/tap (`GravadorViewModel.swift:145-180`). A entrega para a Biblioteca é um callback instalado em `ContentView`, com dois caminhos (reunião pendente ou registro normal) (`ContentView.swift:462-509`). O próprio teste de captura declara que não cobre chamada real, TCC, subida do `SystemAudioTap` ou inteligibilidade (`CapturaTests.swift:7-15`). A busca em `PapagaioTests` e `PapagaioCore/Tests` não encontrou `GravadorViewModel`, `aoProduzirAudio` ou `DitadoDeNota`.
- Cenário de falha: pausa/continuação, cancelamento, gravação curta, nota em andamento, segurança do importador e o desvio para uma reunião pendente podem quebrar sem qualquer teste de regressão; um áudio pode ser salvo no espaço errado ou não ser salvo. A2-002 já encontrou um ciclo de vida de ditado sem chamador, e esta suíte não teria como detectá-lo.
- Como reproduzir: `rg -n 'GravadorViewModel|aoProduzirAudio|DitadoDeNota' PapagaioTests PapagaioCore/Tests` → nenhum resultado. O experimento de refutação seria uma fábrica de `SessaoGravacao`/permissão e um callback falso; não foi criado teste de auditoria.
- O que procurei para refutar: li `GravadorViewModel` inteiro, `ContentView` na instalação dos callbacks, `ImportadorAudio`, `SessaoGravacao`, `AudioBiblioteca` e todos os testes de captura/importação; procurei testes indiretos via `Biblioteca`, `GoogleCalendar` e `Pipeline`. Eles cobram o backend ou o destino, mas não atravessam o VM e o protocolo de `ContentView`; não há um host de UI/integração que force esse caminho.
- Causa raiz: o estado de tela é dono direto de APIs de áudio, TCC, armazenamento e temporizadores, sem protocolo/fábrica/relógio injetável; a orquestração que transforma um resultado em registro de biblioteca fica em um closure de uma `View`.
- Correção sugerida: injetar armazenamento, fábrica de sessão, autorização e relógio; testar a máquina de estados e os dois callbacks com uma sessão falsa. Manter um teste de integração separado para hardware/TCC. Impacto: refatoração pequena na fronteira, sem mudar o contrato de UI.
- Referência: `audit/02-achados/A2.md:82-140`.

### A5-005: O teste da fila serial não prova a exclusão mútua
- Severidade: **MÉDIO**
- Confiança: **PROVÁVEL**
- Local: `PapagaioTests/BibliotecaTests.swift:161-187`; `Papagaio/ViewModels/Biblioteca.swift:776-837,873-883`; `PapagaioCore/Sources/PapagaioCore/Processamento/PipelineDeArquivo.swift:101-190`
- Evidência: o teste enfileira dois arquivos e apenas consulta por polling `estaProcessando` enquanto `aguardar` aguarda `!processando` (`BibliotecaTests.swift:174-186`). A biblioteca de teste aponta para um `Armazenamento` temporário sem modelos; `executarProcessamento` faz `Preflight` e retorna em `.pesosFaltando` antes de criar `MotoresLocais` (`Biblioteca.swift:873-883`). Assim, `maiorSimultaneo` pode permanecer `0` e a expectativa `<= 1` passa sem qualquer janela de contensão. A serialização de produção existe em `Biblioteca.swift:823-837`, mas o teste não a exercita com trabalho bloqueante.
- Cenário de falha: uma regressão que inicie dois pipelines/modelos ao mesmo tempo pode passar porque ambos terminam no preflight antes do primeiro tick de 20 ms; a memória de 3 GB + 6 GB e a fila exclusiva ficam sem prova.
- Como reproduzir: a leitura acima é o experimento estático. O experimento decisivo (não executado para não criar testes na Onda 3) é injetar um executor falso, bloquear o primeiro em uma continuação, enfileirar o segundo e afirmar que o segundo não entra antes do `liberar`; repetir com falha de preflight e com sucesso controlado.
- O que procurei para refutar: li o auxiliar `aguardar` (`BibliotecaTests.swift:80-93`), o teste de duplicidade, `OperacaoComLimpeza`, `MotoresLocais` e o caminho de preflight; procurei `CheckedContinuation`, barreiras, relógios e dublês de pipeline. Não há qualquer afirmação que exija a segunda tarefa ter iniciado, permanecido ativa ou carregado modelo.
- Causa raiz: a asserção observa uma condição externa enquanto o caminho retorna cedo, em vez de controlar a fronteira de concorrência que deveria proteger.
- Correção sugerida: adicionar uma fronteira de execução/injeção de motores e um teste de barreira para serialização, cancelamento e “segundo não inicia”; manter o caso de preflight apenas como teste de estado. Impacto: baixo no código de produção, alto em confiança do gate.
- Referência: `audit/00-mapa.md:39-45,234-242`.

### A5-006: Fixtures compartilham estado global e deixam armazenamento/temporários para trás
- Severidade: **MÉDIO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioTests/PastasDaBibliotecaTests.swift:16-31,66-69`; `PapagaioTests/TarefasDaConversaViewModelTests.swift:11-17,80-96`; `PapagaioCore/Tests/PapagaioCoreTests/PersistenciaTests.swift:298-308`; `PapagaioCore/Sources/PapagaioCore/Captura/Armazenamento.swift:9-18`; `.github/workflows/ci.yml:31-42`
- Evidência: `PastasDaBibliotecaTests` cria uma raiz temporária, mas o auxiliar retorna somente `Biblioteca`, então nenhum chamador consegue removê-la (`PastasDaBibliotecaTests.swift:17-31`); a limpeza de `UserDefaults.standard` é feita só no final feliz, não em `defer` (`:66-69`). O teste de tarefas usa `ArquivoID` aleatório, mas não remove `tarefasDaConversa.<UUID>` (`TarefasDaConversaViewModelTests.swift:11-17,80-96`). O teste de persistência contradiz o comentário de isolamento e chama `Armazenamento.padrao()`, que resolve `~/Library/Application Support/Papagaio` (`PersistenciaTests.swift:303-308`; `Armazenamento.swift:24-32`). O CI não desliga testes paralelos, embora o próprio código reconheça Swift Testing paralelo por padrão.
- Cenário de falha: uma asserção que lance/encerre o teste deixa chaves e diretórios; execuções paralelas podem sobrescrever a lista global de pastas ou apagar estado criado por outro teste. Uma interrupção no teste de persistência pode deixar áudio no Application Support real. Isso cria falhas dependentes de ordem e viola o isolamento prometido pelos comentários.
- Como reproduzir: `rg -n 'UserDefaults\.standard|Armazenamento\.padrao\(|defer|tearDown' PapagaioTests PapagaioCore/Tests`; o resultado mostra os casos acima e também os muitos auxiliares corretos com suite/defer. Para observar a poluição, a execução deve falhar antes da limpeza ou repetir a suíte em paralelo; não alterei dados do usuário para medir isso.
- O que procurei para refutar: procurei `UserDefaults(suiteName:)`, `containerLocal(..., emMemoria:true)`, `defer`, `DownloadDeTeste.limpar` e auxiliares de pasta. `GoogleCalendarTests`, `LixeiraDeMidiaTests`, `BibliotecaTests` e os downloads têm isolamento razoável; o problema são os ramos que escapam para `.standard`/Application Support e os auxiliares que perdem a URL temporária.
- Causa raiz: armazenamentos concretos e fábricas concretas são globais, e a política de limpeza depende de o teste alcançar o fim em vez de uma fronteira `defer`/teardown. O CI ainda deixa o paralelismo como padrão.
- Correção sugerida: passar `UserDefaults`, `FileManager`, armazenamento e relógio por dependência; retornar/limpar a raiz no auxiliar; usar `defer` para toda mutação; limpar o player com `encerrar()` mesmo em falha; evitar `Armazenamento.padrao()` em testes e isolar/desligar paralelismo quando o teste usa estado global. Impacto: baixo, somente infraestrutura de teste.
- Referência: `audit/00-mapa.md:114-117,626-645`.

### A5-007: As operações críticas de CKShare/convite/equipe não têm fronteira testável
- Severidade: **ALTO**
- Confiança: **CONFIRMADO**
- Local: `Papagaio/CloudKit/ServicoDeEquipesCloudKit.swift:40-105,242-370`; `Papagaio/CloudKit/DelegadoDeConvitesCloudKit.swift:12-33`; `Papagaio/CloudKit/SincronizadorDaBibliotecaCloudKit.swift:125-175`; `PapagaioTests/EquipesCloudKitTests.swift:26-154,239-457`
- Evidência: a produção cria `CKRecordZone`, `CKShare`, consulta/salva `CKDatabase`, aceita metadados e executa rotação/exclusão (`ServicoDeEquipesCloudKit.swift:48-105,245-301,339-370`). O delegate chama `ServicoDeEquipesCloudKit()` diretamente, sem uma fronteira para um serviço falso (`DelegadoDeConvitesCloudKit.swift:18-23`). Nos 16 testes de `EquipesCloudKitTests`, o transporte real aparece apenas por trás de `TransporteDeConversasFake`; eles cobrem paginação/payload/fila e políticas, não `criarWorkspace`, `entrarNaEquipe`, `rotacionarCodigo`, `excluirEquipeGlobalmente` ou `aceitar` (busca por esses nomes em `PapagaioTests` não encontrou chamadas).
- Cenário de falha: URL/permissão do `CKShare`, código público, proprietário da zona, remoção do compartilhamento antigo, marcador `EquipeExcluida`, esquema e notificação do delegado podem estar errados enquanto a suíte segue verde; a falha só aparece com duas contas iCloud reais.
- Como reproduzir: `rg -n 'criarWorkspace|entrarNaEquipe|rotacionarCodigo|excluirEquipeGlobalmente|userDidAcceptCloudKitShare' PapagaioTests` → nenhum teste; `EquipesCloudKitTests.swift:359-401` confirma que o dublê substitui somente `TransporteDeConversasCloudKit`. A validação real está fora desta auditoria por depender de serviço externo.
- O que procurei para refutar: percorri todos os testes de CloudKit, `FilaPersistenteCloudKit`, `Sincronizador`, políticas de mídia/conflito e auxiliares; o dublê é bom para paginação/backoff, mas não representa `CKShare`, `CKDatabase`, `shareMetadata`, `accept` ou `deleteRecordZone`. Também procurei testes indiretos do delegate; não há.
- Causa raiz: o serviço de domínio combina regra e APIs CloudKit concretas, com `CKContainer` como única fronteira e sem protocolo para operações de banco/compartilhamento; a suíte escolheu testar a camada de dados superior, não a fronteira que concede/revoga acesso.
- Correção sugerida: extrair um gateway de CloudKit/compartilhamento injetável e testar contratos com adaptador em memória; cobrir criação, entrada, aceite, rotação, exclusão e erros de esquema. Manter um teste separado, opcional, com duas contas iCloud reais. Impacto: refatoração de impacto médio, sem serviço real no gate unitário.
- Referência: `README.md:86-98,124-129`; `audit/00-mapa.md:269-287`.

### A5-008: Os testes de OAuth/MCP do Core não cobrem as implementações que o app executa
- Severidade: **ALTO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Tests/PapagaioCoreTests/IntegracaoTests.swift:6-8,10-149,151-294`; `Papagaio/Integracao/SessaoOAuth.swift:47-73,182-235`; `Papagaio/Integracao/ClienteMCP.swift:25-73,77-149`; `Papagaio/Integracao/GranolaViewModel.swift:27-49`; `Papagaio/Integracao/GoogleCalendarViewModel.swift:18-44`; `PapagaioTests/GoogleCalendarTests.swift:158-216`
- Evidência: o próprio arquivo Core diz que rede/persistência real fica para a CLI (`IntegracaoTests.swift:6-8`) e testa `AutenticacaoOAuth`/mapeamento, não as classes do app. O app tem outra `SessaoOAuth` com `URLSession` privado e DCR próprio (`SessaoOAuth.swift:58-73,182-235`), outro `ClienteMCP` com `initialize`, SSE e sessão (`ClienteMCP.swift:32-73,102-149`), e VMs que instanciam cofre/apresentador/sessão reais (`GranolaViewModel.swift:37-49`, `GoogleCalendarViewModel.swift:29-44`). A suíte app só testa persistência/importação do Calendar e paginação/data inválida com `TransporteCalendarFake`; não há `SessaoOAuth`, `ClienteMCP` ou `GranolaViewModel` em `PapagaioTests`.
- Cenário de falha: DCR com status não-2xx, troca/refresh de token, `client_secret_basic`, revogação, `Mcp-Session-Id`, SSE, nova tentativa após 401, envelope malformado, falha de Keychain ou timer de reconexão podem quebrar no app enquanto os testes puros do Core/CLI permanecem verdes. A suíte atual pode dar confiança a uma classe que não está em produção.
- Como reproduzir: `rg -n 'SessaoOAuth|ClienteMCP|GranolaViewModel|AutenticacaoOAuth' PapagaioTests PapagaioCore/Tests` → só encontra `AutenticacaoOAuth` nos testes Core; o app não tem teste da classe. Para a hipótese, o experimento é um `URLProtocol`/HTTP local que responde DCR, token, refresh, initialize, SSE e 401; não foi executado contra serviço real.
- O que procurei para refutar: li `FonteGoogleCalendarAPI` (tem `Transportar` injetável e dois testes), `RefatoracaoCoreTests` (URLProtocol para downloads), `OAuthGoogleTests` (cofre em memória e callback local) e todos os testes de integração. Reconheci essas fronteiras como boas, mas nenhuma alcança `SessaoOAuth`/`ClienteMCP` do app ou o VM que os orquestra.
- Causa raiz: existem duas implementações de OAuth/MCP em camadas diferentes, e a implementação do app fixa `URLSession`, Keychain e dependências de apresentação dentro do objeto; a suíte Core valida a outra ABI.
- Correção sugerida: escolher uma implementação como contrato de produção; injetar `URLSession`/transporte, cofre, apresentador e relógio; testar fixtures HTTP para sucesso, status, refresh, revogação, nova tentativa, SSE, sessão e cancelamento; testar estado/temporizador dos VMs. Testes com conta real ficam separados. Impacto: médio na refatoração, alto em cobertura do fluxo externo.
- Referência: `audit/00-mapa.md:289-303`.

### A5-009: O ramo de reprodução de dois canais nunca é exercido
- Severidade: **MÉDIO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioCore/Sources/PapagaioCore/Reproducao/ReprodutorDeArquivo.swift:80-104,136-145,191-200`; `PapagaioCore/Tests/PapagaioCoreTests/ReproducaoTests.swift:107-134,136-175,177-202,204-252`; `Papagaio/Funcionalidades/Detalhe/ArquivoDetalheView.swift:484-519`; `PapagaioTests/InterfaceTests.swift:10-22`
- Evidência: a produção promete tocar microfone e sistema em paralelo e usa `secundario` para duração, reprodução, pausa, busca e volume (`ReprodutorDeArquivo.swift:80-104,136-145,191-200`). Todos os quatro construtores dos testes de player passam apenas `audio`; a busca por `secundario` nos testes Core só encontrou referências a “dois canais” em Pipeline/Segmentação, não a `ReprodutorDeArquivo`. A view real passa `secundario: audioSecundario` (`ArquivoDetalheView.swift:495-504`), mas `InterfaceTests` só exercita o atalho de foco.
- Cenário de falha: o secundário pode falhar ao abrir, ficar dessincronizado, não pausar, não acompanhar a busca/velocidade ou sobreviver ao encerramento; os nove testes Core ainda passam porque são monocanalais. A limpeza também é manual: os dois primeiros testes de player pausam, mas não chamam `encerrar()`.
- Como reproduzir: `rg -n 'secundario|secundário' PapagaioCore/Tests` não encontra construtor de player com segundo canal. O experimento decisivo é gerar dois M4A, passar ambos ao init e comparar `deviceCurrentTime`, estado e limpeza; não criei esse teste.
- O que procurei para refutar: li todos os nove `ReproducaoTests`, o auxiliar de geração de áudio, o teste de `encerrar`, os testes de navegação e a integração da view. A suíte é serializada e tem limites de tempo; navegação, cursor de palavra e tempo primário estão bem cobertos, mas apenas a fronteira secundária está ausente.
- Causa raiz: o auxiliar de fixture só retorna um arquivo e o contrato de duas entradas do player não tem um caso de teste; a UI real depende desse ramo não testado.
- Correção sugerida: adicionar um caso mono/microfone+sistema com dois arquivos, afirmar preparação, reprodução/pausa/busca/velocidade e `encerrar()` em `defer`; cobrir também `audioSecundario` ausente/inválido. Impacto: baixo, sem alterar o player.
- Referência: `audit/00-mapa.md:257-267`.

### A5-010: Notas e tarefas da conversa têm máquinas de estado sem testes de comportamento
- Severidade: **MÉDIO**
- Confiança: **CONFIRMADO**
- Local: `Papagaio/ViewModels/NotasDaConversaViewModel.swift:49-130`; `Papagaio/ViewModels/TarefasDaConversaViewModel.swift:56-92,100-183,186-217`; `PapagaioTests/TarefasDaConversaViewModelTests.swift:14-134`; `Papagaio/Persistencia/TarefasDaConversa.swift:4-39`
- Evidência: `NotasDaConversaViewModel.sincronizar` migra notas da gravação de forma idempotente, `agendarSalvamento` tem debounce de 650 ms, `salvarAgora` dispara callback assíncrono e `encerrar` deve persistir o último texto (`NotasDaConversaViewModel.swift:49-130`). O VM de tarefas tem `carregar`, `adicionar`, `salvarEdicao`, `excluirTarefaEmEdicao` (que move para lixeira), aceitar/rejeitar sugestão, conclusão e mover (`TarefasDaConversaViewModel.swift:56-217`). O arquivo de testes cobre criação, prazo, base e responsáveis, mas não chama `salvarEdicao`, `excluirTarefaEmEdicao`, `aceitarSugestao`, `rejeitarSugestao`, `alternarConclusao` ou `mover`; não existe arquivo de teste para `NotasDaConversaViewModel`.
- Cenário de falha: abrir/reabrir uma conversa pode duplicar notas, perder a última edição no desaparecimento da tela, ou uma tarefa pode não chegar à lixeira/continuar como sugestão depois de uma edição. São efeitos de dados no fluxo de detalhe, não só estilo de UI.
- Como reproduzir: `rg -n 'NotasDaConversaViewModel|salvarEdicao|excluirTarefaEmEdicao|aceitarSugestao|rejeitarSugestao' PapagaioTests` → nenhum teste dessas chamadas. O experimento de refutação seria injetar armazenamento/relógio e usar uma barreira no callback; não foi criado teste de auditoria.
- O que procurei para refutar: li os dois VMs, os dois arquivos de testes de tarefas, `TarefasDaConversaStore`, `TarefasDoPainelViewModelTests`, `GoogleCalendarTests` e o uso no detalhe; procurei testes indiretos de notas via `NotasDaConversaViewModel`/`TarefaDaConversaViewModel`. Os testes de painel cobrem o armazenamento geral, mas não a migração/debounce do VM de detalhe nem a lixeira de edição.
- Causa raiz: efeitos colaterais de persistência, debounce e notificação estão escondidos em armazenamentos estáticos e tarefas sem porta de entrada para teste; a cobertura fica concentrada nas regras puras de prazo.
- Correção sugerida: injetar armazenamento, relógio e notificador; testar idempotência, cancelamento do debounce, persistência no `encerrar`, edição, exclusão/lixeira e aceitação/recusa de sugestões. Impacto: baixo a médio, sem mudar o domínio.
- Referência: `audit/00-mapa.md:239-242,257-267`.

### A5-011: Os testes Python do executor testam a implementação antiga e não são executados no CI
- Severidade: **MÉDIO**
- Confiança: **CONFIRMADO**
- Local: `Scripts/tests/test_scripts.py:14-51,61-87`; `Scripts/testa-papagaio-core.sh:44-56,73-95`; `.github/workflows/ci.yml:10-20,22-42`
- Evidência: o teste chama a recuperação de atributo de “rebuild” e exige duas chamadas `swift test`, ausência de `--skip-build` e `xattr <-cr>` (`test_scripts.py:61-82`). O script WIP agora limpa com `find ... xattr -c`, assina o bundle e executa `swift test --skip-build` (`testa-papagaio-core.sh:44-56,80-91`). O setup cria apenas diretórios `Products`, não um `PapagaioCoreTests.xctest`/`codesign` falso (`test_scripts.py:19-25,32-50`). A execução local deu 8 testes/3 falhas; a busca no CI não contém `test_scripts`/`unittest` e só chama o executor do Core/app (`ci.yml:10-20,31-42`).
- Cenário de falha: o teste local fica vermelho por uma expectativa de implementação, enquanto a CI não executa nenhum dos 8; uma regressão real no executor/caminho de recuperação pode não ser vista. As três falhas atuais são WIP compatível com o estado sujo, não prova de que o produto foi alterado.
- Como reproduzir: `python3 -m unittest Scripts.tests.test_scripts` → 8 testes, 3 falhas (`scripts-tests.log:1-29`). `rg -n 'test_scripts|unittest' .github` → nenhum resultado.
- O que procurei para refutar: li `setUp`, o dublê de `swift`, o dublê de `xattr`, todos os oito testes e o script; procurei passos na CI e variantes de `coverage/timeout`. O isolamento temporário do Python está correto, e `test_target_sync...` cobre outro script; o problema é o contrato obsoleto e a ausência de gate.
- Causa raiz: testes de script verificam detalhes de implementação (`xattr -cr`, número de invocações, `--skip-build`) em vez do resultado recuperável, enquanto o executor evoluiu para reassinar o bundle; o job CI não inclui a suíte.
- Correção sugerida: alinhar o teste ao contrato suportado (resultado, código de saída e bundle executável), criar fixture de `PapagaioCoreTests.xctest`/codesign ou injetar o mecanismo de recuperação, e adicionar `python3 -m unittest Scripts.tests.test_scripts` ao CI. Impacto: baixo; não alterar o executor nem o teste nesta auditoria.
- Referência: `audit/00-mapa.md:448-463,556-567`.

### A5-012: O runner do Core depende de FinderInfo e altera a árvore de fontes para recuperar
- Severidade: **MÉDIO**
- Confiança: **CONFIRMADO**
- Local: `Scripts/testa-papagaio-core.sh:27-42,59-75,77-95`; `audit/00-mapa.md:354-358`; `PapagaioCore/Sources/PapagaioCore/ModelosDeDiarizacao/`
- Evidência: o runner primeiro aceita falha de codesign, depois procura a string exata, limpa atributos em profundidade e ainda executa `find` sobre `Sources/PapagaioCore/ModelosDeDiarizacao` (`testa-papagaio-core.sh:35-42,63-75`). A recuperação depende de uma corrida: o comentário do próprio script diz que o File Provider regrava FinderInfo em milissegundos após a limpeza (`:27-33`). Na execução focada com `.build` padrão, o comando terminou antes do teste com `resource fork, Finder information...`/CodeSign e código de saída 1; a tentativa com scratch isolado construiu e deixou o teste de pipeline executar. A baseline anterior registrou a mesma primeira falha e recuperação.
- Cenário de falha: o mesmo commit passa numa máquina sem File Provider e falha localmente, ou falha na primeira execução e passa na segunda; o resultado depende de metadados do filesystem, não do código. A limpeza de atributo na fonte é efeito colateral de um runner de teste e pode reintroduzir a condição antes de o job terminar.
- Como reproduzir: `./Scripts/testa-papagaio-core.sh --filter pipelineTraduzAntesDeSalvarEResumir` (sem scratch) → falha de `CodeSign`/FinderInfo; com `--scratch-path` em diretório aprovado → build e teste alcançam o filtro. O resultado completo depende do estado do File Provider.
- O que procurei para refutar: li o caminho normal, o fallback, `TENTATIVAS`, `xattr`, `codesign`, a limpeza de fonte e o comando CI; procurei scratch path e limpeza. O script tem uma barreira útil (só repete quando a string de FinderInfo aparece) e não trata falha real como sucesso, mas ainda não há timeout nem isolamento do checkout.
- Causa raiz: o gate usa artefatos dentro de uma árvore que pode sincronizar atributos e precisa mutar a própria fonte para recuperar; a política de novas tentativas é temporal, não determinística.
- Correção sugerida: executar o core em scratch fora da árvore sincronizada, copiar/limpar apenas artefatos de teste, evitar `xattr` na fonte versionada e testar a recuperação em CI com um fixture de FinderInfo. Manter um limite de tentativas/tempo. Impacto: baixo/médio no runner, sem tocar domínio.
- Referência: `audit/00-mapa.md:354-358,716-725`.

### A5-013: Alguns testes só verificam proxies e não o contrato anunciado
- Severidade: **BAIXO**
- Confiança: **CONFIRMADO**
- Local: `PapagaioTests/BibliotecaTests.swift:322-341,393-403`; `PapagaioCore/Tests/PapagaioCoreTests/CapturaTests.swift:240-269`; `PapagaioCore/Tests/PapagaioCoreTests/CanceladorDeEcoTests.swift:59-70`; `PapagaioCore/Tests/PapagaioCoreTests/RuntimeTests.swift:167-175`
- Evidência: `faltaDePesosViraFalha` só faz `guard case .falhou`, sem conferir a mensagem de modelo ausente (`BibliotecaTests.swift:323-340`); `erroDeCarregamentoEhObservavel` só executa `carregar()` em container vazio e espera `nil`, sem caminho de falha (`BibliotecaTests.swift:394-403`). O teste que diz “copiando como veio, sem re-encodar” compara sample rate e canais, mas não compara bytes, codec ou assinatura da origem e destino (`CapturaTests.swift:240-268`). `testResetarLimpaEstado` chama `resetar()` e só afirma `resultado.count == 256` (`CanceladorDeEcoTests.swift:59-70`); o teste de monitoramento só afirma memória do processo > 0 (`RuntimeTests.swift:167-175`).
- Cenário de falha: erro de preflight com motivo vazio, erro de carga engolido, recodificação preservando 44,1 kHz/mono, `resetar()` no-op ou monitor que não para podem passar. O nome do teste cria uma confiança maior que a asserção.
- Como reproduzir: a reprodução é a leitura dos quatro trechos e `rg -n '#expect|XCTAssert|Issue.record'`; o experimento de refutação é trocar cada dublê por um caso de falha/estado observável e verificar se o teste ainda passa. Nenhum teste novo foi criado.
- O que procurei para refutar: percorri todos os `#expect`, `XCTAssert`, `Issue.record`, `try!` e callbacks dos dois diretórios; há afirmações fortes em `PipelineTests` (ordem e dois salvamentos), `LixeiraDeMidiaTests` (rollback), `FilaPersistenteCloudKit` (backoff) e `ReproducaoTests` (limpeza), então o achado não é “todos os testes são fracos”; são quatro contratos específicos sem afirmação de resultado completo.
- Causa raiz: o teste foi escrito contra o caminho feliz/um proxy acessível, não contra a falha ou efeito colateral que o nome promete; não há auxiliar de “repositório que falha” para esses VMs.
- Correção sugerida: afirmar a mensagem/erro observável, injetar falha, comparar o arquivo inteiro para verificar a fidelidade da cópia e expor/verificar o estado de reset/monitor; se a intenção for apenas um teste de fumaça, renomear o teste para não prometer o contrato. Impacto: baixo, somente testes.
- Referência: —.

## Matriz por fluxo crítico

| Fluxo | Cobertura executável observada | Cobertura real que falta/limite | Achados relacionados |
|---|---|---|---|
| **Gravação/importação → transcrição → resumo/notas/tarefas** | `CapturaTests` (10), `PipelineTests` (16), `TranscricaoTests`/`SumarizacaoTests` (20 testes, mas 4 reais ignorados), `BibliotecaTests` (26) | Não há teste de `GravadorViewModel`, callback `ContentView`, TCC/microfone/tap real, AEC no pipeline, inferência real, diarização real ou integração VM→SwiftData; a suíte principal usa mocks/bytes inválidos | A5-001,003,004,005,006,013 |
| **Biblioteca: busca, pastas, favoritos, lixeira** | `PersistenciaTests` (23), `BibliotecaTests` (26), `PastasDaBibliotecaTests` (4), `LixeiraDeMidiaTests` (8), `Tarefas*` (12) | A busca em SwiftData é bem testada; não há teste do filtro/ações da `BibliotecaHomeView`, caminho de erro de `carregar`, nem isolamento completo de `UserDefaults.standard`/Application Support | A5-005,006,010,013 |
| **Player + navegação por transcrição** | `ReproducaoTests` (9), `InterfaceTests` (15; apenas um atalho de player) | Navegação, busca, cursor de palavra e timer primário têm testes; não há canal secundário, duração/reprodução/pausa/sincronia de dois arquivos nem teste de ciclo de vida da view | A5-006,009 |
| **Equipes CloudKit: criação, CKShare, código, sincronização** | `EquipesCloudKitTests` (16), com `TransporteDeConversasFake` e fila persistente | Regras de paginação/backoff/conflito são indiretamente cobertas; criação de zona/compartilhamento, entrada, delegado, aceite, rotação, exclusão/marcador global e esquema real não têm teste; serviço real não foi exercitado | A5-001,002,006,007 |
| **OAuth Google Calendar / Granola / MCP** | `OAuthGoogleTests` (9; 2 pendurados na baseline), `GoogleCalendarTests` (5), Core `IntegracaoTests` (14) | Calendar tem fixtures de API; Core testa PKCE/URLs/mapeamento, não a implementação OAuth/MCP do app; não há teste de DCR/token/refresh/revogação, SSE/401, Keychain, timer/VM ou serviço real | A5-001,002,008,011,012 |

## Inventário de testes e sobreposições

### Contagem por suíte

- **App (`PapagaioTests/`) — 13 arquivos, 107 `@Test`:**
  `BibliotecaTests` 26; `EquipesCloudKitTests` 16; `InterfaceTests` 15; `OAuthGoogleTests` 9; `LixeiraDeMidiaTests` 8; `TarefasDaConversaViewModelTests` 7; `GoogleCalendarTests` 5; `OrdenacaoDeTarefasTests` 5; `TarefasDoPainelViewModelTests` 5; `MidiasDaConversaViewModelTests` 4; `PastasDaBibliotecaTests` 4; `InicializacaoExternaTests` 2; `InvalidacaoVisualTests` 1.
- **Core (`PapagaioCore/Tests/PapagaioCoreTests/`) — 20 arquivos, 216 `@Test` + 6 XCTest:**
  `AlinhamentoDeFalantesTests` 19; `CapturaTests` 10; `ContratosTests` 6; `DetectorDeAtividadeDeVozTests` 11; `DiarizacaoTests` 2; `ExportacaoMarkdownTests` 2; `FalasDaConversaTests` 11; `FiltroDeRepeticaoTests` 16; `IntegracaoTests` 14; `PersistenciaTests` 23; `PipelineTests` 16; `RefatoracaoCoreTests` 8; `ReproducaoTests` 9; `ResolvedorDeFalantesTests` 16; `RuntimeTests` 12; `SegmentacaoTests` 11; `SumarizacaoTests` 11; `TranscricaoTests` 9; `ValidacaoDeCitacoesTests` 10; `CanceladorDeEcoTests` 6 XCTest.
- **Scripts — 1 arquivo, 8 `unittest`:** `Scripts/tests/test_scripts.py`.
- **Fixture — 1 WAV commitado + 1 gerador:** `Fixtures/fala_ola_mundo.wav` e `Fixtures/gerar_fixture.sh`. O gerador cita `val_fixture.py`, mas esse arquivo não existe no checkout; a fixture versionada ainda é consumida pelo teste VAD.

### Duplicações e sobreposições que não contam como cobertura independente

- Há um nome de teste exatamente repetido em domínios diferentes: **“Entrada vazia devolve vazio, sem crashar”** em `FiltroDeRepeticaoTests.swift:165` e `SegmentacaoTests.swift:169`; não é duplicação de implementação, mas prejudica a leitura de resultado por nome.
- `PipelineTests` e `PersistenciaTests` exercitam round-trip de IDs/notas em camadas diferentes; `PipelineTests` usa `RepositorioEspiao`, enquanto `PersistenciaTests` usa SwiftData. Somar os dois não prova a fronteira pipeline→SwiftData.
- `CapturaTests` e `PipelineTests` selecionam canais/nomes de arquivo; o segundo usa closures falsas e o primeiro testa apenas decodificação/importação local. Nenhum dos dois executa o `SessaoGravacao` real.
- `EquipesCloudKitTests` cobre transporte/paginação/fila, não o `ServicoDeEquipesCloudKit`; a sobreposição com `Sincronizador` e `FilaPersistente` é deliberada, mas não cobre `CKShare`.
- `TarefasDaConversaViewModelTests` e `TarefasDoPainelViewModelTests` cobrem armazenamentos diferentes (conversa e painel); não substituem um teste do VM de detalhe para edição/lixeira/sugestões.
- `InterfaceTests` e `EquipesCloudKitTests` repetem comparações de texto localizado por literais, reforçando A5-002; o mesmo domínio de resumo tem `SumarizacaoTests` e `ValidacaoDeCitacoesTests`, mas com contratos diferentes (decodificação/prompt versus âncora de citação).

### Dublês e auxiliares refusados como evidência suficiente

- `RepositorioEspiao`, `TransporteDeConversasFake`, `TransporteCloudKitSuspenso`, `TransporteCalendarFake`, `CofreOAuthGoogleEmMemoria`, `ProtocoloDownloadDeTeste` e fechamentos de `transcrever`/`resumir` são úteis para unidade. Eles não modelam SwiftData, `CKShare/CKDatabase`, HTTP real, Keychain real ou inferência real; por isso não foram contados como cobertura ponta a ponta.
- `URLSessionConfiguration.ephemeral` + `URLProtocol` em `RefatoracaoCoreTests` é um contraexemplo positivo de fronteira de teste; a falta é que a mesma fronteira não foi aplicada ao OAuth/MCP do app.

## Cobertura real desconhecida

- Não há `codeCoverageEnabled`, `-enableCodeCoverage` ou configuração equivalente no scheme/CI (`.github/workflows/ci.yml:31-42`, `Loro.xcscheme:25-49`); portanto **percentual de linhas, ramos e funções é desconhecido**.
- Contagem de `@Test` não equivale a cobertura de funcionalidade: há 337 casos contados (107 app + 216 Core Swift Testing + 6 XCTest + 8 Python), mas quatro testes de modelo real foram ignorados e os domínios externos/efeitos colaterais acima não foram executados.
- A heurística de “nome de arquivo aparece em algum teste” não foi usada como prova; no mapa ela aponta 48/171 arquivos de app com par nominal, mas isso não mede linhas nem comportamento.
- A qualidade de Whisper/Qwen, AEC integrado, diarização CoreML, microfone/TCC, dois canais do player, CloudKit real, OAuth/MCP real e Keychain real permanece **não medida**.

## Buscas e refutações realizadas

- `rg` por `GravadorViewModel`, `NotasDaConversaViewModel`, `GranolaViewModel`, `SessaoOAuth`, `ClienteMCP`, `criarWorkspace`, `entrarNaEquipe`, `rotacionarCodigo`, `excluirEquipeGlobalmente` e `userDidAcceptCloudKitShare` em `PapagaioTests`/`PapagaioCore/Tests`: nenhum teste direto para a maioria dos símbolos; as exceções são as camadas puras descritas acima.
- `rg` por `#expect`, `XCTAssert`, `Issue.record`, `try!`, `Task.sleep`, `withCheckedContinuation`, `defer`, `tearDown` e `UserDefaults.standard`: usado para procurar falsos verdes, travamentos, limpeza e efeitos colaterais; as afirmações fortes citadas foram preservadas como refutação.
- `rg` por `codeCoverageEnabled|coverage`, `test_scripts|unittest`, `timeout`, `parallel` em `.github`, scheme e scripts: nenhuma configuração de cobertura, teste de script ou tempo limite no gate; o app CI não passa `-parallel-testing-enabled NO`.
- `git ls-files` confirmou a fixture WAV e o gerador; `test -e .../val_fixture.py` retornou ausente.
- `defaults read -g AppleLanguages` retornou `en-BR, pt-BR` e `AppleLocale` retornou `en_BR`, corroborando as seis falhas de localidade.

## Limitações

- Não executei CloudKit real, duas contas iCloud, OAuth Google/Granola real, MCP real, microfone, TCC, Process Taps ou hardware de captura; as constatações de fluxo externo são lacunas de testabilidade confirmadas, não bugs de serviço comprovados.
- Não rodei a suíte completa do app até uma linha final: a execução foi interrompida no travamento OAuth. Não alterei código para forçar o resultado.
- A suíte Core completa encontrará FinderInfo no `.build` desta máquina; o filtro direto foi repetido em scratch isolado. O working tree já continha WIP em VAD/benchmark/scripts, portanto a reconciliação dos testes Python é classificada como estado do checkout, não como patch de produção aplicado por A5.
- Não criei testes de auditoria, não mexi em produção/testes e não calculei cobertura inventada.

## Contagens finais

- **Achados A5:** 13.
- **Severidade:** 0 CRÍTICO; **5 ALTO** (A5-001,003,004,007,008); **7 MÉDIO** (A5-002,005,006,009,010,011,012); **1 BAIXO** (A5-013).
- **Confiança:** 12 CONFIRMADO; 1 PROVÁVEL (A5-005); 0 HIPÓTESE.
- **Casos inventariados:** 337 (107 app + 216 Core Swift Testing + 6 Core XCTest + 8 Python).
- **Execuções focadas:** pipeline 1/2 problemas; modelos 4/4 testes ignorados; app reproduziu 6 testes de localidade e ficou sem final no OAuth; Python 8/3 falhas; runner com FinderInfo falhou no `.build` padrão e executou no scratch limpo.

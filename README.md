# Demonstração de prevenção com hooks do GitHub Copilot

Este repositório demonstra como usar o evento `preToolUse` para impedir que
agentes do GitHub Copilot modifiquem ou excluam arquivos críticos.

Os arquivos em `config/environments/` simulam configurações realistas de
desenvolvimento, homologação e produção. Eles contêm URLs reservadas pelo
domínio `.test` e parâmetros operacionais fictícios, sem credenciais ou
segredos.

A configuração do hook fica em
`.github/hooks/protect-critical-config.json`. Antes de uma ferramenta ser
executada, as implementações equivalentes
`.github/scripts/protect-critical-files.ps1` e
`.github/scripts/protect-critical-files.sh` analisam seu payload. A política:

- bloqueia ferramentas de criação, edição, patch e exclusão quando elas
  referenciam `config/environments/`;
- bloqueia comandos Bash e PowerShell que tentam alterar, mover, sobrescrever
  ou excluir arquivos nessa pasta;
- permite leitura dos arquivos protegidos e alterações no restante do
  repositório.

Os caminhos protegidos são definidos em `.github/protected-files.txt`, com um
padrão glob relativo à raiz do repositório por linha. Linhas vazias e iniciadas
por `#` são ignoradas. `*` corresponde a caracteres dentro de um segmento,
`**` pode atravessar diretórios e `?` corresponde a um caractere. Nesta demo,
`config/environments` protege a própria pasta e `config/environments/**`
protege todo o seu conteúdo.

Quando há bloqueio, o hook retorna `permissionDecision: "deny"` e explica a
política ao agente. O mesmo comportamento funciona no GitHub Copilot CLI e no
Copilot cloud agent.

## Pré-requisitos

- GitHub Copilot CLI;
- PowerShell no Windows ou Bash com `awk` e `grep` no Linux, macOS e Codespaces.

## Como testar com o GitHub Copilot CLI

Os hooks são carregados quando uma sessão começa. Na raiz do repositório,
inicie uma nova sessão:

```powershell
copilot
```

Peça primeiro uma operação permitida:

```text
Leia config/environments/production.yaml e resuma a configuração, sem alterar
nenhum arquivo.
```

Em seguida, tente editar um arquivo protegido:

```text
Altere request_timeout_ms para 8000 em
config/environments/production.yaml.
```

O Copilot pode tentar usar uma ferramenta de edição ou um patch. O hook deve
negar a execução e informar que a pasta é protegida.

Para testar uma tentativa de exclusão:

```text
Exclua config/environments/staging.yaml.
```

Para confirmar que alterações fora da pasta continuam permitidas:

```text
Crie um arquivo chamado anotacoes.txt com o texto "teste permitido".
```

Depois do teste, o arquivo `anotacoes.txt` pode ser removido.

## Limitações

Esta demo protege o fluxo normal de ferramentas dos agentes. Ela não substitui
permissões do sistema operacional, proteção de branches ou revisão de código.
Comandos indiretos ou deliberadamente ofuscados também podem exigir políticas
mais rigorosas. Em produção, combine hooks com controles de acesso e mantenha
os scripts de política fora do alcance de alterações não autorizadas.

Os hooks do Copilot também não impedem que um pull request com alterações em
arquivos protegidos seja mesclado no GitHub. Para controlar merges, use um
[workflow do GitHub Actions acionado por `pull_request`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)
que analise o diff e configure seu resultado como um
[status check obrigatório no ruleset](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#require-status-checks-to-pass-before-merging).
Não existe uma Action específica necessária: o próprio workflow pode comparar
os arquivos alterados com os padrões protegidos. Um arquivo
[`CODEOWNERS`](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
pode ainda exigir a aprovação dos responsáveis pelos caminhos críticos.

Consulte a
[referência oficial de hooks](https://docs.github.com/en/copilot/reference/hooks-reference)
para detalhes sobre eventos, payloads e decisões.

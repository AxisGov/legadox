#!/usr/bin/env bash
# Trabalho e task correntes, lidos dos artefatos das skills de origem (DL-56).
# Ate a correcao, a lib lia `.expx/trabalho-atual.json`, que nenhuma skill grava:
# sem id, o raio nunca era achado e todos os hooks de metodo saiam permitindo,
# inclusive os de bloqueio. Achado M6 do CodeAnt em katosmv/conselhos-municipais#208.
#
# Cada caso roda nas duas arvores (.claude e .opencode) e com e sem jq no PATH.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# PATH sem jq: as ferramentas que a lib e os hooks usam, e nada mais.
mkdir -p "$T/semjq"
for c in cat awk sed grep head tail tr date mkdir wc dirname basename mv ls sort cut git find; do
  p="$(command -v "$c" 2>/dev/null)" && ln -s "$p" "$T/semjq/$c"
done
BASH_BIN="$(command -v bash)"

ok=0; falhou=0
confere() { # confere <nome> <obtido> <esperado>
  if [ "$2" = "$3" ]; then ok=$((ok+1)); printf '  ok    %s\n' "$1"
  else falhou=$((falhou+1)); printf '  FALHA %s (obtido: [%s], esperado: [%s])\n' "$1" "$2" "$3"; fi
}

# ------------------------------------------------------------------ fixtures

projeto() { # projeto <nome> — projeto em modo legado, vazio
  local p="$T/p/$1"; rm -rf "$p"; mkdir -p "$p/docs/legado/raio" "$p/.expx"
  printf '# Perfil\n' >"$p/docs/legado/PERFIL.md"
  printf '%s\n' "$p"
}

planejamento() { # planejamento <pasta> <trabalho_id>
  mkdir -p "$1"
  printf -- '---\nexpx_schema: 1\nexpx_tool: sprintx\nkind: planejamento\ntrabalho_id: %s\nestado: em_curso\n---\n' "$2" >"$1/00-PLANEJAMENTO.md"
}

ocorrencia() { # ocorrencia <pasta> <trabalho_id>
  mkdir -p "$1"
  printf -- '---\nexpx_schema: 1\nexpx_tool: runx\nkind: ocorrencia\ntrabalho_id: %s\ntitulo: Frete\n---\n' "$2" >"$1/00-OCORRENCIA.md"
}

orquestrador() { # orquestrador <pasta> <ferramenta> <trabalho_id> <status> <concluido_em>
  mkdir -p "$1"
  printf -- '---\nexpx_schema: 1\nexpx_tool: %s\nkind: orquestrador\ntrabalho_id: %s\nstatus: %s\nconcluido_em: %s\n---\n' "$2" "$3" "$4" "$5" >"$1/ORQUESTRADOR.md"
}

raio_alto() { # raio_alto <projeto> <id>
  printf '# Raio\n\nfaixa: ALTO\n\nAprovado por: {{validador}}\n' >"$1/docs/legado/raio/$2.md"
}

# ------------------------------------------------------------------ execucao

LIB_REL="hooks/legadox/comum/legadox-comum.sh"

lib() { # lib <arvore> <path> <projeto> <expressao>
  printf '{}' | CLAUDE_PROJECT_DIR="$3" PATH="$2" \
    "$BASH_BIN" -c '. "$1"; eval "$2"' _ "$R/$1/$LIB_REL" "$4" 2>/dev/null
}

hook() { # hook <arvore> <path> <projeto> <hook> <arquivo alvo> — imprime o codigo de saida
  local saida
  printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$5" \
    | CLAUDE_PROJECT_DIR="$3" PATH="$2" "$BASH_BIN" "$R/$1/hooks/legadox/$4.sh" >"$T/out" 2>"$T/err"
  saida=$?
  printf '%s\n' "$saida"
}

for arvore in .claude .opencode; do
  for modo in comjq semjq; do
    if [ "$modo" = comjq ]; then P="$PATH"; else P="$T/semjq"; fi
    if [ "$modo" = comjq ] && ! command -v jq >/dev/null 2>&1; then continue; fi
    echo "== $arvore ($modo) =="
    tid() { lib "$arvore" "$P" "$1" 'legadox_trabalho_id'; }
    tmot() { lib "$arvore" "$P" "$1" 'legadox_trabalho_motivo'; }
    task() { lib "$arvore" "$P" "$1" 'legadox_task_atual'; }
    kmot() { lib "$arvore" "$P" "$1" 'legadox_task_motivo'; }

    # --- o defeito: sprintx so com 00-PLANEJAMENTO (F1), antes do ORQUESTRADOR (F4)
    p="$(projeto sx-f1)"
    planejamento "$p/docs/sprintx/features/exportacao-csv" exportacao-csv
    raio_alto "$p" exportacao-csv
    confere "sprintx na F1: id da pasta" "$(tid "$p")" exportacao-csv
    confere "sprintx na F1: raio ALTO sem aprovacao bloqueia" "$(hook "$arvore" "$P" "$p" aprovacao-em-raio-alto src/a.js)" 2

    # --- runx so com 00-OCORRENCIA (E1): o id do raio e a pasta, nao o OC-ID
    p="$(projeto rx-e1)"
    ocorrencia "$p/docs/manutencao/OC-2026-0142-frete" OC-2026-0142
    raio_alto "$p" OC-2026-0142-frete
    confere "runx no E1: id e a pasta <OC-ID>-<slug>" "$(tid "$p")" OC-2026-0142-frete
    confere "runx no E1: raio ALTO sem aprovacao bloqueia" "$(hook "$arvore" "$P" "$p" aprovacao-em-raio-alto src/a.js)" 2

    # --- plano escrito sem raio: avisa citando o trabalho
    p="$(projeto sem-raio)"
    planejamento "$p/docs/sprintx/features/fx" fx
    confere "plano sem raio: aviso sai 0" "$(hook "$arvore" "$P" "$p" raio-antes-do-plano docs/sprintx/features/fx/sprint-01/tasks.md)" 0
    confere "plano sem raio: aviso cita o raio do trabalho" "$(grep -c 'docs/legado/raio/fx.md' "$T/err")" 1

    # --- o lock antigo e ignorado, mesmo presente
    p="$(projeto lock-residual)"
    printf '{"trabalho_id":"fantasma","task":"T-99.99"}\n' >"$p/.expx/trabalho-atual.json"
    raio_alto "$p" fantasma
    confere "trabalho-atual.json residual e ignorado" "$(tid "$p")" ""
    confere "trabalho-atual.json residual: motivo nenhum" "$(tmot "$p")" nenhum
    confere "trabalho-atual.json residual: nao bloqueia" "$(hook "$arvore" "$P" "$p" aprovacao-em-raio-alto src/a.js)" 0

    # --- ORQUESTRADOR decide o fim do trabalho
    p="$(projeto concluido)"
    planejamento "$p/docs/sprintx/features/velha" velha
    orquestrador "$p/docs/sprintx/features/velha" sprintx velha concluido 2026-09-01
    ocorrencia "$p/docs/manutencao/OC-2026-0007-x" OC-2026-0007
    orquestrador "$p/docs/manutencao/OC-2026-0007-x" runx OC-2026-0007 concluido 2026-09-02
    planejamento "$p/docs/sprintx/features/nova" nova
    orquestrador "$p/docs/sprintx/features/nova" sprintx nova bloqueado null
    confere "concluidos nao contam; bloqueado conta" "$(tid "$p")" nova

    p="$(projeto nao-iniciado)"
    ocorrencia "$p/docs/manutencao/OC-2026-0001-a" OC-2026-0001
    orquestrador "$p/docs/manutencao/OC-2026-0001-a" runx OC-2026-0001 nao_iniciado null
    confere "nao_iniciado conta como aberto" "$(tid "$p")" OC-2026-0001-a

    # --- ambiguidade e invalidez: indeterminado, falha aberta
    p="$(projeto dois)"
    planejamento "$p/docs/sprintx/features/a" a
    ocorrencia "$p/docs/manutencao/OC-2026-0002-b" OC-2026-0002
    raio_alto "$p" a
    confere "dois abertos: indeterminado" "$(tid "$p")" ""
    confere "dois abertos: motivo varios" "$(tmot "$p")" varios
    confere "dois abertos: nao bloqueia" "$(hook "$arvore" "$P" "$p" aprovacao-em-raio-alto src/a.js)" 0

    p="$(projeto contraditorio)"
    planejamento "$p/docs/sprintx/features/a" a
    orquestrador "$p/docs/sprintx/features/a" sprintx a concluido null
    confere "concluido sem data: invalido" "$(tmot "$p")" invalido
    orquestrador "$p/docs/sprintx/features/a" sprintx a em_andamento 2026-09-01
    confere "aberto com data: invalido" "$(tmot "$p")" invalido
    orquestrador "$p/docs/sprintx/features/a" sprintx a pausado null
    confere "status fora do enum: invalido" "$(tmot "$p")" invalido

    p="$(projeto id-divergente)"
    planejamento "$p/docs/sprintx/features/a" outro
    planejamento "$p/docs/sprintx/features/b" b
    orquestrador "$p/docs/sprintx/features/b" sprintx b concluido 2026-09-01
    confere "sprintx com id diferente da pasta: invalido" "$(tmot "$p")" invalido
    p="$(projeto id-runx)"
    ocorrencia "$p/docs/manutencao/OC-2026-0003-x" OC-2026-0004
    confere "runx com pasta de outro OC-ID: invalido" "$(tmot "$p")" invalido
    p="$(projeto id-prefixo)"
    ocorrencia "$p/docs/manutencao/OC-2026-00031-x" OC-2026-0003
    confere "runx com OC-ID so prefixo de texto: invalido" "$(tmot "$p")" invalido

    p="$(projeto kind-errado)"
    mkdir -p "$p/docs/sprintx/features/a"
    printf -- '---\nexpx_tool: runx\nkind: planejamento\ntrabalho_id: a\n---\n' >"$p/docs/sprintx/features/a/00-PLANEJAMENTO.md"
    confere "expx_tool errado: invalido" "$(tmot "$p")" invalido
    printf -- '---\nexpx_tool: sprintx\nkind: tasks\ntrabalho_id: a\n---\n' >"$p/docs/sprintx/features/a/00-PLANEJAMENTO.md"
    confere "kind errado: invalido" "$(tmot "$p")" invalido
    printf 'sem frontmatter\n' >"$p/docs/sprintx/features/a/00-PLANEJAMENTO.md"
    confere "sem frontmatter: invalido" "$(tmot "$p")" invalido
    : >"$p/docs/sprintx/features/a/00-PLANEJAMENTO.md"
    confere "arquivo vazio: invalido" "$(tmot "$p")" invalido
    printf -- '---\nexpx_tool: sprintx\nkind: planejamento\ntrabalho_id: a\n' >"$p/docs/sprintx/features/a/00-PLANEJAMENTO.md"
    confere "frontmatter sem fechamento: invalido" "$(tmot "$p")" invalido
    printf -- '---\nexpx_tool: sprintx\nkind: planejamento\ntrabalho_id: a\ntrabalho_id: a\n---\n' >"$p/docs/sprintx/features/a/00-PLANEJAMENTO.md"
    confere "chave de controle duplicada: invalido" "$(tmot "$p")" invalido
    planejamento "$p/docs/sprintx/features/a" a
    printf -- '---\nexpx_tool: sprintx\nkind: orquestrador\ntrabalho_id: a\nstatus: em_andamento\n---\n' >"$p/docs/sprintx/features/a/ORQUESTRADOR.md"
    confere "ORQUESTRADOR sem concluido_em: invalido" "$(tmot "$p")" invalido

    # --- invalido nao e silencioso: o aviso do plano aponta o arquivo
    p="$(projeto invalido-aviso)"
    planejamento "$p/docs/sprintx/features/a" a
    planejamento "$p/docs/sprintx/features/velha" velha
    orquestrador "$p/docs/sprintx/features/velha" sprintx velha concluido null
    raio_alto "$p" a
    confere "invalido: aprovacao nao bloqueia (falha aberta)" "$(hook "$arvore" "$P" "$p" aprovacao-em-raio-alto src/a.js)" 0
    confere "invalido: plano avisa" "$(hook "$arvore" "$P" "$p" raio-antes-do-plano docs/sprintx/features/a/sprint-01/tasks.md)" 0
    confere "invalido: aviso cita o arquivo causador" "$(grep -c 'docs/sprintx/features/velha/ORQUESTRADOR.md' "$T/err")" 1

    # --- layout antigo da sprintx: docs/<slug>/
    p="$(projeto antigo)"
    planejamento "$p/docs/relatorios" relatorios
    confere "layout antigo docs/<slug>/" "$(tid "$p")" relatorios

    # --- sem PERFIL, nada e varrido
    p="$(projeto sem-perfil)"; rm -f "$p/docs/legado/PERFIL.md"
    planejamento "$p/docs/sprintx/features/a" a
    confere "sem modo legado: nao resolve" "$(tid "$p")" ""

    # --- task corrente
    p="$(projeto tasks)"
    d="$p/docs/sprintx/features/a"; planejamento "$d" a; mkdir -p "$d/sprint-01" "$d/sprint-02" "$d/sprint-03"
    printf -- '---\nexpx_tool: sprintx\nkind: tasks\ntrabalho_id: a\ntasks:\n  - id: T-01.01\n    titulo: Um\n    status: concluida\n  - id: T-01.02\n    titulo: Dois\n    status: em_andamento\n    arquivos:\n      cria: []\n---\n\nstatus: em_andamento (prosa nao conta)\n' >"$d/sprint-01/tasks.md"
    printf -- '---\nexpx_tool: sprintx\nkind: plano\ntrabalho_id: a\nsprint:\n  titulo: S2\n  status: em_andamento\nfases:\n  - id: F-02.1\n    status: em_andamento\n    tasks: [T-02.01]\ntasks:\n  - id: T-02.01\n    status: pendente\n---\n' >"$d/sprint-02/tasks.md"
    confere "uma task em andamento; sprint e fase nao contam" "$(task "$p")" T-01.02
    printf -- '---\nkind: tasks\ntasks:\n  - id: T-03.01\n    status: concluida\n    revisao:\n      status: em_andamento\n---\n' >"$d/sprint-03/tasks.md"
    confere "status aninhado dentro da task nao conta" "$(task "$p")" T-01.02
    rm -f "$d/sprint-03/tasks.md"
    sed -i 's/status: pendente/status: em_andamento/' "$d/sprint-02/tasks.md"
    confere "duas em andamento: indeterminada" "$(task "$p")" ""
    confere "duas em andamento: motivo varias" "$(kmot "$p")" varias
    sed -i 's/status: em_andamento$/status: concluida/' "$d/sprint-01/tasks.md"
    confere "kind plano condensado" "$(task "$p")" T-02.01
    sed -i 's/^    status: em_andamento$/    status: concluida/' "$d/sprint-02/tasks.md"
    confere "nenhuma em andamento: motivo nenhuma" "$(kmot "$p")" nenhuma

    # --- a task vai para o rastro, no arquivo do trabalho
    p="$(projeto rastro)"
    d="$p/docs/sprintx/features/a"; planejamento "$d" a; mkdir -p "$d/sprint-01"
    printf -- '---\nkind: tasks\ntasks:\n  - id: T-01.01\n    status: em_andamento\n---\n' >"$d/sprint-01/tasks.md"
    printf '# Raio\n\nfaixa: ALTO\n\nAprovado por: Fulana\nAprovado em: 2026-10-01\n' >"$p/docs/legado/raio/a.md"
    hook "$arvore" "$P" "$p" aprovacao-em-raio-alto src/a.js >/dev/null
    confere "rastro em docs/eventos/a.jsonl com a task" "$(grep -c '"task":"T-01.01"' "$p/docs/eventos/a.jsonl" 2>/dev/null)" 1

    # --- caracterizacao declarada no plano do layout canonico da sprintx
    p="$(projeto caracterizacao)"
    d="$p/docs/sprintx/features/a"; planejamento "$d" a; mkdir -p "$d/sprint-01"
    printf -- '---\nkind: tasks\n---\n\nT-01.01 caracterizacao de src/a.js antes de alterar\n' >"$d/sprint-01/tasks.md"
    printf '# Raio\n\nfaixa: MEDIO\n' >"$p/docs/legado/raio/a.md"
    mkdir -p "$p/src"; : >"$p/src/a.js"; : >"$p/src/b.js"   # arquivo novo nao exige caracterizacao
    hook "$arvore" "$P" "$p" caracterizacao-antes src/a.js >/dev/null
    confere "caracterizacao no plano de docs/sprintx/features/<slug>/ e achada" "$(wc -c <"$T/err" | tr -d ' ')" 0
    hook "$arvore" "$P" "$p" caracterizacao-antes src/b.js >/dev/null
    confere "arquivo nao caracterizado ainda avisa" "$(grep -c 'Alteracao em arquivo sem teste de caracterizacao' "$T/err")" 1
  done
done

# ------------------------------------------------- paridade .claude x .opencode
# Mesmo cenario, uma arvore de cada vez: mesmo codigo de saida, mesma mensagem e a
# mesma linha de rastro (sem o carimbo de hora).
echo "== paridade =="
cenario() { # cenario <projeto> — invalido + aberto + raio ALTO sem aprovacao + task
  planejamento "$1/docs/sprintx/features/a" a
  mkdir -p "$1/docs/sprintx/features/a/sprint-01"
  printf -- '---\nkind: tasks\ntasks:\n  - id: T-01.01\n    status: em_andamento\n---\n' >"$1/docs/sprintx/features/a/sprint-01/tasks.md"
  raio_alto "$1" a
}
for caso in "aprovacao-em-raio-alto src/a.js" "raio-antes-do-plano docs/sprintx/features/a/sprint-01/tasks.md" "zona-de-risco src/a.js"; do
  set -- $caso
  for arvore in .claude .opencode; do
    p="$(projeto "par${arvore}")"; cenario "$p"
    [ "$1" = raio-antes-do-plano ] && rm -f "$p/docs/legado/raio/a.md"
    [ "$1" = zona-de-risco ] && printf '# Perfil\n\nZona: Pagamentos\nPastas: src/\n' >"$p/docs/legado/PERFIL.md" \
      && rm -f "$p/docs/legado/raio/a.md"
    s="$(hook "$arvore" "$PATH" "$p" "$1" "$2")"
    printf '%s\n' "$s" >"$T/par$arvore.saida"
    cp "$T/err" "$T/par$arvore.err"
    sed 's/"ts":"[^"]*"//' "$p/docs/eventos/a.jsonl" >"$T/par$arvore.rastro" 2>/dev/null || : >"$T/par$arvore.rastro"
  done
  confere "$1: mesmo codigo de saida" "$(cat "$T/par.opencode.saida")" "$(cat "$T/par.claude.saida")"
  confere "$1: mesma mensagem" "$(cmp -s "$T/par.claude.err" "$T/par.opencode.err" && echo igual)" igual
  confere "$1: mesmo rastro" "$(cmp -s "$T/par.claude.rastro" "$T/par.opencode.rastro" && echo igual)" igual
  confere "$1: rastro com a task" "$(grep -c '"task":"T-01.01"' "$T/par.claude.rastro")" 1
done

printf '\n  %s ok, %s falhas\n' "$ok" "$falhou"
[ "$falhou" -eq 0 ]

# legadox — biblioteca comum dos hooks.
# Sourced por todos os hooks. Nao executa nada sozinho.
#
# Contrato expx-eventos v1, regras que este arquivo materializa:
#   1. Rapido       — nada de rede, nada de suite, nada de git log pesado
#   3. Falha aberta — hook de metodo que quebra sai 0 e deixa passar
#   6. Sem estado   — toda decisao sai de arquivo que ja existe
#   7. Sempre grava no rastro
#
# Convencao de saida dos hooks que usam esta lib:
#   permitir            exit 0, silencioso
#   avisar   (modo aviso)    exit 0 + stderr, evento regra_violada
#   bloquear (modo bloqueio) exit 2 + stderr, evento acao_bloqueada

set -uo pipefail

# ---------------------------------------------------------------- raiz e stdin

# Raiz do projeto: o harness exporta CLAUDE_PROJECT_DIR. Sem ele, sobe ate achar .git.
legadox_raiz() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"; return 0
  fi
  local d; d="$(pwd)"
  while [ "$d" != "/" ]; do
    [ -d "$d/.git" ] && { printf '%s\n' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  pwd
}

RAIZ="$(legadox_raiz)"
LEGADO="$RAIZ/docs/legado"
EXPX="$RAIZ/.expx"

# O evento JSON chega no stdin, e stdin nao rebobina.
#
# A leitura acontece AQUI, no corpo da lib, uma unica vez, no shell principal.
# Ler sob demanda dentro de uma funcao nao funciona: as funcoes sao quase sempre
# chamadas dentro de $(...), que roda em subshell — o valor lido morreria com o
# subshell e a proxima chamada encontraria stdin ja drenado, devolvendo vazio.
EVENTO_JSON=""
if [ ! -t 0 ]; then EVENTO_JSON="$(cat 2>/dev/null || true)"; fi
[ -z "$EVENTO_JSON" ] && EVENTO_JSON='{}'

legadox_ler_stdin() { return 0; }   # mantida por compatibilidade; leitura ja feita

TEM_JQ=0
command -v jq >/dev/null 2>&1 && TEM_JQ=1

# Extrai campo do evento. Com jq quando ha; senao um grep que cobre string simples.
# Regra 3: sem jq o hook degrada para permissivo, nunca para bloqueio por engano.
legadox_campo() {
  local caminho="$1" saida=""
  legadox_ler_stdin
  if [ "$TEM_JQ" -eq 1 ]; then
    saida="$(printf '%s' "$EVENTO_JSON" | jq -r "$caminho // empty" 2>/dev/null || true)"
  fi
  printf '%s\n' "$saida"
}

legadox_ferramenta() { legadox_campo '.tool_name'; }

# Caminho do arquivo alvo, relativo a raiz. Cobre Write/Edit/MultiEdit/NotebookEdit.
#
# Resolvido uma unica vez no shell principal (mesmo motivo do stdin) e sem jq: o
# caminho e um campo simples e um `case` de bash o extrai por uma fracao do custo de
# subir um processo. jq fica de reserva para o caso raro em que o campo tem escape.
legadox_extrair_caminho() {
  local j="$EVENTO_JSON" f="" resto=""
  case "$j" in
    *'"file_path"'*)     resto="${j#*\"file_path\"}" ;;
    *'"notebook_path"'*) resto="${j#*\"notebook_path\"}" ;;
    *) return 0 ;;
  esac

  # Entre a chave e o valor pode haver espaco e quebra de linha (JSON identado).
  # Assumir `":"` colado faz o parser devolver lixo em vez de vazio — e lixo aqui
  # e pior que falha, porque o hook segue adiante com um caminho invalido.
  resto="${resto#"${resto%%[![:space:]]*}"}"     # espaco, tab, CR ou LF antes dos dois-pontos
  case "$resto" in :*) resto="${resto#:}" ;; *) f="" ;; esac
  resto="${resto#"${resto%%[![:space:]]*}"}"     # espaco, tab, CR ou LF depois dos dois-pontos
  case "$resto" in
    \"*) f="${resto#\"}"; f="${f%%\"*}" ;;
    *)   f="" ;;
  esac

  # Escape no caminho, ou qualquer coisa que o parser simples nao entendeu:
  # cai para o jq, que trata direito.
  case "$f" in
    ''|*\\*) f="$(legadox_campo '.tool_input.file_path')"
             [ -z "$f" ] && f="$(legadox_campo '.tool_input.notebook_path')" ;;
  esac
  [ -z "$f" ] && return 0
  case "$f" in "$RAIZ"/*) f="${f#"$RAIZ"/}" ;; esac
  printf '%s\n' "$f"
}

ARQUIVO_ALVO="$(legadox_extrair_caminho)"
legadox_arquivo_alvo() { printf '%s\n' "$ARQUIVO_ALVO"; }

# ------------------------------------------------------------ trabalho e raio

# O trabalho corrente sai dos artefatos que as skills de origem ja gravam (DL-56),
# nunca do `.expx/estado.json`, que e so exibicao. A pasta do trabalho e reconhecida
# pelo artefato que nasce primeiro — `00-PLANEJAMENTO.md` na F1 da sprintx,
# `00-OCORRENCIA.md` no E1 da runx —, porque o raio age antes do ORQUESTRADOR
# existir (F4 / E2). O ORQUESTRADOR, quando ha, so decide se o trabalho acabou.
#
#   docs/sprintx/features/<slug>/   sprintx
#   docs/<slug>/                    sprintx, layout antigo
#   docs/manutencao/<OC-ID>-<slug>/ runx
#
# Trabalho existe SOMENTE com exatamente uma pasta aberta, e o id e o nome da pasta
# (o nome do raio nas duas integracoes). Nenhuma, varias, ou qualquer artefato
# invalido => indeterminado: os hooks de metodo saem permitindo (falha aberta), e o
# motivo fica em TRABALHO_MOTIVO (nenhum | varios | invalido) para as mensagens.
# Nunca por mtime, nunca por branch, nunca por estado.json.
TRABALHO_ID=""
TRABALHO_PASTA=""
TRABALHO_MOTIVO=""
TRABALHO_INVALIDO=""

# Uma passada de awk sobre todos os artefatos candidatos, so o frontmatter de topo.
# Imprime "ok <pasta>", "nenhum", "varios" ou "invalido <arquivo>".
legadox_resolver_trabalho() {
  local r
  r="$(legadox_candidatos_trabalho | legadox_classificar_trabalho)" || true
  case "$r" in
    "ok "*)       TRABALHO_PASTA="${r#ok }"; TRABALHO_ID="${TRABALHO_PASTA##*/}"; TRABALHO_MOTIVO="" ;;
    "invalido "*) TRABALHO_MOTIVO="invalido"; TRABALHO_INVALIDO="${r#invalido }" ;;
    varios)       TRABALHO_MOTIVO="varios" ;;
    *)            TRABALHO_MOTIVO="nenhum" ;;
  esac
}

# Os artefatos candidatos que existem, um por linha, relativos a raiz. Arquivo vazio
# sai marcado com "!": o awk nunca ve a primeira linha dele, e ele sumiria em vez de
# invalidar a resolucao.
legadox_candidatos_trabalho() {
  ( cd "$RAIZ" 2>/dev/null || exit 0
    local f
    for f in docs/sprintx/features/*/00-PLANEJAMENTO.md docs/sprintx/features/*/ORQUESTRADOR.md \
             docs/manutencao/*/00-OCORRENCIA.md docs/manutencao/*/ORQUESTRADOR.md \
             docs/*/00-PLANEJAMENTO.md docs/*/ORQUESTRADOR.md; do
      [ -f "$f" ] || continue
      if [ -s "$f" ]; then printf '%s\n' "$f"; else printf '!%s\n' "$f"; fi
    done )
}

legadox_classificar_trabalho() {
  local lista vazio
  lista="$(cat)"
  [ -n "$lista" ] || { printf 'nenhum\n'; return 0; }
  vazio="$(printf '%s\n' "$lista" | sed -n 's/^!//p' | head -1)"
  [ -n "$vazio" ] && { printf 'invalido %s\n' "$vazio"; return 0; }
  # Caminhos com espaco nao existem nos layouts acima (slug e OC-ID), mas a lista
  # e passada ao awk linha a linha, sem depender de separacao por espaco.
  local IFS=$'\n'
  # shellcheck disable=SC2086
  set -f; set -- $lista; set +f
  ( cd "$RAIZ" 2>/dev/null && awk '
    function limpo(v) {
      sub(/^[^:]*:/, "", v); gsub(/\r/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      return v
    }
    function nulo(v) { return v == "null" || v == "~" }
    function invalido(f) { if (!(f in RUIM)) { RUIM[f] = 1; ORDEM_RUIM[++NRUIM] = f } }
    FNR == 1 {
      n = split(FILENAME, p, "/"); nome = p[n]
      if (p[2] == "sprintx" && p[3] == "features") { pasta = "docs/sprintx/features/" p[4]; fer = "sprintx" }
      else if (p[2] == "manutencao") { pasta = "docs/manutencao/" p[3]; fer = "runx" }
      else { pasta = "docs/" p[2]; fer = "sprintx" }
      if (!(pasta in FER)) { FER[pasta] = fer; PASTAS[++NP] = pasta }
      ARQ[FILENAME] = pasta; NOME[FILENAME] = nome; ORDEM[++NA] = FILENAME
      estado = ($0 ~ /^---[[:space:]]*$/) ? 1 : 0
      if (!estado) invalido(FILENAME)
      next
    }
    estado != 1 { next }
    /^---[[:space:]]*$/ { estado = 2; FECHOU[FILENAME] = 1; nextfile }
    /^(expx_tool|kind|trabalho_id|status|concluido_em):/ {
      k = $0; sub(/:.*/, "", k)
      if ((FILENAME SUBSEP k) in V) invalido(FILENAME)
      V[FILENAME, k] = limpo($0)
    }
    END {
      for (i = 1; i <= NA; i++) {
        f = ORDEM[i]; pasta = ARQ[f]; fer = FER[pasta]; nome = NOME[f]
        id_pasta = pasta; sub(/.*\//, "", id_pasta)
        if (!(f in FECHOU)) { invalido(f); continue }
        kind = (nome == "ORQUESTRADOR.md") ? "orquestrador" : (nome == "00-OCORRENCIA.md") ? "ocorrencia" : "planejamento"
        if (V[f, "kind"] != kind || V[f, "expx_tool"] != fer) { invalido(f); continue }
        id = V[f, "trabalho_id"]
        if (id == "") { invalido(f); continue }
        if (fer == "sprintx" && id != id_pasta) { invalido(f); continue }
        # O OC-ID tem forma fixa, OC-<AAAA>-<NNNN> (runx, 01-investigacao.md): sem
        # ela, um id truncado como "OC" casaria com qualquer pasta "OC-..." como
        # prefixo. Sem intervalo {n} na regex: o mawk antigo nao o entende.
        if (fer == "runx" && id !~ /^OC-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9]*$/) { invalido(f); continue }
        if (fer == "runx" && id != id_pasta && substr(id_pasta, 1, length(id) + 1) != id "-") { invalido(f); continue }
        if (kind != "orquestrador") continue
        st = V[f, "status"]
        ce = V[f, "concluido_em"]   # ausente chega vazio: invalido nos dois ramos
        if (st == "concluido") {
          if (ce == "" || nulo(ce)) { invalido(f); continue }
          FECHADA[pasta] = 1
        } else if (st == "nao_iniciado" || st == "em_andamento" || st == "bloqueado") {
          if (!nulo(ce)) invalido(f)
        } else invalido(f)
      }
      if (NRUIM) { print "invalido " ORDEM_RUIM[1]; exit }
      abertas = 0
      for (i = 1; i <= NP; i++) if (!(PASTAS[i] in FECHADA)) { abertas++; aberta = PASTAS[i] }
      if (abertas == 0) print "nenhum"
      else if (abertas == 1) print "ok " aberta
      else print "varios"
    }' "$@" 2>/dev/null )
}

legadox_trabalho_id()     { [ -n "$TRABALHO_ID" ] && printf '%s\n' "$TRABALHO_ID"; return 0; }
legadox_trabalho_motivo() { [ -n "$TRABALHO_MOTIVO" ] && printf '%s\n' "$TRABALHO_MOTIVO"; return 0; }

# Explica a um humano por que nao ha trabalho corrente. Vazio quando ha.
legadox_trabalho_indeterminado_msg() {
  case "$TRABALHO_MOTIVO" in
    nenhum)   printf '%s\n' "Nenhum trabalho aberto: nao ha 00-PLANEJAMENTO.md (sprintx) nem 00-OCORRENCIA.md
(runx) de trabalho nao concluido em docs/." ;;
    varios)   printf '%s\n' "Ha mais de um trabalho aberto em docs/, e o legadox nao escolhe entre eles." ;;
    invalido) printf '%s\n' "O artefato $TRABALHO_INVALIDO tem frontmatter invalido ou contraditorio
(kind, expx_tool, trabalho_id que nao casa com a pasta, status ou concluido_em),
entao nenhum trabalho corrente pode ser determinado. Corrija esse arquivo." ;;
  esac
}

# A task corrente: a unica `status: em_andamento` entre os itens da chave de topo
# `tasks:` dos `sprint-*/tasks.md` do trabalho corrente. So valem os arquivos de
# `kind: tasks` ou `kind: plano` (o condensado); o kind pode vir depois da lista,
# entao a contagem de cada arquivo so entra quando ele termina. So frontmatter, so
# o nivel do item: `sprint.status`, `fases[].status` e prosa nao contam. Imprime
# "ok <id>", "nenhuma" ou "varias".
legadox_resolver_task() {
  [ -n "$TRABALHO_PASTA" ] || { printf 'nenhuma\n'; return 0; }
  local f arqs=""
  for f in "$RAIZ/$TRABALHO_PASTA"/sprint-*/tasks.md; do
    [ -f "$f" ] && arqs="$arqs$f"$'\n'
  done
  [ -n "$arqs" ] || { printf 'nenhuma\n'; return 0; }
  local IFS=$'\n'
  # shellcheck disable=SC2086
  set -f; set -- $arqs; set +f
  ( awk '
    function limpo(v) {
      sub(/^[^:]*:/, "", v); gsub(/\r/, "", v)
      sub(/[[:space:]]+#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      return v
    }
    function fecha_item() {
      if (em_item && st == "em_andamento" && id != "") { fn++; fachado = id }
      em_item = 0; id = ""; st = ""
    }
    function fecha_arquivo() {
      fecha_item()
      if (aberto && (kind == "tasks" || kind == "plano") && fn) { n += fn; achado = fachado }
      aberto = 0; fn = 0; fachado = ""; kind = ""
    }
    FNR == 1 {
      fecha_arquivo(); aberto = 1
      fm = ($0 ~ /^---[[:space:]]*$/) ? 1 : 0; topo = ""; ind = -1; next
    }
    fm != 1 { next }
    /^---[[:space:]]*$/ { fecha_arquivo(); fm = 2; nextfile }
    /^[^[:space:]#-][^:]*:/ {
      fecha_item(); topo = $0; sub(/:.*/, "", topo); ind = -1
      if (topo == "kind") kind = limpo($0)
      next
    }
    topo != "tasks" { next }
    {
      linha = $0; gsub(/\r/, "", linha)
      match(linha, /^ */); recuo = RLENGTH
      resto = substr(linha, recuo + 1)
      if (substr(resto, 1, 2) == "- " && (ind < 0 || recuo == ind)) {
        fecha_item(); ind = recuo; em_item = 1
        chave_linha = substr(resto, 3); recuo_chave = recuo + 2
      } else { chave_linha = resto; recuo_chave = recuo }
      if (!em_item || recuo_chave != ind + 2) next
      if (chave_linha ~ /^id:/) id = limpo(chave_linha)
      else if (chave_linha ~ /^status:/) st = limpo(chave_linha)
    }
    END {
      fecha_arquivo()
      if (n == 0) print "nenhuma"
      else if (n == 1) print "ok " achado
      else print "varias"
    }' "$@" 2>/dev/null )
}

legadox_task_atual() {
  local r; r="$(legadox_resolver_task)"
  case "$r" in "ok "*) printf '%s\n' "${r#ok }" ;; esac
  return 0
}

legadox_task_motivo() {
  local r; r="$(legadox_resolver_task)"
  case "$r" in "ok "*) ;; *) printf '%s\n' "${r:-nenhuma}" ;; esac
  return 0
}

legadox_arquivo_raio() {
  local id; id="$(legadox_trabalho_id)"
  [ -z "$id" ] && return 0
  local f="$LEGADO/raio/$id.md"
  [ -f "$f" ] && printf '%s\n' "$f"
}

# A faixa sai do arquivo do raio: linha "faixa: ALTO", "**Faixa:** ALTO" ou "Raio de impacto | ALTO".
# Nao infere, nao adivinha. Sem arquivo de raio, devolve vazio.
#
# Uma passada de awk em vez de grep|grep|head|tr|sed: a faixa e consultada por todos
# os hooks, em toda escrita, e cinco processos por consulta apareciam no relogio.
legadox_faixa() {
  local f; f="$(legadox_arquivo_raio)"
  [ -z "$f" ] && return 0
  # IGNORECASE e extensao do gawk: o awk do macOS a ignora silenciosamente, o que
  # transformaria a leitura da faixa em vazio — e faixa vazia desliga todos os
  # hooks de metodo sem avisar. A comparacao e feita em minusculas, a mao, que e
  # portavel entre BSD awk e gawk.
  awk '
    {
      linha = tolower($0)
      gsub(/é/, "e", linha)
      if (match(linha, /(faixa|raio de impacto|raio)/)) {
        # Separadores de Markdown podem incluir Unicode (por exemplo, travessao).
        # Evita enumerar separadores e o / literal que e invalido no BSD awk.
        # Procura o valor numa janela curta logo depois do rotulo reconhecido.
        s = substr(linha, RSTART + RLENGTH, 32)
        if (match(s, /(baixo|medio|alto)/)) {
          print toupper(substr(s, RSTART, RLENGTH)); exit
        }
      }
    }' "$f" 2>/dev/null
}

# Trabalho e faixa sao imutaveis durante a execucao de um hook. Resolvidos uma vez,
# no shell principal, para que as varias consultas de um mesmo hook nao repitam a
# leitura. A varredura dos artefatos so acontece em modo legado: isto roda ao
# carregar a lib, antes do legadox_saida_rapida de cada hook, e projeto sem
# PERFIL.md nao pode pagar por ela.
[ -f "$LEGADO/PERFIL.md" ] && legadox_resolver_trabalho
FAIXA_CACHE="$(legadox_faixa)"
legadox_faixa() { printf '%s\n' "$FAIXA_CACHE"; }

# Regra de ouro da adocao: nenhum hook de metodo atua em BAIXO.
# Sem faixa conhecida tambem nao atua — hook nao inventa risco.
legadox_faixa_exige_rigor() {
  case "$(legadox_faixa)" in MEDIO|ALTO) return 0 ;; *) return 1 ;; esac
}

legadox_modo_legado_ativo() { [ -f "$LEGADO/PERFIL.md" ]; }

# Saida rapida: o teste mais barato que existe, feito antes de qualquer jq, git ou
# find. Sem PERFIL.md nao ha modo legado, e a esmagadora maioria das chamadas de
# ferramenta acontece em projeto sem modo legado — essas precisam custar quase nada.
#
# Regra 1 do contrato: o hook roda em toda chamada de ferramenta; acima de 200 ms o
# dev sente. Como sao varios hooks em sequencia por escrita, o orcamento real de
# cada um e uma fracao disso.
legadox_saida_rapida() { [ -f "$LEGADO/PERFIL.md" ] || exit 0; }

# ---------------------------------------------------------------------- modo

# Modo por hook, de .expx/hooks.json: {"legadox": {"orcamento-de-mudanca": "aviso"}}
# Ausente => o padrao que o proprio hook declara ao chamar.
legadox_modo() {
  local hook="$1" padrao="$2" cfg="$EXPX/hooks.json" m=""
  if [ -f "$cfg" ] && [ "$TEM_JQ" -eq 1 ]; then
    m="$(jq -r --arg h "$hook" '.legadox[$h] // empty' "$cfg" 2>/dev/null || true)"
  fi
  case "$m" in aviso|bloqueio|desligado) printf '%s\n' "$m" ;; *) printf '%s\n' "$padrao" ;; esac
}

# ---------------------------------------------------------------------- rastro

legadox_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Escapa uma string para JSON sem depender de jq. Bash faz aqui somente os escapes
# exigidos pelos campos que os hooks produzem; assim a regra "sempre grava no
# rastro" continua verdadeira mesmo na instalacao minima.
legadox_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

legadox_lista_json() {
  local arquivos="$1" linha primeiro=1
  printf '['
  while IFS= read -r linha; do
    [ -z "$linha" ] && continue
    [ "$primeiro" -eq 0 ] && printf ','
    printf '"%s"' "$(legadox_json_escape "$linha")"
    primeiro=0
  done <<<"$arquivos"
  printf ']'
}
# Uma linha JSON por evento, append-only, em docs/eventos/<trabalho_id>.jsonl.
# Rotaciona acima de 5 MB, como manda o contrato.
# Falha aqui nunca derruba o hook: o rastro e observabilidade, nao controle.
legadox_rastro() {
  local evento="$1" resultado="$2" detalhe="$3" hook="$4" arquivos="${5:-}"
  {
    local id; id="$(legadox_trabalho_id)"; [ -z "$id" ] && id="sem-trabalho"
    local dir="$RAIZ/docs/eventos"
    mkdir -p "$dir" 2>/dev/null || return 0
    local arq="$dir/$id.jsonl"

    if [ -f "$arq" ]; then
      local tam; tam=$(wc -c <"$arq" 2>/dev/null | tr -d ' ')
      if [ -n "$tam" ] && [ "$tam" -gt 5242880 ] 2>/dev/null; then
        local n=1; while [ -f "$dir/$id.$n.jsonl" ]; do n=$((n+1)); done
        mv "$arq" "$dir/$id.$n.jsonl" 2>/dev/null || true
      fi
    fi

    local faixa; faixa="$(legadox_faixa)"; [ -z "$faixa" ] && faixa="null"
    local task; task="$(legadox_task_atual)"
    local lista="[]"
    if [ -n "$arquivos" ]; then
      if [ "$TEM_JQ" -eq 1 ]; then
        lista="$(printf '%s' "$arquivos" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"
      fi
    fi

    if [ "$TEM_JQ" -eq 1 ]; then
      jq -c -n \
        --arg ts "$(legadox_ts)" --arg id "$id" --arg ev "$evento" \
        --arg res "$resultado" --arg det "$detalhe" --arg hk "$hook" \
        --arg fx "$faixa" --arg tk "$task" --argjson arqs "$lista" \
        '{ts:$ts, expx_eventos:1, trabalho_id:$id, ferramenta:"legadox", origem:"hook",
          evento:$ev, fase:null, task:(if $tk=="" then null else $tk end), agente:"principal",
          resultado:$res, detalhe:$det, arquivos:$arqs,
          hook:$hk, faixa:(if $fx=="null" then null else $fx end)}' >>"$arq" 2>/dev/null || true
    else
      local task_json="null" faixa_json="null"
      [ -n "$task" ] && task_json="\"$(legadox_json_escape "$task")\""
      [ "$faixa" != "null" ] && faixa_json="\"$(legadox_json_escape "$faixa")\""
      lista="$(legadox_lista_json "$arquivos")"
      printf '{"ts":"%s","expx_eventos":1,"trabalho_id":"%s","ferramenta":"legadox","origem":"hook","evento":"%s","fase":null,"task":%s,"agente":"principal","resultado":"%s","detalhe":"%s","arquivos":%s,"hook":"%s","faixa":%s}\n' \
        "$(legadox_json_escape "$(legadox_ts)")" "$(legadox_json_escape "$id")" \
        "$(legadox_json_escape "$evento")" "$task_json" "$(legadox_json_escape "$resultado")" \
        "$(legadox_json_escape "$detalhe")" "$lista" "$(legadox_json_escape "$hook")" \
        "$faixa_json" >>"$arq" 2>/dev/null || true
    fi
  } 2>/dev/null || true
  return 0
}

# ------------------------------------------------------------------- veredito

# Aplica o modo. Chamado no fim de todo hook que decidiu barrar.
# aviso    -> stderr + exit 0  (o modelo le, o trabalho segue)
# bloqueio -> stderr + exit 2  (PreToolUse barra; stderr volta como motivo)
legadox_decidir() {
  local hook="$1" padrao="$2" mensagem="$3" arquivos="${4:-}"
  local modo; modo="$(legadox_modo "$hook" "$padrao")"

  # A decisao encerra o hook; retornar deixaria o chamador registrar falso sucesso.
  [ "$modo" = "desligado" ] && exit 0

  # O rastro leva so a primeira linha da mensagem. A mensagem inteira e instrucao
  # para o modelo, nao dado para o painel — gravar os paragrafos todos incharia o
  # arquivo e empurraria a rotacao de 5 MB sem acrescentar informacao nenhuma.
  local resumo="${mensagem%%$'\n'*}"

  if [ "$modo" = "bloqueio" ]; then
    legadox_rastro "acao_bloqueada" "bloqueado" "$resumo" "$hook" "$arquivos"
    legadox_falar "$hook" "$mensagem" "bloqueio"
    exit 2
  fi

  legadox_rastro "regra_violada" "aviso" "$resumo" "$hook" "$arquivos"
  legadox_falar "$hook" "$mensagem" "aviso"
  exit 0
}

# Como a mensagem chega ao modelo depende do EVENTO, nao da vontade do hook:
#
#   PreToolUse   stderr + exit 2 bloqueia, e o stderr volta como o motivo.
#                Em aviso, stderr tambem e lido.
#   PostToolUse  exit 2 NAO bloqueia e o stderr NAO volta ao modelo. O unico canal
#                e JSON no stdout com hookSpecificOutput.additionalContext.
#                Escrever em stderr aqui e falha silenciosa — o aviso simplesmente
#                nao chega, e o hook parece funcionar.
#
# Por isso a escolha do canal e feita aqui, uma vez, e nao espalhada pelos hooks.
legadox_falar() {
  local hook="$1" mensagem="$2" tipo="$3"
  local evento; evento="$(legadox_campo '.hook_event_name')"
  local texto

  if [ "$tipo" = "aviso" ]; then
    texto="[legadox · aviso · $hook — a acao NAO foi bloqueada]
$mensagem"
  else
    texto="$mensagem"
  fi

  if [ "$evento" = "PostToolUse" ]; then
    if [ "$TEM_JQ" -eq 1 ]; then
      jq -c -n --arg t "$texto" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$t}}' 2>/dev/null \
        || printf '%s\n' "$texto" >&2
    else
      # Sem jq nao da para montar o JSON com seguranca. stderr nao chega ao modelo
      # no PostToolUse, mas ainda aparece no transcript para o humano.
      printf '%s\n' "$texto" >&2
    fi
    return 0
  fi

  printf '%s\n' "$texto" >&2
}

# Saida limpa: silenciosa, como manda a regra 2.
legadox_permitir() { exit 0; }

# Guarda comum a todo hook de metodo. Retorna 1 quando o hook nao deve atuar.
legadox_deve_atuar() {
  legadox_modo_legado_ativo || return 1
  legadox_faixa_exige_rigor || return 1
  return 0
}

#!/usr/bin/env bash
# Todo agente Claude da skill declara `papel:` no frontmatter, e o papel é o
# decidido para ele.
#
# A F4 do ExpxDev vai decidir pelo papel, e não pelo nome, quais agentes
# passam pela integridade final e rodam em primeiro plano: `revisar` e `testar`
# (CONTRATO-expx-orquestracao §2.2, §12.2 e §13.1). Sem `papel:`, o agente
# deixará de ser verificado sem nenhum erro. Por isso o teste também exige o papel esperado:
# trocar o papel de um aprovador muda a garantia, não só um metadado. Os agentes
# do OpenCode não são instalados pelo `expx init` e ficam fora.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# O papel de cada agente, pelo nome do arquivo. Agente novo entra aqui.
esperado() {
  case "$1" in
    avaliador-de-raio) echo investigar ;;
    legadox-cartografo) echo investigar ;;
    *) echo "" ;;
  esac
}

falhas=0
total=0
for agente in "$RAIZ"/.claude/agents/*.md; do
  [ -f "$agente" ] || continue
  total=$((total + 1))
  nome="$(basename "$agente" .md)"
  # Só vale o frontmatter fechado: sem o segundo `---`, a linha não é metadado.
  # Comentário no fim da linha é YAML válido e sai do valor.
  papel="$(awk '
    NR==1 { if ($0 != "---") exit; next }
    $0 == "---" { fechado = 1; exit }
    # Como o YAML le a linha: `papel:x` sem espaco nao e a chave, e as aspas delimitam o valor.
    $0 ~ /^papel:[ \t]/ {
      v = $0; sub(/^papel:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      p = v; n++
    }
    END { if (!fechado) print "frontmatter sem fechamento"; else if (n > 1) print "papel repetido"; else print p }' "$agente")"
  quer="$(esperado "$nome")"
  case "$papel" in
    planejar|implementar|investigar|testar|revisar) ;;
    *) echo "FALHA: ${agente#"$RAIZ"/} sem papel: valido (achado: '${papel}')"; falhas=$((falhas + 1)); continue ;;
  esac
  if [ -z "$quer" ]; then
    echo "FALHA: ${agente#"$RAIZ"/} sem papel decidido neste teste"; falhas=$((falhas + 1))
  elif [ "$papel" != "$quer" ]; then
    echo "FALHA: ${agente#"$RAIZ"/} com papel '${papel}', esperado '${quer}'"; falhas=$((falhas + 1))
  fi
done
[ "$total" -gt 0 ] || { echo "FALHA: nenhum agente em .claude/agents"; exit 1; }
[ "$falhas" -eq 0 ] || exit 1
echo "ok: $total agente(s) com papel"

#!/usr/bin/env bash
# Todo agente Claude da skill declara `classe:` no frontmatter.
#
# Com `.expx/orquestracao.json` ativo, o ExpxDev resolve o modelo de cada agente
# pela classe. Sem `model`, ou com `model: inherit`, não há classe a inferir, e o
# `expx init` falha com `sem_classe` (achado do Conselhos na 0.13.0). Os agentes
# do OpenCode não são instalados pelo `expx init` e ficam fora.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
falhas=0
total=0
for agente in "$RAIZ"/.claude/agents/*.md; do
  [ -f "$agente" ] || continue
  total=$((total + 1))
  # Só vale o frontmatter fechado: sem o segundo `---`, a linha não é metadado.
  # Comentário no fim da linha é YAML válido e sai do valor.
  classe="$(awk '
    NR==1 { if ($0 != "---") exit; next }
    $0 == "---" { fechado = 1; exit }
    /^classe:/ { v = $0; sub(/^classe:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); c = v }
    END { if (fechado) print c; else print "frontmatter sem fechamento" }' "$agente")"
  case "$classe" in
    mecanico_triagem|raciocinio_normal|profundo_excepcional) ;;
    *) echo "FALHA: ${agente#"$RAIZ"/} sem classe: valida (achado: '${classe}')"; falhas=$((falhas + 1)) ;;
  esac
done
[ "$total" -gt 0 ] || { echo "FALHA: nenhum agente em .claude/agents"; exit 1; }
[ "$falhas" -eq 0 ] || exit 1
echo "ok: $total agente(s) com classe"

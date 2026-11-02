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
  classe="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1 && /^classe:/{sub(/^classe:[ \t]*/,""); sub(/[ \t]+$/,""); print}' "$agente")"
  case "$classe" in
    mecanico_triagem|raciocinio_normal|profundo_excepcional) ;;
    *) echo "FALHA: ${agente#"$RAIZ"/} sem classe: valida (achado: '${classe}')"; falhas=$((falhas + 1)) ;;
  esac
done
[ "$total" -gt 0 ] || { echo "FALHA: nenhum agente em .claude/agents"; exit 1; }
[ "$falhas" -eq 0 ] || exit 1
echo "ok: $total agente(s) com classe"

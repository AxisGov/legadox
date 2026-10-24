#!/usr/bin/env bash
# Extracao do caminho alvo pela biblioteca comum, SEM jq (o fallback que todo hook
# de escrita usa). JSON valido pode ter espaco, tab ou quebra de linha antes e
# depois dos dois-pontos; em todos o caminho tem de sair inteiro, nas duas arvores
# (.claude e .opencode). Achado do CodeAnt em katosmv/conselhos-municipais#208.
set -uo pipefail

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# PATH minimo sem jq: a biblioteca so precisa de `cat` para ler o evento.
mkdir -p "$T/bin" "$T/projeto"
ln -s "$(command -v cat)" "$T/bin/cat"
BASH_BIN="$(command -v bash)"

ok=0; falhou=0
caso() { # caso <lib> <nome> <evento> <esperado>
  local obtido
  obtido="$(printf '%s' "$3" | CLAUDE_PROJECT_DIR="$T/projeto" PATH="$T/bin" \
    "$BASH_BIN" -c '. "$1"; printf "%s" "$ARQUIVO_ALVO"' _ "$1")"
  if [ "$obtido" = "$4" ]; then ok=$((ok+1)); printf '  ok    %s\n' "$2"
  else falhou=$((falhou+1)); printf '  FALHA %s (obtido: [%s])\n' "$2" "$obtido"; fi
}

for arvore in .claude .opencode; do
  LIB="$R/$arvore/hooks/legadox/comum/legadox-comum.sh"
  echo "== $arvore =="
  caso "$LIB" "compacto"                    '{"tool_input":{"file_path":"src/a.js"}}' src/a.js
  caso "$LIB" "espaco depois"               '{"tool_input": {"file_path": "src/a.js"}}' src/a.js
  caso "$LIB" "quebra de linha antes"       $'{"tool_input": {"file_path"\n: "src/a.js"}}' src/a.js
  caso "$LIB" "tab antes"                   $'{"tool_input": {"file_path"\t: "src/a.js"}}' src/a.js
  caso "$LIB" "tab depois"                  $'{"tool_input": {"file_path":\t"src/a.js"}}' src/a.js
  caso "$LIB" "quebra de linha depois"      $'{\n  "tool_input": {\n    "file_path":\n      "src/a.js"\n  }\n}' src/a.js
  caso "$LIB" "notebook com CRLF"           $'{"tool_input": {"notebook_path"\r\n:\r\n"n/b.ipynb"}}' n/b.ipynb
  caso "$LIB" "raiz absoluta vira relativa" "{\"tool_input\":{\"file_path\": \"$T/projeto/src/a.js\"}}" src/a.js
done

printf '\n  %s ok, %s falhas\n' "$ok" "$falhou"
[ "$falhou" -eq 0 ]

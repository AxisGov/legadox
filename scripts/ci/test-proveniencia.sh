#!/usr/bin/env bash
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$raiz"

legada_base='((github[.]com[/:]|raw[.]githubusercontent[.]com/)bittencourtthulio/(runx|mergex|sprintx|buildx|expxdev|legadox|stackx|memox|prodx|designx)([.]git)?|bittencourtthulio[.]github[.]io/expxdev|npx[ ]expxdev)'
legada="$legada_base([^[:alnum:]_.-]|$)"
allowlist='scripts/ci/proveniencia-allowlist.tsv'
separador=$'\x1f'
declare -A encontrados=()
declare -A esperados=()
declare -A descricoes=()

[ -f "$allowlist" ] || {
  printf 'allowlist de proveniencia ausente: %s\n' "$allowlist" >&2
  exit 1
}

registrar_ocorrencia() {
  local arquivo="$1"
  local ocorrencia="$2"
  local normalizada
  local chave

  [ -n "$ocorrencia" ] || return 0
  if [[ "$ocorrencia" =~ [^[:alnum:]_.-]$ ]]; then
    ocorrencia="${ocorrencia%?}"
  fi
  normalizada="$(printf '%s' "$ocorrencia" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  chave="$arquivo$separador$normalizada"
  encontrados["$chave"]=$((${encontrados["$chave"]:-0} + 1))
}

registrar_fluxo() {
  local arquivo="$1"
  local ocorrencia

  while IFS= read -r ocorrencia; do
    registrar_ocorrencia "$arquivo" "$ocorrencia"
  done
}

registrar_grep_arquivo() {
  local arquivo="$1"
  local saida
  local status

  if saida="$(LC_ALL=C grep -a -h -o -i -E -- "$legada" "$arquivo")"; then
    registrar_fluxo "$arquivo" <<< "$saida"
    return 0
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      printf 'falha ao varrer arquivo rastreado: %s (grep=%s)\n' "$arquivo" "$status" >&2
      return "$status"
    fi
  fi
  return 0
}

registrar_grep_texto() {
  local arquivo="$1"
  local texto="$2"
  local saida
  local status

  if saida="$(printf '%s\n' "$texto" | LC_ALL=C grep -a -h -o -i -E -- "$legada")"; then
    registrar_fluxo "$arquivo" <<< "$saida"
    return 0
  else
    status=$?
    if [ "$status" -ne 1 ]; then
      printf 'falha ao varrer link rastreado: %s (grep=%s)\n' "$arquivo" "$status" >&2
      return "$status"
    fi
  fi
  return 0
}

lista_rastreados="$(mktemp)" || {
  printf 'nao foi possivel criar lista temporaria de arquivos rastreados\n' >&2
  exit 1
}
trap 'rm -f "$lista_rastreados"' EXIT
git ls-files -z > "$lista_rastreados" || {
  printf 'git ls-files falhou durante a enumeracao de proveniencia\n' >&2
  exit 1
}

while IFS= read -r -d '' arquivo; do
  if [ -L "$arquivo" ]; then
    destino="$(readlink -- "$arquivo")" || {
      printf 'falha ao ler link rastreado: %s\n' "$arquivo" >&2
      exit 1
    }
    registrar_grep_texto "$arquivo" "$destino"
    continue
  fi
  [ -f "$arquivo" ] || continue

  # grep -a torna a verificacao independente de extensao, atributo Git e NUL.
  # Binarios sem uma ocorrencia textual exata sao inertes; se a URL proibida
  # estiver embutida, ela continua sendo proveniencia rastreada e deve falhar.
  registrar_grep_arquivo "$arquivo"
done < "$lista_rastreados"
rm -f "$lista_rastreados"
trap - EXIT

numero_linha=0
while IFS=$'\t' read -r arquivo ocorrencia quantidade finalidade justificativa extra ||
  [ -n "$arquivo$ocorrencia$quantidade$finalidade$justificativa$extra" ]; do
  numero_linha=$((numero_linha + 1))
  [ -n "$arquivo$ocorrencia$quantidade$finalidade$justificativa$extra" ] || continue
  case "$arquivo" in
    \#*) continue ;;
  esac

  if [ -n "$extra" ] || [ -z "$arquivo" ] || [ -z "$ocorrencia" ] ||
    [ -z "$quantidade" ] || [ -z "$finalidade" ] || [ -z "$justificativa" ]; then
    printf 'allowlist invalida na linha %d: sao exigidos cinco campos TSV\n' "$numero_linha" >&2
    exit 1
  fi
  case "$arquivo" in
    */|*'*'*|*'?'*|*'['*|*']'*)
      printf 'allowlist exige arquivo exato, sem diretorio ou curinga: %s\n' "$arquivo" >&2
      exit 1
      ;;
  esac
  [[ "$quantidade" =~ ^[1-9][0-9]*$ ]] || {
    printf 'quantidade invalida na allowlist, linha %d: %s\n' "$numero_linha" "$quantidade" >&2
    exit 1
  }

  decodificada="${ocorrencia//%2E/.}"
  decodificada="${decodificada//%20/ }"
  normalizada="$(printf '%s' "$decodificada" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [ "$decodificada" = "$normalizada" ] || {
    printf 'ocorrencia da allowlist deve estar normalizada em lowercase, linha %d\n' "$numero_linha" >&2
    exit 1
  }
  printf '%s\n' "$normalizada" | grep -Eq "^$legada$" || {
    printf 'ocorrencia invalida na allowlist, linha %d: %s\n' "$numero_linha" "$ocorrencia" >&2
    exit 1
  }

  chave="$arquivo$separador$normalizada"
  [ -z "${esperados[$chave]+definido}" ] || {
    printf 'excecao duplicada na allowlist para %s: %s\n' "$arquivo" "$normalizada" >&2
    exit 1
  }
  esperados["$chave"]="$quantidade"
  descricoes["$chave"]="$finalidade  -  $justificativa"
done < "$allowlist"

violacoes=0
for chave in "${!encontrados[@]}"; do
  arquivo="${chave%%"$separador"*}"
  ocorrencia="${chave#*"$separador"}"
  quantidade="${encontrados[$chave]}"
  if [ -z "${esperados[$chave]+definido}" ]; then
    printf 'origem legada nao autorizada: %s | %s | ocorrencias=%s\n' \
      "$arquivo" "$ocorrencia" "$quantidade" >&2
    violacoes=1
  elif [ "$quantidade" -ne "${esperados[$chave]}" ]; then
    printf 'contagem divergente: %s | %s | esperado=%s encontrado=%s | %s\n' \
      "$arquivo" "$ocorrencia" "${esperados[$chave]}" "$quantidade" \
      "${descricoes[$chave]}" >&2
    violacoes=1
  fi
done
for chave in "${!esperados[@]}"; do
  if [ "${encontrados[$chave]:-0}" -ne "${esperados[$chave]}" ]; then
    arquivo="${chave%%"$separador"*}"
    ocorrencia="${chave#*"$separador"}"
    printf 'excecao ausente ou alterada: %s | %s | esperado=%s encontrado=%s | %s\n' \
      "$arquivo" "$ocorrencia" "${esperados[$chave]}" \
      "${encontrados[$chave]:-0}" "${descricoes[$chave]}" >&2
    violacoes=1
  fi
done
[ "$violacoes" -eq 0 ] || exit 1

if [ -f src/nucleo/catalogo.ts ]; then
  for repo in runx mergex sprintx buildx; do
    grep -q "https://github.com/AxisGov/$repo" src/nucleo/catalogo.ts || {
      printf 'catalogo sem origem canonica AxisGov/%s\n' "$repo" >&2
      exit 1
    }
  done
  grep -q 'https://github.com/AxisGov/expxdev' package.json
else
  for repo in runx mergex sprintx buildx expxdev; do
    grep -q "https://github.com/AxisGov/$repo" README.md || {
      printf 'README sem origem canonica AxisGov/%s\n' "$repo" >&2
      exit 1
    }
  done
fi

workflow='.github/workflows/proveniencia.yml'
if [ ! -f "$workflow" ]; then
  workflow='.github/workflows/ci.yml'
fi
LC_ALL=C awk '
  /^  pull_request:[[:space:]]*(#[^[:cntrl:]]*)?$/ {
    encontrado = 1
    no_bloco = 1
    next
  }
  /^  pull_request:[[:space:]]*\{\}[[:space:]]*(#[^[:cntrl:]]*)?$/ {
    encontrado = 1
    no_bloco = 0
    next
  }
  /^  pull_request:/ {
    encontrado = 1
    invalido = 1
    no_bloco = 0
    next
  }
  no_bloco && /^  [^[:space:]]/ {
    no_bloco = 0
  }
  no_bloco && /^[[:space:]]+[^[:space:]#]/ {
    invalido = 1
  }
  END {
    exit !(encontrado && !invalido)
  }
' "$workflow" || {
  printf 'evento pull_request ausente ou filtrado no workflow de proveniencia\n' >&2
  exit 1
}
grep -Eq '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bash[[:space:]]+scripts/ci/test-proveniencia[.]sh[[:space:]]*(#[^[:cntrl:]]*)?$' "$workflow" || {
  printf 'workflow nao executa scripts/ci/test-proveniencia.sh\n' >&2
  exit 1
}
grep -Eq '^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]+bash[[:space:]]+scripts/ci/test-proveniencia-contrato[.]sh[[:space:]]*(#[^[:cntrl:]]*)?$' "$workflow" || {
  printf 'workflow nao executa scripts/ci/test-proveniencia-contrato.sh\n' >&2
  exit 1
}

printf 'proveniencia AxisGov verificada\n'

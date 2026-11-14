#!/usr/bin/env bash
set -euo pipefail

raiz="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$raiz/scripts/ci/test-proveniencia.sh"
temporario="$(mktemp -d)"
trap 'rm -rf "$temporario"' EXIT

github_host='github.com'
raw_host='raw.githubusercontent.com'
proprietario='bittencourtthulio'
base="$temporario/base"

mkdir -p "$base/scripts/ci" "$base/.github/workflows"
git -C "$base" init -q
cp "$guard" "$base/scripts/ci/test-proveniencia.sh"
printf '%s\n' \
  '# arquivo<TAB>ocorrencia normalizada (%2E representa ponto)<TAB>quantidade<TAB>finalidade<TAB>justificativa' \
  > "$base/scripts/ci/proveniencia-allowlist.tsv"
printf '%s\n' \
  "https://$github_host/AxisGov/runx" \
  "https://$github_host/AxisGov/mergex" \
  "https://$github_host/AxisGov/sprintx" \
  "https://$github_host/AxisGov/buildx" \
  "https://$github_host/AxisGov/expxdev" \
  > "$base/README.md"
printf '%s\n' \
  'name: fixture' \
  'on:' \
  '  pull_request:' \
  'jobs:' \
  '  origem:' \
  '    steps:' \
  '      - run: bash scripts/ci/test-proveniencia.sh' \
  '      - run: bash scripts/ci/test-proveniencia-contrato.sh' \
  > "$base/.github/workflows/proveniencia.yml"
git -C "$base" add .
git -C "$base" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture: guard sob teste'

nova_fixture() {
  local nome="$1"
  local destino="$temporario/$nome"
  git clone -q --no-hardlinks "$base" "$destino"
  printf '%s\n' "$destino"
}

rastrear_texto() {
  local repo="$1"
  local caminho="$2"
  local conteudo="$3"
  mkdir -p "$(dirname "$repo/$caminho")"
  printf '%s\n' "$conteudo" > "$repo/$caminho"
  git -C "$repo" add -- "$caminho"
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm "fixture: $caminho"
}

adicionar_excecao() {
  local repo="$1"
  local caminho="$2"
  local ocorrencia="$3"
  local finalidade="$4"
  local justificativa="$5"
  printf '%s\t%s\t1\t%s\t%s\n' \
    "$caminho" "$ocorrencia" "$finalidade" "$justificativa" \
    >> "$repo/scripts/ci/proveniencia-allowlist.tsv"
  git -C "$repo" add scripts/ci/proveniencia-allowlist.tsv
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm "fixture: autoriza $caminho"
}

esperar_falha() {
  local nome="$1"
  local repo="$2"
  if bash "$repo/scripts/ci/test-proveniencia.sh" >"$temporario/$nome.out" 2>&1; then
    printf 'FALHA: guard aceitou violacao %s\n' "$nome" >&2
    sed -n '1,80p' "$temporario/$nome.out" >&2
    exit 1
  fi
}

esperar_sucesso() {
  local nome="$1"
  local repo="$2"
  if ! bash "$repo/scripts/ci/test-proveniencia.sh" >"$temporario/$nome.out" 2>&1; then
    printf 'FALHA: guard rejeitou caso permitido %s\n' "$nome" >&2
    sed -n '1,120p' "$temporario/$nome.out" >&2
    exit 1
  fi
}

caso_bloqueado() {
  local nome="$1"
  local caminho="$2"
  local conteudo="$3"
  local repo
  repo="$(nova_fixture "$nome")"
  rastrear_texto "$repo" "$caminho" "$conteudo"
  esperar_falha "$nome" "$repo"
}

caso_bloqueado https_mixed bootstrap.sh \
  "https://$github_host/BittencourtThulio/RunX.git"
caso_bloqueado ssh_scp_like bootstrap.sh \
  "git@$github_host:BittencourtThulio/MergeX.git"
caso_bloqueado git_protocol bootstrap.sh \
  "git://$github_host/BITTENCOURTTHULIO/sprintx.git"
caso_bloqueado raw_mixed bootstrap.sh \
  "https://$raw_host/BittencourtThulio/buildx/main/SKILL.md"
caso_bloqueado http_without_dot_git bootstrap.sh \
  "http://$github_host/$proprietario/runx"
caso_bloqueado ssh_scheme bootstrap.sh \
  "ssh://git@$github_host/$proprietario/mergex.git"
caso_bloqueado bootstrap_tracked bootstrap.sh \
  "git clone https://$github_host/$proprietario/runx.git"
caso_bloqueado gitmodules_tracked .gitmodules \
  "[submodule \"legado\"] path = legado url = git@$github_host:$proprietario/mergex.git"
caso_bloqueado workflow_new '.github/workflows/novo-legado.yml' \
  "# clone: https://$github_host/$proprietario/sprintx.git"
caso_bloqueado filename_spaces 'docs/instalador legado.md' \
  "git clone https://$github_host/$proprietario/buildx.git"
caso_bloqueado arbitrary_case bootstrap.sh \
  "https://$github_host/BiTtEnCoUrTtHuLiO/BuIlDx"
# Todos os forks AxisGov, não só os cinco primeiros (conselhos, 2026-11-14): o
# link do README, o asset do banner, o site e o npx do pacote expxdev (o npm é do upstream)
caso_bloqueado fork_legadox docs/ecossistema.md \
  "[legadox](https://$github_host/$proprietario/legadox)"
caso_bloqueado fork_memox_maiusculo docs/ecossistema.md \
  "[memox](https://$github_host/$proprietario/MemoX)"
caso_bloqueado fork_designx_asset docs/ecossistema.md \
  "<img src=\"https://$raw_host/$proprietario/designx/main/.github/assets/banner.svg\">"
caso_bloqueado site_upstream docs/ecossistema.md \
  "https://$proprietario.github.io/expxdev/#legadox"
caso_bloqueado npx_upstream docs/ecossistema.md \
  "npx ""expxdev init"
repo_modulex="$(nova_fixture modulex_sem_fork)"
rastrear_texto "$repo_modulex" docs/ecossistema.md \
  "[modulex](https://$github_host/$proprietario/modulex)"
esperar_sucesso modulex_sem_fork "$repo_modulex"

repo_atributo="$(nova_fixture atributo_binary)"
rastrear_texto "$repo_atributo" bootstrap.sh \
  "https://$github_host/$proprietario/runx.git"
rastrear_texto "$repo_atributo" .gitattributes 'bootstrap.sh binary'
esperar_falha atributo_binary "$repo_atributo"

repo_nul_operacional="$(nova_fixture nul_operacional)"
{
  printf '#!/usr/bin/env bash\n'
  printf '\000git clone https://%s/%s/runx.git\n' "$github_host" "$proprietario"
} > "$repo_nul_operacional/bootstrap.sh"
git -C "$repo_nul_operacional" add bootstrap.sh
git -C "$repo_nul_operacional" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture: script operacional com NUL'
esperar_falha nul_operacional "$repo_nul_operacional"

repo_nul_sem_shebang="$(nova_fixture nul_sem_shebang)"
{
  contador=0
  while [ "$contador" -lt 32 ]; do
    printf '\000\001\002\003\004\005\006\007'
    contador=$((contador + 1))
  done
  printf 'git clone https://%s/%s/runx.git\n' "$github_host" "$proprietario"
} > "$repo_nul_sem_shebang/bootstrap.sh"
git -C "$repo_nul_sem_shebang" add bootstrap.sh
git -C "$repo_nul_sem_shebang" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'fixture: texto operacional ofuscado por NUL'
esperar_falha nul_sem_shebang "$repo_nul_sem_shebang"

repo_extra="$(nova_fixture extra_allowlisted)"
rastrear_texto "$repo_extra" docs/historico-proveniencia.md \
  "https://$github_host/$proprietario/runx https://$github_host/$proprietario/runx"
adicionar_excecao "$repo_extra" docs/historico-proveniencia.md \
  'github%2Ecom/bittencourtthulio/runx' \
  'documentacao historica' \
  'preserva uma unica origem observada para auditoria de migracao'
esperar_falha extra_allowlisted "$repo_extra"

for tipo in migracao fixture historico; do
  repo_permitido="$(nova_fixture "permitido_$tipo")"
  case "$tipo" in
    migracao) caminho='migrations/origem-legada.txt' ;;
    fixture) caminho='fixtures/migracao/origem-legada.txt' ;;
    historico) caminho='docs/historico-proveniencia.md' ;;
  esac
  rastrear_texto "$repo_permitido" "$caminho" \
    "https://$github_host/$proprietario/runx"
  adicionar_excecao "$repo_permitido" "$caminho" \
    'github%2Ecom/bittencourtthulio/runx' \
    "$tipo de proveniencia" \
    'ocorrencia exata necessaria para provar reconhecimento e migracao'
  esperar_sucesso "permitido_$tipo" "$repo_permitido"
done

repo_axisgov="$(nova_fixture axisgov)"
rastrear_texto "$repo_axisgov" bootstrap.sh \
  "git clone https://$github_host/AxisGov/runx.git"
esperar_sucesso axisgov "$repo_axisgov"

repo_binario="$(nova_fixture binario)"
printf '\211PNG\r\n\032\n' > "$repo_binario/asset.bin"
contador=0
while [ "$contador" -lt 32 ]; do
  printf '\000\001\002\003\004\005\006\007' >> "$repo_binario/asset.bin"
  contador=$((contador + 1))
done
printf 'https://%s/AxisGov/runx.git\000' "$github_host" \
  >> "$repo_binario/asset.bin"
git -C "$repo_binario" add asset.bin
git -C "$repo_binario" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture: binario'
esperar_sucesso binario "$repo_binario"

repo_nao_rastreado="$(nova_fixture nao_rastreado)"
printf '%s\n' "https://$github_host/$proprietario/runx.git" \
  > "$repo_nao_rastreado/nao-rastreado.txt"
esperar_sucesso nao_rastreado "$repo_nao_rastreado"

esperar_falha_de_leitura() {
  local nome="$1"
  local repo="$2"
  local bin_falso="$3"

  if PATH="$bin_falso:$PATH" bash "$repo/scripts/ci/test-proveniencia.sh" >"$temporario/$nome.out" 2>&1; then
    printf 'FALHA: guard ignorou erro de leitura %s\n' "$nome" >&2
    exit 1
  fi
  grep -q 'falha ao varrer arquivo rastreado' "$temporario/$nome.out" || {
    printf 'FALHA: erro de leitura nao foi reportado por %s\n' "$nome" >&2
    sed -n '1,80p' "$temporario/$nome.out" >&2
    exit 1
  }
}

repo_limite="$(nova_fixture limite_repositorio)"
rastrear_texto "$repo_limite" docs/fork-valido.md \
  "https://$github_host/$proprietario/runx-fork"
esperar_sucesso limite_repositorio "$repo_limite"

repo_erro_leitura="$(nova_fixture erro_leitura)"
rastrear_texto "$repo_erro_leitura" falha-leitura.txt \
  "https://$github_host/AxisGov/runx"
bin_falso="$repo_erro_leitura/fake-bin"
mkdir -p "$bin_falso"
grep_real="$(command -v grep)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'for argumento in "$@"; do' \
  '  case "$argumento" in' \
  '    *falha-leitura.txt) exit 2 ;;' \
  '  esac' \
  'done' \
  "exec \"$grep_real\" \"\$@\"" \
  > "$bin_falso/grep"
chmod +x "$bin_falso/grep"
esperar_falha_de_leitura erro_leitura "$repo_erro_leitura" "$bin_falso"

for filtro in paths paths-ignore branches branches-ignore types; do
  repo_filtro="$(nova_fixture "workflow_$filtro")"
  case "$filtro" in
    paths|paths-ignore) valor='"docs/**"' ;;
    branches|branches-ignore) valor='"main"' ;;
    types) valor='"opened"' ;;
  esac
  rastrear_texto "$repo_filtro" .github/workflows/proveniencia.yml \
    "$(printf '%s\n' \
      'name: fixture' \
      'on:' \
      '  pull_request:' \
      "    $filtro: [$valor]" \
      'jobs:' \
      '  origem:' \
      '    steps:' \
      '      - run: bash scripts/ci/test-proveniencia.sh' \
      '      - run: bash scripts/ci/test-proveniencia-contrato.sh')"
  esperar_falha "workflow_$filtro" "$repo_filtro"
done

repo_sem_guard="$(nova_fixture workflow_sem_guard)"
rastrear_texto "$repo_sem_guard" .github/workflows/proveniencia.yml \
  "$(printf '%s\n' \
    'name: fixture' \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  origem:' \
    '    steps:' \
    '      - run: bash scripts/ci/test-proveniencia-contrato.sh')"
esperar_falha workflow_sem_guard "$repo_sem_guard"

repo_sem_contrato="$(nova_fixture workflow_sem_contrato)"
rastrear_texto "$repo_sem_contrato" .github/workflows/proveniencia.yml \
  "$(printf '%s\n' \
    'name: fixture' \
    'on:' \
    '  pull_request:' \
    'jobs:' \
    '  origem:' \
    '    steps:' \
    '      - run: bash scripts/ci/test-proveniencia.sh')"
esperar_falha workflow_sem_contrato "$repo_sem_contrato"

for mascarado in guard contrato; do
  repo_mascarado="$(nova_fixture "workflow_mascarado_$mascarado")"
  comando_guard='bash scripts/ci/test-proveniencia.sh'
  comando_contrato='bash scripts/ci/test-proveniencia-contrato.sh'
  case "$mascarado" in
    guard) comando_guard="$comando_guard || true" ;;
    contrato) comando_contrato="$comando_contrato || true" ;;
  esac
  rastrear_texto "$repo_mascarado" .github/workflows/proveniencia.yml \
    "$(printf '%s\n' \
      'name: fixture' \
      'on:' \
      '  pull_request:' \
      'jobs:' \
      '  origem:' \
      '    steps:' \
      "      - run: $comando_guard" \
      "      - run: $comando_contrato")"
  esperar_falha "workflow_mascarado_$mascarado" "$repo_mascarado"
done

printf 'contrato de proveniencia verificado\n'

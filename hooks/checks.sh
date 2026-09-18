#!/usr/bin/env bash
# Leak and slop gate. hooks/pre-commit runs it on staged content, hooks/pre-push on the
# full tree. Exits non-zero on the first category that finds anything.
set -euo pipefail

mode="${1:-tree}"   # staged | tree
cd "$(git rev-parse --show-toplevel)"

if [[ "$mode" == staged ]]; then
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git diff --cached --name-only --diff-filter=ACMR -z)
else
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(git ls-files -z)
fi
(( ${#files[@]} == 0 )) && exit 0

failed=0

command -v gitleaks >/dev/null 2>&1 || { echo "checks: gitleaks is not installed, see CONTRIBUTING.md" >&2; exit 1; }
if [[ "$mode" == staged ]]; then
  gitleaks git --staged --no-banner --redact || failed=1
else
  gitleaks dir --no-banner --redact . || failed=1
fi

# This file holds the patterns, so it would match itself.
scanned=()
for f in "${files[@]}"; do
  [[ "$f" == hooks/checks.sh ]] || scanned+=("$f")
done
(( ${#scanned[@]} == 0 )) && exit "$failed"

# content <description> <extended-regex>
content() {
  local hits
  if [[ "$mode" == staged ]]; then
    hits="$(for f in "${scanned[@]}"; do git show ":$f" 2>/dev/null | grep -nIE "$2" | sed "s|^|$f:|"; done || true)"
  else
    hits="$(grep -nIE "$2" -- "${scanned[@]}" 2>/dev/null || true)"
  fi
  if [[ -n "$hits" ]]; then
    printf 'checks: %s\n%s\n' "$1" "$hits" >&2
    failed=1
  fi
}

content "em dash or en dash"            $'\xe2\x80\x94|\xe2\x80\x93'
content "smart quote"                   $'\xe2\x80\x98|\xe2\x80\x99|\xe2\x80\x9c|\xe2\x80\x9d'
content "unicode arrow"                 $'\xe2\x86\x90|\xe2\x86\x92|\xe2\x86\x91|\xe2\x86\x93|\xe2\x87\x92'
content "AWS account id"                '(^|[^0-9])[0-9]{12}([^0-9]|$)'
content "ARN with digits"               'arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:'
# svc.cluster.local is a Kubernetes name every reader has, so .local is not on the list.
content "internal hostname"             '\.(internal|corp)\b|ollygarden\.(cloud|dev|internal)'

exit "$failed"

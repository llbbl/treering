#!/usr/bin/env bash
#
# Treering fixture and cross-reference validation.
#
# Run it with no arguments to validate the working tree:
#
#     ./scripts/validate-fixtures.sh
#
# It is the single source of truth for these checks: CI
# (.github/workflows/validate.yml) invokes this same script, so a check cannot
# pass locally and fail in CI, or drift the other way.
#
# Dependencies: bash and jq. Nothing else. This repository has no runtime and no
# package manager, and adding one to run six structural checks would cost every
# contributor an install for no gain.
#
# Options:
#   --spec-version   Run only check 6 (spec-field agreement) and, on success,
#                    print the single agreed spec version to stdout. Used by the
#                    tagging workflow so the tag version is derived from the same
#                    code that validates it.
#   --quiet          Suppress per-check progress; still prints failures.
#
# Exit status: 0 if every check passed, 1 otherwise. Every failure names the
# file, and where applicable the case id, so the message is actionable without
# re-running anything by hand.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FIXTURE_DIR="fixtures"
SPEC_FILE="SPEC.md"
OQ_FILE="OPEN-QUESTIONS.md"
# Files whose OQ-N citations must resolve. OPEN-QUESTIONS.md is in the list as
# well as being the target: it cross-references its own entries in prose ("caught
# during the OQ-2 reconciliation pass"), and those references go stale under a
# renumbering exactly like any other. Its *heading* lines are excluded before
# checking, since a heading citing itself is a tautology that would only inflate
# the count.
CITING_FILES=("$SPEC_FILE" "README.md" "$FIXTURE_DIR/README.md" "$OQ_FILE")

QUIET=0
SPEC_VERSION_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --spec-version) SPEC_VERSION_ONLY=1; QUIET=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'validate-fixtures: unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

FAILURES=0

# Field separator for the id/ref/index tuples jq emits below. Deliberately ASCII
# US (0x1f) and not a tab: bash classifies tab as IFS whitespace, so
# `IFS=$'\t' read` collapses runs of tabs and drops leading ones. A case with a
# missing "spec_ref" emits an empty middle field, which a tab-separated read
# silently shifts away — the check then passes on exactly the input it exists to
# catch. US cannot appear in a fixture id or a section reference.
SEP=$'\037'

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

note() {
  [ "$QUIET" -eq 1 ] && return 0
  printf '%s\n' "$1"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'validate-fixtures: jq is required but was not found on PATH.\n' >&2
    printf '  macOS: brew install jq   Debian/Ubuntu: apt-get install jq\n' >&2
    exit 2
  fi
}

require_jq

# Collect the fixture files once. Sorted so output is stable across machines.
FIXTURES=()
while IFS= read -r f; do
  FIXTURES+=("$f")
done < <(find "$FIXTURE_DIR" -maxdepth 1 -name '*.json' -type f | LC_ALL=C sort)

if [ "${#FIXTURES[@]}" -eq 0 ]; then
  # An empty fixture directory is not "nothing to check", it is the check
  # failing to find its subject. Treat it as an error, not a vacuous pass.
  printf 'FAIL: no fixture files found under %s/ — wrong directory, or the suite was deleted.\n' "$FIXTURE_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check 1 — every fixture file is parseable JSON.
#
# A syntax error otherwise reaches main and every downstream runner discovers it
# separately, at fixture-load time, in a language-specific way.
# ---------------------------------------------------------------------------
PARSEABLE=()
check_json_parses() {
  note "==> [1/6] JSON parses"
  local f err
  for f in "${FIXTURES[@]}"; do
    if err="$(jq empty "$f" 2>&1)"; then
      PARSEABLE+=("$f")
    else
      fail "$f is not valid JSON: ${err//$'\n'/ }"
    fi
  done
}

# ---------------------------------------------------------------------------
# Check 2 — case ids are present, non-empty, and unique across every suite.
#
# A duplicate id makes one of the two cases invisible to any runner that keys
# its results on id, and the runner still reports a full pass. Ids are also
# checked for presence, because a null id would otherwise collapse into a
# "duplicate null" and report the wrong problem.
# ---------------------------------------------------------------------------
check_unique_ids() {
  note "==> [2/6] case ids unique across suites"
  local f ids dupes id owners
  ids="$(
    for f in "${PARSEABLE[@]}"; do
      jq -r --arg f "$f" --arg sep "$SEP" '
        (.cases // [])
        | to_entries[]
        | [(.value.id // ""), $f, (.key | tostring)]
        | join($sep)
      ' "$f"
    done
  )"

  # Missing or empty id.
  while IFS="$SEP" read -r id file idx; do
    [ -n "${file:-}" ] || continue
    if [ -z "$id" ]; then
      fail "$file: cases[$idx] has a missing or empty \"id\"."
    fi
  done <<< "$ids"

  # Duplicates.
  dupes="$(printf '%s\n' "$ids" | awk -F"$SEP" 'NF && $1 != "" {print $1}' | LC_ALL=C sort | uniq -d)"
  if [ -n "$dupes" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      owners="$(printf '%s\n' "$ids" | awk -F"$SEP" -v id="$id" '$1 == id {printf "%s[%s] ", $2, $3}')"
      fail "duplicate case id \"$id\" appears in: ${owners% }"
    done <<< "$dupes"
  fi
}

# ---------------------------------------------------------------------------
# Check 3 — every spec_ref names a section that exists in SPEC.md.
#
# The highest-value check in this file. Renumbering a SPEC section silently
# orphans every fixture pointing at the old number: nothing errors, the fixtures
# still run, and the citation now leads nowhere.
#
# spec_ref values look like "§4", "§6.4.1", "§7.1.2". SPEC.md headings vary in
# both depth and punctuation:
#
#     ## 4. Value serialization        -> 4
#     ### 6.4 `timestamp` and ...      -> 6.4
#     ### 7.1.1 Type names are open    -> 7.1.1   (three levels at ### depth)
#     #### 6.4.1 `NO_COLOR`            -> 6.4.1   (three levels at #### depth)
#
# So the number is matched independently of heading depth, and a trailing dot on
# a top-level heading is tolerated. Headings with no leading number
# ("## Provenance") are simply not citable and contribute nothing.
# ---------------------------------------------------------------------------
check_spec_refs() {
  note "==> [3/6] spec_ref targets exist in $SPEC_FILE"
  if [ ! -f "$SPEC_FILE" ]; then
    fail "$SPEC_FILE not found; cannot resolve any spec_ref."
    return
  fi

  local headings f
  headings="$(
    grep -E '^#{1,6}[[:space:]]+[0-9]+(\.[0-9]+)*\.?[[:space:]]' "$SPEC_FILE" \
      | sed -E 's/^#{1,6}[[:space:]]+([0-9]+(\.[0-9]+)*)\.?[[:space:]].*$/\1/'
  )"

  if [ -z "$headings" ]; then
    fail "$SPEC_FILE contains no numbered headings; the spec_ref check would pass vacuously."
    return
  fi

  for f in "${PARSEABLE[@]}"; do
    while IFS="$SEP" read -r id ref idx; do
      [ -n "${idx:-}" ] || continue
      if [ -z "$ref" ]; then
        fail "$f: case \"${id:-<no id>}\" (cases[$idx]) has a missing or empty \"spec_ref\"."
        continue
      fi
      # Strip the section sign and any surrounding space; "§6.4.1" -> "6.4.1".
      local bare
      bare="${ref#§}"
      bare="${bare## }"
      bare="${bare%% }"
      if ! printf '%s\n' "$headings" | grep -qxF "$bare"; then
        fail "$f: case \"$id\" cites $SPEC_FILE $ref, which has no matching heading. Either the section was renumbered or the citation is a typo."
      fi
    done < <(jq -r --arg sep "$SEP" '
      (.cases // [])
      | to_entries[]
      | [(.value.id // ""), (.value.spec_ref // ""), (.key | tostring)]
      | join($sep)
    ' "$f")
  done
}

# ---------------------------------------------------------------------------
# Check 4 — a pending case must say why it is pending.
#
# fixtures/README.md makes pending_reason mandatory ("required when pending is
# true; cite the OQ number"). Nothing enforced it, and three fixtures once sat
# pending for months past the gate that was supposed to release them, because no
# fixture recorded what the gate was.
# ---------------------------------------------------------------------------
check_pending_reasons() {
  note "==> [4/6] pending cases carry a pending_reason"
  local f
  for f in "${PARSEABLE[@]}"; do
    while IFS="$SEP" read -r id idx; do
      [ -n "${idx:-}" ] || continue
      fail "$f: case \"${id:-<no id>}\" (cases[$idx]) is pending: true but has no non-empty \"pending_reason\". State the gate, citing the OQ number."
    done < <(jq -r --arg sep "$SEP" '
      (.cases // [])
      | to_entries[]
      | select(.value.pending == true)
      | select((.value.pending_reason // "" | tostring | gsub("^\\s+|\\s+$";"")) == "")
      | [(.value.id // ""), (.key | tostring)]
      | join($sep)
    ' "$f")
  done
}

# ---------------------------------------------------------------------------
# Check 5 — every OQ-N citation resolves to a heading in OPEN-QUESTIONS.md.
#
# The prose files cite open questions by number in running text. A planned
# reorganisation of OPEN-QUESTIONS.md (issue #11) would renumber them; this
# check is what makes that safe to do.
# ---------------------------------------------------------------------------
check_oq_citations() {
  note "==> [5/6] OQ-N citations resolve in $OQ_FILE"
  if [ ! -f "$OQ_FILE" ]; then
    fail "$OQ_FILE not found; cannot resolve any OQ-N citation."
    return
  fi

  local defined f cited n total=0
  defined="$(grep -oE '^#{1,6}[[:space:]]+OQ-[0-9]+' "$OQ_FILE" | grep -oE 'OQ-[0-9]+' | LC_ALL=C sort -u)"

  if [ -z "$defined" ]; then
    fail "$OQ_FILE defines no OQ-N headings; the citation check would pass vacuously."
    return
  fi

  for f in "${CITING_FILES[@]}"; do
    [ -f "$f" ] || continue
    if [ "$f" = "$OQ_FILE" ]; then
      cited="$(grep -vE '^#{1,6}[[:space:]]' "$f" | grep -oE 'OQ-[0-9]+' | LC_ALL=C sort -u)"
    else
      cited="$(grep -oE 'OQ-[0-9]+' "$f" | LC_ALL=C sort -u)"
    fi
    [ -n "$cited" ] || continue
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      total=$((total + 1))
      if ! printf '%s\n' "$defined" | grep -qxF "$n"; then
        fail "$f cites $n, which has no heading in $OQ_FILE. Lines: $(grep -nE "\<$n\>" "$f" | cut -d: -f1 | paste -sd, -)"
      fi
    done <<< "$cited"
  done
  note "    $total distinct citation(s) across ${#CITING_FILES[@]} file(s); $(printf '%s\n' "$defined" | wc -l | tr -d ' ') OQ headings defined"
}

# ---------------------------------------------------------------------------
# Check 6 — every suite agrees on its top-level "spec" field.
#
# Drift here is silent to a runner (each suite carries its own) and corrupts the
# version derived by the tagging workflow, which reads major.minor from this
# field. Also enforces a parseable major.minor, for the same reason.
# ---------------------------------------------------------------------------
AGREED_SPEC=""
check_spec_agreement() {
  note "==> [6/6] all suites agree on \"spec\""
  local f v seen line values
  values=""
  for f in "${PARSEABLE[@]}"; do
    v="$(jq -r '.spec // ""' "$f")"
    if [ -z "$v" ]; then
      fail "$f has no top-level \"spec\" field."
      continue
    fi
    values="${values}${v}${SEP}${f}"$'\n'
  done

  seen="$(printf '%s' "$values" | awk -F"$SEP" 'NF {print $1}' | LC_ALL=C sort -u)"
  local count
  count="$(printf '%s\n' "$seen" | awk 'NF' | wc -l | tr -d ' ')"

  if [ "$count" -gt 1 ]; then
    fail "suites disagree on \"spec\". Found $count distinct values:"
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      line="$(printf '%s' "$values" | awk -F"$SEP" -v v="$v" '$1 == v {printf "%s ", $2}')"
      printf '        %s -> %s\n' "$v" "${line% }" >&2
    done <<< "$seen"
    return
  fi

  [ "$count" -eq 1 ] || return
  AGREED_SPEC="$(printf '%s\n' "$seen" | awk 'NF' | head -n1)"

  # The tag version derives major.minor from this string; refuse a value it
  # cannot parse rather than letting the tagging workflow guess.
  if ! printf '%s' "$AGREED_SPEC" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?([-+].*)?$'; then
    fail "spec value \"$AGREED_SPEC\" is not a parseable version. The fixture tag derives major.minor from it, so it must start with <major>.<minor>."
    AGREED_SPEC=""
    return
  fi
  note "    spec = $AGREED_SPEC (all ${#PARSEABLE[@]} suites)"
}

# ---------------------------------------------------------------------------

check_json_parses

if [ "${#PARSEABLE[@]}" -eq 0 ]; then
  printf 'FAIL: no fixture file parsed; the remaining checks cannot run.\n' >&2
  exit 1
fi

if [ "$SPEC_VERSION_ONLY" -eq 1 ]; then
  check_spec_agreement
  if [ "$FAILURES" -ne 0 ] || [ -z "$AGREED_SPEC" ]; then
    exit 1
  fi
  printf '%s\n' "$AGREED_SPEC"
  exit 0
fi

check_unique_ids
check_spec_refs
check_pending_reasons
check_oq_citations
check_spec_agreement

# A summary line, so a green run says what it actually covered rather than
# just being silent. A validation suite whose passing output is indistinguishable
# from a suite that ran nothing is the vacuous pass this repository exists to
# warn about.
TOTAL_CASES="$(jq -s '[.[].cases | length] | add // 0' "${PARSEABLE[@]}")"
TOTAL_PENDING="$(jq -s '[.[].cases[] | select(.pending == true)] | length' "${PARSEABLE[@]}")"

echo
if [ "$FAILURES" -eq 0 ]; then
  printf 'OK: %s cases across %s suites (%s pending), spec %s. 6/6 checks passed.\n' \
    "$TOTAL_CASES" "${#PARSEABLE[@]}" "$TOTAL_PENDING" "${AGREED_SPEC:-?}"
  exit 0
fi

printf '%s check failure(s). See FAIL lines above.\n' "$FAILURES" >&2
exit 1

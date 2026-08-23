# CI

Treering has no runtime, no build, and no package manager. What it has is a web of
cross-references that nothing enforced mechanically: a fixture's `spec_ref` into
`SPEC.md`, a prose file's `OQ-N` into `OPEN-QUESTIONS.md`, and seven independent
`spec` fields that are supposed to agree. Each can break without any individual
file becoming invalid, which is exactly the failure mode this repository exists
to warn about — a suite that reports a full pass while checking less than it
claims.

Everything here is shell plus `jq`. Adding a language runtime to run structural
checks would cost every contributor an install and buy nothing.

## What runs

| File | Trigger | Does |
|---|---|---|
| `workflows/validate.yml` | every push, every PR | runs `scripts/validate-fixtures.sh` |
| `workflows/tag-fixtures.yml` | push to `main` touching `fixtures/**` | derives and pushes an annotated `fixtures-v*` tag |

## Running the checks locally

```
./scripts/validate-fixtures.sh
```

Requires `bash` and `jq`. CI invokes this same script rather than reimplementing
the checks in YAML, so a check cannot pass on a laptop and fail in CI, or drift
the other way. Exit status is 0 or 1; every failure names the file, and where
applicable the case id.

The six checks:

1. **Every `fixtures/*.json` parses.** A syntax error otherwise reaches `main`
   and is rediscovered separately by every downstream runner, in a
   language-specific way, at fixture-load time.
2. **Case ids are present and unique across all suites.** A duplicate id makes
   one of the two cases invisible to any runner that keys results on id — and
   the runner still reports a full pass.
3. **Every `spec_ref` names a heading that exists in `SPEC.md`.** The
   highest-value check here. Renumbering a section silently orphans every
   fixture pointing at the old number; nothing errors and the citation simply
   leads nowhere. Heading depth is ignored on purpose, because the spec already
   mixes `### 7.1.1` with `#### 6.4.1`.
4. **Every `pending: true` case carries a non-empty `pending_reason`.**
   `fixtures/README.md` already required this; nothing enforced it.
5. **Every `OQ-N` citation resolves to a heading in `OPEN-QUESTIONS.md`.**
   Checked in `SPEC.md`, `README.md`, `fixtures/README.md`, and in
   `OPEN-QUESTIONS.md`'s own prose — it cross-references its own entries, and
   those go stale under a renumbering like any other citation. Its heading lines
   are excluded, since a heading citing itself proves nothing. This is what
   makes the planned reorganisation in issue #11 safe to attempt.
6. **All suites agree on their `spec` field**, and that value parses as
   `major.minor`. Drift is invisible to a runner (each suite carries its own)
   and would corrupt the tag version derived below.

## How the fixture tag version is derived

Nothing is hardcoded.

- **`major.minor`** comes from the `spec` field the fixture files carry
  (`"0.1.0-draft"` → `0.1`), read via
  `./scripts/validate-fixtures.sh --spec-version`, which proves all seven
  suites agree before the value is used.
- **`patch`** is one past the highest existing tag on that `major.minor` line,
  or `0` if the line has none. Moving the spec to `0.2` therefore starts at
  `fixtures-v0.2.0` with no edit to any workflow.

Tags are read with `git tag --list`, deliberately **not** `git describe`.
`git describe` only sees tags reachable from `HEAD`, so after a revert it
reports an older tag and the next patch number collides with one already
published.

The annotation's first sentence is generated from the fixtures being tagged
(spec version, case count, suite count, pending count). The second is human
prose about what changed, taken from the commit message — the PR title for a
GitHub merge commit, the subject for a squash merge. When neither yields
anything usable (a plain `Merge branch`, a `Revert`), the tag ships with the
first sentence only and the run logs a warning. A fabricated summary in a
permanent annotation is worse than a missing one, because a reader cannot tell
it apart from a real one.

---

## Not built: bumping the downstream pin

This is the genuinely useful next step, and it is **deliberately absent**.

### The problem

`llbbl/logan-logger-ts` pins fixtures by tag in its `Treering Conformance` job:

```yaml
- name: Checkout treering fixtures
  uses: actions/checkout@v4
  with:
    repository: llbbl/treering
    ref: fixtures-v0.1.3
```

That job also fails, on purpose, whenever `fixtures/` on treering's default
branch has moved past the pinned tag — otherwise a green build proves nothing
about the fixtures it was actually meant to run. So every tag cut here makes
that repository red until someone edits one line of its `ci.yml`. Automating the
edit would close the loop: tag here, PR opened there, human reviews and merges.

### Why it is not automated

It needs a credential this repository does not have. `GITHUB_TOKEN` is scoped to
`llbbl/treering` and cannot write a branch, or open a pull request, in another
repository. There is no configuration that changes that; it is the token's
design. So the work is blocked on a decision only the repository owner can make.

### The three options, honestly

**1. A fine-grained personal access token.** Scoped to `llbbl/logan-logger-ts`
with `Contents: write` and `Pull requests: write`, stored here as a repository
secret. Simplest to set up — perhaps ten minutes. The costs: it is bound to a
human account, so it carries that account's identity on every PR and dies when
the account does; it expires and needs rotating on a calendar; and a secret in
this repository that can write to another one widens the blast radius of any
compromise here.

**2. A GitHub App.** Installed on both repositories, granted only
`Contents: write` and `Pull requests: write` on the consumer. The workflow mints
a short-lived installation token (`actions/create-github-app-token`) from an app
id and private key held as secrets. Better on every axis that matters — not tied
to a person, narrowly scoped, token expires in an hour — at the cost of maybe an
hour of setup and one more thing to own. This is the right answer if the pattern
is going to repeat across more consumer repositories.

**3. `repository_dispatch`.** treering sends an event; `logan-logger-ts` owns a
workflow that edits its own `ci.yml` and opens the PR. Appealing because the
edit logic lives in the repository that understands its own workflow file. Two
catches, both real: sending the dispatch *still* requires a PAT or App token
with write access to the target, so it does not avoid the credential decision,
it only narrows what the credential may do; and a pull request opened with that
repository's own `GITHUB_TOKEN` **does not trigger its workflows**, so the
conformance job would not run on the very PR whose purpose is to prove
conformance. Working around that means a PAT or App there too.

### If it gets built

- Fail loudly when the pin is already current rather than opening an empty PR.
- Do not `sed` for `fixtures-v[0-9.]*` across `ci.yml`. Match the `ref:` line
  within the conformance job specifically, and fail if the match count is not
  exactly one — a silent zero-match is how this kind of automation rots.
- Consider moving the pinned tag in `logan-logger-ts` to a single declared
  location so the bump edits one obvious value.
- Give it `workflow_dispatch` as well, so a missed or failed run can be replayed
  without inventing a fixture change.

### Until then

After a tag is cut here, in `llbbl/logan-logger-ts`, bump `ref:` in the
`Treering Conformance` job to the new tag and open a PR. The run summary of
`tag-fixtures.yml` prints the tag it just pushed as a reminder.

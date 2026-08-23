# Conformance fixtures

Language-neutral test cases. An implementation conforms if it passes every case that is
not marked `pending`.

Fixtures are plain JSON so that a Go, Rust, Python, or TypeScript runner can consume
them without a shared library.

## File shape

```json
{
  "suite": "serialization",
  "spec": "0.1.0-draft",
  "cases": [
    {
      "id": "serialization/circular-self",
      "description": "An object referencing itself serializes the cycle as [Circular]",
      "spec_ref": "§4",
      "pending": false,
      "input": { },
      "expect": { }
    }
  ]
}
```

- `id` — stable, unique, `suite/name`. Never renumber; append.
- `spec_ref` — the section of `SPEC.md` the case enforces.
- `pending` — when true the case documents intended behavior the reference
  implementation does not yet exhibit. Runners **MUST** skip these and **SHOULD**
  report them as skipped rather than passing silently.
- `pending_reason` — required when `pending` is true; cite the OQ number.

## Value construction DSL

Some inputs cannot be written directly in JSON — cycles, functions, big integers.
Wherever a fixture supplies a *value*, these tagged objects may appear. A runner
materializes them into native values before invoking the implementation.

| Tag | Meaning |
|---|---|
| `{"$id": "name", "value": <v>}` | binds `<v>` to `name` for later reference, materializes as `<v>` |
| `{"$ref": "name"}` | the value previously bound to `name` — used to build cycles and DAGs |
| `{"$fn": "name"}` | a callable named `name`; `{"$fn": null}` for an anonymous one |
| `{"$undefined": true}` | the language's absent/unset value |
| `{"$bigint": "123..."}` | an integer beyond the native JSON-safe range, given as a decimal string |
| `{"$symbol": "desc"}` | an interned atom with description `desc` |
| `{"$error": {...}}` | an error, see below |
| `{"$lazy": "text"}` | a nullary callable returning `"text"` — for lazy-message cases |

### Errors

```json
{"$error": {"name": "TypeError", "message": "boom", "stack": "<STACK>", "props": {"code": "E42"}}}
```

`"<STACK>"` is a placeholder. Stacks are environment-specific, so runners **MUST**
substitute the literal string `<STACK>` for the stack value before comparing, rather
than attempting to match real stack text.

### Languages that lack a concept

A runner **MUST** skip any case whose input uses a tag the language has no equivalent
for, and report it as skipped with a reason. It **MUST NOT** fabricate a substitute.
Per SPEC §4 an implementation never produces a case it cannot represent.

## Comparison

`expect.json` and `expect.text` are compared as **exact strings**, after `<STACK>`
substitution. Byte equality, not structural equality — field order is normative
(SPEC §2.2), and structural comparison would not catch a violation.

`expect.omits` lists keys that must be absent from the output object.

`expect.calls` asserts side effects, currently only used for lazy messages:
`{"lazy_invoked": false}`.

## Fixed inputs

Cases that emit a record supply a frozen `timestamp` and `runtime` so output is
deterministic. Runners **MUST** inject these rather than letting the implementation
read a real clock. An implementation that cannot have its clock injected is not
testable against these fixtures and **SHOULD** grow a seam for it.

## Suites

| File | Covers |
|---|---|
| `levels.json` | ordinals, filtering, string parsing (SPEC §1) |
| `envelope.json` | record fields, JSON and text forms, metadata omission (SPEC §2) |
| `context.json` | child loggers, shallow merge, precedence (SPEC §3) |
| `serialization.json` | circular refs, errors, functions, bigints, symbols (SPEC §4) |
| `config.json` | defaults, precedence, environment variables, config files (SPEC §6) |
| `transports.json` | selection, isolation, per-transport level (SPEC §7) |
| `redaction.json` | key matching and recursion (SPEC §8) |

## What a runner must supply

Written after building the first one (TypeScript, `logan-logger`). These are the
requirements that were not obvious from the format alone.

**A seam for the clock and the runtime.** Cases that emit a record supply a frozen
`timestamp` and `runtime` — the whole `envelope` suite, most of `context`, and one
`redaction` case. An implementation that reads a real clock at emit time cannot pass them.
The seam does **not** need to be public API — the reference implementation carries it on
a private key that no entry point re-exports, so `LoggerConfig` is unchanged. But it has
to be inheritable by child loggers, because the `context/*` cases emit from children.

**A binding table for `$id` and `$ref`.** These exist to build cycles and DAGs, so
materialization is two-pass or single-pass-with-environment; it cannot be a plain
recursive map.

**Byte comparison, not structural.** `expect.json` and `expect.text` are exact strings.
A structural comparison passes on output whose field order violates §2.2, which is the
single most likely thing to differ between implementations and therefore the single
thing most worth catching.

**A guard against vacuous passing.** The easiest way to write a runner that reports every
case as passing is to silently ignore an `expect` key it does not understand. Track
which expectations each case actually discharged and fail any case that carried one
the runner never checked. The reference runner also rejects unknown `input` keys
rather than skipping them. Without this, adding a fixture the runner does not
understand *increases* the apparent pass count.

**A CI guard against a missing fixture directory.** A runner that skips when fixtures are
absent is right locally and dangerous in CI, where a broken checkout turns the whole
suite into a silent pass. Assert the directory exists as a separate step before running.

**`resource_count` needs a language-appropriate answer.** `context/child-opens-no-resources`
asks for open handles. Counting file descriptors is not portable — the reference runner
counts resource-owning transports constructed instead, which bounds handles from above.
Any equivalent upper bound is acceptable; say in your report which you used.

**Cases you cannot represent are skipped, with a reason, and never faked.** A language
with no symbol type skips `serialization/symbol`. It does not invent a substitute, and it
does not count the case as passing.

## Assertion kinds

Most cases emit a record and compare the output. Where the thing under test is not a
record — an ordinal table, a resolved configuration, the list of destinations that got
built — the case names an `input.assert` instead, and the runner answers it in whatever
way its language makes honest. `resource_count` set the precedent; the kinds below
follow it.

| `input.assert` | Discharges | Asks for |
|---|---|---|
| `ordinals` | `expect.ordinals` | the level table (SPEC §1.1) |
| `no_silent_emit` | `expect.has_silent_emit_method` | that SILENT is threshold-only (SPEC §1.2) |
| `resource_count` | `expect.transport_instances`, `expect.open_handles` | resources a child opened (SPEC §3.3) |
| `effective_config` | `expect.config` | the configuration after the whole precedence chain (SPEC §6) |
| `transport_list` | `expect.transports` | the type name of each transport constructed, in order (SPEC §7.1, §7.2) |
| `transport_context` | `expect.context` | the presentation settings a transport will actually format with (SPEC §7.1.2) |
| `transport_writes` | `expect.writes` | which records reached which transport (SPEC §7.3) |

### `effective_config`

`expect.config` is a **projection**, not the whole configuration: the runner reports only
the fields the case names, and compares those. Everything else is out of scope for that
case, which is what lets one fixture pin one field.

`level` is compared as its **ordinal** (SPEC §1.1), never as a string. That is deliberate.
A string surviving into the resolved configuration is precisely the §6.5 normalization
failure, and comparing against `"debug"` would let it pass.

`colorize` has no default fixture. §6.1 makes its default runtime-dependent, so no
portable value exists; it is asserted only where a source sets it explicitly.

The `NO_COLOR` cases (§6.4.1) are the exception, and the two directions are portable for
different reasons.

`colorize: false` is portable because `NO_COLOR` forces it regardless of runtime,
TTY-ness or any other source. `false` is the only conforming answer on every platform.

`colorize: true` rests on something narrower, worth naming because it was not always
written down. Such a case needs a source that sets it — `LOG_COLOR=true` or explicit
config — and §6.2 puts both of those above the runtime-dependent default. That ordering
alone is not enough: an implementation may check whether stdout is a terminal before
coloring, and these fixtures run in CI, where stdout is a pipe. What actually makes the
assertion portable is §6.4.1's constraint that a process-wide TTY check, in an
implementation that has one, sits at the default tier and never overrules an explicit
source — the same constraint `FORCE_COLOR` is now under. Without that rule a conforming
TTY-checking implementation would fail every `colorize: true` case in the suite, for a
reason that has nothing to do with what any of them is testing.

The constraint reaches only *that* kind of check. A transport declining ANSI because of
what it writes to is untouched by it, and untouched by these cases: see
`transport_context` below for why they all name a transport that writes nowhere.

### `transport_list` and `transport_context`

Both name transports through the ordinary `transports` configuration, so a case can mix
built-ins with the reserved name below. Neither emits a record, so a case using them can
also assert `"diagnostics": []`.

`transport_context` reports the **effective** presentation settings of the *first*
constructed transport: the `format`, `timestamp` and `colorize` that transport will
actually format with, **after** it has applied its own `options` over the logger context
per SPEC §7.1.2. Not what the logger handed in — what the transport came out holding.

Spelled out, so a Go runner and a TypeScript one compute the same thing. For each of the
three fields, the effective value is:

1. the transport's own `options.<field>`, where it has one;
2. otherwise the value the logger handed the transport, which is the resolved
   configuration's value for that field.

That is the whole rule. **The probe knows nothing about `NO_COLOR` and must not check
it.**

It does not need to. SPEC §6.4.1 requires that a vetoed `colorize` never become observable
to a transport as `true` — not through the logger context, not through the transport's own
`options` — so by the time the probe reaches step 1 the veto has already been applied to
both inputs, and it falls out of those two steps on its own.

Worth stating flatly, because the probe *could not* implement the carve-out itself even if
asked to. All it sees is `context.colorize: false` next to `options.colorize: true`, and
it cannot tell that apart from a caller who passed `colorize: false` at the logger and
`true`
on the transport — a case where §7.1.2 says the transport's own `true` legitimately
**wins**. Telling them apart needs to know *why* the context value is `false`, which is
knowledge the implementation has and a transport does not. So the guarantee is the
implementation's to provide and the probe's to rely on.

**This definition was tightened after the pre-merge one let a real regression through.**
The kind previously reported the settings a transport "was handed", which sounds
equivalent and is not: §6.4.1 already forces the *handed-in* `colorize` to `false`, so a
case pairing `NO_COLOR` with `options: {colorize: true}` never consulted the transport
option at all and passed against an implementation with no carve-out — the exact
implementation §7.1.2 exists to reject. Removing the clamp from the reference
implementation left the fixture green. Reporting the post-`options` value is what puts the
carve-out under test.

**What the resulting case actually catches is worth being precise about**, because on a
first read it can look like it polices implementation strategy rather than behavior. It
does not. The probe is a *registered* transport (§7.1.1), reached through the same public
registry path an application would use — so it stands in for a transport that the
implementation did not write. An implementation that clamps `colorize` only inside its
own built-in console transport passes its own unit tests, emits perfectly uncolored
output from everything it ships, and still fails here — correctly, because a registered
transport carrying `options.colorize: true` would emit ANSI under `NO_COLOR` on that
implementation.
That is a real user-visible defect, not a difference of approach. Where the veto gets
applied remains free; that it reaches transports the implementation does not own is the
requirement, and SPEC §6.4.1 states it in those terms.

A runner **MUST** read these values from the transport itself rather than recomputing them
from the case's `input`. Recomputing them means asserting the runner's own arithmetic,
which is the mistake `input.sources` already warns about above.

Destination-specific color suppression (SPEC §6.4.1, "TTY detection and `FORCE_COLOR`" —
a transport declining ANSI because it writes to a file) is also part of "effective", and
is deliberately kept out of reach: every case using this kind names the reserved
`fixture-registry-probe` transport, which writes nowhere and so never suppresses on a
destination's behalf. A case that named `file` here would be asserting a platform
decision, not a precedence rule.

### `transport_writes`

`expect.writes` maps a transport's `options.name` to the levels that reached it, in
emission order. The runner substitutes a recording destination for each configured
transport, **preserving its declared `level` exactly as configuration produced it** —
substituting the destination is what makes delivery observable, and preserving the level
untouched is what keeps §7.3 and §6.5's normalization rule under test rather than
papered over.

`input.threshold` sets the logger threshold and `input.emit` lists the levels to emit,
the same keys `levels.json` already uses.

### The reserved `fixture-registry-probe` transport

§7.1.1 requires the set of type names to be open, and there is no way to test a registry
using only names that are already built in. A runner **MUST** therefore register one
transport under the name `fixture-registry-probe` before running the suite, through the
same public registration path an application would use. It may discard everything written
to it — it writes nowhere, which is also what keeps destination-specific color suppression
out of these cases.

**It must accept presentation options and expose what it resolved them to.** The probe is
not an inert sink: `transports/no-color-outranks-a-transport-option` hands it
`options.colorize`, and `transports/transport-option-still-wins-for-other-fields` hands it
both `options.format` and `options.colorize`. Whatever the probe does with a record, it
**MUST** apply SPEC §7.1.2 to those options exactly as a real transport would — preferring
its own over the logger context, field by field — and it **MUST** make the three resolved
values readable by the runner afterwards.

**That preference is the whole of the probe's logic.** It **MUST NOT** read `NO_COLOR`,
and it **MUST NOT** carry a special case for the §6.4.1 carve-out. A veto reaches it
already applied to both of its inputs, which SPEC §6.4.1 requires of the implementation,
and a
probe that re-applied it would paper over precisely the implementations this suite exists
to catch. Keeping the probe dumb is what makes it portable: two dozen lines in any
language, with no environment access and no spec knowledge beyond "mine wins over theirs".

That second half is what the `transport_context` rule above depends on: a runner is
required to read those values off the transport rather than recompute them from the case's
`input`, and it can only do that if the probe exposes them. A probe that ignores its
options, or resolves them privately and tells no one, turns every `transport_context` case
into an assertion about the runner's own arithmetic — which is exactly the vacuous pass
this file warns about elsewhere. How the values are exposed is the runner's business: a
public field, an accessor, a captured struct. That they are exposed is not.

An implementation whose configuration type cannot express a registered name fails these
cases. That is the point: §7.1.1 calls out a reference implementation that accepted any
string at `registerTransport` while its config type was a closed union, so a registered
transport needed a cast to name.

## Configuration inputs

`input.config` is one configuration object, exactly as a caller would pass it.

`input.sources` is an **ordered list** of them, lowest precedence first, together forming
the explicit-config tier. It exists because §6.2's merge rules — `metadata` shallow,
`transports` wholesale — are only observable across two sources, and a single object
cannot express two. A runner combines them using the implementation's own merge, not one
it writes itself; a runner that reimplements the merge is testing its own arithmetic.

Where both appear, and where `files` appears too, the tier stacks in this order, lowest
first:

```
files  <  sources  <  config
```

which is §6.2's rule that file contents "sit below anything the caller passes alongside
them".

`level` — top-level or per-transport — is written in these sections as a **canonical
level string**, and the runner converts it to whatever its language uses for a level
before handing it over. That is not a normalization test: these sections stand in for
values a caller constructs in code, where a statically typed implementation would not
accept a string at all. §6.5's normalization rule is about what a *file* contains, so
every case that tests it goes through `input.files`, where the JSON is written out
verbatim and reaches the implementation unconverted.

## Ambient state: `env` and `files`

§6.3 and §6.5 describe behaviour driven by things that are not arguments — environment
variables and files on disk. Cases covering them use two extra `input` sections. Both
are ambient process state, so the contract below is about isolation as much as setup.

### `input.env`

```json
{ "input": { "env": { "LOG_LEVEL": "debug", "LOG_COLOR": null }, "level": "debug", "message": "x" } }
```

A map of variable name to value. The runner sets each before constructing the logger and
**MUST** restore the prior state afterwards, including restoring "was not set" for
variables it created — and **MUST** do so even when the case fails or throws, or one
failure silently corrupts every case after it.

`null` means **ensure unset**, which is distinct from empty string. §6.3 gives an unset
variable and an unparseable one different meanings, so a fixture needs to express both.

Cases carrying `env` **MUST NOT** run concurrently with any other case in the same
process. Either run the suite serially or isolate each file in its own process.

The map says what a case sets, not what the process already has. A runner **MUST** also
ensure every variable in §6.3 that the case does *not* name is unset for the duration —
otherwise a `LOG_LEVEL` in the developer's own shell decides whether a case asserting
`"diagnostics": []` passes. Cases with no `env` section at all are simpler: the
implementation is told to ignore the environment outright, since none of them is about it.

**`NO_COLOR` must be neutralized the same way**, even though it is not a §6.3 variable.
§6.4.1 makes it an override that outranks every configuration source, so a developer who
keeps `NO_COLOR` set in their own shell — an increasingly common preference — would
otherwise see every `colorize` assertion resolve to `false` and every disagreement case
warn spuriously. It is the one variable outside this library's namespace that changes a
conformance result.

### `input.files`

```json
{ "input": { "files": { "logan.config.json": "{\"level\":\"warn\"}" }, "level": "debug", "message": "x" } }
```

A map of relative path to exact file contents. The runner creates a fresh temporary
directory per case, writes the files, and points config discovery at that directory.
Paths may contain separators; the runner creates intervening directories. The directory
is removed afterwards, again including on failure.

**This requires a base-directory seam in the implementation**, the same shape of
requirement as the clock. Config discovery that can only read the real process working
directory is not testable here, and changing the process working directory is not an
acceptable substitute: it is global state, it breaks under any concurrent runner, and
several languages make it awkward or unavailable. The reference implementation takes an
explicit base directory as an option.

An implementation with no filesystem — a browser build — skips these cases with a reason,
under the same rule as an unsupported DSL tag.

### `expect.diagnostics`

```json
{ "expect": { "diagnostics": ["LOG_TIMESTAMP", "banana"] } }
```

A list of substrings, each of which **MUST** appear somewhere in the diagnostics the case
produced. This is the one comparison in the suite that is deliberately **not** exact.

Diagnostic text is where implementations legitimately differ — an absolute path, a
language's own error wording, a prefix identifying the library. Pinning it exactly would
either force every implementation to copy one language's phrasing or make the assertion
worthless. What the spec actually requires is that a diagnostic *names the thing that was
wrong*, so the fixture asserts the identifying substrings and nothing more.

Absence matters too: a case that expects no diagnostics **MUST** assert
`"diagnostics": []`, and the runner **MUST** fail it if any were produced. Silence is a
requirement in §6.3 — a variable that parses cleanly warns about nothing.

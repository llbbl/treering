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
| `redaction.json` | key matching and recursion (SPEC §8) |

## What a runner must supply

Written after building the first one (TypeScript, `logan-logger`). These are the
requirements that were not obvious from the format alone.

**A seam for the clock and the runtime.** 19 of the 60 cases supply a frozen `timestamp`
and `runtime`. An implementation that reads a real clock at emit time cannot pass them.
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

**A guard against vacuous passing.** The easiest way to write a runner that reports 60/60
is to silently ignore an `expect` key it does not understand. Track which expectations
each case actually discharged and fail any case that carried one the runner never
checked. The reference runner also rejects unknown `input` keys rather than skipping
them. Without this, adding a fixture the runner does not understand *increases* the
apparent pass count.

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

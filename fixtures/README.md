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

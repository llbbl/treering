# Treering

A language-neutral specification for structured logging, plus a conformance suite that
proves independent implementations agree.

Tree rings are a chronological record laid down over time. Dendrochronology works by
**cross-dating** — matching ring patterns from different trees against a shared
reference chronology to confirm they describe the same years. That is what this
repository is: a reference chronology for log records, and the fixtures to cross-date
an implementation against it.

## What this is

- **[`SPEC.md`](SPEC.md)** — the normative specification. Levels, the record envelope,
  context propagation, value serialization, configuration, transports, redaction.
- **[`fixtures/`](fixtures/)** — language-neutral JSON conformance cases. An
  implementation conforms if it passes every non-`pending` case.
- **[`OPEN-QUESTIONS.md`](OPEN-QUESTIONS.md)** — the decisions still to make, each with
  the evidence behind it.

## What this is not

It is not a library, and there is no shared binary. Implementations do not link against
a common core.

That is deliberate. The hard part of a logging library is not the logic — formatting a
timestamp and filtering by level is trivial in every language. The hard part is
*idiomatic integration* with each ecosystem: `tracing` in Rust, `log/slog` in Go,
`logging` in Python, framework middleware everywhere. A shared native core does not
help with that, and it would impose an FFI crossing on the hottest, cheapest operation
in the library — one log call — while forcing every consumer to install a platform
binary.

So what ports across languages is the **contract**, not the code. Each implementation
is small, native, dependency-free, and provably identical in output.

## Conformance

A conforming implementation:

1. Passes every fixture not marked `pending`
2. States the spec version it targets
3. Documents any feature it omits under an explicit allowance in the spec

Cases marked `pending` describe intended behavior that the reference implementation
does not yet exhibit. They are skipped, not failed, and each cites the open question
that governs it.

## Status

**0.1.0-draft.** Extracted from [`logan-logger`](https://github.com/llbbl/logan-logger-ts)
v1.1.18 and revised against 2.0.2, which is the reference implementation and does not
yet pass the full suite — see `OPEN-QUESTIONS.md` for the specific divergences.

Nothing here is stable until 1.0. The envelope in particular has one unresolved
question (OQ-7, whether `runtime` should split into `language` and `runtime`) that
would be a breaking change.

## Implementations

| Language | Package | Spec version | Status |
|---|---|---|---|
| TypeScript | [`logan-logger`](https://github.com/llbbl/logan-logger-ts) | 0.1.0-draft | reference; suite not yet wired up |

## License

MIT

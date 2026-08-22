# Treering Specification

**Version:** 0.1.0-draft
**Status:** Draft. Extracted from `logan-logger` (TypeScript) at v1.1.18.

Treering specifies the observable behavior of a structured logging library, so that
independent implementations in different languages emit identical output for identical
input. It specifies a contract, not an implementation. There is no shared binary and no
FFI; each language implements the contract natively and proves conformance by passing
the shared fixture suite in `fixtures/`.

Key words **MUST**, **MUST NOT**, **SHOULD**, **MAY** are used per RFC 2119.

---

## 1. Levels

### 1.1 Ordinals

Levels are totally ordered by severity.

| Level | Ordinal | Canonical string |
|---|---|---|
| DEBUG | 0 | `debug` |
| INFO | 1 | `info` |
| WARN | 2 | `warn` |
| ERROR | 3 | `error` |
| SILENT | 4 | `silent` |

Implementations **MUST** use these ordinals. Comparisons are numeric, so a language
without enums **MAY** use plain integers.

### 1.2 Filtering

A record at level `L` is emitted if and only if `L >= threshold`.

`SILENT` is a **threshold-only** value. It is a valid logger threshold, where it
suppresses everything, but it **MUST NOT** appear as the level of an emitted record.
Implementations **MUST NOT** expose a `silent()` emit method.

### 1.3 Parsing level strings

Parsing is case-insensitive and accepts these aliases:

| Input (case-insensitive) | Result |
|---|---|
| `debug` | DEBUG |
| `info` | INFO |
| `warn`, `warning` | WARN |
| `error` | ERROR |
| `silent`, `none` | SILENT |
| anything else | INFO |

An unrecognized level string **MUST NOT** raise. It resolves to INFO. Implementations
**SHOULD** emit a diagnostic on an unrecognized value, but **MUST NOT** fail.

---

## 2. The record envelope

### 2.1 Fields

Every record has exactly these fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `timestamp` | ISO 8601, UTC, millisecond precision | yes | e.g. `2026-08-22T04:15:30.123Z` |
| `level` | canonical lowercase string (§1.1) | yes | |
| `message` | string | yes | may be empty |
| `runtime` | string | yes | see §2.3 |
| `metadata` | object | no | **omitted entirely** when absent, see §2.4 |

### 2.2 JSON serialization

The JSON form **MUST** serialize keys in this order:

```
timestamp, level, message, runtime, metadata
```

Field order is normative. Conformance is checked by byte comparison, so an
implementation whose language emits maps in arbitrary order **MUST** impose this order
explicitly.

```json
{"timestamp":"2026-08-22T04:15:30.123Z","level":"info","message":"User logged in","runtime":"node","metadata":{"userId":123}}
```

No whitespace between tokens in the compact form. A pretty-printed form **MAY** be
offered as a separate option and is not covered by fixtures.

### 2.3 The `runtime` field

Identifies the execution environment that produced the record. The TypeScript
implementation uses `node`, `deno`, `bun`, `browser`, `webworker`, `unknown`.

Each implementation **MUST** define its own closed set of values and document them.
A Go implementation would use `go`; Rust, `rust`. The field is descriptive, not
enumerated across languages.

> **Open question OQ-7** — whether this should instead be two fields (`language` and
> `runtime`) for cross-language legibility. See `OPEN-QUESTIONS.md`.

### 2.4 Absent metadata

When a record has no metadata, or metadata that resolves to an empty map, the
`metadata` key **MUST be omitted entirely**. It **MUST NOT** appear as `null`, `{}`,
or an empty string.

An implementation **MUST** treat "no metadata supplied" and "metadata supplied but
empty after merging" identically.

### 2.5 Text serialization

```
[<timestamp>] <LEVEL>: <message>
```

with, when metadata is present, a single space followed by the JSON serialization of
the metadata object (§4):

```
[2026-08-22T04:15:30.123Z] INFO: User logged in {"userId":123}
```

`<LEVEL>` is the canonical string **uppercased**. `<timestamp>` is the same ISO 8601
value as the JSON form. Note the asymmetry with §2.2: text uppercases the level, JSON
lowercases it. This is intentional and normative.

---

## 3. Context and child loggers

### 3.1 Creating a child

`child(metadata)` returns a new logger carrying the parent's context merged with the
supplied map. The parent is **MUST NOT** be mutated.

Merging is a **shallow** merge. The child's keys win:

```
child_context = { ...parent_context, ...new_metadata }
```

Nested objects are replaced wholesale, not merged recursively.

### 3.2 Merging at emit time

When a record is emitted, the effective metadata is:

```
effective = { ...logger_context, ...call_site_metadata }
```

Call-site metadata wins over logger context. Again shallow.

If `effective` has zero keys, the `metadata` field is omitted per §2.4.

### 3.3 Child loggers share output

A child logger **MUST** write through the same output destinations as its parent.
Creating a child **MUST NOT** open new file handles, sockets, or other resources.

> This is normative because the reference implementation got it wrong: each child
> constructed a fresh set of transports, so a per-request child logger opened two
> additional file handles against the same file on every request.

### 3.4 Level inheritance

A child inherits the parent's threshold at creation. Changing the parent's threshold
afterwards **MUST NOT** retroactively change the child's. Implementations **MAY**
allow a child's threshold to be set independently.

---

## 4. Value serialization

Serializing arbitrary user-supplied metadata **MUST NOT** raise, and **MUST NOT**
produce output that fails to parse as JSON. Every case below has a defined textual
substitution.

| Input | Output |
|---|---|
| circular reference | `"[Circular]"` |
| function / callable | `"[Function: <name>]"`, or `"[Function: anonymous]"` if unnamed |
| `undefined` / unset | `"[undefined]"` |
| big integer beyond native JSON range | `"[BigInt: <decimal>]"` |
| symbol / interned atom | `"[Symbol: <description>]"` |
| error / exception | object, see §4.2 |

Languages without a given concept simply never produce that case; they **MUST NOT**
invent one.

### 4.1 Repeated references are not circular

An object graph where the same value appears more than once without forming a cycle —
a diamond or DAG — **MUST** serialize that value in full at each occurrence.
`"[Circular]"` is reserved for genuine cycles, meaning the value is an ancestor of
itself on the current path.

> The reference implementation fails this: it marks every visited object in a set that
> is never unwound, so sibling references to one object emit `"[Circular]"` for the
> second occurrence. This spec deliberately does **not** enshrine that. Correct
> implementations track the **current path**, not all visited values.

### 4.2 Errors

An error serializes to an object with, in this key order:

```
name, message, stack, <remaining own properties in insertion order>
```

`stack` **MAY** be absent in languages without stack capture, in which case the key is
omitted rather than null.

Custom properties attached to the error **MUST** be included, excluding any that would
duplicate `name`, `message`, or `stack`.

> The reference implementation has two error serializers that disagree: one enumerates
> all own property names, the other spreads only enumerable ones. The rule above —
> all own properties — is the normative one. See OQ-3.

### 4.3 Determinism

Given identical input, serialization **MUST** be byte-identical across runs and across
implementations. Map iteration order **MUST** be insertion order, or explicitly sorted
if the language cannot preserve insertion order — implementations **MUST** document
which, and fixtures accommodate only insertion order today.

---

## 5. Lazy messages

A message **MAY** be supplied as a nullary function returning a string.

The function **MUST NOT** be invoked when the record is filtered out by level. This is
the entire purpose of the feature: it exists so expensive message construction can be
skipped.

Implementations in languages without closures-as-values **MAY** omit this feature, but
**MUST** document the omission.

---

## 6. Configuration

### 6.1 Fields

| Field | Type | Default |
|---|---|---|
| `level` | level | INFO |
| `format` | `json` \| `text` | `text` |
| `timestamp` | boolean | `true` |
| `colorize` | boolean | runtime-dependent |
| `metadata` | map | `{}` |
| `transports` | list of transport configs | one console transport |

### 6.2 Precedence

Later sources override earlier ones:

```
library defaults  <  config file  <  explicit config  <  environment variables
```

Merge rules per field:

- `metadata` merges **shallowly** across sources; later keys win.
- `transports` is **replaced wholesale**. It never merges.
- Every other field is replaced.

### 6.3 Environment variables

| Variable | Effect |
|---|---|
| `LOG_LEVEL` | parsed per §1.3 |
| `LOG_FORMAT` | accepted only if exactly `json` or `text`; otherwise ignored |
| `LOG_TIMESTAMP` | `true` if the value lowercased equals `true`, else `false` |
| `LOG_COLOR` | `true` if the value lowercased equals `true`, else `false` |

The boolean rule is deliberately strict: `1`, `yes`, and `on` all resolve to **false**.
Implementations **MUST NOT** broaden this without a spec revision.

> OQ-5 proposes broadening it, since `LOG_TIMESTAMP=1` silently disabling timestamps is
> a poor experience.

### 6.4 `timestamp` and `colorize` are currently unenforced

The reference implementation declares both but its formatter ignores them: timestamps
are always emitted and color is never applied by the shared formatter.

This spec declares the intended behavior — `timestamp: false` **MUST** omit the
timestamp from the text form, and `colorize` **MUST** control ANSI coloring of the
level token in the text form only, never the JSON form. Fixtures for these are marked
pending until the reference implementation complies. See OQ-4.

---

## 7. Transports

### 7.1 Selection

- `transports` omitted → a single console transport.
- `transports` supplied → exactly the listed transports, in order.

File output **MUST** be opt-in. An implementation **MUST NOT** enable file output
implicitly based on an environment variable such as `NODE_ENV=production`.

> Implicit production file logging is what made the reference implementation fail in
> containers: it called `mkdir` on every logger construction regardless of whether the
> working directory was writable.

### 7.2 Isolation

Each transport is constructed independently. A transport that fails to initialize
**MUST NOT** prevent the others from working. The failure **MUST** be reported on a
diagnostic channel naming the transport and the underlying cause.

Diagnostics **MUST** be accurate about which stage failed. Conflating "the logging
backend is unavailable" with "the backend loaded but a destination could not be opened"
is specifically forbidden.

### 7.3 Per-transport level

A transport **MAY** declare its own threshold. A record reaches a transport only if it
passes both the logger threshold and the transport threshold.

---

## 8. Redaction

`redact(value, keys)` returns a copy with matching values replaced by the literal
string `"[REDACTED]"`.

Default key set: `password`, `token`, `secret`, `key`, `auth`.

Matching is case-insensitive **substring** matching against the field name.

> This over-matches by design in the reference implementation: a field named `monkey`
> contains `key` and is redacted. OQ-6 proposes exact-match-or-word-boundary instead.
> Until resolved, implementations **MUST** reproduce substring matching so fixtures
> agree.

Redaction is **not** applied automatically. It is an explicit utility the caller
invokes. An implementation **MUST NOT** redact by default, because silently altering
logged data is worse than the exposure it prevents when the caller did not ask.

Redaction recurses into nested maps and lists, preserving container types.

---

## 9. Conformance

An implementation conforms if it passes every fixture in `fixtures/` that is not marked
`pending`.

Fixtures are language-neutral JSON: an input description and an expected output. See
`fixtures/README.md` for the format and the runner contract.

Claiming conformance requires stating the spec version and listing any features
documented as omitted under §5.

---

## Provenance

Extracted from `logan-logger` v1.1.18, specifically:

- `src/core/types.ts` — levels, config shape, record shape
- `src/core/logger.ts` — filtering, context merging, lazy messages
- `src/utils/formatting.ts` — JSON and text forms
- `src/utils/serialization.ts` — value substitution, error handling, redaction
- `src/utils/config.ts` — defaults, environment variables, merge rules

Where the implementation is self-contradicting or clearly wrong, this document
specifies the intended behavior and records the divergence in `OPEN-QUESTIONS.md`
rather than enshrining the bug.

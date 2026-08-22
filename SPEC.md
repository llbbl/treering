# Treering Specification

**Version:** 0.1.0-draft
**Status:** Draft. Extracted from `logan-logger` (TypeScript) at v1.1.18, revised
against 2.0.2 and the 2.1.0 configuration work.

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
| symbol / interned atom | `"[Symbol: <language's own string form>]"` — see below |
| error / exception | object, see §4.2 |

Languages without a given concept simply never produce that case; they **MUST NOT**
invent one.

The symbol row is the one place this table defers to the host language. JavaScript's
`Symbol.prototype.toString()` already wraps the description, so a symbol described
`mySymbol` serializes as `[Symbol: Symbol(mySymbol)]` — the doubled word is correct and
the fixtures pin it.

Earlier revisions wrote `"[Symbol: <description>]"`, which reads as `[Symbol: mySymbol]`
and contradicted `serialization/symbol` and `serialization/nested-mixed`. An
implementer following the prose rather than the fixtures would have failed a case the
prose told them to pass. Where this table and a fixture disagree, the **fixture** is
normative — it is the thing conformance is measured against.

### 4.1 Repeated references are not circular

An object graph where the same value appears more than once without forming a cycle —
a diamond or DAG — **MUST** serialize that value in full at each occurrence.
`"[Circular]"` is reserved for genuine cycles, meaning the value is an ancestor of
itself on the current path.

> The reference implementation failed this until 2.0.0: it marked every visited object
> in a set that was never unwound, so sibling references to one object emitted
> `"[Circular]"` for the second occurrence. This spec deliberately did **not** enshrine
> that. Correct implementations track the **current path**, not all visited values.

### 4.2 Errors

An error serializes to an object with, in this key order:

```
name, message, stack, <remaining own properties in insertion order>
```

`stack` **MAY** be absent in languages without stack capture, in which case the key is
omitted rather than null.

Custom properties attached to the error **MUST** be included, excluding any that would
duplicate `name`, `message`, or `stack`.

> The reference implementation used to carry two error serializers that disagreed: one
> enumerated all own property names, the other spread only enumerable ones. The rule
> above — all own properties — is the normative one, and 1.1.21 converged on it.
> See OQ-3.

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

`logan-logger` additionally accepts `format: 'custom'`, which this table does not
sanction because the value has no defined behavior — it is currently a synonym for
`text`. See OQ-11; it should be given meaning or removed, not left ambiguous.

### 6.2 Precedence

Later sources override earlier ones:

```
library defaults  <  explicit config  <  environment variables
```

Configuration files are deliberately **not** a tier of their own. Discovery is I/O,
so a synchronous constructor cannot perform it, and the reference implementation
keeps `createLogger()` synchronous. File contents therefore enter as *explicit
config*, supplied by the caller:

```typescript
const logger = createLogger(await loadConfigFromFile());
```

Placed there they sit below anything the caller passes alongside them, and below the
environment — the ordering earlier drafts of this section ascribed to a dedicated
tier. An implementation whose constructor is already asynchronous **MAY** insert file
config as its own tier immediately above library defaults; one whose constructor is
synchronous **MUST NOT** claim that tier exists. See §6.5. (OQ-2)

Merge rules per field:

- `metadata` merges **shallowly** across sources; later keys win.
- `transports` is **replaced wholesale**. It never merges.
- Every other field is replaced.

### 6.3 Environment variables

| Variable | Effect |
|---|---|
| `LOG_LEVEL` | parsed per §1.3 |
| `LOG_FORMAT` | accepted only if exactly `json` or `text`; otherwise ignored |
| `LOG_TIMESTAMP` | parsed as a boolean, below |
| `LOG_COLOR` | parsed as a boolean, below |

Booleans accept, case-insensitively and after trimming surrounding whitespace:

| Value | Result |
|---|---|
| `true`, `1`, `yes`, `on` | true |
| `false`, `0`, `no`, `off` | false |
| anything else | **unset** — warn once, fall through to the next source |

An unrecognized value **MUST NOT** be treated as `false`. The variable is ignored, so
the precedence chain in §6.2 continues to whatever set the field below it, and the
implementation **MUST** warn — once per distinct message, not once per logger
constructed.

This revises OQ-5, which is now resolved. Earlier revisions required the strict rule
(true only when the value lowercased is exactly `true`), which made `LOG_TIMESTAMP=1`
silently *disable* timestamps — the value most likely to be intended as "on" was one of
the many that meant "off". That rule is withdrawn; implementations **MUST NOT** apply
it.

### 6.4 `timestamp` and `colorize`

`timestamp: false` **MUST** omit the timestamp from the text form, and `colorize`
**MUST** control ANSI coloring of the level token in the text form only, never the JSON
form. The JSON envelope always carries a timestamp and is never colorized.

Earlier revisions marked both as declared-but-ignored by the reference implementation.
That is no longer true — `logan-logger` 2.0.0 honors both. See OQ-4.

`colorize` alone is not sufficient to decide whether to emit ANSI. An implementation
that writes escapes into a redirected stream corrupts every log file it touches. The
reference implementation additionally requires stdout to be a TTY and honors `NO_COLOR`
and `FORCE_COLOR`; this spec does not yet require that, which is a gap, not an
endorsement of the alternative. Tracked as treering#1.

### 6.5 Configuration files

Earlier revisions declined to specify discovery at all, pending OQ-2. It is now
settled.

An implementation that offers file-based configuration **MUST** search these
candidates, in this order, and use the first one present:

| Candidate | Read from |
|---|---|
| `logan.config.json` | the whole file |
| `.loganrc` | the whole file |
| `package.json` | the `logan` key |

All three are **JSON**. `.loganrc` is conventionally JSON in most ecosystems but not
universally; implementations **MUST NOT** accept YAML or INI without a spec revision.

Rules:

- Candidates are resolved against a caller-supplied base directory, defaulting to the
  process working directory. Implementations **SHOULD** accept an explicit base
  directory, because the working directory is not the package root under process
  managers or in a monorepo.
- A `package.json` with no `logan` key counts as **absent**, so the search continues.
  Returning an empty config here would stop the search and mask a later candidate.
- **Absent** means continue. **Malformed** — unparseable, or not a JSON object — means
  warn naming the path and stop; a broken config file is a mistake to surface, not to
  route around. An implementation **MUST NOT** silently fall back to defaults.
- These are distinct states. An I/O failure on a path that exists is not absence.
  A path that cannot be a config file at all (it is a directory, or a path component
  is not a directory) **MUST** be treated as absent and the search continued; a file
  that exists but cannot be *read* — permissions, sandbox denial — **MUST** warn.
- When the caller names a path explicitly, absent and malformed are both **errors**.
  Asking for a specific file that is not there is a caller mistake. The one exception
  is a sandboxed runtime that denies filesystem access wholesale: that **MUST NOT**
  throw, because it is a property of the host, not of the configuration.
- Implementations **MUST NOT** load executable configuration (`.js`, `.ts`, or any
  form requiring evaluation). Nothing in §6.1 needs to be computed, and executing a
  file discovered in the working directory during logger construction is a code
  execution surface with no offsetting benefit.

Values are **normalized on load**, not passed through raw. A config file naturally
writes `"level": "debug"`, a string, where §1.1 requires an ordinal. Implementations
**MUST** parse it per §1.3, and **MUST** apply the same conversion to a per-transport
`level` (§7.3) — an unconverted string there makes the transport comparison
indeterminate, which in the reference implementation caused the transport threshold to
be ignored entirely rather than to fail loudly. A field that is unrecognized, or of the
wrong type, **MUST** be dropped with a warning naming the file and the field.

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

Default key set:

```
password  token  secret  key  auth
authorization  apikey  authtoken  accesstoken  secretkey
```

Supplying a key set **replaces** the defaults; it does not extend them.

### 8.1 Field name matching

A field is redacted when **any token of its name** matches a key. Matching is on whole
tokens, never on substrings, so `api_key` is redacted and `monkey` is not.

Earlier revisions specified case-insensitive substring matching and required
implementations to reproduce it. That rule is withdrawn (OQ-6).

**Tokenization.** Split the field name at every one of these boundaries, in any order —
the result is the same:

1. Between a lowercase letter or digit and an uppercase letter — `apiKey` → `api`, `Key`
2. Between an uppercase run and an uppercase letter followed by a lowercase letter —
   `APIKey` → `API`, `Key`
3. Between a letter and a digit, in either direction — `key1` → `key`, `1`
4. At every run of characters that are not ASCII letters or digits — `api_key`,
   `api-key`, `api.key` all → `api`, `key`

Then lowercase every token and discard empty ones. This yields the same tokens for
`api_key`, `apiKey`, `API-KEY`, `API_KEY` and `ApiKey`, which is the point: an
implementation **MUST** treat snake_case, camelCase, kebab-case, PascalCase and
SCREAMING_SNAKE identically.

**Matching.** Keys are tokenized by the same rule as field names — this is not
optional, see below. A field is redacted when, for some key:

- every token of the key appears among the field's tokens, **or**
- the field's tokens joined together equal the key's tokens joined together

with, in both comparisons, a **field** token also matching a key token followed by `s`.
All comparisons are on lowercased values.

**The plural rule is one-way**: a field token may be the plural of a key token, never
the reverse. Key `ssn` reaches field `ssns`; key `ssns` does **not** reach field `ssn`.
Keys are written in the singular by convention, and leaving the direction unstated would
let two conforming implementations disagree on a case no fixture pins down.

The joined comparison is what lets `apiKey` as a key reach a field spelled `apikey`, and
`apikey` as a key reach a field spelled `api_key`.

**A key with zero tokens matches nothing.** An implementation **MUST** discard keys that
tokenize to nothing — `""`, `"---"`, `"   "` — before matching. This is not a tidiness
rule: "every token of the key appears" is *vacuously true* for a key with no tokens, so
an unguarded implementation redacts every field in the object. An empty string reaching
the key set from configuration or a trailing comma is not unusual, and the failure is
total.

For a single-token key this reduces to "some field token equals the key", which is the
common case and the one every default key exercises.

**Tokenizing the key side is required, not cosmetic.** An implementation that compares
the key raw against each field token silently breaks every multi-token key: a caller
passing `creditCard` gets nothing, because the field's tokens are `credit` and `card`
and neither equals `creditcard`. It fails closed with no error, and it fails only for
callers who supplied their own keys — precisely the callers who thought about this most.
An implementation **MUST NOT** compare an untokenized key against a tokenized field.

### 8.2 Why the default key set carries joined spellings

`apikey` and `monkey` are the same shape: one all-lowercase token ending in `key`. No
tokenization can separate them, so a rule alone cannot redact one and spare the other.
The joined spellings — `authorization`, `apikey`, `authtoken`, `accesstoken`,
`secretkey` — are therefore listed explicitly.

Without them, moving from substring to token matching would **stop** redacting
`authorization`, `apikey`, `accesstoken` and `secretkey`, all of which the previous rule
caught. A redaction utility that sheds coverage on upgrade is worse than one that
over-matches: a spurious `[REDACTED]` is visible and annoying, a missing one is a leaked
credential nobody sees. Implementations **MUST NOT** narrow the default key set below
this list.

The list is not exhaustive and cannot be. A field named `mytoken` is a single token and
is not redacted; callers with house naming conventions **SHOULD** pass their own keys.

One consequence of the joined comparison in §8.1 is worth stating so it is not mistaken
for a bug: a field whose tokens *join* to a key is redacted even when no single token
matches, so `to_ken` is redacted by the key `token`. Substring matching did not catch
that. It is coverage growing rather than shrinking, which §8.2 permits, and no realistic
field name was found that trips it — but it follows from the rule and implementations
**MUST NOT** special-case it away.

### 8.3 Application

Redaction is **not** applied automatically. It is an explicit utility the caller
invokes. An implementation **MUST NOT** redact by default, because silently altering
logged data is worse than the exposure it prevents when the caller did not ask.

Redaction recurses into nested maps and lists, preserving container types.

### 8.4 Cycles

Redaction **MUST NOT** raise on a cyclic input, and **MUST NOT** substitute a marker for
the cycle. It returns a copy whose structure mirrors the input's, cycles included.

Redaction produces a *value*, not a serialization. Rendering a cycle is §4's job, and
`"[Circular]"` is §4's vocabulary. An implementation that substitutes that marker during
redaction becomes a second place deciding what a cycle looks like, and the two can then
drift — which is precisely the defect OQ-3 recorded when two error serializers disagreed.
Redaction stays narrow: it replaces sensitive values and changes nothing else.

The observable result is unchanged either way. A redacted cyclic value passed to the
serializer yields `"[Circular]"` at the cycle, because §4.1 puts it there:

```
{"name":"x","password":"[REDACTED]","self":"[Circular]"}
```

An implementation whose language cannot express a cyclic value at all is under §4's
existing rule — it never produces the case, and **MUST NOT** invent a substitute.

**Repeated references** follow from the same requirement. If two fields of the input are
the same object, the corresponding fields of the copy are the same object. This is not
separately observable: §4.1 requires both to serialize in full, and they do whether or
not the copy shares them. It is stated because it falls out of any correct
cycle-preserving implementation, and an implementation that deliberately breaks sharing
is doing extra work to produce a less faithful copy.

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
- `src/utils/config-file.ts` — config file discovery and normalization (added for §6.5)

Where the implementation is self-contradicting or clearly wrong, this document
specifies the intended behavior and records the divergence in `OPEN-QUESTIONS.md`
rather than enshrining the bug.

Sections 6.2 through 6.5 were revised against 2.0.2 and the 2.1.0 configuration work,
which resolved OQ-2 and OQ-5.

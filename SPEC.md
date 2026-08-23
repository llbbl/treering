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

**This chain is not the whole rule for `colorize`.** §6.4.1 places `NO_COLOR` above all
three tiers — as a veto rather than a fourth source — and constrains where an optional
TTY gate may sit. An implementation built from this section alone resolves `colorize`
correctly for every input except the one users care about most, so read §6.4.1 before
writing the resolver.

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

Every variable in this table is read **case-insensitively and after trimming surrounding
whitespace**. There is no exception: a variable that behaved differently from its
neighbours would be a trap, not a feature.

| Variable | Effect |
|---|---|
| `LOG_LEVEL` | parsed per §1.3, but see the override below |
| `LOG_FORMAT` | accepted only if `json` or `text`; anything else is **unset** |
| `LOG_TIMESTAMP` | parsed as a boolean, below |
| `LOG_COLOR` | parsed as a boolean, below |

An earlier revision said `LOG_FORMAT` was accepted "only if **exactly** `json` or
`text`", which read as the one case-sensitive variable in the table. That was drift, not
intent, and is withdrawn.

**A variable that is set to the empty string is still set.** It is a value like any
other, it matches nothing in the tables below, and it therefore takes the
unrecognized-value path including the diagnostic. Implementations **MUST NOT** conflate
"set to empty" with "not set" — a language whose empty string is falsy will do so by
accident if the presence check is a truthiness test, and the mandated diagnostic then
disappears while the resulting value stays accidentally correct.

This rule governs **the variables in this table**, which are the ones in this library's
namespace. `NO_COLOR` is not one of them: it is defined by a standard this spec does not
own, its empty value means *unset*, and §6.4.1 specifies it. The two rules are opposite on
purpose — see §6.4.1 before making them consistent.

**`LOG_LEVEL` overrides §1.3's fallback.** §1.3 resolves an unrecognized level string to
INFO, which is right for parsing a value in isolation. Applied to an environment
variable it is wrong: a typo in an operator's shell would *raise* verbosity on a service
that explicitly asked for `ERROR`, and quietly. So an unrecognized `LOG_LEVEL` is
**unset** — warn, and fall through to the next source in §6.2 — like every other
variable here. §1.3 still governs `parse`-style entry points that take a level string
directly.

Booleans accept:

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

`colorize` alone is not sufficient to decide whether to emit ANSI. An implementation that
writes escapes into a redirected stream corrupts every log file it touches. Two things
bear on that: the `NO_COLOR` convention, specified in §6.4.1, and whether the destination
is an interactive terminal, which this spec still does not require — see "TTY detection
and `FORCE_COLOR`" at the end of §6.4.1.

#### 6.4.1 `NO_COLOR`

An implementation **MUST** honor the [`NO_COLOR`](https://no-color.org/) convention.

When the environment variable `NO_COLOR` is set to a non-empty value, `colorize`
**MUST** resolve to `false`, regardless of what any other source says: `LOG_COLOR=true`
(§6.3), an explicit `colorize: true` from the caller, a `colorize` read from a
configuration file (§6.5), and a `colorize` supplied in a per-transport `options` block
— the source easiest to miss, since §7.1.2 otherwise lets a transport prefer its own
options. §7.1.2 carries the matching carve-out.

`NO_COLOR` therefore sits **above** §6.2's precedence chain rather than inside it:

```
library defaults  <  explicit config  <  environment variables  <<  NO_COLOR
```

§6.2 orders the sources this library owns; `NO_COLOR` belongs to none, being a
preference the user expresses to every program at once. A veto, not a setting.

**But a veto nothing can observe is not enforced.** The veto **MUST** be observable in
the resolved configuration: whatever mechanism an implementation uses, a caller
inspecting the effective `colorize` **MUST** see `false` — otherwise the configuration
reports `colorize: true` to everyone who asks, including every conformance case here.

**The same holds at the transport boundary.** While the veto is in force, a transport
**MUST NOT** be able to observe a `colorize` of `true` — not from the logger context it
is handed, and not from its own `options` (§7.1.2). An implementation may arrange that
however it likes — neutralize the option at construction, hand a vetoed value down per
write, anything with the same observable result. What it **MUST NOT** do is apply the
veto only inside the transports it ships itself.

The reason is §7.1.1: the set of transport type names is **open**, so some transports
are written by application authors. A clamp inside the implementation's own console
transport never reaches a registered one, which reads `options.colorize: true` and emits
ANSI while the user who set `NO_COLOR` watches color arrive — and its author did nothing
wrong, since §7.1.2's design is that the logger resolves presentation *so that* a
transport need not. The duty rests on the implementation, at the handoff.

**The value carries no meaning, but emptiness does.** Presence is the entire signal, so
`NO_COLOR=0` and `NO_COLOR=false` both disable color. `NO_COLOR=""` **MUST** be treated
as though the variable were absent, per the convention's wording — "present and not an
empty string". Unlike the variables in §6.3, `NO_COLOR` is **not** trimmed and **not**
case-folded before this test: the raw value is examined, so a single space is non-empty
and disables color.

That is the exact opposite of §6.3's empty-string rule, because §6.3 governs this
library's own namespace while `NO_COLOR`'s semantics are fixed by a standard this spec
does not own. Implementations **SHOULD** record that reason wherever the two checks sit
near each other in code, since the inconsistency otherwise reads as an oversight. OQ-4
has the argument.

**An opt-out from environment configuration does not reach `NO_COLOR`.** An
implementation **MAY** offer callers a way to ignore environment-based configuration
wholesale. Such an opt-out **MUST NOT** suppress the `NO_COLOR` veto, and an
implementation offering one **MUST** still resolve `colorize` to `false` when `NO_COLOR`
is set to a non-empty value. An opt-out is itself configuration, settable in a committed
file (§6.5), so honoring it would let one checked-in line defeat `NO_COLOR` for everyone
who runs that project. OQ-4 has the rest.

**Disagreement is reported.** When `NO_COLOR` is set to a non-empty value and
`LOG_COLOR` parses to `true` (§6.3), the user has asked for two incompatible things
through two environment variables. `colorize` resolves to `false`, and the
implementation **MUST** emit a diagnostic that names both variables literally — the
strings `NO_COLOR` and `LOG_COLOR`, so a reader can grep for them and a fixture can
assert them. It **SHOULD** also state that color was disabled and which variable won;
that half is only a **SHOULD** because no implementation-neutral substring exists for
it, so no conformance case can check it (OQ-4). Warn once, per §6.3.

**This** diagnostic **MUST NOT** be emitted when:

- `NO_COLOR` is absent, or is set to the empty string. An empty value is unset here, so
  there is no veto in force and nothing for `LOG_COLOR` to contradict, whatever it says;
- `LOG_COLOR` is absent, or is set to a value that does not parse to `true` under §6.3.
  The two **agreeing** — `NO_COLOR` non-empty alongside a `LOG_COLOR` that parses to
  `false` — is the ordinary shape of this, and it is silent;
- `NO_COLOR` overrides a non-environment source, such as an explicit `colorize: true` in
  code or in a configuration file. Overriding the program's own choice is the
  convention's entire purpose, so it is not noteworthy; the diagnostic is for a user
  contradicting themselves.

The word **this** is load-bearing, and the bullets say "does not parse to `true`" rather
than "is set" for the same reason: worded loosely they would forbid the
unrecognized-`LOG_COLOR` warning §6.3 requires and the suite asserts. This section
governs its own diagnostic only.

##### TTY detection and `FORCE_COLOR`

`colorize` is **not** required to be gated on the destination being an interactive
terminal, and `FORCE_COLOR` is not required at all. Both are **implementation-tested
rather than fixture-tested**: `fixtures/README.md` has no vocabulary for "stdout is not
a terminal", so neither is reachable by a case and an implementation either way
conforms. *Where* such a check may sit is specified here.

**Two different things get called "a TTY gate", and only one is constrained.** The first
is a check on *the process's own output stream* that takes part in resolving the
logger's `colorize` — one question, asked once, about stdout. An implementation that has
one **MUST** place it at the **default** tier of §6.2. It **MAY** use it to answer the
runtime-dependent default §6.1 leaves open, the question a TTY check is good at. It
**MUST NOT** let the check outrank an explicit `colorize` from the caller, a `colorize`
read from a configuration file, or `LOG_COLOR` (§6.3): a caller naming `colorize` has
already answered it.

Applied to the *resolved* value instead it returns `colorize: false` whenever stdout is
a pipe — the condition in CI, where these fixtures run — failing every case that asserts
`colorize: true`. Pinned to the default tier it still decides every case nobody else
did.

The second is a transport deciding about *its own destination*. A transport **MAY**
refuse to emit ANSI for the sink it writes to, whatever `colorize` it was handed and
whatever a caller configured — §6.4's reason: escapes in a redirected stream corrupt
every log file they touch. An unconditionally colorless file transport is correct, not a
precedence violation; it reports that its destination cannot carry a preference rather
than overruling one. A logger with a console and a file transport should color the first
and not the second.

The line between them is **scope, not mechanism**: "should this program use color at
all" is precedence and is constrained, "can *this destination* carry color" is not. An
implementation may call `isatty` in both places.

**`FORCE_COLOR` is constrained the same way.** Reading it is still not required. An
implementation that does read it **MUST** place it at the **default** tier of §6.2 —
stated independently, since an implementation may read `FORCE_COLOR` without having a
TTY check to anchor to. It **MUST NOT** outrank an explicit `colorize` from the caller
or from a configuration file, or `LOG_COLOR` (§6.3), and it **MUST NOT** overturn
`NO_COLOR` (§6.4.1) — leaving it open while pinning the TTY check would leave the
identical hole one variable to the left. Some ecosystems let `FORCE_COLOR` beat
`NO_COLOR`; this spec does not, for the reason settled above. `NO_COLOR` sits above the
whole chain, so a check of either kind can only agree with it — a fact about
*precedence* only, leaving the veto still to be made observable at the transport
boundary, deliberately, per the rule above.

That TTY detection is not *required* remains a gap, not an endorsement of the
alternative, and is named here so it is visible rather than absent. Tracked as
treering#1.

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

An unrecognized transport type **MUST** be reported on the diagnostic channel and
skipped. It **MUST NOT** abort construction — one unusable destination is not a reason
to lose the others, which is §7.2 applied at selection time.

### 7.1.1 Type names are open

The set of transport type names is **not** closed. An implementation **SHOULD** offer a
registry so an application can add a transport and name it from configuration like any
built-in. `console` is the only name every implementation **MUST** provide; `file` is
required wherever the runtime has a filesystem.

An implementation whose configuration type cannot express a registered name has a
registry it cannot reach from config, which is a bug even though it type-checks. Naming
this because the reference implementation shipped exactly that: `registerTransport`
accepted any string while the config type was a closed union of four, so a registered
transport needed a double cast to use.

The cost is real and worth accepting deliberately: an open set means a mistyped name is
no longer a compile-time error in a statically typed implementation. It surfaces at
construction as the diagnostic above. Implementations **MUST NOT** close the set to
recover that check.

### 7.1.2 Presentation context

A transport **MUST** be given the logger's `format`, `timestamp` and `colorize` when it
is constructed, and **MUST** prefer its own options over them where both are supplied.
A transport that cannot see them has to duplicate the logger's presentation settings or
hardcode them, and the two then drift.

**The preference rule has exactly two exceptions, and both concern `colorize`.**

The first runs *downward*, from configuration. Where §6.4.1 has forced `colorize` to
`false`, a transport **MUST NOT** re-enable it from its own options. The veto reaches the
transport, not merely the logger.

Enforcing that is the **implementation's** job, not the transport author's. §6.4.1
requires that a vetoed `colorize` never reach a transport as `true` in the first place —
neither through the context nor through the transport's own options — so a transport
contributed by an application author conforms by doing nothing special. That is the only
workable arrangement, given that §7.1.1 leaves the set of transport types open.

The second runs *upward*, from the destination. A transport **MAY** decline to emit ANSI
for the sink it writes to whatever `colorize` reached it — from the logger context, from
its own options, or from a caller who named it explicitly. §6.4.1 grants this under "TTY
detection and `FORCE_COLOR`", and §6.4 states why it has to exist: escapes written into a
redirected stream corrupt every log file they touch. A file transport that is
unconditionally colorless is conforming, not a preference violation.

They point in opposite directions and neither is negotiable. The first stops a transport
turning color *on* against the user's stated preference; the second lets a transport keep
color *off* when its destination cannot carry it. What no transport may do is the middle
case — emit ANSI under a veto because its own options said so.

The preference rule at the top of this section **MUST NOT** be read as complete on its
own, because reading it that way is how the first exception's hole appeared. Taken alone
the preference rule licenses exactly the wrong answer:
`NO_COLOR` is set, the logger resolves `colorize` to `false`, a transport configured with
`options.colorize: true` prefers its own value, escapes reach the stream — and both
sections have been obeyed to the letter. §6.4.1 names per-transport options among the
sources its veto outranks; the first exception above is that same rule restated where an
implementer writing transport construction will actually be looking, because a rule that
looks complete is the one nobody cross-checks.

**The preference rule applies however the transport is supplied.** If an implementation
offers an escape hatch for passing a pre-built transport object, that object has no
construction step to receive the context, so the implementation **MUST** also accept a
factory form that does. An escape hatch that silently cannot see the context is not
equivalent to a registered transport, and callers will not discover the difference until
their output is formatted wrongly.

**So does the carve-out, and it needs a second mechanism to get there.** Phrased as "a
transport **MUST NOT** re-enable `colorize` from its own options", the veto reaches only a
transport that *has* options — a pre-built object with color hardcoded has none to
suppress, emits ANSI under `NO_COLOR`, and breaks nothing written above. Offering a
factory form closes that for callers who use it and leaves the raw-object path open. So:
where §6.4.1 has vetoed `colorize`, an implementation offering a raw-object escape hatch
**MUST** do one of three things — carry the veto to the object through whatever channel it
does expose, strip ANSI from what the object writes, or decline the raw-object form under
a veto and require the factory one. Which it picks is its own affair. What it **MUST NOT**
do is hand a pre-built object the stream and treat the veto as that object's problem. An
escape hatch is a thing a caller reaches for once and forgets; the user who set `NO_COLOR`
never agreed to it.

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

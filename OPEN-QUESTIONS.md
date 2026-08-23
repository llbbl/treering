# Open questions

Each item is a place where the reference implementation (`logan-logger` v2.0.2) is
ambiguous, self-contradicting, or arguably wrong. The spec takes a position on each;
these are the positions worth revisiting before 1.0.

Resolving one of these may require a change in `logan-logger` itself. Where that is
true it is noted.

---

## OQ-1 — Repeated references reported as circular

**Status:** resolved and closed. Fixed in `logan-logger` 2.0.0;
`serialization/repeated-not-circular` is active and passing under the conformance
runner (llbbl/treering#3).

`safeStringify` adds every visited object to a `WeakSet` that is never unwound:

```ts
if (typeof value === 'object' && value !== null) {
  if (seen.has(value)) return '[Circular]';
  seen.add(value);
}
```

So a value referenced twice as siblings — a DAG, not a cycle — emits `"[Circular]"` on
the second occurrence. Logging `{ a: user, b: user }` loses `b` entirely.

**Spec position (§4.1):** genuine cycles only. Track the current path, unwind on the
way out.

**Fixed in `logan-logger`** by
[#57](https://github.com/llbbl/logan-logger-ts/issues/57): `safeStringify` now
tracks only the current traversal path and unwinds on the way out, so `[Circular]`
means an ancestor of itself. Shipped in 2.0.0, as a major because it changes output
for existing users.

---

## OQ-2 — `.loganrc` is advertised but unreachable

**Status:** resolved. Discovery is now specified in SPEC §6.5, and the precedence
question it blocked is settled in §6.2. Fixed in `logan-logger` 2.1.0 (llbbl/logan-logger-ts#58).

`loadConfigFromFile` searches:

```
logan.config.json, logan.config.js, .loganrc, package.json
```

but `loadNodeConfig` only handles paths ending in `.json` or `.js`. `.loganrc` matches
neither and silently returns `{}`.

Worse, the loop returns on the **first** iteration regardless of outcome, because
`loadNodeConfig` catches its own errors and returns `{}` rather than throwing. So
`logan.config.js`, `.loganrc`, and `package.json` are **never** consulted. Only
`logan.config.json` is reachable, and only if it parses.

**Resolution:** support three of the four properly, and drop the fourth.
`logan.config.json`, `.loganrc` and `package.json#logan` are searched in order via a
candidate table rather than by extension sniffing, and the loader distinguishes
absent / unreadable / malformed instead of collapsing all three into `{}`.

`logan.config.js` was **removed** rather than fixed. It was unreachable through the
default search, so removing it from that path breaks nobody; an explicit
`loadConfigFromFile('x.js')` did work, so this is a narrow real break, which is why the
fix shipped as a minor rather than a patch. Nothing in §6.1 needs to be computed, so
JSON covers the whole surface, and dropping it removed a code execution surface —
a file discovered in the working directory being imported and evaluated during logger
construction. §6.5 now forbids executable configuration for every implementation.

Two things surfaced while fixing this that the original question did not anticipate:

- **Normalization is mandatory, not cosmetic.** A config file naturally writes
  `"level": "debug"`. Handed to the runtime unconverted, every `level >= threshold`
  comparison is `NaN`, so the logger silently discards **every** record. The
  reproduction in the original report — `{"logan":{"level":"debug"}}` — would have gone
  from a silent no-op to a silent blackout had the chain been fixed on its own.
- **The same defect exists one level down, inverted.** An unconverted per-transport
  `level` (§7.3) makes that comparison `NaN` too, but there the failure is
  `NaN → false → nothing is filtered`. A file transport configured
  `{"type":"file","level":"error"}` to keep debug noise off disk receives every debug
  record instead. Silent over-retention is worse than silent loss, and §6.5 now requires
  the conversion at both levels.

**Fixed in `logan-logger` 2.1.0.**

---

## OQ-3 — Two disagreeing error serializers

**Status:** resolved. Fixture `serialization/error-non-enumerable` is active.

`safeStringify` enumerates `Object.getOwnPropertyNames(value)` and copies everything
except `name`/`message`/`stack`. `serializeError` instead spreads `...(error as any)`,
which copies only **enumerable** own properties.

For a typical `Error`, `name`, `message`, and `stack` are non-enumerable, so the two
functions produce different objects for the same input.

**Spec position (§4.2):** all own properties, in the order `name, message, stack, rest`.

**Fixed in `logan-logger` v1.1.21** by
[#59](https://github.com/llbbl/logan-logger-ts/issues/59): `safeStringify`'s error
branch delegates to `serializeError`, which reads all own properties via
`Object.getOwnPropertyNames` in the order `name, message, stack, rest`, omits
`stack` when undefined, and yields `'[Throws]'` for an accessor that throws.

---

## OQ-4 — `timestamp` and `colorize` are declared but ignored

**Status:** resolved and closed. Fixed in `logan-logger` 2.0.0; both
`envelope/timestamp-disabled` and `envelope/colorize-never-affects-json` are active and
passing under the conformance runner (llbbl/treering#3). Their `pending_reason` text had
gone stale — it described plumbing that 2.0.0 replaced.

`LoggerConfig` declares both. `formatLogEntry(entry, format)` accepts neither, so:

- `timestamp: false` has no effect; the timestamp is always emitted
- `colorize` has no effect in the shared formatter; `formatLevel(level, colorize)`
  exists and applies ANSI codes but the formatter never calls it

This is the same shape as `transports`, which was also declared and ignored until it
became a reported bug.

**Spec position (§6.4):** both are honored, `colorize` affects the text form only.
Fixtures are marked `pending` until the implementation complies.

**Fixed in `logan-logger`** by
[#60](https://github.com/llbbl/logan-logger-ts/issues/60): `formatLogEntry` takes a
`FormatOptions` argument and the console transport passes the config through. Both
options affect the text form only — the JSON envelope always carries a timestamp
and is never colorized. Shipped in 2.0.0.

The spec originally said nothing about how `colorize` interacts with the environment,
noting only that the implementation gates it on stdout being a TTY and honors `NO_COLOR`
and `FORCE_COLOR`. Without some such gate, honoring `colorize` starts writing ANSI escapes
into every redirected log file.

**Half of that is now specified.** §6.4.1 makes `NO_COLOR` normative and gives it override
semantics: set to a non-empty value it forces `colorize` to `false` above everything in
§6.2's chain, its value is meaningless, an empty value means unset, and disagreement with
`LOG_COLOR=true` disables color and warns. It reaches per-transport options too, it is
observable in the resolved configuration rather than only at the point of writing, and no
opt-out from environment configuration suppresses it. Ten fixtures cover it. See
[#10](https://github.com/llbbl/treering/issues/10).

**Neither TTY detection nor `FORCE_COLOR` is required**, and both remain
[treering#1](https://github.com/llbbl/treering/issues/1). They are not merely unwritten:
no fixture can reach them, because `fixtures/README.md` has no vocabulary for "stdout is
not a terminal". §6.4.1 names them as implementation-tested rather than fixture-tested so
the gap is visible in the spec instead of absent from it.

**What is now specified is where each may sit.** A process-wide TTY check — one question
about the process's own stdout, feeding the logger's resolved `colorize` — sits at §6.2's
default tier: it may answer the runtime-dependent default, and never outranks explicit
config or `LOG_COLOR`. `FORCE_COLOR`, where an implementation reads it, sits at that same
tier and does not overturn `NO_COLOR`. Without those placements an implementation
checking the *resolved* value would fail every fixture asserting `colorize: true`
whenever stdout is a pipe, which is the condition in CI.

**A transport declining ANSI for its own destination is a different thing, and is not
constrained.** §6.4.1 says so explicitly: `logan-logger`'s file transport hardcodes
colorless output regardless of an explicit `colorize: true`, and that is correct, not a
precedence violation. The line the spec draws is scope — "should this program use color"
is precedence; "can *this destination* carry color" belongs to the destination.

### Why the two empty-string rules are opposite

§6.3 requires an empty `LOG_COLOR` to be treated as *set* — matching nothing, taking the
unrecognized path, and warning. §6.4.1 requires an empty `NO_COLOR` to be treated as
*unset*. Both are correct, and an implementation that reconciles them into a single rule
will break one of them.

The difference is ownership. §6.3 governs variables in this library's own namespace, where
an empty value is a mistake worth reporting to whoever set it. `NO_COLOR` is defined by a
standard this spec does not own and cannot revise, and that standard says "present and not
an empty string" — so an empty value means the user did not express the preference at all.

The inconsistency is otherwise indistinguishable from an oversight, which is why §6.4.1
asks implementations to record the reason wherever the two checks sit near each other in
code. The reference implementation carries it as a comment beside both checks.

### Why "states that color was disabled" is a SHOULD and not a MUST

An earlier revision of §6.4.1 required the disagreement diagnostic both to name
`NO_COLOR` and `LOG_COLOR` *and* to state that color was disabled. The second half was
downgraded to **SHOULD**.

`expect.diagnostics` compares substrings, which is what makes the naming half checkable in
every language. There is no implementation-neutral substring for *"color was disabled"* —
each implementation phrases it in its own words and often its own locale — so no
conformance case can reach that requirement.

A **MUST** that no conformance case can reach is indistinguishable from a suggestion, and
in a spec whose premise is that its requirements are verifiable against a fixture suite,
leaving it as a **MUST** would teach readers that some of them are decorative. It is
written as the **SHOULD** it always was in practice. It is still a **SHOULD** rather than
silence, because a diagnostic naming two variables and no consequence leaves the reader to
guess which one won.

### Why an environment opt-out does not suppress the veto

§6.4.1 keeps one compact reason: an opt-out is itself configuration, settable in a
committed file, so honoring it would let one checked-in line defeat `NO_COLOR` for
everyone who runs that project. Two further reasons stand behind it.

The two mechanisms answer different people. An opt-out of that kind exists so a library is
not steered by the *host application's* operational settings. `NO_COLOR` is not an
operational setting: it is the *end user's* preference, addressed to every program in
their session at once, and a library was never the party it was aimed at.

And the failure mode is structural rather than deliberate. An implementation that reads
`NO_COLOR` through the same gate it uses for the §6.3 variables inherits the opt-out
without anyone deciding to. The veto has to be checked whether or not those variables are.

### Why the TTY subsection stopped being called "What is not specified"

It was headed that way while both TTY detection and `FORCE_COLOR` were wholly unspecified.
Having either remains optional, but *where* each may sit is now required, so the old title
described only half of the section. Renamed to "TTY detection and `FORCE_COLOR`".

---

## OQ-5 — Strict boolean parsing for environment variables

**Status:** resolved as option 2. SPEC §6.3 rewritten; the strict rule is withdrawn.

`LOG_TIMESTAMP` and `LOG_COLOR` were true only when the value lowercased was exactly
`true`. So `LOG_TIMESTAMP=1` silently disabled timestamps, as did `yes`, `on`, and any
typo.

**Options:**
1. Keep strict (previously documented in §6.3)
2. Accept `1`/`true`/`yes`/`on` as true, `0`/`false`/`no`/`off` as false, and treat
   anything else as unset rather than false

**Resolution:** option 2, plus a warning on an unrecognized value. Treating an
unparseable value as unset rather than as `false` is the important half — it lets the
precedence chain fall through to whatever configured the field below, instead of a typo
silently overriding an explicit setting.

Caught during the OQ-2 reconciliation pass: `logan-logger` **already shipped option 2**
in 2.0.0, via [#65](https://github.com/llbbl/logan-logger-ts/issues/65), while §6.3
still said implementations "MUST NOT broaden this without a spec revision". The
reference implementation was in violation of its own spec for three releases. This is
the spec revision.

Worth noting for whoever writes the second implementation: the value of this question
was never the truthy list, it was the third state. A two-valued parse has nowhere to put
"I could not read this."

---

## OQ-6 — Redaction over-matches

**Status:** resolved as option 3, with a correction. SPEC §8 rewritten.

Matching was `field.toLowerCase().includes(sensitive.toLowerCase())`, so with the old
default key set:

| Field | Redacted? | Intended? |
|---|---|---|
| `password` | yes | yes |
| `authorization` | yes | yes |
| `monkey` | **yes** | no — contains `key` |
| `keyboard_layout` | **yes** | no |
| `tokenizer` | **yes** | no |
| `public_key` | yes | debatable — it is public |

**Options:**
1. Keep substring (current, §8)
2. Exact match on the full field name
3. Word-boundary match, so `api_key` and `apiKey` hit but `monkey` does not

Option 3 is probably right but needs a defined word-splitting rule that works for
`snake_case`, `camelCase`, `kebab-case`, and `PascalCase` identically across languages.
That rule has to be specified precisely or implementations will diverge.

**Resolution:** option 3, with a correction the question did not anticipate. The
tokenization rule is now SPEC §8.1, covering camelCase, PascalCase, SCREAMING_SNAKE,
every non-alphanumeric separator, and letter/digit boundaries, plus a plural rule so a
token matches a key or the key followed by `s`.

**The correction: option 3 on its own loses coverage, in the dangerous direction.**
Tokenizing against the original five keys was measured against a corpus of real field
names, and it stops redacting:

| Field | Old rule | Pure option 3 |
|---|---|---|
| `authorization` | redacted | **leaks** |
| `apikey` | redacted | **leaks** |
| `accesstoken` | redacted | **leaks** |
| `secretkey` | redacted | **leaks** |
| `tokens`, `keys`, `passwords` | redacted | **leaks** |

The cause is structural, not a flaw in the splitting rule: `apikey` and `monkey` are the
same shape — one all-lowercase token ending in `key` — so no tokenization can redact one
and spare the other. The fix is a dictionary, not a better rule. The default key set
gained the joined spellings, and the plural case became a matching rule rather than ten
more entries so it applies to caller-supplied keys too.

Measured on 46 credential-shaped names and 20 innocent ones: **zero coverage lost, all
19 previously over-matched names fixed**, with a 10-key default set. `mytoken` remains
uncovered and is documented as such — it is a single token, and only a caller-supplied
key can reach it.

**A second correction, found while implementing.** The first draft of §8.1 tokenized the
field name but compared each key **raw**. That silently breaks every multi-token key: a
caller passing `creditCard` redacts nothing, because the field's tokens are `credit` and
`card` and neither equals `creditcard`. Measured against the old substring rule, keys
like `apiKey`, `creditCard`, `customSecret` and `userPassword` all went dead.

This was worse than the first problem it was meant to solve. It fails closed, silently,
and only for callers who supplied their own key set — the callers who thought hardest
about redaction. It surfaced because two existing `logan-logger` tests passed camelCase
keys and started failing.

§8.1 now tokenizes both sides and matches when every key token is present among the
field tokens, or the two joined forms are equal. For a single-token key that reduces to
the original rule, so no fixture changed. It also makes `apiKey` as a supplied key reach
`api_key` and `x-auth-token`, which is what a caller would assume it already did.

The general lesson is worth keeping for other redaction questions: for this utility a
false positive is visible and a false negative is invisible, so any change **MUST** be
evaluated for coverage lost before it is evaluated for elegance. Both corrections here
were coverage losses hiding inside a cleaner-looking rule.

---

## OQ-7 — `runtime` field across languages

**Status:** spec defers.

`runtime` holds `node`/`deno`/`bun`/`browser`/`webworker`/`unknown`. In a Go
implementation the natural value is `go`, which conflates language and runtime in a way
that is fine in JavaScript — where several runtimes share one language — and awkward
elsewhere.

**Options:**
1. Keep one free-form `runtime` field, each implementation documents its values (§2.3)
2. Split into `language` (`javascript`, `go`, `rust`, `python`) and `runtime`
   (`node`, `deno`, `bun`, `cpython`, `tokio`, …)
3. Drop it from the envelope; it is arguably deployment metadata, not record data

Option 2 is the most useful for a log aggregator receiving records from several
languages, which is the scenario Treering exists to serve. It is also a breaking
envelope change, so it should be settled before 1.0.

---

## OQ-8 — `SILENT` in the level enum

**Status:** spec restricts it.

`SILENT = 4` sits in the same enum as emit levels. `formatLevel` even assigns it a
color, implying somewhere expected to render a record at level SILENT.

**Spec position (§1.2):** threshold-only, never a record level, no `silent()` method.

Low risk, but implementations in languages with exhaustive matching will need a
separate threshold type or a documented invariant.

---

## OQ-9 — Timestamp precision and clock source

**Status:** unspecified.

The spec mandates ISO 8601 UTC with millisecond precision, matching JavaScript's
`toISOString()`. Languages with nanosecond clocks must truncate, and the rounding
direction is not specified.

**Also unspecified:** whether the timestamp is captured when the log call is made or
when the record is written. Under async transports these differ, and it matters for
ordering. Should be "at call time"; needs stating.

---

## OQ-10 — Ordering guarantees

**Status:** unspecified.

Nothing says whether records emitted in program order must appear in output order. For
a synchronous console transport this is free. For buffered or async file transports it
is a real constraint, and it interacts with flush-on-crash.

Needs a position before anyone writes a batching transport.

---

## OQ-11 — `format: 'custom'` exists in the implementation but not the spec

**Status:** spec is narrower than the reference implementation.

SPEC §6.1 types `format` as `json | text`, and §6.3 accepts `LOG_FORMAT` only when it
is exactly one of those. But `logan-logger`'s own `LoggerConfig['format']` is
`'json' | 'text' | 'custom'`, and `'custom'` is threaded through `TransportContext`,
`ConsoleTransportOptions` and `FileTransportOptions` — where it is currently treated as
a synonym for `text`.

Surfaced while fixing OQ-2: the config-file loader rejected `'custom'` while
`createLogger({ format: 'custom' })` accepted it, so the same value was legal through
one door and not the other. The loader was made consistent with the library, which
leaves the spec as the odd one out.

**Decision needed:** either define what `custom` *means* — it currently has no behavior
of its own, which is a poor thing to put in a cross-implementation spec — or remove it
from `LoggerConfig` and let a custom transport own its formatting. The second is more
appealing: a transport already receives the whole record and can format it however it
likes, so a `format` value that means "some transport will decide" is redundant with
the transport list.

**Requires a decision before any second implementation.**

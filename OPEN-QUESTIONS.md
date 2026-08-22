# Open questions

Each item is a place where the reference implementation (`logan-logger` v1.1.18) is
ambiguous, self-contradicting, or arguably wrong. The spec takes a position on each;
these are the positions worth revisiting before 1.0.

Resolving one of these may require a change in `logan-logger` itself. Where that is
true it is noted.

---

## OQ-1 — Repeated references reported as circular

**Status:** spec diverges from implementation.

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

**Requires a fix in `logan-logger`.** This is a behavior change and would need a
fixture update; it produces different output for existing users, so it belongs with
the 2.0 work.

---

## OQ-2 — `.loganrc` is advertised but unreachable

**Status:** implementation bug, spec is silent.

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

**Decision needed:** support all four properly, or shrink the documented list to what
actually works. The spec currently says nothing about config file discovery for exactly
this reason.

**Requires a fix in `logan-logger`.**

---

## OQ-3 — Two disagreeing error serializers

**Status:** spec picks one.

`safeStringify` enumerates `Object.getOwnPropertyNames(value)` and copies everything
except `name`/`message`/`stack`. `serializeError` instead spreads `...(error as any)`,
which copies only **enumerable** own properties.

For a typical `Error`, `name`, `message`, and `stack` are non-enumerable, so the two
functions produce different objects for the same input.

**Spec position (§4.2):** all own properties, in the order `name, message, stack, rest`.

**Requires a fix in `logan-logger`** to unify the two paths.

---

## OQ-4 — `timestamp` and `colorize` are declared but ignored

**Status:** spec declares intent; fixtures pending.

`LoggerConfig` declares both. `formatLogEntry(entry, format)` accepts neither, so:

- `timestamp: false` has no effect; the timestamp is always emitted
- `colorize` has no effect in the shared formatter; `formatLevel(level, colorize)`
  exists and applies ANSI codes but the formatter never calls it

This is the same shape as `transports`, which was also declared and ignored until it
became a reported bug.

**Spec position (§6.4):** both are honored, `colorize` affects the text form only.
Fixtures are marked `pending` until the implementation complies.

**Requires a fix in `logan-logger`.**

---

## OQ-5 — Strict boolean parsing for environment variables

**Status:** spec enshrines current behavior, flags it.

`LOG_TIMESTAMP` and `LOG_COLOR` are true only when the value lowercased is exactly
`true`. So `LOG_TIMESTAMP=1` silently disables timestamps, as does `yes`, `on`, and any
typo.

**Options:**
1. Keep strict (current, documented in §6.3)
2. Accept `1`/`true`/`yes`/`on` as true, `0`/`false`/`no`/`off` as false, and treat
   anything else as unset rather than false

Option 2 is friendlier and the failure mode of option 1 is silent. Leaning 2, but it is
a behavior change.

---

## OQ-6 — Redaction over-matches

**Status:** spec enshrines current behavior, flags it.

Matching is `field.toLowerCase().includes(sensitive.toLowerCase())`, so with the default
key set:

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

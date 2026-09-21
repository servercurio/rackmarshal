<!--
  ~ SPDX-License-Identifier: Apache-2.0
-->

# 0019 — Brand identity

- **Status:** Draft
- **Owner:** Nathan Klick
- **Date:** 2026-09-16
- **Summary:** The Rackmarshal visual identity, derived entirely from the existing Server Curio mark. It fixes
  a six-value brand ramp, a plum-carries-action rule that keeps crimson free for failure, measured
  contrast pairs for both themes, two Rackmarshal-specific state ramps, a three-face type system, and an icon
  system that adopts Lucide and draws the six concepts no icon library has. It also adopts the Rackmarshal
  product mark, distinct from the Server Curio corporate mark. The machine-readable form is
  `brand/tokens.css`; the reference page is `brand/index.html`.

> An initial draft. The surfaces that consume this are [0016](0016-web-ui-architecture.md),
> [0017](0017-portal.md), [0018](0018-console.md), and the login site in
> [0007](0007-sso.md).

## Context & goals

`rackmarshal` has held a brand mark at `docs/images/logo.svg` since the repository was created, and
`.claude/conventions.md` protects it: one source of truth, no divergent copies, and `logo-mark.svg` must
keep path data identical to it. What has never existed is anything downstream of the mark — no palette,
no type system, no rule for which colour means failure. 0016 introduces three browser surfaces that all
need those answers on the same day, and 0007's login site has needed them since it was written.

**Goals**

- Derive every colour from the existing mark rather than inventing a palette beside it.
- Publish contrast that was measured, so 0007's WCAG 2.2 AA commitment is checkable.
- Name the states Rackmarshal actually has, not a generic success/warning/error triple.
- Ship tokens in a form the UIs consume directly, so the documentation and the product cannot drift.

**Non-goals**

- Restyling the mark. Its geometry and colours are fixed; this document only describes how to use them.
- A component library — 0016 owns the stack and defers extraction.
- Marketing or website design. This is the product identity; the Hugo site may adopt it later.

## Proposal

### The ramp

The mark is a heat gradient: plum at the cool outer ring, rose through the middle, crimson where the
metal is worked, and three sand-coloured sparks thrown clear of it. Five values come straight out of
`docs/images/logo.svg`; the sixth is the ground they sit on.

| Name   | Hex       | Origin in the mark            | Role                                |
|--------|-----------|-------------------------------|-------------------------------------|
| Anvil  | `#15090E` | Derived — near-black, plum-biased | Dark ground                     |
| Plum   | `#4D1229` | Outer ring, "Curio" wordmark  | Primary action                      |
| Rose   | `#993744` | Middle ring, tagline          | Secondary, quiet emphasis           |
| Ember  | `#B61F33` | S-spiral, "Server" wordmark   | The mark, and critical state only   |
| Spark  | `#F7BB7A` | The three spark dots          | Highlight fill, focus ring on dark  |
| Quench | `#FAF7F5` | Derived — warm off-white      | Light ground                        |

Neutrals are biased toward plum rather than being pure grey, so a surface next to the mark reads as part
of the same object. The full scale runs `#FFFFFF`, `#FAF7F5`, `#F2ECEA`, `#E6DCDD`, `#948089`, `#6B5560`,
`#3D2730`, `#2A1218`.

### Plum carries action, not ember

Crimson is the loudest value in the mark and also the universal colour of failure. A product whose
primary buttons are crimson looks like a product in an incident, and leaves nothing distinct to signal an
actual one. So:

- **Plum** carries primary actions — buttons, links, active navigation. At `13.73:1` on Quench it is
  among the most legible values available, which suits a control.
- **Ember** appears in the marks and wordmarks, and otherwise only where something has genuinely failed or
  an action is destructive.

This is the one rule in this document that a designer would not arrive at from the mark alone, and it is
the reason the system does not look like an alert.

### Contrast

Every pair below was computed from WCAG relative luminance rather than judged by eye. Text requires
4.5:1; control borders and focus indicators require 3:1 under
[SC 1.4.11](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast).

| Token           | Light     | On Quench | Dark      | On `#1F1016` |
|-----------------|-----------|-----------|-----------|--------------|
| `text`          | `#2A1218` | 16.43 AAA | `#F2E9E6` | 15.36 AAA    |
| `text-muted`    | `#6B5560` | 6.36 AA   | `#B39BA3` | 7.11 AAA     |
| `action`        | `#4D1229` | 13.73 AAA | `#D98A9B` | 7.04 AAA     |
| `critical`      | `#B61F33` | 6.09 AA   | `#EA5468` | 5.22 AA      |
| `warn`          | `#7E4E0F` | 6.60 AA   | `#E0A355` | 8.34 AAA     |
| `ok`            | `#17795E` | 5.01 AA   | `#4FBF9B` | 8.09 AAA     |
| `border-strong` | `#948089` | 3.45      | `#7C5763` | 3.16         |
| `border`        | `#E6DCDD` | 1.26      | `#37222A` | 1.32         |

Three of these values exist because the first candidate failed:

- `warn` began at `#B8741F` and measured **3.54 on Quench**, below AA. It darkened to `#7E4E0F`.
- Dark `critical` began at `#E14356` and measured **4.49 on the raised surface**, below AA. It lifted to
  `#EA5468`.
- A single `border` token measured **1.26** — fine for a rule, far below the 3:1 an input edge needs —
  so the system carries a separate `border-strong` used on every control boundary.

Two usage rules fall out of the measurements. **Spark is never text on a light ground** — at 1.59 it
is a fill, with Anvil text on it at 11.46. And **a dark-theme critical button takes an Anvil label, not
white**: white on `#EA5468` is 3.52 and fails, while Anvil on the same fill is 5.54 and passes. It is the
only place in the system where a label colour flips with the theme.

### Rackmarshal's own state vocabulary

A generic success/warning/error triple would not cover what these surfaces must show.

**Endpoint drift** — the four values `provisioner` stores in `endpoint_status`
([0011](0011-provisioner.md)), rendered as a pill with the word always present, never colour alone:

| State     | Token      | Meaning                                       |
|-----------|------------|-----------------------------------------------|
| `in_sync` | `ok`       | Applied generation matches the desired one    |
| `drifted` | `warn`     | Host state diverged from the bundle           |
| `failed`  | `critical` | The last apply returned an error              |
| `unknown` | `unknown`  | No report within the expected interval        |

**Environment tier** — Rackmarshal components are environment-aware (CONVENTIONS), and an operator with four
profiles open needs to know which one a destructive control belongs to. The tier renders as a left
stripe rather than a filled badge, because it is ambient context rather than an alert.

| Tier          | Light     | Dark      |
|---------------|-----------|-----------|
| `production`  | `#B61F33` | `#EA5468` |
| `staging`     | `#7E4E0F` | `#E0A355` |
| `test`        | `#17795E` | `#4FBF9B` |
| `development` | `#6B5560` | `#B39BA3` |

### Type

| Role    | Face          | Weights   | Licence | Carries                                     |
|---------|---------------|-----------|---------|---------------------------------------------|
| Display | Archivo       | 500–700   | OFL 1.1 | Headings, the masthead, numerals in tiles   |
| Body    | IBM Plex Sans | 400–600   | OFL 1.1 | Running text, labels, tables                |
| Data    | IBM Plex Mono | 400–500   | OFL 1.1 | Identifiers, digests, config keys, log lines |

The monospace face is load-bearing rather than decorative. These surfaces render SPIFFE IDs, certificate
serials, SHA-256 digests, and environment IDs in 26 characters of unpadded base32 — strings where a
misread character is a real operational error. Digits that line up in columns use
`font-variant-numeric: tabular-nums`.

The scale is a 1.25 ratio from a 16px base: 12, 14, 16, 20, 25, 31, 39, 49 px. Uppercase labels carry
`0.12em` tracking; headings set `text-wrap: balance`.

One discrepancy is recorded rather than quietly fixed: the tagline inside `logo.svg` is set in Open Sans,
which is not part of this system. Re-setting it in Archivo would change the mark file, which conventions
protect. See Open questions.

### Icons

Rackmarshal adopts an open set for the generic vocabulary and draws the handful of concepts no icon library
has. The adopted set is **Lucide** (ISC, 1600+ icons), whose geometry the drawn glyphs match exactly, so
the two are indistinguishable in use:

| Property        | Value                              |
|-----------------|------------------------------------|
| Canvas          | 24 × 24                            |
| `viewBox`       | `0 0 24 24`                        |
| `fill`          | `none`                             |
| `stroke`        | `currentColor`                     |
| `stroke-width`  | `2`                                |
| Caps and joins  | `round`                            |
| Safe area       | 2 px on all sides                  |

Lucide is chosen over Tabler and Phosphor for its round caps and joins, which echo the round-capped
terminals of the mark's rings; Tabler's 6,184 icons (MIT, same 24 × 24 / 2 px grid) is the larger set
but squarer, and Phosphor (MIT, 1,248 icons in six weights) is drawn on a 16 × 16 canvas with more
personality than a dense operations table wants. Lucide's ISC notice ships with the vendored assets.

**Drawn for Rackmarshal.** Six concepts have no reasonable stand-in, and approximating them with a puzzle piece
or a generic server would misinform:

| Glyph              | Concept                                         | Construction                          |
|--------------------|-------------------------------------------------|---------------------------------------|
| `agent`            | The daemon on a managed host (0012)             | Chassis with two sparks from the mark |
| `plugin`           | A separate process the agent launches (0013)    | Parent and child with a link          |
| `directive-bundle` | The signed DSSE envelope agents pull (0011)     | Package with a seal                   |
| `environment`      | The trust domain and its identity               | Open ring with a centre, as the mark  |
| `enrollment-token` | The single-use credential that enrolls a host   | Ticket with a punch                   |
| `drift`            | Applied state diverged from desired             | Dashed outline with a solid offset    |

**Optical weight is held constant across sizes.** A 2 px stroke drawn for 24 px looks heavy at 16 px, so
the stroke thins as the icon does: 24 px at `2`, 20 px at `1.75`, 16 px at `1.5`. Below 16 px an icon is
not used at all.

**Icons may stand alone where space is tight** — toolbars, a collapsed sidebar rail, and the action
column of a dense table. Every icon-only control carries an accessible name and a tooltip, and the
control is at least a 24 × 24 target inside a 44 × 44 hit area. Two limits keep this from eroding:

- **State always keeps its word.** Drift and tier render their label; an icon may accompany it, never
  replace it. This is the browser counterpart of 0010's rule that every status is a word and colour only
  repeats it, and icon shape is no more reliable than colour for someone who has not learned the set.
- **Destructive controls always keep their label.** Retire, revoke, and delete are never icon-only,
  anywhere, at any width.

Icons are decorative by default and carry `aria-hidden="true"`; an icon that is the only content of a
control carries `role="img"` and an accessible name instead. Filled and stroked variants are never mixed
in one view.

### The mark and the lockup

Two assets exist. `docs/images/logo.svg` is the full lockup — the one the README shows at 600 px wide —
and `docs/images/logo-mark.svg` is the symbol alone for square and small formats. Their shared path data
stays byte-identical, which `.claude/conventions.md` already requires.

The lockup is three parts on a `0 0 1699 420` canvas:

| Part     | Content                                     | Colour                        |
|----------|---------------------------------------------|-------------------------------|
| Mark     | Three rings and three sparks                | The full ramp                 |
| Wordmark | "Server" then "Curio", drawn as paths       | Ember, then Plum              |
| Tagline  | "Rackmarshal Infrastructure Management", 72 px    | Rose, Open Sans 500           |

**The tagline is the only part that varies.** Sibling Server Curio repositories share the mark and
wordmark and change the tagline text alone. The wordmark is path data rather than live text, so it is
never re-set in a typeface or retyped — including in Archivo, which would otherwise look like the
consistent choice.

**Which to use.** The lockup wherever Rackmarshal introduces itself and there is room for it to be read: a
README, a login page, a document cover. The symbol alone wherever it is recognised rather than read: a
favicon, an avatar, a collapsed sidebar rail, an app icon.

- **Clear space** — at least the outer ring's stroke width on all four sides, for both assets.
- **Minimum size** — 240 px wide for the lockup, below which the tagline stops being legible; 24 px for
  the symbol, below which the three sparks close up and a single-colour silhouette should be used.
- **Never** — stretch or condense, recolour the ramp, add shadow or glow, rotate or flip, place it on a
  ground that drops contrast below 3:1, re-space the mark against the wordmark, retype the wordmark in a
  font, or recreate any of it in another tool.

### The Rackmarshal mark

The Server Curio mark identifies the company; Rackmarshal, as one product within it, has its own mark — a
server rack with an overlaid five-point marshal badge. The two are used in different places and are
**never locked up together**: a surface carries one or the other. A README, a company page, or a document
cover uses the Server Curio lockup; a Rackmarshal application masthead, favicon, or installer uses the
Rackmarshal mark.

The mark is the **Command** direction from the supplied kit: a solid cabinet with an offset badge and a
title-case wordmark. Four assets, an icon and a horizontal lockup in each theme:

| Asset      | File                          | Canvas    | For                                   |
|------------|-------------------------------|-----------|---------------------------------------|
| Icon       | `rackmarshal-mark.svg`        | 256 × 256 | Mastheads, favicons, the sidebar rail |
| Icon, dark | `rackmarshal-mark-dark.svg`   | 256 × 256 | The same, on Anvil                    |
| Lockup     | `rackmarshal-lockup.svg`      | 857 × 256 | Login, splashes, headers, email       |
| Lockup, dark | `rackmarshal-lockup-dark.svg` | 857 × 256 | The same, on Anvil                  |

**The pairs do not adapt themselves.** Unlike `tokens.css`, the mark has no theme logic: the light files
carry a Plum cabinet, the dark files a Quench one. The badge is Spark in both. The consuming surface picks
the file matching its ground.

**The lockup wordmark is two-tone, the same move the Server Curio wordmark makes.** "Server" is Ember and
"Curio" is Plum; "Rack" takes the hot value and "marshal" the deep one, so the two lockups are recognisably
the same construction. The accent flips by theme because neither value survives both grounds — Spark
measures `1.59` on Quench, Ember `3.00` on Anvil — so Spark stands in for Ember on dark exactly as
`--focus` already does in `tokens.css`:

| File                          | "Rack"            | "marshal"          |
|-------------------------------|-------------------|--------------------|
| `rackmarshal-lockup.svg`      | Ember `6.09` AA   | Plum `13.73` AAA   |
| `rackmarshal-lockup-dark.svg` | Spark `11.46` AAA | Quench `18.27` AAA |

This is the one place Ember appears outside the Server Curio mark and critical state. It is confined to
four letters of a wordmark, never a fill or a control, so the ramp rule — crimson stays free to mean
failure — holds. The icon files remain Ember-free, which is what keeps a masthead or favicon from reading
as an alert.

**Minimum size is 32 px for the icon.** The rack indicators simplify as the mark is reduced; below 32 px
a dedicated simplified favicon is preferable to shrinking this one. The lockup's wordmark sets its own
floor: below roughly 200 px wide the lettering stops being legible, so use the icon instead.

The wordmark reads **Rackmarshal**, one word with a lowercase *m*. It is outlined path data in the
supplied asset, so rendering never depends on an installed font, and it is not editable in place —
changing the *lettering* means regenerating from the kit's `source/build_logos.py`. The two-tone split is
not a re-setting of the type: the glyph run is partitioned between the `k` and the `m` into two `<path>`
elements that carry different fills and identical `transform` and curve data, so the outlines are
byte-for-byte what the kit produced.

- **Never** — put a light mark on a dark ground or the reverse, recolour outside the ramp, lock the
  Rackmarshal mark up with the Server Curio mark, stretch or condense it, separate the badge from the
  cabinet, move the wordmark's colour break off the `k`/`m` boundary, or reduce the icon below 32 px.

### Distribution

| Artefact            | Path                            | Consumed by                     |
|---------------------|---------------------------------|---------------------------------|
| Tokens              | `docs/design/brand/tokens.css`  | Every surface in 0016           |
| Reference page      | `docs/design/brand/index.html`  | Humans                          |
| Mark, full lockup   | `docs/images/logo.svg`          | Mastheads, documents            |
| Mark, symbol only   | `docs/images/logo-mark.svg`     | Favicons, avatars, sidebar rail |
| Rackmarshal mark    | `docs/images/rackmarshal-mark*.svg`   | Product surfaces, rail, favicon |
| Rackmarshal lockup  | `docs/images/rackmarshal-lockup*.svg` | Login, splashes, headers        |
| Drawn icons         | `docs/design/brand/index.html`  | Inline pending extraction       |

`tokens.css` is the single machine-readable source. Each UI repository vendors a copy and CI fails on
drift against this repository, the same mechanism CONVENTIONS already applies to generated API code.
Tailwind v4 consumes the custom properties directly through `@theme`, so no value is transcribed by hand.
Theme resolution follows the three-state pattern: a bare `:root` block carries the complete light
palette, `prefers-color-scheme` redefines tokens for viewers on the system default, and
`[data-theme]` redefines them again so an explicit choice wins in both directions.

## Alternatives considered

- **A blue or teal accent** — the conventional infrastructure-product palette, and a neutral backdrop
  for crimson state colours. Rejected because it would mean the product shares no colour with its own
  mark.
- **Ember as the action colour** — the most direct reading of the mark. Rejected above; it makes every
  page read as an incident and leaves failure nothing to say.
- **Inter, or Inter with a geometric display face** — the safe pairing. Rejected as the default that
  every dashboard already uses; Archivo has more character at display sizes and IBM Plex has an
  engineering provenance that suits the subject.
- **Keeping Open Sans throughout**, matching the tagline in the mark. It would remove the discrepancy
  noted above, at the cost of a body face chosen in 2011 for a different purpose.
- **Full inversion for the dark theme** — mechanically simple. Rejected because three of the light
  values fail against a dark ground; each was lifted individually and re-measured.

## Open questions

- **The tagline face** — re-set `logo.svg`'s tagline in Archivo for consistency, accepting a change to
  a protected file, or keep Open Sans and record it as a permanent exception?
- **Dark as the default** — infrastructure operators frequently prefer it. Should hardened tiers
  default to dark regardless of the system setting, or is that an unwelcome override?
- **A production visual treatment** — beyond the tier stripe, should `production` carry a stronger
  persistent signal, such as a masthead rule in Ember?
- **Filled variants** — the drawn glyphs are stroke-only. Does a selected navigation item need a filled
  counterpart, and if so must filled versions of the adopted icons be drawn as well?
- **Agentless endpoints** — 0011 enforces agentless devices directly. Does that path need its own
  glyph, or is the absence of the `agent` icon sufficient?
- **Icon extraction** — the six drawn glyphs live inline in `brand/index.html`. When do they become
  individual SVG files, and does the vendored icon set ship as a sprite or as separate assets?
- **Rackmarshal mark on mixed grounds** — the light and dark files cover solid grounds. What is used over
  a photograph or a gradient, where neither pairing holds?
- **A simplified favicon** — the kit recommends one below 32 px rather than shrinking the icon. Who draws
  it, and does it keep the badge or the cabinet?
- **Print and slide templates** — out of scope here, but the palette will be asked for.

## References

- `docs/images/logo.svg`, `docs/images/logo-mark.svg` — the source of every brand value above.
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/) and
  [SC 1.4.11 Non-text Contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast).
- [Archivo](https://fonts.google.com/specimen/Archivo),
  [IBM Plex Sans](https://fonts.google.com/specimen/IBM+Plex+Sans),
  [IBM Plex Mono](https://fonts.google.com/specimen/IBM+Plex+Mono) — all SIL Open Font License 1.1.
- [Lucide](https://github.com/lucide-icons/lucide) — ISC, a fork of Feather; the adopted icon set, whose
  grid the drawn glyphs match. Alternatives weighed:
  [Tabler](https://github.com/tabler/tabler-icons) (MIT, 6,184 icons) and
  [Phosphor](https://github.com/phosphor-icons/homepage) (MIT, 1,248 icons, six weights).
- [Tailwind CSS v4 `@theme`](https://tailwindcss.com/docs/theme) — how the tokens reach utility classes.
- [brand.hashgraph.com](https://brand.hashgraph.com/) — the structural reference for this document's
  shape: ramp, usage, misuse, typography, downloads.

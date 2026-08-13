# daisyUI v4 Class Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all ten daisyUI classes that were removed in v5 and still appear in this app's templates, without changing how a single page renders.

**Architecture:** The classes are inert — they generate no CSS — so deleting them cannot change rendering, and that is provable by rebuilding the stylesheets and diffing. One class is load-bearing as a *JavaScript selector hook* rather than as a style, so it is decoupled in a separate PR first. The lint guard that prevents regressions is extended from five classes to ten in the same PR that empties its allowlist, because it fails on stale allowlist entries by design.

**Tech Stack:** Rails 8, daisyUI 5.7.16, Tailwind CSS 4.3.3, Rollup, Minitest + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-13-daisyui-v4-sweep-design.md`

## Global Constraints

- Run all Rails/yarn commands from `web-app/`. Docs live in `docs/` at the **project root**.
- Lint is `bundle exec standardrb`. **Never `bin/rubocop`.** Never run brakeman.
- **Never run a destructive DB command against development.** Books data exists only in dev.
- Use `PARALLEL_WORKERS=4` for Rails test runs — this worktree shares `the_greatest_test` with the main checkout and the default 32 workers deadlock.
- Do not touch the movies domain, and do not include it in any verification output.
- The ten removed classes, in the exact order they must appear in `REMOVED_CLASSES`:
  `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`,
  `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`.
- `file-input` (no `-bordered`) **is** a valid daisyUI 5 class and must never be removed.
- Working directory: `/home/shane/dev/the-greatest/.claude/worktrees/daisyui-v4-sweep/web-app`
- E2E runs need the dev server on port 3000. `bin/dev` self-terminates without a TTY — use
  `yarn build:all` then `bin/rails server -p 3000` in the background.

## File Structure

**PR 1 — unblock (3 files)**

| File | Responsibility after the change |
|---|---|
| `app/components/books/filter_option_rows_component.html.erb` | Carries `data-option-label` on the option-name span — the stable hook the controller reads |
| `app/javascript/controllers/books/filter_controller.js` | Reads `[data-option-label]` instead of `.label-text` |
| `test/components/books/filter_option_rows_component_test.rb` | Pins the hook so a future sweep cannot silently remove it |
| `test/components/autocomplete_component_test.rb` | Drops an assertion on a class with no styling |

**PR 2 — sweep (114 files)**

| File | Responsibility after the change |
|---|---|
| 112 `.erb` under `app/views/**`, `app/components/**` | Same markup, dead class names gone |
| `app/javascript/controllers/user_list_modal_controller.js` | Same generated markup, `label-text` gone |
| `test/lint/daisyui_v4_classes_test.rb` | Guards ten classes across ERB **and** JS; empty allowlist |
| `docs/features/daisyui-v5-migration-notes.md` (new) | Inventory of styling silently lost before this work |

---

# PR 1 — Unblock

### Task 1: Replace the `.label-text` selector hook with a data attribute

`filter_controller.js` builds the public books filter's "selected filters" summary by reading
`.label-text` text content. Deleting that class in PR 2 would make the summary render `Any` instead
of the chosen genres. The label also contains **two** `label-text` spans (name and count), so the
current code silently depends on `querySelector` returning the first — a dedicated attribute fixes
that too.

**Files:**
- Modify: `app/components/books/filter_option_rows_component.html.erb:6`
- Modify: `app/javascript/controllers/books/filter_controller.js:257`
- Test: `test/components/books/filter_option_rows_component_test.rb`

**Interfaces:**
- Produces: a `data-option-label` attribute on the option-name `<span>`. PR 2's sweep must leave it alone.

- [ ] **Step 1: Write the failing test**

Add to `test/components/books/filter_option_rows_component_test.rb`, following the existing
`data-option-value` assertion at line 43:

```ruby
test "marks the option name with a stable hook the filter controller can read" do
  render_inline(described_class.new(**category_args))

  assert_selector "label[data-option-value='novels'] span[data-option-label]", exact_text: "Novels"
end

test "the count span is not mistaken for the option name" do
  render_inline(described_class.new(**category_args_with_count))

  assert_selector "span[data-option-label]", count: 1
end
```

Match the existing file's helper names for building args — read the top of the file and reuse
whatever it already uses to construct `category_args`; do not invent a new fixture shape.

- [ ] **Step 2: Run it and watch it fail**

```bash
PARALLEL_WORKERS=4 bin/rails test test/components/books/filter_option_rows_component_test.rb
```

Expected: FAIL — `data-option-label` does not exist yet. If it passes, the selector is wrong; fix
the test before continuing.

- [ ] **Step 3: Add the hook to the markup**

In `app/components/books/filter_option_rows_component.html.erb`, line 6, change:

```erb
    <span class="label-text"><%= record.name %></span>
```

to:

```erb
    <span class="label-text" data-option-label><%= record.name %></span>
```

Leave `label-text` in place for now — PR 2 removes it. Leave the count span on line 11 untouched;
it must **not** get the attribute.

- [ ] **Step 4: Run the test and watch it pass**

```bash
PARALLEL_WORKERS=4 bin/rails test test/components/books/filter_option_rows_component_test.rb
```

Expected: PASS, both new tests.

- [ ] **Step 5: Point the controller at the new hook**

In `app/javascript/controllers/books/filter_controller.js`, line 257, change:

```js
      const names = checked.map((el) => el.closest("label")?.querySelector(".label-text")?.textContent.trim())
```

to:

```js
      const names = checked.map((el) => el.closest("label")?.querySelector("[data-option-label]")?.textContent.trim())
```

- [ ] **Step 6: Rebuild JS and prove the summary still works in a browser**

```bash
yarn build:all
bin/rails server -p 3000 &
npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/filters.spec.ts
```

Expected: all pass, including
`the level-1 summary reflects applied filters without opening any pane` (line 34), which asserts the
summary reads `Novels` and `French`.

- [ ] **Step 7: Prove the e2e assertion is not vacuous**

Temporarily break the selector — change `[data-option-label]` to `[data-option-label-nope]` — rerun
just that spec, and confirm it **fails** with the summary reading `Any`. Then restore it and rerun to
confirm green. This is the only evidence that the spec actually covers the hook.

- [ ] **Step 8: Commit**

```bash
git add app/components/books/filter_option_rows_component.html.erb \
        app/javascript/controllers/books/filter_controller.js \
        test/components/books/filter_option_rows_component_test.rb
git commit -m "Give the books filter summary a stable hook instead of a style class

filter_controller read .label-text to build the selected-filters summary,
so deleting that dead class would have silently rendered Any instead of the
chosen genres. The label carries two .label-text spans -- name and count --
so the old code also depended on querySelector returning the first."
```

### Task 2: Drop the assertion on a class with no styling

`test/components/autocomplete_component_test.rb:35` asserts `input.input-disabled`. That class
generates no CSS, so the assertion proves nothing about the disabled state; the
`assert_selector "input[disabled]"` immediately above it is the real check. Removing it now keeps
PR 2 purely mechanical.

**Files:**
- Modify: `test/components/autocomplete_component_test.rb:35`

- [ ] **Step 1: Confirm the neighbouring assertion is the real one**

Temporarily change `disabled: true` to `disabled: false` in that test and run:

```bash
PARALLEL_WORKERS=4 bin/rails test test/components/autocomplete_component_test.rb
```

Expected: FAIL on `assert_selector "input[disabled]"`. This proves the remaining assertion carries
the coverage. Restore `disabled: true`.

- [ ] **Step 2: Delete the dead assertion**

Remove exactly this line:

```ruby
    assert_selector "input.input-disabled"
```

- [ ] **Step 3: Run the test**

```bash
PARALLEL_WORKERS=4 bin/rails test test/components/autocomplete_component_test.rb
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/components/autocomplete_component_test.rb
git commit -m "Drop an autocomplete assertion on a class with no styling

input-disabled was removed in daisyUI 5 and generates no CSS, so asserting
it proved nothing about the disabled state. The input[disabled] assertion
above it is the real coverage -- verified by flipping disabled to false and
watching that one fail."
```

### Task 3: Open PR 1

- [ ] **Step 1: Full local gate**

```bash
bundle exec standardrb
PARALLEL_WORKERS=4 bin/rails test
npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/filters.spec.ts
```

Expected: all green.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin daisyui-v4-sweep
gh pr create --base main --title "Give the books filter summary a stable hook" --body "..."
```

The body must state that this is a prerequisite for the dead-class sweep, name the regression it
prevents, and record the vacuousness check from Task 1 Step 7. **Ask the user before pushing.**

- [ ] **Step 3: Wait for CI green, then ask the user to merge**

---

# PR 2 — The Sweep

Start this only after PR 1 is merged. Branch off the updated `main`:

```bash
git fetch origin && git checkout -b daisyui-v4-sweep-bulk origin/main
```

### Task 4: Extend the guard to all ten classes and to JavaScript

**Files:**
- Modify: `test/lint/daisyui_v4_classes_test.rb`

**Interfaces:**
- Produces: `REMOVED_CLASSES` of ten entries; `target_files` covering `app/javascript`; a matcher that also reads `className = "..."` and backtick strings.

- [ ] **Step 1: Capture the stylesheet baseline before touching anything**

```bash
yarn build:all
mkdir -p /tmp/claude-1001/css-baseline
cp app/assets/builds/books.css app/assets/builds/games.css app/assets/builds/music.css /tmp/claude-1001/css-baseline/
```

This baseline is the evidence for Task 6. Capture it before any template edit.

- [ ] **Step 2: Extend `REMOVED_CLASSES`**

Replace the array with:

```ruby
  REMOVED_CLASSES = %w[
    form-control
    label-text
    label-text-alt
    input-bordered
    select-bordered
    textarea-bordered
    file-input-bordered
    input-disabled
    table-hover
    tabs-boxed
  ].freeze
```

- [ ] **Step 3: Correct the false comment about `file-input-bordered`**

The existing comment above `offenders` claims `file-input-bordered` is "a valid, current daisyUI
class". It is not — it is absent from the compiled CSS and from
`docs/external-libraries/daisyui-llms.txt`, while plain `file-input` is present. Whole-token
matching is still correct, but for a different reason. Replace that paragraph with:

```ruby
  # Only scans text inside a `class="..."` / `class: "..."` / `className = "..."`
  # value -- ERB/Ruby comments are stripped first -- and only counts a whole
  # space-separated class token as a hit, never a substring.
  #
  # Whole-token matching matters because "file-input-bordered" contains
  # "input-bordered". Both are dead, and both are listed above; token matching
  # is what makes a file containing the former get reported as that class
  # alone rather than as two overlapping hits. Note that plain "file-input"
  # IS a current daisyUI 5 class and must never be added to the list.
```

- [ ] **Step 4: Widen the scan to JavaScript**

`user_list_modal_controller.js` builds markup in a template string, so an ERB-only scan misses it.
Change `target_files`:

```ruby
  def target_files
    Dir.glob(Rails.root.join("{app/views,app/components,app/javascript}/**/*"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end
```

And widen the matcher to catch `className =` assignments and backtick strings:

```ruby
  def removed_classes_in(content)
    found = []
    content.scan(/\bclass(?:Name)?\s*[:=]\s*(["'`])(.*?)\1/m) do |_quote, value|
      value.split(/\s+/).each do |token|
        found << token if REMOVED_CLASSES.include?(token)
      end
    end
    found.uniq
  end
```

- [ ] **Step 5: Regenerate the allowlist so the guard is green before the sweep**

The five new classes make previously-invisible files into offenders. Regenerate the literal list:

```bash
bin/rails runner '
  require Rails.root.join("test/lint/daisyui_v4_classes_test.rb")
  puts DaisyuiV4ClassesTest.new(:x).send(:offenders).keys.sort
' 2>/dev/null
```

If that is awkward to load outside the test harness, instead run the guard, read the failure
message — it prints every offending path — and paste those paths into `ALLOWLIST`, sorted.

- [ ] **Step 6: Run the guard and watch it pass**

```bash
PARALLEL_WORKERS=4 bin/rails test test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS, both tests.

- [ ] **Step 7: Prove the widened guard is not vacuous**

Three deliberate breaks, each reverted after checking:

1. Add `class="tabs tabs-boxed"` to any file under `app/views/books/` → the "outside the allowlist" test must fail naming that file.
2. Add `className = "label-text"` to any file under `app/javascript/` → must also fail, proving the JS scan and the `className` branch both work.
3. Delete one entry from `ALLOWLIST` → the "no stale entries" test must fail naming it.

If break 2 does not fail, the `className`/backtick regex is wrong — fix it before continuing.

- [ ] **Step 8: Commit**

```bash
git add test/lint/daisyui_v4_classes_test.rb
git commit -m "Extend the daisyUI guard to ten classes and to JavaScript

The guard knew five of the ten classes this app still uses that daisyUI 5
removed. label-text-alt alone is 179 occurrences in 46 files, entirely
invisible to it. Also widened to app/javascript, where markup built in
template strings carried label-text past an ERB-only scan.

Corrects a false comment: file-input-bordered was described as a valid
current class. It is absent from both the compiled CSS and the pinned v5
reference. Plain file-input is the real class and stays off the list."
```

### Task 5: Apply the sweep

**Files:**
- Modify: 112 `.erb` files under `app/views/**` and `app/components/**`
- Modify: `app/javascript/controllers/user_list_modal_controller.js:100`
- Modify: `app/components/autocomplete_component.html.erb:21` (by hand)
- Modify: `test/lint/daisyui_v4_classes_test.rb` (empty the allowlist)

- [ ] **Step 1: Re-confirm no dead class sits in a multi-line class attribute**

A multi-line attribute is the one case where token removal could reflow markup and create diff
noise. **This was measured while writing the plan and the answer was 0**, which is why the script
below can normalise horizontal whitespace safely. Re-run it, because `main` may have moved:

```bash
python3 - <<'PY'
import re, pathlib
DEAD = r'form-control|label-text-alt|label-text|input-bordered|select-bordered|textarea-bordered|file-input-bordered|input-disabled|table-hover|tabs-boxed'
attr = re.compile(r'class(?:Name)?\s*[:=]\s*(["\'`])(.*?)\1', re.S)
hits = []
for p in [q for d in ('app/views','app/components') for q in pathlib.Path(d).rglob('*.erb')]:
    for m in attr.finditer(p.read_text()):
        if '\n' in m.group(2) and re.search(DEAD, m.group(2)):
            hits.append(f"{p}: {m.group(2)[:60]!r}")
print(f"multi-line class attributes containing a dead class: {len(hits)}")
print("\n".join(hits[:20]))
PY
```

If the count is 0, the script below is safe as written. If it is not 0, handle those files by hand
after the script runs and check their diffs individually.

- [ ] **Step 2: Write the codemod**

Save as `/tmp/claude-1001/sweep.py`. It removes whole tokens only, never substrings, and never
touches `file-input`:

```python
#!/usr/bin/env python3
"""One-shot codemod: strip daisyUI classes removed in v5. Whole tokens only."""
import re, pathlib

DEAD = ['form-control', 'label-text-alt', 'label-text', 'input-bordered',
        'select-bordered', 'textarea-bordered', 'file-input-bordered',
        'input-disabled', 'table-hover', 'tabs-boxed']

ATTR = re.compile(r'(class(?:Name)?\s*[:=]\s*)(["\'`])(.*?)\2', re.S)

def clean(value):
    for c in DEAD:
        value = re.sub(r'(?<![\w-])' + re.escape(c) + r'(?![\w-])', '', value)
    value = re.sub(r'[ \t]{2,}', ' ', value)
    return value.strip(' \t')

changed = []
targets = [q for d in ('app/views', 'app/components') for q in pathlib.Path(d).rglob('*.erb')]
targets.append(pathlib.Path('app/javascript/controllers/user_list_modal_controller.js'))

for p in targets:
    src = p.read_text()
    out = ATTR.sub(lambda m: m.group(1) + m.group(2) + clean(m.group(3)) + m.group(2), src)
    if out != src:
        p.write_text(out)
        changed.append(str(p))

print(f"{len(changed)} files changed")
```

- [ ] **Step 3: Run it**

```bash
python3 /tmp/claude-1001/sweep.py
git diff --stat | tail -3
```

Expected: ~113 files changed.

- [ ] **Step 4: Hand-edit the one interpolated occurrence**

The script cannot fix `app/components/autocomplete_component.html.erb:21`, where the class is inside
ERB output rather than a literal token. It currently reads:

```erb
           class="input input-bordered w-full <%= 'input-disabled' if disabled %>"
```

After the script it will read `class="input w-full <%= 'input-disabled' if disabled %>"`. Change it
to drop the interpolation entirely:

```erb
           class="input w-full"
```

The `<%= 'disabled' if disabled %>` attribute on the next line is what actually disables the input
and must stay — daisyUI 5 styles `:disabled` natively.

- [ ] **Step 5: Remove now-empty class attributes**

```bash
grep -rn 'class=""\|class: ""\|className = ""' app/views app/components app/javascript | head -20
```

Delete each empty attribute rather than leaving it. If the list is long, do it with a follow-up
regex, then re-run the grep to confirm it is empty.

- [ ] **Step 6: Empty the allowlist**

In `test/lint/daisyui_v4_classes_test.rb`:

```ruby
  ALLOWLIST = %w[
  ].freeze
```

- [ ] **Step 7: Run the guard**

```bash
PARALLEL_WORKERS=4 bin/rails test test/lint/daisyui_v4_classes_test.rb
```

Expected: PASS. A failure on "outside the allowlist" means the script missed an occurrence — the
message names the file. A failure on "stale entries" means the allowlist was not emptied.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Remove every daisyUI class that v5 deleted

1,052 occurrences across 112 templates plus one JS template string. All ten
classes are inert -- absent from the compiled CSS -- so this changes no
rendering; see the byte-identical stylesheet check in the PR body.

Scripted, because 1,050 of the 1,052 were plain literals in a class
attribute. The two exceptions were the conditionally interpolated
input-disabled in autocomplete_component, edited by hand.

Allowlist emptied in the same commit: the guard fails on stale entries by
design, so cleaning a file and dropping its entry cannot be separated."
```

### Task 6: Prove nothing moved, and record what was already lost

- [ ] **Step 1: The byte-identical stylesheet check**

This is the core evidence for the whole PR:

```bash
yarn build:all
for f in books games music; do
  if diff -q /tmp/claude-1001/css-baseline/$f.css app/assets/builds/$f.css >/dev/null; then
    echo "$f.css IDENTICAL"
  else
    echo "$f.css DIFFERS -- something live was deleted"
    diff /tmp/claude-1001/css-baseline/$f.css app/assets/builds/$f.css | head -20
  fi
done
```

Expected: all three IDENTICAL. **Any difference means a live class was removed — stop and
investigate rather than explaining it away.**

- [ ] **Step 2: Full test gate**

```bash
bundle exec standardrb
PARALLEL_WORKERS=4 bin/rails test
```

Expected: green, ~6,350 runs, output pristine.

- [ ] **Step 3: Browser gate**

```bash
bin/rails server -p 3000 &
npx playwright test --config=e2e/playwright.config.ts
```

Expected: green, including the 28 admin specs — the bulk of the sweep is admin markup.

- [ ] **Step 4: Write the lost-styling inventory**

Create `docs/features/daisyui-v5-migration-notes.md` recording what was silently lost *before* this
sweep, so the deletions do not bury it. Use the real counts from the spec: 13 files with
`table-hover` (tables with no hover highlight), 2 with `tabs-boxed` (unstyled tab strips), 10 with
`input-disabled`. For each, name the v5 replacement — `tabs-box` for the third, native `:disabled`
styling for the second, and a `hover:` utility on rows for the first — and state plainly that
restoring them is deliberate follow-up work, not part of this change.

- [ ] **Step 5: Commit**

```bash
git add docs/features/daisyui-v5-migration-notes.md
git commit -m "Record the styling silently lost before the v4 sweep

table-hover, tabs-boxed and input-disabled were dead long before this PR, so
those tables, tab strips and disabled inputs already render unstyled.
Deleting the class names makes that invisible; this is the list to act on."
```

### Task 7: Open PR 2

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin daisyui-v4-sweep-bulk
```

**Ask the user before pushing.** The PR body must include: the ten-class table with counts, the
byte-identical stylesheet output from Task 6 Step 1 verbatim, the three vacuousness checks from
Task 4 Step 7, and the note that `file-input` is a real v5 class deliberately left alone.

- [ ] **Step 2: Wait for CI green, then ask the user to merge**

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: the ten-class inventory → Task 4 Step 2; the
`.label-text` JS hook → Task 1; the stale test assertion → Task 2; the 112-file sweep → Task 5; the
JS template string → Task 5 Step 2 (target list); the interpolated exception → Task 5 Step 4; the
guard extension and allowlist emptying → Tasks 4 and 5 Step 6; byte-identical CSS → Task 6 Step 1;
the lost-styling inventory → Task 6 Step 4; two PRs → Tasks 3 and 7.

**Type/name consistency.** `data-option-label` is the same string in Task 1 Steps 1, 3, 5, and 7.
`REMOVED_CLASSES` ordering in Task 4 Step 2 matches the Global Constraints list. The codemod's
`DEAD` list in Task 5 Step 2 contains the same ten names, ordered longest-first where they overlap
(`label-text-alt` before `label-text`) so the shorter never consumes the longer's prefix.

**Known gap, accepted.** Task 4 Step 5 offers two ways to regenerate the allowlist because loading a
Minitest class through `rails runner` may not work cleanly; the fallback — read the failure message,
which prints every offending path — always works.

**Pre-verified while writing this plan.** Two of the riskiest assumptions were checked rather than
assumed, and both hold:

- The codemod's `clean()` was run against 11 adversarial inputs. `file-input` survives while
  `file-input-bordered` is removed, and `input-error` survives while `input-bordered` is removed —
  the negative lookbehind `(?<![\w-])` is what prevents the shorter name matching inside the longer.
  0 failures.
- Multi-line class attributes containing a dead class: **0**, so horizontal-whitespace
  normalisation cannot reflow markup.

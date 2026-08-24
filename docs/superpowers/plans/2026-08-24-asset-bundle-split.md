# Asset Bundle Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single 184 KB gzipped `application.js` loaded by every layout with minified, per-domain web bundles plus one admin bundle, and move the Firebase auth SDK behind an on-demand loader.

**Architecture:** A JSON bundle registry (`config/asset_bundles.json`) is the single source of truth read by both `rollup.config.js` and Ruby, so a layout can never name a bundle the build does not produce. Explicit per-bundle Stimulus manifests replace the auto-generated `controllers/index.js` that imports all 24 controllers. Outputs stay self-contained IIFE with no shared chunks, because Propshaft cannot rewrite ES import specifiers. Firebase becomes its own entry, injected at runtime by an injected `<script src>`.

**Tech Stack:** Rollup 4, `@rollup/plugin-terser`, Propshaft 1.3.2, Stimulus 3, Turbo 8, Minitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-24-asset-bundle-split-design.md`

## Global Constraints

- Run **all** commands from `web-app/`. Docs live at project root in `docs/`.
- Linter is `bundle exec standardrb`, **never** `bin/rubocop`. Owner does not use brakeman.
- Baseline on this branch: **7516 runs, 162967 assertions, 0 failures, 0 errors, 0 skips**. Check `ps aux | grep "[r]ails test"` before running — concurrent runs share one DB and manufacture phantom failures.
- **From Task 4 onward, run the full suite as `bin/rails db:test:prepare test`, not `bin/rails test`.** `jsbundling-rails` enhances `test:prepare` with `javascript:build`, so that command runs `yarn install && yarn build` first. Plain `bin/rails test` does not build. Once Task 4 stops producing `application.js`, any test that renders a layout raises `Propshaft::MissingAssetError` unless the new bundles exist on disk. This is also exactly what CI runs, and why CI passes today without a separate build step.
- Single-file test runs (`bin/rails test test/lint/foo.rb`) are fine throughout — the lint guards read source, never build output.
- Minitest 6: `assert_equal nil, x` is a hard failure. Use `assert_nil`.
- `app/assets/builds/*` is **gitignored** (only `.keep` is tracked). Rails tests can never assert on built output — every guard must work from source.
- daisyUI 5 / Tailwind 4. Ten v4 classes are banned and guarded by `test/lint/daisyui_v4_classes_test.rb` with an empty allowlist.
- Never run destructive DB commands against development.
- Commit freely on this branch. Do **not** push or open a PR without asking.
- Bundle names are exactly: `books-web`, `music-web`, `games-web`, `movies-web`, `admin`, `firebase-auth`. One `<domain>-web` per domain layout under `app/views/layouts/*/application.html.erb`.

---

## File Structure

**Created:**
- `web-app/config/asset_bundles.json` — bundle name → entry path registry, read by rollup and Ruby
- `web-app/app/javascript/turbo.js` — Turbo import indirection (later swaps turbo-rails for turbo core)
- `web-app/app/javascript/entrypoints/{books_web,music_web,games_web,movies_web,admin,firebase_auth}.js` — one per bundle
- `web-app/app/javascript/manifests/{web_shared,books_web,music_web,games_web,movies_web,admin}.js` — Stimulus registration
- `web-app/app/javascript/controllers/auto_dismiss_controller.js` — restores never-shipped admin flash behavior
- `web-app/app/javascript/services/firebase_loader.js` — memoized script injection + signed-in heuristics
- `web-app/test/lint/stimulus_manifest_test.rb` — controller/manifest drift guard
- `web-app/test/lint/asset_bundle_coverage_test.rb` — layout → bundle coverage guard
- `web-app/test/lint/stimulus_debug_mode_test.rb` — keeps Stimulus debug logging out of production

**Modified:**
- `web-app/package.json` — add `@rollup/plugin-terser`
- `web-app/rollup.config.js` — registry-driven, minified
- `web-app/app/javascript/controllers/application.js` — drop debug mode and console noise
- `web-app/app/javascript/controllers/authentication_controller.js` — async Firebase access
- `web-app/app/helpers/domain_helper.rb` — `domain_js_bundle`
- `web-app/app/views/layouts/{books,music,games,movies}/application.html.erb` — per-domain bundle
- `web-app/app/views/layouts/admin.html.erb` — `admin` bundle + Firebase src value
- `web-app/app/views/layouts/application.html.erb` — repoint dead asset references
- `web-app/app/components/authentication/widget_component/widget_component.html.erb` — Firebase src value

**Deleted:**
- `web-app/app/javascript/{application,books,music,games,movies}.js` — old entrypoints
- `web-app/app/javascript/controllers/index.js` — the all-importing manifest
- `web-app/app/javascript/controllers/{conditional_field,metadata_editor,modal_form}_controller.js` — registered, referenced by nothing

---

### Task 1: Stop shipping Stimulus debug mode to production

`controllers/application.js` sets `application.debug = true` and logs two lines on every page load for every visitor. This is a self-contained cleanup with its own guard, done first so later tasks inherit a quiet baseline.

**Files:**
- Create: `web-app/test/lint/stimulus_debug_mode_test.rb`
- Modify: `web-app/app/javascript/controllers/application.js`

**Interfaces:**
- Consumes: nothing
- Produces: `app/javascript/controllers/application.js` continues to export `{ application }` — every manifest in Task 4 imports it by that name.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lint/stimulus_debug_mode_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# Stimulus debug mode logs every controller connect/disconnect and every action
# dispatch to the console. It is a development aid that was left switched on,
# so it shipped to every visitor on every site along with two startup console
# logs. There is no build-time development/production split for this file --
# one bundle serves both -- so the only place to enforce this is the source.
#
# If you need Stimulus debug output locally, set `window.Stimulus.debug = true`
# from the browser console. `window.Stimulus` is still exported for exactly
# that purpose; it costs nothing and does not log on its own.
class StimulusDebugModeTest < ActiveSupport::TestCase
  SOURCE = "app/javascript/controllers/application.js"

  test "Stimulus debug mode is not enabled in committed source" do
    refute_match(/\.debug\s*=\s*true/, source,
      "#{SOURCE} enables Stimulus debug mode, which logs controller lifecycle " \
      "and action dispatches to the console for every visitor on every page. " \
      "Remove the assignment; set window.Stimulus.debug = true from the browser " \
      "console when you need it locally.")
  end

  test "the Stimulus entrypoint logs nothing on startup" do
    offenders = source.lines.each_with_index.filter_map do |line, index|
      "  line #{index + 1}: #{line.strip}" if line.match?(/console\.\w+\(/)
    end

    assert_empty offenders,
      "#{SOURCE} runs on every page of every site, so anything it logs is " \
      "console noise for every visitor:\n#{offenders.join("\n")}"
  end

  private

  def source
    @source ||= File.read(Rails.root.join(SOURCE))
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/lint/stimulus_debug_mode_test.rb`

Expected: **2 failures** — one naming `application.debug = true`, one listing the two `console.log` lines.

Do not continue until you have seen both fail. A guard that has never been red is not known to test anything.

- [ ] **Step 3: Make it pass**

Replace the whole of `web-app/app/javascript/controllers/application.js` with:

```js
import { Application } from "@hotwired/stimulus"

const application = Application.start()

// Exposed so `window.Stimulus.debug = true` works from the browser console.
// Do NOT set debug here: this file runs on every page of every site, so
// leaving it on logs every controller connect and action dispatch for every
// visitor. Guarded by test/lint/stimulus_debug_mode_test.rb.
window.Stimulus = application

export { application }
```

- [ ] **Step 4: Run it and watch it pass**

Run: `bin/rails test test/lint/stimulus_debug_mode_test.rb`
Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add web-app/test/lint/stimulus_debug_mode_test.rb web-app/app/javascript/controllers/application.js
git commit -m "Stop shipping Stimulus debug mode to production

application.debug = true logged every controller lifecycle event and
action dispatch to the console for every visitor on all sites, alongside
two startup console.logs. Guarded so it cannot come back.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Fix the controller inventory, guarded by a drift test

Four defects exist today and Task 4's manifests would bake them in: `auto-dismiss` is referenced by three admin views and registered nowhere (admin flash has never auto-dismissed), and `conditional-field`, `metadata-editor`, `modal-form` are registered but referenced by no view.

The guard's first two rules run against the current `controllers/index.js`, so it can be written and made red **before** any manifests exist. Task 4 extends the same file with the manifest-aware rules.

**Files:**
- Create: `web-app/test/lint/stimulus_manifest_test.rb`
- Create: `web-app/app/javascript/controllers/auto_dismiss_controller.js`
- Modify: `web-app/app/javascript/controllers/index.js`
- Delete: `web-app/app/javascript/controllers/conditional_field_controller.js`
- Delete: `web-app/app/javascript/controllers/metadata_editor_controller.js`
- Delete: `web-app/app/javascript/controllers/modal_form_controller.js`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `AutoDismissController` registered as `"auto-dismiss"`, reading `data-auto-dismiss-delay-value` (Number, default `3000`).
  - `StimulusManifestTest#referenced_controllers` → `Hash<String identifier, Array<String relative_path>>`. Task 4 reuses this method.
  - `StimulusManifestTest#registered_controllers` → `Array<String identifier>`. Task 4 replaces its body to read manifests instead of `index.js`; the name and return type stay identical.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lint/stimulus_manifest_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# Keeps the set of Stimulus controllers referenced by markup and the set
# registered in JavaScript in agreement, in both directions.
#
# Both directions fail SILENTLY in a browser, which is why this is a test and
# not a code review item:
#
#   - A controller referenced by data-controller="..." but never registered
#     does nothing at all. No console error, no visual difference from markup
#     that never had the attribute. `auto-dismiss` sat in three admin flash
#     partials in exactly this state, so admin flash messages never once
#     auto-dismissed.
#   - A controller registered but referenced nowhere is dead weight compiled
#     into a bundle every visitor downloads. Three controllers were in this
#     state (conditional-field, metadata-editor, modal-form).
#
# There is deliberately NO allowlist. A controller registered dynamically or
# referenced from somewhere this scanner cannot see would need one, and no such
# case exists. If you are about to add one, you are almost certainly looking at
# a real defect instead.
class StimulusManifestTest < ActiveSupport::TestCase
  test "every controller referenced in markup is registered" do
    unregistered = referenced_controllers.keys - registered_controllers

    assert_empty unregistered,
      "These controllers are referenced by data-controller=\"...\" but registered " \
      "nowhere, so they silently do nothing:\n" \
      "#{unregistered.map { |id| "  #{id}: #{referenced_controllers[id].join(", ")}" }.join("\n")}"
  end

  test "every registered controller is referenced in markup" do
    unreferenced = registered_controllers - referenced_controllers.keys

    assert_empty unreferenced,
      "These controllers are registered but no markup references them. They are " \
      "compiled into a bundle every visitor downloads for nothing. Delete the " \
      "controller and its registration:\n#{unreferenced.map { |id| "  #{id}" }.join("\n")}"
  end

  private

  # Stimulus identifier => sorted list of Rails.root-relative paths referencing it.
  #
  # data-controller takes a space-separated list ("user-list-state membership-state"),
  # so each attribute value is split. ERB interpolation inside the value would
  # produce a junk identifier; no occurrence exists today, and one would fail the
  # first test loudly rather than silently, which is the right direction to fail.
  def referenced_controllers
    @referenced_controllers ||= begin
      result = Hash.new { |hash, key| hash[key] = [] }

      markup_files.each do |relative_path|
        File.read(Rails.root.join(relative_path)).scan(/\bdata-controller\s*=\s*(["'])(.*?)\1/m) do |_quote, value|
          value.split(/\s+/).reject(&:empty?).each { |identifier| result[identifier] << relative_path }
        end
      end

      result.each_value(&:sort!)
      result
    end
  end

  # Identifiers passed to application.register("...", X) anywhere in the
  # registration source. Task 4 repoints registration_files at the manifests.
  def registered_controllers
    @registered_controllers ||= registration_files.flat_map { |relative_path|
      File.read(Rails.root.join(relative_path)).scan(/application\.register\(\s*["']([^"']+)["']/).flatten
    }.uniq.sort
  end

  def registration_files
    ["app/javascript/controllers/index.js"]
  end

  def markup_files
    @markup_files ||= Dir.glob(Rails.root.join("{app/views,app/components}/**/*"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/lint/stimulus_manifest_test.rb`

Expected: **2 failures**.
- First names `auto-dismiss` in the three `_flash_success.html.erb` partials.
- Second lists `conditional-field`, `metadata-editor`, `modal-form`.

If the second test names anything beyond those three, stop and report it — the inventory has changed since this plan was written and the extra entries need a decision, not a deletion.

- [ ] **Step 3: Write the missing auto-dismiss controller**

Create `web-app/app/javascript/controllers/auto_dismiss_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="auto-dismiss"
//
// Removes its element after delayValue milliseconds. Used by the admin
// list-items flash partials, which pass data-auto-dismiss-delay-value="3000".
// Those partials referenced this controller before it existed, so the
// behaviour they were written for has never actually run.
export default class extends Controller {
  static values = { delay: { type: Number, default: 3000 } }

  connect() {
    // Turbo caches the mutated DOM and re-runs connect() on restore, so an
    // already-scheduled timer must be cleared before scheduling another --
    // otherwise a Back navigation stacks timers on the same element.
    this.clearTimer()
    this.timer = setTimeout(() => this.element.remove(), this.delayValue)
  }

  disconnect() {
    this.clearTimer()
  }

  clearTimer() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }
}
```

- [ ] **Step 4: Delete the three dead controllers**

```bash
git rm web-app/app/javascript/controllers/conditional_field_controller.js
git rm web-app/app/javascript/controllers/metadata_editor_controller.js
git rm web-app/app/javascript/controllers/modal_form_controller.js
```

- [ ] **Step 5: Update the registration manifest**

In `web-app/app/javascript/controllers/index.js`, delete these three import/register pairs:

```js
import ConditionalFieldController from "./conditional_field_controller"
application.register("conditional-field", ConditionalFieldController)

import MetadataEditorController from "./metadata_editor_controller"
application.register("metadata-editor", MetadataEditorController)

import ModalFormController from "./modal_form_controller"
application.register("modal-form", ModalFormController)
```

And add, keeping the file's alphabetical-by-identifier ordering (immediately after the `admin--search` pair):

```js
import AutoDismissController from "./auto_dismiss_controller"
application.register("auto-dismiss", AutoDismissController)
```

- [ ] **Step 6: Run it and watch it pass**

Run: `bin/rails test test/lint/stimulus_manifest_test.rb`
Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 7: Run the full suite and the linter**

```bash
ps aux | grep "[r]ails test"   # must be empty before running
bin/rails test
bundle exec standardrb
```

Expected: 7516+ runs, 0 failures, 0 errors. standardrb clean.

- [ ] **Step 8: Commit**

```bash
git add -A web-app/app/javascript/controllers web-app/test/lint/stimulus_manifest_test.rb
git commit -m "Reconcile Stimulus controller registrations with markup

auto-dismiss was referenced by three admin flash partials but registered
nowhere, so admin flash messages never auto-dismissed. conditional-field,
metadata-editor and modal-form were registered but referenced by no view.
Both directions now guarded.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Registry-driven, minified rollup config

Introduces `config/asset_bundles.json` as the shared source of truth and turns on minification. Bundle *contents* do not change yet — this task is only about how the build is described and compressed, so any size change is attributable to terser alone.

**Files:**
- Create: `web-app/config/asset_bundles.json`
- Create: `web-app/test/lint/asset_bundle_coverage_test.rb`
- Modify: `web-app/package.json`
- Modify: `web-app/rollup.config.js`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `config/asset_bundles.json` — a JSON object mapping bundle name (String, e.g. `"books-web"`) to entry path relative to `web-app/` (String). Read by `rollup.config.js`, by `DomainHelper#domain_js_bundle`'s guard in Task 5, and by `AssetBundleCoverageTest`.
  - Build outputs land at `app/assets/builds/<bundle-name>.js`, so `javascript_include_tag "<bundle-name>"` resolves.

- [ ] **Step 1: Install the minifier**

```bash
cd web-app && yarn add --dev @rollup/plugin-terser
```

Expected: `package.json` gains `@rollup/plugin-terser` under `devDependencies`, `yarn.lock` updates.

- [ ] **Step 2: Write the failing test**

Create `web-app/test/lint/asset_bundle_coverage_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# config/asset_bundles.json is the single source of truth for what the
# JavaScript build produces. rollup.config.js reads it to decide what to build;
# Ruby reads it to know what a layout is allowed to ask for.
#
# The reason it is shared rather than duplicated: Propshaft raises
# Propshaft::MissingAssetError on a missing asset, so a layout naming a bundle
# the build does not produce is not a degraded page, it is a 500 on every page
# of that site -- and app/assets/builds/* is gitignored, so no test can catch it
# by inspecting build output. Keeping one list, checked from both sides, is what
# makes that unrepresentable.
#
# Task 5 adds the layout -> bundle direction to this file.
class AssetBundleCoverageTest < ActiveSupport::TestCase
  test "the bundle registry is valid JSON mapping names to entry files" do
    assert_kind_of Hash, registry, "config/asset_bundles.json must be a JSON object"
    refute_empty registry, "config/asset_bundles.json is empty"

    registry.each do |name, entry|
      assert_match(/\A[a-z0-9-]+\z/, name,
        "Bundle name #{name.inspect} must be lowercase kebab-case: it becomes the " \
        "built filename and the argument to javascript_include_tag.")
      assert_kind_of String, entry, "Entry for #{name.inspect} must be a path string"
    end
  end

  test "every registered bundle has an entry file on disk" do
    missing = registry.reject { |_name, entry| File.exist?(Rails.root.join(entry)) }

    assert_empty missing,
      "These bundles are registered in config/asset_bundles.json but their entry " \
      "file does not exist, so the build would fail:\n" \
      "#{missing.map { |name, entry| "  #{name} -> #{entry}" }.join("\n")}"
  end

  private

  def registry
    @registry ||= JSON.parse(File.read(Rails.root.join("config/asset_bundles.json")))
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `bin/rails test test/lint/asset_bundle_coverage_test.rb`
Expected: FAIL — `Errno::ENOENT`, no such file `config/asset_bundles.json`.

- [ ] **Step 4: Create the registry**

Create `web-app/config/asset_bundles.json`. Entries point at the current entrypoints for now; Task 4 repoints them at the new ones.

```json
{
  "application": "app/javascript/application.js",
  "books": "app/javascript/books.js",
  "music": "app/javascript/music.js",
  "games": "app/javascript/games.js",
  "movies": "app/javascript/movies.js"
}
```

- [ ] **Step 5: Rewrite the rollup config**

Replace the whole of `web-app/rollup.config.js`:

```js
import fs from "node:fs"
import resolve from "@rollup/plugin-node-resolve"
import commonjs from "@rollup/plugin-commonjs"
import terser from "@rollup/plugin-terser"

// Single source of truth, shared with Ruby. See
// test/lint/asset_bundle_coverage_test.rb for why this list is not duplicated.
// Read relative to the process working directory: yarn runs scripts from
// web-app/, which is also where this config lives.
const BUNDLES = JSON.parse(fs.readFileSync("config/asset_bundles.json", "utf8"))

// Self-contained IIFE per bundle, deliberately: Propshaft rewrites only
// explicit RAILS_ASSET_URL() markers, never ES import specifiers, so a shared
// rollup chunk referenced as ./chunk-abc.js would resolve to an undigested
// /assets/chunk-abc.js and 404. Duplicating Turbo and Stimulus across bundles
// costs nothing anyway -- the sites are separate hostnames with separate HTTP
// caches, so a "shared" vendor chunk would never actually be shared.
//
// No output.name: these entries are side-effectful and export nothing, so
// rollup does not need a global to hang exports off.
export default Object.entries(BUNDLES).map(([name, input]) => ({
  input,
  output: {
    file: `app/assets/builds/${name}.js`,
    format: "iife",
    inlineDynamicImports: true,
    sourcemap: true
  },
  plugins: [resolve(), commonjs(), terser()]
}))
```

- [ ] **Step 6: Run the test and watch it pass**

Run: `bin/rails test test/lint/asset_bundle_coverage_test.rb`
Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 7: Build and measure**

```bash
cd web-app && yarn build
ls -l app/assets/builds/*.js
gzip -9 -c app/assets/builds/application.js | wc -c
```

Expected: `application.js` drops from ~889,000 bytes raw to roughly 384,000, and its gzipped size from ~183,900 to roughly **89,500**. Record the exact number — Task 8 compares against it.

If gzipped size did not roughly halve, terser is not running. Check that the plugin is in the `plugins` array and that `yarn build` reported no warnings.

- [ ] **Step 8: Verify the app still boots**

```bash
bin/rails db:test:prepare test
bundle exec standardrb
```

Expected: 7518+ runs, 0 failures. standardrb clean.

Then load a page manually and confirm no console errors:

```bash
bin/rails server
```

Visit `https://dev-new.thegreatestbooks.org/` and confirm the Login button opens the modal. (Use `yarn build:all` + `bin/rails server`, not `bin/dev` — foreman needs a TTY. Check what is already on port 3000 first; another worktree may be serving it.)

- [ ] **Step 9: Commit**

```bash
git add web-app/config/asset_bundles.json web-app/rollup.config.js web-app/package.json web-app/yarn.lock web-app/test/lint/asset_bundle_coverage_test.rb
git commit -m "Minify JS bundles and drive rollup from a shared registry

The build had no JS minifier at all. Terser roughly halves transfer size
(184 KB -> 89 KB gzipped for the shared bundle). config/asset_bundles.json
becomes the single source of truth read by both rollup and Ruby, so a
layout cannot name a bundle the build does not produce.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Split into per-domain web bundles and one admin bundle

Replaces the all-importing `controllers/index.js` with explicit manifests so rollup can tree-shake, and extends the drift guard with the manifest-aware rules.

**Files:**
- Create: `web-app/app/javascript/turbo.js`
- Create: `web-app/app/javascript/manifests/{web_shared,books_web,music_web,games_web,movies_web,admin}.js`
- Create: `web-app/app/javascript/entrypoints/{books_web,music_web,games_web,movies_web,admin}.js`
- Modify: `web-app/config/asset_bundles.json`
- Modify: `web-app/test/lint/stimulus_manifest_test.rb`
- Delete: `web-app/app/javascript/controllers/index.js`
- Delete: `web-app/app/javascript/{application,books,music,games,movies}.js`

**Interfaces:**
- Consumes: `config/asset_bundles.json` (Task 3); `{ application }` from `controllers/application.js` (Task 1).
- Produces:
  - `app/javascript/turbo.js` — side-effect module that installs Turbo. Task 6 rewrites its body; every entrypoint imports it as `"../turbo"` and that import line never changes.
  - Bundle names `books-web`, `music-web`, `games-web`, `movies-web`, `admin`, consumed by Task 5's layouts.
  - `StimulusManifestTest#registration_files` now returns the manifest paths.

- [ ] **Step 1: Extend the drift guard with manifest-aware rules**

In `web-app/test/lint/stimulus_manifest_test.rb`, replace the `registration_files` method with:

```ruby
  WEB_MANIFESTS = {
    "books" => "app/javascript/manifests/books_web.js",
    "music" => "app/javascript/manifests/music_web.js",
    "games" => "app/javascript/manifests/games_web.js",
    "movies" => "app/javascript/manifests/movies_web.js"
  }.freeze

  ADMIN_MANIFEST = "app/javascript/manifests/admin.js"

  def registration_files
    WEB_MANIFESTS.values + [ADMIN_MANIFEST]
  end
```

Then add these three tests above the `private` keyword:

```ruby
  test "admin-only controllers are absent from every web manifest" do
    admin_only = referenced_controllers.select { |_id, paths| paths.all? { |path| admin_path?(path) } }

    leaked = admin_only.keys.each_with_object({}) do |identifier, result|
      domains = WEB_MANIFESTS.keys.select { |domain| registered_in?(WEB_MANIFESTS[domain], identifier) }
      result[identifier] = domains if domains.any?
    end

    assert_empty leaked,
      "These controllers are referenced only from admin markup, so shipping them " \
      "in a public bundle makes every reader download admin code:\n" \
      "#{leaked.map { |id, domains| "  #{id}: in #{domains.join(", ")}" }.join("\n")}"
  end

  test "controllers referenced from shared markup are in every web manifest" do
    shared = referenced_controllers.select { |_id, paths|
      paths.any? { |path| !admin_path?(path) && domain_of(path).nil? }
    }

    gaps = shared.keys.each_with_object({}) do |identifier, result|
      missing = WEB_MANIFESTS.keys.reject { |domain| registered_in?(WEB_MANIFESTS[domain], identifier) }
      result[identifier] = missing if missing.any?
    end

    assert_empty gaps,
      "These controllers are referenced from markup shared across domains (layouts, " \
      "reviews/, user_lists/, root-level components), so every web bundle needs them. " \
      "Missing from:\n#{gaps.map { |id, domains| "  #{id}: #{domains.join(", ")}" }.join("\n")}"
  end

  test "controllers referenced from domain markup are in that domain's web manifest" do
    gaps = referenced_controllers.each_with_object({}) do |(identifier, paths), result|
      domains = paths.filter_map { |path| domain_of(path) unless admin_path?(path) }.uniq
      missing = domains.reject { |domain| registered_in?(WEB_MANIFESTS[domain], identifier) }
      result[identifier] = missing if missing.any?
    end

    assert_empty gaps,
      "These controllers are referenced from a domain's own markup but are not in " \
      "that domain's web manifest, so they silently do nothing on that site:\n" \
      "#{gaps.map { |id, domains| "  #{id}: #{domains.join(", ")}" }.join("\n")}"
  end
```

And add these three private helpers:

```ruby
  def admin_path?(relative_path)
    relative_path.start_with?("app/views/admin/", "app/components/admin/")
  end

  # The first path segment under app/views or app/components that names a domain.
  #
  # Scans EVERY segment, not just the first. Books-only markup lives at both
  # app/views/books/... and app/views/saved_searches/books/..., and only the
  # second segment identifies the domain in the latter -- matching just the
  # first segment would classify saved-search-picker as shared and demand it in
  # the music, games and movies manifests, where nothing references it.
  #
  # Returns nil for genuinely shared markup (reviews/, user_lists/, toast/,
  # root-level components), which rule 4 then requires in every web manifest.
  def domain_of(relative_path)
    relative_path
      .sub(%r{\Aapp/(?:views|components)/}, "")
      .split("/")
      .find { |segment| WEB_MANIFESTS.key?(segment) }
  end

  # Membership resolves transitively: books_web.js imports web_shared.js, so a
  # controller registered in web_shared counts as present in every web manifest.
  # Reading each manifest in isolation would report every shared controller as
  # missing from all four.
  def registered_in?(manifest_path, identifier)
    manifest_closure(manifest_path).any? do |path|
      File.read(Rails.root.join(path)).match?(/application\.register\(\s*["']#{Regexp.escape(identifier)}["']/)
    end
  end

  def manifest_closure(manifest_path, seen = Set.new)
    return seen if seen.include?(manifest_path)
    seen << manifest_path

    File.read(Rails.root.join(manifest_path)).scan(/^import\s+["']\.\/([a-z_]+)["']/).flatten.each do |sibling|
      manifest_closure("app/javascript/manifests/#{sibling}.js", seen)
    end

    seen
  end
```

Also update `registered_controllers` so it resolves the same closure rather than reading only the listed files:

```ruby
  def registered_controllers
    @registered_controllers ||= registration_files
      .flat_map { |path| manifest_closure(path).to_a }
      .uniq
      .flat_map { |path| File.read(Rails.root.join(path)).scan(/application\.register\(\s*["']([^"']+)["']/).flatten }
      .uniq
      .sort
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/lint/stimulus_manifest_test.rb`
Expected: FAIL — `Errno::ENOENT` for `app/javascript/manifests/books_web.js`. All five tests error out because no manifest exists yet.

- [ ] **Step 3: Create the Turbo indirection module**

Create `web-app/app/javascript/turbo.js`:

```js
// Every entrypoint imports Turbo through this module rather than depending on
// @hotwired/turbo-rails directly, so the dependency can be changed in one place.
import "@hotwired/turbo-rails"
```

- [ ] **Step 4: Create the shared web manifest**

Create `web-app/app/javascript/manifests/web_shared.js`:

```js
// Stimulus controllers used by public markup on every domain: the layouts, the
// reviews and user-list surfaces, and root-level components. Domain manifests
// import this and add their own.
//
// This replaces controllers/index.js, which imported all 24 controllers into a
// single bundle and is why nothing tree-shook. Do NOT run
// `bin/rails stimulus:manifest:update` -- it regenerates that file and this app
// no longer uses it. Registrations here are checked against markup by
// test/lint/stimulus_manifest_test.rb.
import { application } from "../controllers/application"

import AuthenticationController from "../controllers/authentication_controller"
application.register("authentication", AuthenticationController)

import AutocompleteController from "../controllers/autocomplete_controller"
application.register("autocomplete", AutocompleteController)

import MembershipStateController from "../controllers/membership_state_controller"
application.register("membership-state", MembershipStateController)

import Reviews__ModalController from "../controllers/reviews/modal_controller"
application.register("reviews--modal", Reviews__ModalController)

import Reviews__MyReviewsController from "../controllers/reviews/my_reviews_controller"
application.register("reviews--my-reviews", Reviews__MyReviewsController)

import Reviews__SpoilerController from "../controllers/reviews/spoiler_controller"
application.register("reviews--spoiler", Reviews__SpoilerController)

import Reviews__WidgetController from "../controllers/reviews/widget_controller"
application.register("reviews--widget", Reviews__WidgetController)

import ToastController from "../controllers/toast_controller"
application.register("toast", ToastController)

import UserListAddItemController from "../controllers/user_list_add_item_controller"
application.register("user-list-add-item", UserListAddItemController)

import UserListModalController from "../controllers/user_list_modal_controller"
application.register("user-list-modal", UserListModalController)

import UserListStateController from "../controllers/user_list_state_controller"
application.register("user-list-state", UserListStateController)

import UserListWidgetController from "../controllers/user_list_widget_controller"
application.register("user-list-widget", UserListWidgetController)
```

- [ ] **Step 5: Create the domain web manifests**

Create `web-app/app/javascript/manifests/books_web.js`:

```js
import { application } from "../controllers/application"
import "./web_shared"

import Books__FilterController from "../controllers/books/filter_controller"
application.register("books--filter", Books__FilterController)

import SavedSearchPickerController from "../controllers/saved_search_picker_controller"
application.register("saved-search-picker", SavedSearchPickerController)
```

Create `web-app/app/javascript/manifests/music_web.js`:

```js
import { application } from "../controllers/application"
import "./web_shared"

import YearRangeModalController from "../controllers/year_range_modal_controller"
application.register("year-range-modal", YearRangeModalController)
```

Create `web-app/app/javascript/manifests/games_web.js`:

```js
import { application } from "../controllers/application"
import "./web_shared"

import YearRangeModalController from "../controllers/year_range_modal_controller"
application.register("year-range-modal", YearRangeModalController)
```

Create `web-app/app/javascript/manifests/movies_web.js`:

```js
import "./web_shared"
```

- [ ] **Step 6: Create the admin manifest**

Create `web-app/app/javascript/manifests/admin.js`:

```js
// One admin bundle for all domains: admin lives at /admin on each domain's own
// hostname, and there is no domain-specific admin JavaScript, so per-domain
// admin bundles would be byte-identical. Split this only when that stops being
// true.
import { application } from "../controllers/application"

import Admin__MarkdownPreviewController from "../controllers/admin/markdown_preview_controller"
application.register("admin--markdown-preview", Admin__MarkdownPreviewController)

import Admin__SearchController from "../controllers/admin/search_controller"
application.register("admin--search", Admin__SearchController)

import AuthenticationController from "../controllers/authentication_controller"
application.register("authentication", AuthenticationController)

import AutocompleteController from "../controllers/autocomplete_controller"
application.register("autocomplete", AutocompleteController)

import AutoDismissController from "../controllers/auto_dismiss_controller"
application.register("auto-dismiss", AutoDismissController)

import ClipboardCopyController from "../controllers/clipboard_copy_controller"
application.register("clipboard-copy", ClipboardCopyController)

import ReviewFilterController from "../controllers/review_filter_controller"
application.register("review-filter", ReviewFilterController)

import Reviews__SpoilerController from "../controllers/reviews/spoiler_controller"
application.register("reviews--spoiler", Reviews__SpoilerController)

import SharedModalController from "../controllers/shared_modal_controller"
application.register("shared-modal", SharedModalController)

import WizardStepController from "../controllers/wizard_step_controller"
application.register("wizard-step", WizardStepController)
```

- [ ] **Step 7: Create the entrypoints**

Create `web-app/app/javascript/entrypoints/books_web.js`:

```js
import "../turbo"
import "../services/cloudflare_challenge"
import "../manifests/books_web"
```

Create `web-app/app/javascript/entrypoints/music_web.js`:

```js
import "../turbo"
import "../services/cloudflare_challenge"
import "../manifests/music_web"
```

Create `web-app/app/javascript/entrypoints/games_web.js`:

```js
import "../turbo"
import "../services/cloudflare_challenge"
import "../manifests/games_web"
```

Create `web-app/app/javascript/entrypoints/movies_web.js`:

```js
import "../turbo"
import "../services/cloudflare_challenge"
import "../manifests/movies_web"
```

Create `web-app/app/javascript/entrypoints/admin.js`:

```js
import "../turbo"
import "../services/cloudflare_challenge"
import "../manifests/admin"
```

- [ ] **Step 8: Point the registry at the new entrypoints**

Replace the contents of `web-app/config/asset_bundles.json`:

```json
{
  "books-web": "app/javascript/entrypoints/books_web.js",
  "music-web": "app/javascript/entrypoints/music_web.js",
  "games-web": "app/javascript/entrypoints/games_web.js",
  "movies-web": "app/javascript/entrypoints/movies_web.js",
  "admin": "app/javascript/entrypoints/admin.js"
}
```

Note the old `application` bundle is now gone from the registry, so `yarn build` stops producing `application.js`. Task 5 repoints the layouts. Until it does, the running app is broken — that is why Tasks 4 and 5 are committed but not deployed independently.

- [ ] **Step 9: Delete the old entrypoints and manifest**

```bash
git rm web-app/app/javascript/controllers/index.js
git rm web-app/app/javascript/application.js
git rm web-app/app/javascript/books.js
git rm web-app/app/javascript/music.js
git rm web-app/app/javascript/games.js
git rm web-app/app/javascript/movies.js
rm -f web-app/app/assets/builds/application.js web-app/app/assets/builds/application.js.map
rm -f web-app/app/assets/builds/books.js web-app/app/assets/builds/books.js.map
rm -f web-app/app/assets/builds/music.js web-app/app/assets/builds/music.js.map
rm -f web-app/app/assets/builds/games.js web-app/app/assets/builds/games.js.map
rm -f web-app/app/assets/builds/movies.js web-app/app/assets/builds/movies.js.map
```

The `rm -f` calls clear stale build output so a later `javascript_include_tag` failure cannot be masked by a leftover file. These are gitignored, so nothing is staged by them.

- [ ] **Step 10: Run the guards and watch them pass**

```bash
bin/rails test test/lint/stimulus_manifest_test.rb test/lint/asset_bundle_coverage_test.rb
```

Expected: PASS, 7 runs, 0 failures.

If "controllers referenced from shared markup are in every web manifest" fails, the transitive closure is not resolving — check that each domain manifest's `import "./web_shared"` matches the `^import\s+["']\.\/([a-z_]+)["']` pattern exactly (no leading whitespace, single or double quotes, no file extension).

- [ ] **Step 11: Build and measure per bundle**

```bash
cd web-app && yarn build
for f in app/assets/builds/*-web.js app/assets/builds/admin.js; do
  printf "%-20s raw %8d  gzip %7d\n" "$(basename $f)" "$(stat -c%s $f)" "$(gzip -9 -c $f | wc -c)"
done
```

Expected: each `*-web.js` around **85 KB gzipped**, `admin.js` noticeably smaller (no Firebase-free saving yet — admin still bundles Firebase via `authentication_controller`, so expect roughly 75 KB). Record the numbers.

- [ ] **Step 12: Commit**

```bash
git add -A web-app/app/javascript web-app/config/asset_bundles.json web-app/test/lint/stimulus_manifest_test.rb
git commit -m "Split JS into per-domain web bundles and one admin bundle

controllers/index.js imported all 24 controllers into one bundle, so
nothing tree-shook and every reader downloaded the admin controller set.
Explicit per-bundle manifests replace it, guarded in both directions plus
three manifest-placement rules.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Wire the layouts to their bundles

**Files:**
- Modify: `web-app/app/helpers/domain_helper.rb`
- Modify: `web-app/app/views/layouts/{books,music,games,movies}/application.html.erb`
- Modify: `web-app/app/views/layouts/admin.html.erb`
- Modify: `web-app/app/views/layouts/application.html.erb`
- Modify: `web-app/test/lint/asset_bundle_coverage_test.rb`
- Modify: `web-app/test/helpers/application_helper_test.rb`
- Create: `web-app/test/integration/domain_bundle_test.rb`

**Interfaces:**
- Consumes: bundle names from `config/asset_bundles.json` (Task 4).
- Produces: `DomainHelper#domain_js_bundle` → String, e.g. `"books-web"`. Used by all domain layouts.

- [ ] **Step 1: Write the failing coverage test**

Add to `web-app/test/lint/asset_bundle_coverage_test.rb`, above the `private` keyword:

```ruby
  test "every domain layout's bundle is produced by the build" do
    missing = domain_layouts.reject { |domain, _path| registry.key?("#{domain}-web") }

    assert_empty missing,
      "These domain layouts resolve to a bundle that config/asset_bundles.json does " \
      "not produce. Propshaft raises MissingAssetError on a missing asset, so this " \
      "is a 500 on every page of that site, not a degraded page:\n" \
      "#{missing.map { |domain, path| "  #{domain} (#{path}) needs bundle #{domain}-web" }.join("\n")}"
  end

  test "the admin layout's bundle is produced by the build" do
    assert registry.key?("admin"),
      "app/views/layouts/admin.html.erb loads the \"admin\" bundle, but " \
      "config/asset_bundles.json does not produce it."
  end

  test "no layout references a bundle outside the registry" do
    offenders = layout_files.each_with_object({}) do |relative_path, result|
      names = File.read(Rails.root.join(relative_path))
        .scan(/javascript_include_tag\s+["']([^"']+)["']/)
        .flatten
        .reject { |name| registry.key?(name) }
      result[relative_path] = names if names.any?
    end

    assert_empty offenders,
      "These layouts name a JavaScript bundle the build does not produce:\n" \
      "#{offenders.map { |path, names| "  #{path}: #{names.join(", ")}" }.join("\n")}"
  end
```

And these private helpers:

```ruby
  # "books" => "app/views/layouts/books/application.html.erb", for every domain
  # that has its own layout. Derived from disk rather than hardcoded so a new
  # domain layout cannot be added without a matching bundle.
  def domain_layouts
    @domain_layouts ||= Dir.glob(Rails.root.join("app/views/layouts/*/application.html.erb"))
      .to_h { |path|
        relative = Pathname.new(path).relative_path_from(Rails.root).to_s
        [relative.split("/")[3], relative]
      }
  end

  def layout_files
    @layout_files ||= Dir.glob(Rails.root.join("app/views/layouts/**/*.erb"))
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/lint/asset_bundle_coverage_test.rb`

Expected: the "no layout references a bundle outside the registry" test **fails**, listing the five layouts that still name `application`, plus `layouts/application.html.erb`'s `#{current_domain}/application`. The first two new tests should already pass, because Task 4 registered `books-web` … `movies-web` and `admin`.

- [ ] **Step 3: Add the helper**

In `web-app/app/helpers/domain_helper.rb`, add above `domain_specific_layout`:

```ruby
  # The JavaScript bundle for the current domain's public site, e.g. "books-web".
  # Bundle names come from config/asset_bundles.json; the pairing between a
  # domain layout and its bundle is enforced by
  # test/lint/asset_bundle_coverage_test.rb, because Propshaft raises on a
  # missing asset and that would be a 500 on every page of the site.
  def domain_js_bundle
    "#{current_domain}-web"
  end
```

- [ ] **Step 4: Repoint the domain layouts**

In each of `app/views/layouts/books/application.html.erb`, `app/views/layouts/music/application.html.erb`, `app/views/layouts/games/application.html.erb`, and `app/views/layouts/movies/application.html.erb`, replace:

```erb
    <%= javascript_include_tag "application", "data-turbo-track": "reload" %>
```

with:

```erb
    <%= javascript_include_tag domain_js_bundle, "data-turbo-track": "reload" %>
```

- [ ] **Step 5: Repoint the admin layout**

In `app/views/layouts/admin.html.erb`, replace:

```erb
  <%= javascript_include_tag "application", "data-turbo-track": "reload" %>
```

with:

```erb
  <%= javascript_include_tag "admin", "data-turbo-track": "reload" %>
```

- [ ] **Step 6: Fix the dead default layout**

`app/views/layouts/application.html.erb` references `#{current_domain}/application` for both stylesheet and script — paths that have never existed. Nothing sets this layout explicitly, but it is Rails' default fallback, so any controller that omits a `layout` declaration renders it and raises `Propshaft::MissingAssetError`.

Replace both lines:

```erb
    <%= stylesheet_link_tag "#{current_domain}/application", "data-turbo-track": "reload" %>
    <%= javascript_include_tag "#{current_domain}/application", "data-turbo-track": "reload", type: "module" %>
```

with:

```erb
    <%= stylesheet_link_tag current_domain.to_s, "data-turbo-track": "reload" %>
    <%= javascript_include_tag domain_js_bundle, "data-turbo-track": "reload" %>
```

`type: "module"` is dropped deliberately: the bundles are IIFE, and a module script would defer execution and change ordering relative to the inline scripts in the domain layouts.

- [ ] **Step 7: Add a helper test**

Add to `web-app/test/helpers/application_helper_test.rb` (or create `web-app/test/helpers/domain_helper_test.rb` if that file has no suitable class):

```ruby
  test "domain_js_bundle names the current domain's web bundle" do
    def self.current_domain = :books
    assert_equal "books-web", domain_js_bundle
  end
```

If `DomainHelper` is not already included in that test's helper class, create `web-app/test/helpers/domain_helper_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

class DomainHelperTest < ActionView::TestCase
  include DomainHelper

  test "domain_js_bundle names the current domain's web bundle" do
    stubs(:current_domain).returns(:books)
    assert_equal "books-web", domain_js_bundle
  end

  test "domain_js_bundle follows the current domain" do
    stubs(:current_domain).returns(:games)
    assert_equal "games-web", domain_js_bundle
  end
end
```

- [ ] **Step 8: Add the request-time assertion**

The lint guard reads ERB source; it does not prove `domain_js_bundle` resolves to the right bundle for a real request on a real host. Create `web-app/test/integration/domain_bundle_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# The lint guard in test/lint/asset_bundle_coverage_test.rb reads layout SOURCE.
# This checks the other half: that a real request on each host resolves
# domain_js_bundle to that domain's bundle and Propshaft can find it.
#
# Asserts on the script src path only -- behaviour, not markup. A designer
# reshaping these layouts must not break this test.
#
# Requires built bundles on disk, so run via `bin/rails db:test:prepare test`
# (which builds) rather than plain `bin/rails test` (which does not).
class DomainBundleTest < ActionDispatch::IntegrationTest
  HOSTS = {
    "books" => "dev-new.thegreatestbooks.org",
    "music" => "dev.thegreatestmusic.org",
    "games" => "dev.thegreatest.games"
  }.freeze

  HOSTS.each do |domain, hostname|
    test "#{domain} pages load the #{domain}-web bundle" do
      host! hostname
      get root_path
      assert_response :success

      sources = Nokogiri::HTML5(response.body).css("script[src]").map { |node| node["src"] }

      assert sources.any? { |src| src.include?("#{domain}-web") },
        "Expected a script tag for the #{domain}-web bundle on #{hostname}, got: #{sources.inspect}"

      (HOSTS.keys - [domain]).each do |other|
        refute sources.any? { |src| src.include?("#{other}-web") },
          "#{hostname} loaded the #{other}-web bundle. Domain bundles must not cross sites."
      end
    end
  end
end
```

- [ ] **Step 9: Run the tests and watch them pass**

```bash
bin/rails db:test:prepare test test/lint/asset_bundle_coverage_test.rb test/helpers/ test/integration/domain_bundle_test.rb
```

Expected: PASS, 0 failures.

If `DomainBundleTest` raises `Propshaft::MissingAssetError`, the bundles were not built — you ran plain `bin/rails test`. If it fails because `root_path` needs fixtures or a ranking configuration that the domain's homepage requires, substitute a simpler always-available path for that domain rather than building fixture scaffolding; the assertion is about the script tag, not the page.

- [ ] **Step 10: Run the full suite**

```bash
ps aux | grep "[r]ails test"
bin/rails db:test:prepare test
bundle exec standardrb
```

Expected: 0 failures, 0 errors.

- [ ] **Step 11: Verify in a browser**

```bash
cd web-app && yarn build:all && bin/rails server
```

Confirm on each of `dev-new.thegreatestbooks.org`, `dev.thegreatestmusic.org`, `dev.thegreatest.games`:
- View source shows the right bundle (`books-web`, `music-web`, `games-web`), not `application`
- No console errors
- The Login modal opens
- On books, the filter drill-down still works (`books--filter`)
- On music/games, the year-range modal still opens (`year-range-modal`)
- `/admin` loads and its search autocomplete works (`admin--search`)

- [ ] **Step 12: Commit**

```bash
git add web-app/app/helpers/domain_helper.rb web-app/app/views/layouts web-app/test
git commit -m "Load per-domain bundles from the layouts

Every layout including admin loaded the same 'application' bundle. Each
domain layout now loads its own web bundle and admin loads the admin
bundle. Also repoints layouts/application.html.erb, whose asset paths
never existed and would raise MissingAssetError if it were ever rendered.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Drop ActionCable from every bundle

`@hotwired/turbo-rails` imports `cable_stream_source_element` and `cable`, pulling ActionCable into every bundle for ~3.5 KB gzipped. Verified unused: no `turbo_stream_from`, no `broadcasts_to`, no `broadcast_*` helper anywhere in `app/`, `config/` or `test/`, and no `app/channels` directory.

**Files:**
- Create: `web-app/test/lint/turbo_cable_test.rb`
- Modify: `web-app/app/javascript/turbo.js`

**Interfaces:**
- Consumes: `app/javascript/turbo.js` (Task 4).
- Produces: nothing new — every entrypoint's `import "../turbo"` is unchanged.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/lint/turbo_cable_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"

# app/javascript/turbo.js imports Turbo core directly instead of
# @hotwired/turbo-rails, which also pulls <turbo-cable-stream-source> and
# ActionCable into every bundle. That is only safe while the app broadcasts
# nothing over a cable. This test enforces the precondition: the moment someone
# adds turbo_stream_from or a broadcasts_* helper, it fails and tells them to
# put turbo-rails back.
#
# Turbo Stream RESPONSES over HTTP (format.turbo_stream, used by several
# controllers) are core Turbo and are unaffected -- only the WebSocket
# broadcast path needs the cable.
class TurboCableTest < ActiveSupport::TestCase
  CABLE_MARKERS = /turbo_stream_from|broadcasts_to|broadcasts_refreshes|broadcast_(?:append|prepend|replace|update|remove|render|action)|Turbo::StreamsChannel/

  test "nothing broadcasts over ActionCable" do
    offenders = source_files.filter_map do |relative_path|
      relative_path if File.read(Rails.root.join(relative_path)).match?(CABLE_MARKERS)
    end

    assert_empty offenders,
      "These files use Turbo's ActionCable broadcast path, but " \
      "app/javascript/turbo.js imports Turbo core WITHOUT the cable stream " \
      "source element, so the broadcast will silently never arrive. Restore " \
      "`import \"@hotwired/turbo-rails\"` in that file (and delete this test's " \
      "premise) if broadcasting is now wanted:\n#{offenders.join("\n")}"
  end

  test "turbo.js keeps the Rails method-override hook" do
    source = File.read(Rails.root.join("app/javascript/turbo.js"))

    assert_match(/encodeMethodIntoRequestBody/, source,
      "app/javascript/turbo.js must install encodeMethodIntoRequestBody. It is " \
      "the one piece of @hotwired/turbo-rails this app still needs: it encodes " \
      "_method into non-GET form bodies. Without it, form_with method: :patch " \
      "and button_to method: :delete silently submit as POST.")
  end

  private

  def source_files
    @source_files ||= Dir.glob(Rails.root.join("{app,config,lib}/**/*.{rb,erb,js}"))
      .reject { |path| path.include?("/assets/builds/") }
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end
end
```

- [ ] **Step 2: Run it and watch the second test fail**

Run: `bin/rails test test/lint/turbo_cable_test.rb`

Expected: "nothing broadcasts over ActionCable" **passes** (nothing does). "turbo.js keeps the Rails method-override hook" **fails**, because `turbo.js` currently just imports turbo-rails.

- [ ] **Step 3: Rewrite the Turbo module**

Replace the whole of `web-app/app/javascript/turbo.js`:

```js
// Turbo core, WITHOUT @hotwired/turbo-rails.
//
// turbo-rails' entry also imports cable_stream_source_element and cable, which
// pulls ActionCable into every bundle for ~3.5 KB gzipped. This app broadcasts
// nothing over a cable: there is no turbo_stream_from anywhere, no broadcasts_*
// helper, and no app/channels. <turbo-cable-stream-source> is the only thing
// that ever opens a cable connection, and it only enters the DOM via
// turbo_stream_from. test/lint/turbo_cable_test.rb enforces that precondition.
//
// Turbo Frames are plain fetch and never involve ActionCable. Turbo Stream
// RESPONSES over HTTP (text/vnd.turbo-stream.html) are core Turbo and are
// likewise unaffected -- several controllers rely on them.
//
// encodeMethodIntoRequestBody is the one Rails-specific piece turbo-rails adds
// that this app genuinely needs: it encodes _method into non-GET form bodies,
// without which `form_with method: :patch` and `button_to method: :delete`
// silently submit as POST. This is a DEEP IMPORT into turbo-rails' internals --
// RE-CHECK THIS PATH ON EVERY turbo-rails UPGRADE. If it moves, the import
// throws at build time rather than failing silently, which is the safe direction.
import * as Turbo from "@hotwired/turbo"
import { encodeMethodIntoRequestBody } from "@hotwired/turbo-rails/app/javascript/turbo/fetch_requests"

window.Turbo = Turbo
addEventListener("turbo:before-fetch-request", encodeMethodIntoRequestBody)
```

- [ ] **Step 4: Run it and watch it pass**

Run: `bin/rails test test/lint/turbo_cable_test.rb`
Expected: PASS, 2 runs, 0 failures.

- [ ] **Step 5: Build and confirm the saving**

```bash
cd web-app && yarn build
for f in app/assets/builds/*-web.js app/assets/builds/admin.js; do
  printf "%-20s gzip %7d\n" "$(basename $f)" "$(gzip -9 -c $f | wc -c)"
done
grep -c "ActionCable\|createConsumer" app/assets/builds/books-web.js || echo "0 (ActionCable gone)"
```

Expected: each bundle drops roughly **3.5 KB gzipped** from Task 4's numbers, and the grep reports 0.

- [ ] **Step 6: Manually verify PATCH and DELETE forms still work**

This is the specific risk of this task and no Rails test can see it — `assert_redirected_to` passes either way because the failure is in the browser's request encoding.

```bash
cd web-app && yarn build:all && bin/rails server
```

In `/admin` on the games domain:
- Edit a game and save (a `PATCH` via `form_with`) — confirm the change persists
- Delete a list item (a `DELETE` via `button_to`) — confirm it is removed, not a routing error

If either submits as POST you will see a routing error or an unexpected `create` action. That means the `encodeMethodIntoRequestBody` import path is wrong for the installed turbo-rails version.

- [ ] **Step 7: Run the full suite**

```bash
ps aux | grep "[r]ails test"
bin/rails db:test:prepare test
bundle exec standardrb
```

- [ ] **Step 8: Commit**

```bash
git add web-app/app/javascript/turbo.js web-app/test/lint/turbo_cable_test.rb
git commit -m "Drop ActionCable from every JS bundle

turbo-rails pulls <turbo-cable-stream-source> and ActionCable into every
bundle, but the app broadcasts nothing over a cable: no turbo_stream_from,
no broadcasts_* helper, no app/channels. Imports Turbo core plus the one
Rails piece still needed, encodeMethodIntoRequestBody, and guards the
precondition.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Load Firebase on demand

The Firebase auth SDK is 32.3 KB gzipped, 36% of a minified bundle, and only `authentication_controller` touches it. Anonymous readers — the overwhelming majority of traffic — never need it.

**Files:**
- Create: `web-app/app/javascript/entrypoints/firebase_auth.js`
- Create: `web-app/app/javascript/services/firebase_loader.js`
- Modify: `web-app/config/asset_bundles.json`
- Modify: `web-app/app/javascript/controllers/authentication_controller.js`
- Modify: `web-app/app/components/authentication/widget_component/widget_component.html.erb`
- Modify: `web-app/app/views/layouts/admin.html.erb`

**Interfaces:**
- Consumes: `config/asset_bundles.json` (Task 3); the four auth service default exports, unchanged.
- Produces:
  - `window.__tgFirebase` → `{ firebaseAuthService, googleProvider, emailProvider, redirectHandler }`
  - `firebase_loader.js` exports `loadFirebase(src) → Promise<__tgFirebase>`, `likelySignedIn() → Boolean`, `clearSignedInHint() → void`, `markSignedIn() → void`, `markPendingRedirect() → void`, `clearPendingRedirect() → void`
  - Stimulus value `data-authentication-firebase-src-value`

- [ ] **Step 1: Register the bundle**

Add to `web-app/config/asset_bundles.json`:

```json
{
  "books-web": "app/javascript/entrypoints/books_web.js",
  "music-web": "app/javascript/entrypoints/music_web.js",
  "games-web": "app/javascript/entrypoints/games_web.js",
  "movies-web": "app/javascript/entrypoints/movies_web.js",
  "admin": "app/javascript/entrypoints/admin.js",
  "firebase-auth": "app/javascript/entrypoints/firebase_auth.js"
}
```

- [ ] **Step 2: Create the Firebase entrypoint**

Create `web-app/app/javascript/entrypoints/firebase_auth.js`:

```js
// Loaded on demand by services/firebase_loader.js, never by a layout.
//
// It is a separate rollup entry rather than a dynamic import() because
// Propshaft rewrites only explicit RAILS_ASSET_URL() markers, never ES import
// specifiers: a rollup-generated chunk referenced as ./chunk-abc.js would
// resolve to an undigested /assets/chunk-abc.js and 404 in production. An
// injected <script src> with a Rails-provided asset_path sidesteps that
// entirely.
import firebaseAuthService from "../services/firebase_auth_service"
import googleProvider from "../services/auth_providers/google_provider"
import emailProvider from "../services/auth_providers/email_provider"
import redirectHandler from "../services/auth_handlers/redirect_handler"

window.__tgFirebase = { firebaseAuthService, googleProvider, emailProvider, redirectHandler }
```

- [ ] **Step 3: Create the loader**

Create `web-app/app/javascript/services/firebase_loader.js`:

```js
// Memoised at MODULE scope, not per controller instance. Turbo caches the
// mutated DOM and re-runs connect() on restore, so an instance-level promise
// would inject the script again on every Back navigation.
let loadPromise = null

const SIGNED_IN_KEY = "tg:auth:signed-in"
const PENDING_REDIRECT_KEY = "tg:auth:pending-redirect"

export function loadFirebase(src) {
  if (loadPromise) return loadPromise

  loadPromise = new Promise((resolve, reject) => {
    if (window.__tgFirebase) {
      resolve(window.__tgFirebase)
      return
    }

    if (!src) {
      reject(new Error("firebase bundle src is missing; is data-authentication-firebase-src-value set?"))
      return
    }

    const script = document.createElement("script")
    script.src = src
    script.async = true

    script.onload = () => {
      if (window.__tgFirebase) {
        resolve(window.__tgFirebase)
      } else {
        reject(new Error("firebase bundle loaded but window.__tgFirebase is undefined"))
      }
    }

    script.onerror = () => {
      // Reset so a later attempt can retry -- e.g. the reader clicks Login
      // again after a transient network failure. Caching the rejection forever
      // would make one dropped request permanently break sign-in for the tab.
      loadPromise = null
      reject(new Error(`failed to load firebase bundle from ${src}`))
    }

    document.head.appendChild(script)
  })

  return loadPromise
}

// Any hint that this browser has a signed-in user, or is mid sign-in.
//
// The signals fail in opposite directions, so the union is safer than either:
//   - tg_uid is a SESSION cookie, server-managed and authoritative, but it dies
//     on browser restart while Firebase's IndexedDB persistence survives.
//   - the localStorage flag survives restarts but is a client mirror that can
//     drift (a sign-out in another tab does not clear it in tabs that never
//     loaded Firebase).
//
// A false positive is cheap: load Firebase, get a null user, clear the flag,
// render Login. A false negative shows "Login" to a signed-in reader, which is
// the visible regression this exists to avoid. So: any hint wins.
export function likelySignedIn() {
  if (/(?:^|;\s*)tg_uid=/.test(document.cookie)) return true

  try {
    if (window.localStorage.getItem(SIGNED_IN_KEY)) return true
  } catch {
    // Storage blocked (private mode, site data disabled) -- fall through.
  }

  return pendingRedirect()
}

// True while a signInWithRedirect round trip is outstanding, so connect() knows
// to load Firebase eagerly and let getRedirectResult complete.
//
// Also matches Firebase's own sessionStorage key as belt-and-braces: if our
// write failed, theirs probably did too, but the flow is worth two chances.
export function pendingRedirect() {
  try {
    if (window.sessionStorage.getItem(PENDING_REDIRECT_KEY)) return true

    for (let i = 0; i < window.sessionStorage.length; i++) {
      if (window.sessionStorage.key(i)?.startsWith("firebase:pendingRedirect")) return true
    }
  } catch {
    // Storage blocked -- fall through.
  }

  return false
}

export function markSignedIn() {
  try { window.localStorage.setItem(SIGNED_IN_KEY, "1") } catch { /* storage blocked */ }
}

export function clearSignedInHint() {
  try { window.localStorage.removeItem(SIGNED_IN_KEY) } catch { /* storage blocked */ }
}

export function markPendingRedirect() {
  try { window.sessionStorage.setItem(PENDING_REDIRECT_KEY, "1") } catch { /* storage blocked */ }
}

export function clearPendingRedirect() {
  try { window.sessionStorage.removeItem(PENDING_REDIRECT_KEY) } catch { /* storage blocked */ }
}
```

- [ ] **Step 4: Convert the authentication controller to async Firebase access**

In `web-app/app/javascript/controllers/authentication_controller.js`:

Replace the four service imports at the top:

```js
import { Controller } from "@hotwired/stimulus"
import firebaseAuthService from "../services/firebase_auth_service"
import googleProvider from "../services/auth_providers/google_provider"
import emailProvider from "../services/auth_providers/email_provider"
import redirectHandler from "../services/auth_handlers/redirect_handler"
```

with:

```js
import { Controller } from "@hotwired/stimulus"
import {
  loadFirebase,
  likelySignedIn,
  markSignedIn,
  clearSignedInHint,
  markPendingRedirect,
  clearPendingRedirect
} from "../services/firebase_loader"
```

Add `firebaseSrc: String` to `static values`:

```js
  static values = {
    reloadAfterAuth: Boolean,
    currentUser: Object,
    firebaseSrc: String
  }
```

Replace `connect()`:

```js
  connect() {
    this.isSignUpMode = false
    this.storedEmail = null
    this.setupEventListeners()

    // Anonymous readers never download the 32 KB Firebase SDK. Anyone with a
    // hint of a session gets it eagerly, so the navbar Login/Logout swap and
    // the post-redirect getRedirectResult still happen on page load.
    if (likelySignedIn()) {
      this.firebase().catch((error) => console.error("Firebase eager load failed:", error))
    } else {
      this.showUnauthenticatedState()
    }
  }
```

Add these two methods immediately after `disconnect()`:

```js
  // The ONLY way this controller reaches Firebase. Never import or reference
  // the service singletons directly: in an async refactor of a controller that
  // used to be entirely synchronous, a missed `await` yields undefined and
  // fails silently. One accessor makes a missed await a visible mistake.
  async firebase() {
    if (!this._firebase) {
      this._firebase = await loadFirebase(this.firebaseSrcValue)
      this._initialiseFirebase(this._firebase)
    }
    return this._firebase
  }

  _initialiseFirebase(firebase) {
    if (this._firebaseInitialised) return
    this._firebaseInitialised = true

    firebase.firebaseAuthService.initialize()
    firebase.redirectHandler.initialize()
    firebase.firebaseAuthService.onAuthStateChanged((user) => {
      this.handleAuthStateChange(user)
    })
  }
```

Replace `handleAuthStateChange` so it maintains the hints:

```js
  handleAuthStateChange(user) {
    // Firebase has now resolved its initial state, including any redirect
    // result, so the redirect is no longer pending either way. Clearing this
    // only on success would leave the flag set forever when a reader cancels
    // the Google flow, forcing an eager load on every later page view.
    clearPendingRedirect()

    if (user) {
      markSignedIn()
      this.showAuthenticatedState(user)
    } else {
      clearSignedInHint()
      this.showUnauthenticatedState()
    }
  }
```

Replace `openModal` so opening the modal is what triggers the download for anonymous readers:

```js
  openModal() {
    this.firebase().catch((error) => console.error("Firebase load failed:", error))

    const modal = document.getElementById('login_modal')
    if (modal) {
      modal.showModal()
    }
  }
```

Replace `signInWithGoogle`:

```js
  async signInWithGoogle(event) {
    event.preventDefault()

    this.showLoading(true)
    this.hideError()
    this.hideInfo()

    try {
      const { googleProvider } = await this.firebase()
      // Set BEFORE the redirect leaves the page: on return, connect() sees this
      // and eager-loads Firebase so getRedirectResult can run.
      markPendingRedirect()
      await googleProvider.signIn(event)
    } catch (error) {
      console.error("Google sign in error:", error)
      clearPendingRedirect()
      this.showError(error.message)
      this.showLoading(false)
    }
  }
```

Replace the body of `submitEmailForm`'s `try`/`catch` to resolve the provider first:

```js
    try {
      const { emailProvider } = await this.firebase()

      if (this.isSignUpMode) {
        await emailProvider.signUp(email, password)
        this.showInfo('Check your email to verify your account.')
      } else {
        await emailProvider.signIn(email, password)
      }
    } catch (error) {
      console.error("Email auth error:", error)
      if (!this.isSignUpMode && (error.code === 'auth/invalid-credential' || error.code === 'auth/wrong-password' || error.code === 'auth/user-not-found')) {
        await this.checkProviderConflict(email, error)
      } else {
        const { emailProvider } = await this.firebase()
        this.showError(emailProvider.getUserFriendlyMessage(error))
      }
    } finally {
      this.showLoading(false)
    }
```

Replace `submitForgotPassword`'s `try`:

```js
    try {
      const { emailProvider } = await this.firebase()
      await emailProvider.sendPasswordReset(email)
      this.showInfo('If an account exists with this email, a password reset link has been sent.')
    } catch {
      // Show the same message regardless of error (security: don't reveal if
      // the email exists).
      this.showInfo('If an account exists with this email, a password reset link has been sent.')
    } finally {
      this.showLoading(false)
    }
```

Replace `resendVerification`'s `try`:

```js
    try {
      const { emailProvider } = await this.firebase()
      await emailProvider.resendVerification()
      this.showInfo('Verification email sent. Check your inbox.')
    } catch (error) {
      console.error("Resend verification error:", error)
      this.showError('Failed to send verification email. Please try again later.')
    }
```

Replace `signOut`'s `try` opening so it resolves the service:

```js
    try {
      const { firebaseAuthService } = await this.firebase()
      await firebaseAuthService.signOut()
      clearSignedInHint()

      const response = await fetch('/auth/sign_out', {
```

(the remainder of `signOut` is unchanged.)

- [ ] **Step 5: Pass the bundle URL from Rails**

In `web-app/app/components/authentication/widget_component/widget_component.html.erb`, change the root element's opening tag from:

```erb
<div class="<%= container_classes %>"
     data-controller="authentication"
     data-authentication-reload-after-auth-value="<%= reload_after_auth_data %>"
     data-reload-after-auth="<%= reload_after_auth_data %>">
```

to:

```erb
<div class="<%= container_classes %>"
     data-controller="authentication"
     data-authentication-reload-after-auth-value="<%= reload_after_auth_data %>"
     data-authentication-firebase-src-value="<%= asset_path("firebase-auth.js") %>"
     data-reload-after-auth="<%= reload_after_auth_data %>">
```

In `web-app/app/views/layouts/admin.html.erb`, change:

```erb
<body class="bg-base-200" data-controller="authentication">
```

to:

```erb
<body class="bg-base-200"
      data-controller="authentication"
      data-authentication-firebase-src-value="<%= asset_path("firebase-auth.js") %>">
```

- [ ] **Step 6: Build and measure**

```bash
cd web-app && yarn build
for f in app/assets/builds/*-web.js app/assets/builds/admin.js app/assets/builds/firebase-auth.js; do
  printf "%-22s gzip %7d\n" "$(basename $f)" "$(gzip -9 -c $f | wc -c)"
done
grep -c "firebase" app/assets/builds/books-web.js || echo "0 (Firebase gone from web bundle)"
```

Expected: `*-web.js` around **49 KB gzipped**, `firebase-auth.js` around **32 KB**, and the grep on `books-web.js` reports 0.

- [ ] **Step 7: Run the full suite**

```bash
ps aux | grep "[r]ails test"
bin/rails db:test:prepare test
bundle exec standardrb
```

Expected: 0 failures, 0 errors. Component tests for the auth widget assert behavior, not markup, so the added data attribute should not move any assertion. If a component test fails on markup, report it rather than loosening the test — it may be asserting on copy it should not be.

- [ ] **Step 8: Commit**

```bash
git add web-app/app/javascript web-app/config/asset_bundles.json web-app/app/components/authentication web-app/app/views/layouts/admin.html.erb
git commit -m "Load the Firebase auth SDK on demand

Firebase is 32 KB gzipped -- 36% of a minified bundle -- and only the
authentication controller touches it, but it booted on every page load for
every reader. It is now its own bundle, injected when a reader opens the
login modal, and eager-loaded when tg_uid, a persisted sign-in hint, or a
pending redirect says this browser has a session.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Verify the auth flows end to end and record the result

The existing Playwright auth setups are the primary regression detector: `e2e/auth/*.setup.ts` clicks Login with **no prior session**, which is exactly the lazy path, and `storageState` then captures `tg_uid` so every subsequent spec runs the eager path. If lazy loading is broken, every admin spec on every domain fails at setup.

CI does not run Playwright, so this task is a mandatory local gate.

**Files:**
- Create: `web-app/e2e/tests/books/firebase-lazy-load.spec.ts`
- Modify: `docs/superpowers/specs/2026-08-24-asset-bundle-split-design.md` (record measured results)

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Start a clean local server**

```bash
cd web-app && yarn build:all
lsof -i :3000    # confirm nothing else is serving -- another worktree may be
bin/rails server
```

If the e2e admin user has lost its role (every admin spec times out on the public homepage), run `bin/rails e2e:admin`.

- [ ] **Step 2: Write the lazy-load spec**

Create `web-app/e2e/tests/books/firebase-lazy-load.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

// Guards the two halves of on-demand Firebase loading. Both are invisible to
// the Rails suite: nothing server-side knows which script tags the browser
// ended up fetching.
test.describe('Firebase loads on demand', () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test('an anonymous reader does not download the Firebase bundle', async ({ page }) => {
    const firebaseRequests: string[] = [];
    page.on('request', (request) => {
      if (request.url().includes('firebase-auth')) firebaseRequests.push(request.url());
    });

    await page.goto('/');
    await page.waitForLoadState('networkidle');

    expect(firebaseRequests).toHaveLength(0);
  });

  test('opening the login modal downloads the Firebase bundle', async ({ page }) => {
    await page.goto('/');
    await page.waitForLoadState('networkidle');

    const firebaseResponse = page.waitForResponse((response) =>
      response.url().includes('firebase-auth') && response.status() === 200
    );

    await page.getByRole('button', { name: 'Login' }).click();

    await firebaseResponse;
    await expect(page.locator('#login_modal')).toBeVisible();
  });
});
```

- [ ] **Step 3: Run the new spec**

```bash
cd web-app && npx playwright test --config=e2e/playwright.config.ts e2e/tests/books/firebase-lazy-load.spec.ts
```

Expected: both pass.

If the first fails, something on the page calls `firebase()` unconditionally — check that `connect()` only calls it inside the `likelySignedIn()` branch.

- [ ] **Step 4: Run the whole E2E suite**

```bash
cd web-app && yarn test:e2e
```

Expected: all specs pass across books, music and games. The auth setups passing is the meaningful signal — they exercise the lazy path against a real Firebase project.

- [ ] **Step 5: Manually verify the Google redirect round trip**

Playwright cannot drive Google's consent screen, so this one is by hand. On `dev-new.thegreatestbooks.org`:

1. Sign out fully and clear site data.
2. Open the login modal, click **Sign in with Google**, complete consent.
3. On return, confirm the navbar shows **Logout** — this is `getRedirectResult` completing, which only happens if `markPendingRedirect` survived the round trip and `connect()` eager-loaded.
4. Reload the page. Confirm the navbar still shows Logout (the `tg_uid` / localStorage eager path).
5. Close the browser entirely, reopen, and visit the site. Confirm the navbar still shows Logout — this is the localStorage hint doing the job `tg_uid` cannot, since `tg_uid` is a session cookie.
6. Sign out. Confirm the navbar shows Login, and that reloading does **not** download `firebase-auth.js` (Network tab).

Step 5 is the one that would regress if the localStorage hint were dropped in favour of `tg_uid` alone. Do not skip it.

- [ ] **Step 6: Verify email/password sign-in and password reset**

Still by hand, on the same domain:

1. Sign in with email and password — confirm it works and the navbar updates.
2. Open the modal, enter an email, click **Forgot password** and submit — confirm the confirmation message appears.
3. On `/admin`, confirm the page loads and sign-out redirects to `/`.

- [ ] **Step 7: Record the measured sizes in the spec**

Append to the Measurements section of `docs/superpowers/specs/2026-08-24-asset-bundle-split-design.md`, replacing the bracketed values with the numbers you recorded:

```markdown
### Measured result

Actual gzipped transfer per public page, measured after implementation:

| Bundle | gzip |
|---|---|
| `books-web.js` | [measured] |
| `music-web.js` | [measured] |
| `games-web.js` | [measured] |
| `admin.js` | [measured] |
| `firebase-auth.js` (on demand only) | [measured] |

Before: 183,913 bytes gzipped on every page of every site.
```

- [ ] **Step 8: Full suite, linter, and commit**

```bash
ps aux | grep "[r]ails test"
bin/rails db:test:prepare test
bundle exec standardrb
```

```bash
git add web-app/e2e/tests/books/firebase-lazy-load.spec.ts docs/superpowers/specs/2026-08-24-asset-bundle-split-design.md
git commit -m "Add lazy-load E2E coverage and record measured bundle sizes

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Out of scope

- **Splitting CSS into web/admin variants.** Measured at 1.75 KB gzipped saving for double the CSS build matrix.
- **Deduplicating the `tg_uid` cookie regex.** Four controllers each carry their own three-line copy and Task 7 adds a fifth. Extracting a shared module used by one of five call sites would be worse than the duplication; extracting it for all five is a separate change with its own test surface.
- **The accumulating `onAuthStateChanged` listener.** `firebaseAuthService.onAuthStateChanged` pushes into an array that `disconnect()` never unwinds, so Turbo restores accumulate listeners. This is pre-existing behavior, unchanged by this work, and fixing it means touching the auth service's lifecycle.
- **Client-side Markdown preview for admin news posts.** `admin/news_posts_base_controller.rb:116` rules it out "while admin and public share application.js". That constraint lifts here, but the comment gives a second, better reason to keep the preview server-rendered — it cannot drift from `BodyRenderer`. Leave it alone.

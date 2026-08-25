import fs from "node:fs"
import path from "node:path"
import resolve from "@rollup/plugin-node-resolve"
import commonjs from "@rollup/plugin-commonjs"
import terser from "@rollup/plugin-terser"

// Single source of truth, shared with Ruby. See
// test/lint/asset_bundle_coverage_test.rb for why this list is not duplicated.
// Read relative to the process working directory: yarn runs scripts from
// web-app/, which is also where this config lives.
const BUNDLES = JSON.parse(fs.readFileSync("config/asset_bundles.json", "utf8"))

// turbo-rails' package.json "exports" map lists only ".", so a deep import of
// its fetch_requests module (see app/javascript/turbo.js, and the comment
// there on why that module is needed at all) is invisible to Node/Rollup's
// package-exports resolution -- @rollup/plugin-node-resolve enforces that map
// the same way Node itself would, and there is no option to relax it for one
// subpath. Left alone, the unresolved specifier does NOT fail the build: it
// falls back to an external with a guessed global, and the shipped bundle
// throws a ReferenceError the instant it runs in a browser. This hook
// resolves that one path directly against the installed package's files,
// ahead of the general resolver below, so the import genuinely works rather
// than merely failing to warn.
//
// This hook and the import in app/javascript/turbo.js must be upgraded
// together -- RE-VERIFY THIS PATH ON EVERY turbo-rails UPGRADE. Note what
// actually happens if it goes stale: this hook returns the path below
// UNCONDITIONALLY, with no existence check, so a moved file does not surface
// as the UNRESOLVED_IMPORT the onwarn hook below is watching for. Instead
// @rollup/plugin-commonjs tries to read the (now wrong) path this hook
// handed it and throws "(plugin commonjs--resolver) ... ENOENT: no such file
// or directory" -- still a hard build failure, just under a different error
// banner than onwarn's comment would suggest.
const TURBO_RAILS_FETCH_REQUESTS = "@hotwired/turbo-rails/app/javascript/turbo/fetch_requests"

const resolveTurboRailsFetchRequests = {
  name: "resolve-turbo-rails-fetch-requests",
  resolveId(source) {
    if (source === TURBO_RAILS_FETCH_REQUESTS) {
      return path.resolve("node_modules/@hotwired/turbo-rails/app/javascript/turbo/fetch_requests.js")
    }
  }
}

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
  plugins: [resolveTurboRailsFetchRequests, resolve(), commonjs(), terser()],
  // Rollup's default for an import nothing can resolve is to warn and treat
  // it as an external -- not to fail the build. That silently ships broken
  // JS (see resolveTurboRailsFetchRequests above), so any UNRESOLVED_IMPORT
  // is promoted to a thrown error here; every other warning still just warns.
  // (This does NOT catch every way the turbo-rails deep import can break --
  // see resolveTurboRailsFetchRequests above for the ENOENT case.)
  onwarn(warning, warn) {
    if (warning.code === "UNRESOLVED_IMPORT") {
      throw new Error(warning.message)
    }
    warn(warning)
  }
}))

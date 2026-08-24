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

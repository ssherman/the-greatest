# frozen_string_literal: true

require "test_helper"

# The Firebase SDK (~32 KB gzipped) must build into its own bundle, from its
# own Rollup entry point (app/javascript/entrypoints/firebase_auth.js), and
# nowhere else. It is injected at runtime by
# app/javascript/services/firebase_loader.js, and authentication_controller.js
# reaches it only through its `this.firebase()` accessor -- never a static
# import.
#
# That convention has already been broken once, silently: a reviewer followed
# a stale doc instruction and added one static import of firebase_auth_service
# into authentication_controller.js. books-web.js went from 50,211 to 81,925
# bytes gzipped -- the whole Firebase SDK back in every public bundle -- with
# the entire test suite green and both lazy-load E2E assertions still passing.
# Nothing else in the repo would have caught it.
#
# Rollup writes a `sources` array into each app/assets/builds/*.js.map listing
# every module that contributed bytes to that bundle. That is the signal this
# test checks: far more reliable than grepping minified/terser'd output for a
# string that could be mangled or inlined away.
class FirebaseBundleIsolationTest < ActiveSupport::TestCase
  FIREBASE_BUNDLE = "firebase-auth"

  # Matches node_modules/@firebase/... and node_modules/firebase/... (the
  # umbrella "firebase" package re-exports the scoped @firebase/* packages).
  # Deliberately node_modules-only: it must not match this app's own
  # app/javascript/services/firebase_*.js or entrypoints/firebase_auth.js,
  # which every bundle's map legitimately lists as the caller/loader.
  FIREBASE_SOURCE = %r{node_modules/(?:@firebase|firebase)/}

  test "no web or admin bundle pulls in Firebase SDK source" do
    other_bundles = registry.keys - [FIREBASE_BUNDLE]
    skip_unless_maps_present!(other_bundles)

    offenders = other_bundles.each_with_object({}) do |name, result|
      hits = firebase_sources(name)
      result[name] = hits if hits.any?
    end

    assert_empty offenders,
      "These built bundles include Firebase SDK source in their sourcemap, which " \
      "means the SDK ships to every visitor instead of being loaded on demand by " \
      "firebase_loader.js. A new auth provider belongs in " \
      "app/javascript/entrypoints/firebase_auth.js, reached through " \
      "authentication_controller.js's this.firebase() accessor -- never a static " \
      "import into a controller or service that ships in one of these bundles:\n" \
      "#{offenders.map { |name, sources| "  #{name}: #{sources.join(", ")}" }.join("\n")}"
  end

  test "the firebase-auth bundle actually contains Firebase SDK source" do
    skip_unless_maps_present!([FIREBASE_BUNDLE])

    assert firebase_sources(FIREBASE_BUNDLE).any?,
      "app/assets/builds/#{FIREBASE_BUNDLE}.js.map has no Firebase SDK source in " \
      "it. Either the build is broken, or this test's FIREBASE_SOURCE marker has " \
      "drifted from the real node_modules paths -- check the map's \"sources\" " \
      "array by hand before assuming the isolation this test guards still holds."
  end

  private

  def firebase_sources(name)
    sources(name).grep(FIREBASE_SOURCE)
  end

  def sources(name)
    JSON.parse(File.read(map_path(name)))["sources"]
  end

  def map_path(name)
    Rails.root.join("app/assets/builds/#{name}.js.map")
  end

  # Bundles are gitignored build output. Someone running this file in
  # isolation without building first should get a clear skip, not a confusing
  # Errno::ENOENT -- but once the maps exist, a real isolation failure must
  # fail loudly, not be swallowed.
  def skip_unless_maps_present!(names)
    missing = names.reject { |name| File.exist?(map_path(name)) }
    return if missing.empty?

    skip "Missing built sourcemap(s) for: #{missing.join(", ")}. Run " \
      "`bin/rails db:test:prepare test` (or `yarn build:all`) to build the bundles " \
      "before running this test."
  end

  def registry
    @registry ||= JSON.parse(File.read(Rails.root.join("config/asset_bundles.json")))
  end
end

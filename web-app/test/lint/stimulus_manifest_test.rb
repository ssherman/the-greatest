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

  private

  WEB_MANIFESTS = {
    "books" => "app/javascript/manifests/books_web.js",
    "music" => "app/javascript/manifests/music_web.js",
    "games" => "app/javascript/manifests/games_web.js",
    "movies" => "app/javascript/manifests/movies_web.js"
  }.freeze

  ADMIN_MANIFEST = "app/javascript/manifests/admin.js"

  # Stimulus identifier => sorted list of Rails.root-relative paths referencing it.
  #
  # BOTH idioms must be scanned. Markup reaches Stimulus two ways in this app:
  #
  #   1. the literal HTML attribute -- data-controller="user-list-state membership-state"
  #   2. Rails' tag-builder hash    -- data: { controller: "metadata-editor modal-form" }
  #
  # The second renders to the first at runtime but never appears as that literal
  # string in the source, and it is the DOMINANT idiom in admin views: 47 files
  # reference modal-form that way and none reference it the other. A scanner
  # matching only the attribute form reports those controllers as referenced by
  # nothing -- which is exactly what happened, and three live controllers were
  # deleted on the strength of it before this was caught.
  #
  # Both values are space-separated lists, so both get split. Tokens containing
  # "/" are skipped: a Stimulus identifier never contains one, but
  # url_for(controller: "admin/games") would otherwise register a phantom.
  def referenced_controllers
    @referenced_controllers ||= begin
      result = Hash.new { |hash, key| hash[key] = [] }

      markup_files.each do |relative_path|
        source = File.read(Rails.root.join(relative_path))

        [/\bdata-controller\s*=\s*(["'])(.*?)\1/m, /\bcontroller:\s*(["'])(.*?)\1/m].each do |pattern|
          source.scan(pattern) do |_quote, value|
            value.split(/\s+/).reject { |token| token.empty? || token.include?("/") }
              .each { |identifier| result[identifier] << relative_path }
          end
        end
      end

      result.each_value { |paths| paths.replace(paths.uniq.sort) }
      result
    end
  end

  def registered_controllers
    @registered_controllers ||= registration_files
      .flat_map { |path| manifest_closure(path).to_a }
      .uniq
      .flat_map { |path| manifest_source(path).scan(/application\.register\(\s*["']([^"']+)["']/) }
      .flatten
      .uniq
      .sort
  end

  # Comments are stripped before scanning, everywhere a manifest is scanned for
  # a register call -- registered_controllers above AND registered_in? below.
  # A commented-out `application.register("x", X)` would otherwise still
  # match, so the guard would report a controller as registered while the
  # browser saw nothing -- exactly the silent-breakage class this test exists
  # to catch. Manifests contain only imports and register calls, no string
  # literals holding "//", so stripping line comments here is safe.
  def manifest_source(path)
    File.read(Rails.root.join(path))
      .gsub(%r{/\*.*?\*/}m, "")
      .gsub(%r{^\s*//[^\n]*}, "")
  end

  def registration_files
    WEB_MANIFESTS.values + [ADMIN_MANIFEST]
  end

  def markup_files
    @markup_files ||= Dir.glob(Rails.root.join("{app/views,app/components}/**/*"))
      .select { |path| File.file?(path) }
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .sort
  end

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
      manifest_source(path).match?(/application\.register\(\s*["']#{Regexp.escape(identifier)}["']/)
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
end

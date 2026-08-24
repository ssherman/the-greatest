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

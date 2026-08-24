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

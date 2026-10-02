# frozen_string_literal: true

require "test_helper"

# These controllers put text they do not control into the page: the signed-in
# user's displayName and photoURL (set by the user at their identity provider),
# and an import job's error message. They must build DOM with createElement /
# textContent / setAttribute, never by assigning an HTML string, which would
# parse whatever markup that text contains.
class UntrustedTextDomTest < ActiveSupport::TestCase
  FILES = %w[
    app/javascript/controllers/authentication_controller.js
    app/javascript/controllers/wizard_step_controller.js
  ].freeze

  HTML_STRING_SINK = /\.(?:innerHTML|outerHTML)\s*=(?!=)|insertAdjacentHTML/

  FILES.each do |relative|
    test "#{relative} writes no HTML strings" do
      source = File.read(Rails.root.join(relative))
      offending = source.each_line.with_index(1).select { |line, _| line.match?(HTML_STRING_SINK) }
      assert_empty offending.map { |line, number| "#{relative}:#{number}: #{line.strip}" },
        "build these elements with createElement/textContent/setAttribute instead"
    end
  end
end

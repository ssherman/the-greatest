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

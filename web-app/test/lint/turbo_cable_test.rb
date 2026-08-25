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
    offenders = source_files.select do |relative_path|
      File.read(Rails.root.join(relative_path)).match?(CABLE_MARKERS)
    end

    assert_empty offenders,
      "These files use Turbo's ActionCable broadcast path, but " \
      "app/javascript/turbo.js imports Turbo core WITHOUT the cable stream " \
      "source element, so the broadcast will silently never arrive. Restore " \
      "`import \"@hotwired/turbo-rails\"` in that file (and delete this test's " \
      "premise) if broadcasting is now wanted:\n#{offenders.join("\n")}"
  end

  test "turbo.js keeps the Rails method-override hook" do
    # Comments are stripped before matching -- this file's own header comment
    # talks about encodeMethodIntoRequestBody at length, and (more importantly)
    # commenting out just the addEventListener(...) call below, while leaving
    # the import intact, must NOT still satisfy the assertion. Matching raw
    # source against a bare /encodeMethodIntoRequestBody/, or even the fuller
    # addEventListener pattern below, would still find the identifier inside a
    # `// addEventListener(...)` line and stay green while every PATCH/DELETE
    # form silently downgrades to POST -- exactly the regression this test
    # exists to catch. The assertion must match the actual listener
    # REGISTRATION, live in the code, not merely the identifier's presence
    # somewhere in the file.
    source = File.read(Rails.root.join("app/javascript/turbo.js"))
      .gsub(%r{/\*.*?\*/}m, "")
      .gsub(%r{^\s*//[^\n]*}, "")

    assert_match(
      /addEventListener\(\s*["']turbo:before-fetch-request["']\s*,\s*encodeMethodIntoRequestBody\s*\)/,
      source,
      "app/javascript/turbo.js must call " \
      "addEventListener(\"turbo:before-fetch-request\", encodeMethodIntoRequestBody). " \
      "That listener is the one piece of @hotwired/turbo-rails this app still " \
      "needs: it encodes _method into non-GET form bodies. Without it, " \
      "form_with method: :patch and button_to method: :delete silently submit " \
      "as POST."
    )
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

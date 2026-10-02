# frozen_string_literal: true

require "test_helper"

# Turbo 8 fetches any link hovered for 100ms and caches that FetchRequest
# whatever the response was, then replays it on the click without calling
# window.fetch. app/javascript/services/cloudflare_challenge.js hands a
# Cloudflare-challenged fetch off to a full navigation, but it can only see
# fetches: a click that replays a challenged prefetch never reaches it, Turbo
# renders the challenge page inline, and the challenge page's CSP meta tag then
# takes over the document. So prefetch is switched off in every layout that
# loads Turbo. The Playwright spec covers books; this keeps the other layouts
# honest.
class TurboPrefetchDisabledTest < ActiveSupport::TestCase
  META_TAG = /<meta\s+name="turbo-prefetch"\s+content="false"\s*>/

  test "every layout that loads a JavaScript bundle switches Turbo prefetch off" do
    missing = turbo_layouts.reject { |path| File.read(Rails.root.join(path)).match?(META_TAG) }

    assert_empty missing,
      "These layouts load Turbo but do not disable link prefetch. Add\n" \
      "  <meta name=\"turbo-prefetch\" content=\"false\">\n" \
      "to their <head>; app/javascript/services/cloudflare_challenge.js says why:\n" \
      "#{missing.map { |path| "  #{path}" }.join("\n")}"
  end

  private

  # Every bundle under app/javascript/entrypoints imports Turbo, so every
  # layout that emits a javascript_include_tag runs it and needs the opt-out.
  def turbo_layouts
    Dir.glob(Rails.root.join("app/views/layouts/**/*.erb"))
      .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
      .select { |path| File.read(Rails.root.join(path)).include?("javascript_include_tag") }
      .sort
  end
end

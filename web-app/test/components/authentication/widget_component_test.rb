# frozen_string_literal: true

require "test_helper"

class Authentication::WidgetComponentTest < ViewComponent::TestCase
  test "renders without raising" do
    assert_nothing_raised { render_inline(Authentication::WidgetComponent.new) }
  end

  test "still renders the email form alongside the OAuth buttons" do
    render_inline(Authentication::WidgetComponent.new)

    # The OAuth loop replaced markup that sat directly above this. If the loop
    # ever swallowed the email step, every assertion below would still pass.
    assert_selector "[data-authentication-target='emailStep'] input[type='email']"
    assert_selector "[data-authentication-target='passwordStep']", visible: :all
  end

  test "renders a button for every enabled provider" do
    render_inline(Authentication::WidgetComponent.new)

    Services::AuthProviderRegistry.enabled_for_view.each do |provider|
      selector = "button[data-authentication-provider-param='#{provider[:id]}']"
      # expected exactly one #{provider[:id]} button
      assert_selector selector, count: 1
    end
  end

  test "does not render a button for a disabled provider" do
    render_inline(Authentication::WidgetComponent.new)

    # Apple stays disabled -- Sign in with Apple is not configured (spec D9)
    assert_no_selector "button[data-authentication-provider-param='apple']"
  end

  test "each button carries the generic action and the registry label" do
    render_inline(Authentication::WidgetComponent.new)

    button = page.find("button[data-authentication-provider-param='twitter']")

    assert_includes button["data-action"], "authentication#signInWithOauth"
    # Substring matching is Capybara's default and would pass on "Sign in with
    # Xylophone", so anchor the whole string.
    assert_equal "Sign in with X", button.text.strip
  end

  test "the enabled registry reaches the client as a Stimulus value" do
    render_inline(Authentication::WidgetComponent.new)

    raw = page.find("[data-controller='authentication']")["data-authentication-providers-value"]
    parsed = JSON.parse(raw)

    assert_equal %w[google twitter facebook], parsed.map { |p| p["id"] }

    # Indexed by id rather than position: `parsed.last` used to mean twitter,
    # and enabling Facebook silently moved these assertions onto a different
    # provider instead of failing.
    by_id = parsed.index_by { |p| p["id"] }

    assert_equal "twitter.com", by_id["twitter"]["firebase_id"]
    assert_equal [], by_id["twitter"]["scopes"], "the client needs the scope list to build the provider"
    # Facebook is the only enabled provider with a non-empty scope list, so it
    # is the one that proves scopes survive the trip to the client at all.
    assert_equal "facebook.com", by_id["facebook"]["firebase_id"]
    assert_equal %w[public_profile email], by_id["facebook"]["scopes"]
  end

  test "every registry provider has an icon partial, enabled or not" do
    Services::AuthProviderRegistry.provider_names.each do |id|
      path = Rails.root.join("app/views/shared/auth_icons/_#{id}.html.erb")
      assert File.exist?(path),
        "#{id} is in the registry but has no icon partial at #{path}. " \
        "Enabling it would then be more than a one-word change."
    end
  end
end

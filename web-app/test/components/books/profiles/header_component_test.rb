# frozen_string_literal: true

require "test_helper"

class Books::Profiles::HeaderComponentTest < ViewComponent::TestCase
  def header(name:)
    Services::Books::Profiles::Build::Header.new(name: name, member_since_year: 2019)
  end

  test "shows the name, its initial and the member-since year" do
    render_inline Books::Profiles::HeaderComponent.new(header: header(name: "ada Lovelace"), audience: :owner)

    assert_selector "h1", text: "ada Lovelace"
    assert_selector "[data-testid='profile-avatar']", text: "A"
    assert_text "Member since 2019"
  end

  test "owner without a name gets a generic heading and an icon, not an initial" do
    render_inline Books::Profiles::HeaderComponent.new(header: header(name: nil), audience: :owner)

    assert_selector "h1", text: "Your profile"
    assert_selector "[data-testid='profile-avatar'] svg"
  end

  test "public header never says Your profile" do
    render_inline Books::Profiles::HeaderComponent.new(header: header(name: nil), audience: :public)

    assert_no_text "Your profile"
  end

  test "the owner's own page shows the privacy status and share settings; nobody else does" do
    header = Services::Books::Profiles::Build::Header.new(name: "Al", member_since_year: 2020)

    render_inline Books::Profiles::HeaderComponent.new(header: header, audience: :owner, profile: books_profiles(:public_profile))
    assert_selector "[data-testid='profile-status']", text: "Public"
    assert_link "Share settings", href: "/my/profile/settings"

    render_inline Books::Profiles::HeaderComponent.new(header: header, audience: :owner, profile: books_profiles(:private_profile))
    assert_selector "[data-testid='profile-status']", text: "Private"

    render_inline Books::Profiles::HeaderComponent.new(header: header, audience: :public, profile: books_profiles(:public_profile))
    assert_no_selector "[data-testid='profile-sharing']"
  end
end

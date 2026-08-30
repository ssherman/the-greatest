# frozen_string_literal: true

require "test_helper"

class FooterComponentTest < ViewComponent::TestCase
  DOMAINS = [:books, :music, :games].freeze

  def render_footer(domain)
    render_inline(FooterComponent.new(domain: domain))
  end

  DOMAINS.each do |domain|
    test "#{domain} footer links to the policy pages" do
      render_footer(domain)

      assert_selector "a[href='/privacy_policy']", text: "Privacy Policy"
      assert_selector "a[href='/deletion_policy']", text: "Deletion Policy"
    end

    test "#{domain} footer links to news and support" do
      render_footer(domain)

      assert_selector "a[href='/news']", text: "News"
      assert_selector "a[href='/membership']", text: "Support"
    end

    # The year is computed, not typed: the music and games footers this replaces
    # both said 2025, hardcoded, and had been wrong since January.
    test "#{domain} footer credits the company and the current year" do
      render_footer(domain)

      assert_selector "footer", text: /Copyright . #{Time.current.year}\b/
      assert_selector "footer", text: /The Greatest LLC/
    end

    # A link with no destination, or one pointing at "#", is the failure mode of
    # a footer assembled from a table of route helpers: a typo'd or nil path
    # renders as a link that looks fine and goes nowhere.
    test "#{domain} footer has no link without a real destination" do
      render_footer(domain)

      hrefs = page.native.css("a").map { |a| a["href"] }

      assert_predicate hrefs.length, :positive?, "rendered no links at all"
      assert_empty hrefs.select { |href| href.nil? || href.empty? || href == "#" }
    end

    test "#{domain} footer links to the contact address" do
      render_footer(domain)

      assert_selector "a[href='mailto:#{SiteContact::ADDRESS}']", text: "Contact"
    end
  end

  test "books footer links to the books browse pages" do
    render_footer(:books)

    assert_selector "a[href='/authors']", text: "Authors"
    assert_selector "a[href='/genres']", text: "Genres"
    assert_selector "a[href='/countries']", text: "Origins"
    assert_selector "a[href='/lists']", text: "Lists"
  end

  test "music footer links to the music browse pages" do
    render_footer(:music)

    assert_selector "a[href='/albums']", text: "Albums"
    assert_selector "a[href='/songs']", text: "Songs"
    assert_selector "a[href='/artists']", text: "Artists"
    assert_selector "a[href='/lists']", text: "Lists"
  end

  test "games footer links to the games browse pages" do
    render_footer(:games)

    assert_selector "a[href='/']", text: "Games"
    assert_selector "a[href='/lists']", text: "Lists"
  end

  DOMAINS.each do |domain|
    test "#{domain} footer links to its rankings explainer" do
      render_footer(domain)

      assert_selector "a[href='/rankings']", text: "Ranking Details"
    end
  end

  # The social accounts are books accounts, so a music or games visitor must not
  # be pointed at them.
  test "books footer links to the books social accounts" do
    render_footer(:books)

    assert_selector "a[href='https://twitter.com/thegreatestbks']"
    assert_selector "a[href='https://discord.gg/8JE9fpMtZp']"
    assert_selector "a[href='https://www.facebook.com/profile.php?id=61555129978566']"
    assert_selector "a[href='https://www.instagram.com/thegreatestbooksever/']"
  end

  [:music, :games].each do |domain|
    test "#{domain} footer carries no social links" do
      render_footer(domain)

      assert_selector "a[href='/news']" # positive control: the footer did render
      assert_no_selector "a[href^='https://twitter.com']"
      assert_no_selector "a[href^='https://discord.gg']"
      assert_no_selector "a[href^='https://www.facebook.com']"
      assert_no_selector "a[href^='https://www.instagram.com']"
    end
  end

  # Every social link is an icon with no visible text, so without an accessible
  # name a screen reader announces four links called "link".
  test "each social link has an accessible name" do
    render_footer(:books)

    page.native.css("a[href^='https://']").each do |link|
      assert_predicate link["aria-label"].to_s, :present?,
        "social link to #{link["href"]} has no aria-label"
    end
  end

  # Exactly one contentinfo landmark. daisyUI's footer examples nest two
  # <footer> elements as siblings, which announces the page as having two
  # footers.
  test "renders a single footer landmark" do
    render_footer(:books)

    assert_selector "footer", count: 1
  end

  # A domain with no entry must fail loudly at render time rather than produce a
  # footer with no links, which looks deliberate.
  test "refuses to render for a domain it has no link set for" do
    assert_raises(KeyError) { render_footer(:nonexistent) }
  end
end

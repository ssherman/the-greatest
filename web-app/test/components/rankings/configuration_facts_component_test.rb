require "test_helper"

module Rankings
  class ConfigurationFactsComponentTest < ViewComponent::TestCase
    setup do
      @configuration = ranking_configurations(:books_global)
    end

    def render_component(configurations:, median_list_counts: nil, median_voter_counts: nil)
      render_inline(ConfigurationFactsComponent.new(
        configurations: configurations,
        median_list_counts: median_list_counts || configurations.index_with { 50 },
        median_voter_counts: median_voter_counts || configurations.index_with { 24 }
      ))
    end

    test "renders the configuration name" do
      render_component(configurations: [@configuration])

      assert_text @configuration.name
    end

    test "renders the exponent and bonus pool, each in its own row" do
      @configuration.update!(exponent: 3.0, bonus_pool_percentage: 4.0)

      render_component(configurations: [@configuration])

      exponent_row = page.find("tr", text: "Position bonus curve")
      assert_text(exponent_row, "3.0")

      bonus_pool_row = page.find("tr", text: "Bonus pool")
      assert_text(bonus_pool_row, "4.0")
    end

    test "reports the weight floor as zero rather than the stored minimum when the minimum is negative" do
      @configuration.update!(min_list_weight: -50)

      render_component(configurations: [@configuration])

      assert_no_text "-50"
      floor_row = page.find("tr", text: "Lowest possible weight")
      assert_text(floor_row, "0")
    end

    test "reports the weight floor as the stored minimum when it is positive" do
      # Music and games configurations carry min_list_weight: 1, and that
      # floor IS reachable (a fully-penalised list floors at 1, not 0) --
      # unlike books' inert -50, this one must be shown, not zeroed out.
      music_config = ranking_configurations(:music_albums_global)
      music_config.update!(min_list_weight: 1)

      render_component(configurations: [music_config])

      floor_row = page.find("tr", text: "Lowest possible weight")
      assert_text(floor_row, "1")
    end

    test "renders each configuration's own typical list length" do
      books = ranking_configurations(:books_global)
      albums = ranking_configurations(:music_albums_global)

      render_component(
        configurations: [books, albums],
        median_list_counts: {books => 100, albums => 275}
      )

      length_row = page.find("tr", text: "Typical list length")
      assert_text(length_row, "100")
      assert_text(length_row, "275")
    end

    test "renders each configuration's own typical voter count, without querying" do
      # median_voter_counts is passed in already computed -- the component
      # must render it rather than calling configuration.median_voter_count
      # itself, which is what made this a query-issuing component before.
      @configuration.expects(:median_voter_count).never

      render_component(configurations: [@configuration], median_voter_counts: {@configuration => 24})

      voters_row = page.find("tr", text: "Typical voters per list")
      assert_text(voters_row, "24")
    end

    test "renders 'not recorded' when the voter count is nil" do
      render_component(configurations: [@configuration], median_voter_counts: {@configuration => nil})

      voters_row = page.find("tr", text: "Typical voters per list")
      assert_text(voters_row, "not recorded")
    end
  end
end

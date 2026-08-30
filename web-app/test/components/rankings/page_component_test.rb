require "test_helper"

module Rankings
  class PageComponentTest < ViewComponent::TestCase
    setup do
      @data = Services::RankingConfiguration::ExplainerData.call(
        configurations: [ranking_configurations(:books_global)]
      ).data
    end

    test "renders the main heading" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_selector "h1", text: "How Our Rankings Work"
    end

    test "links to both open source repositories" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_selector "a[href='https://github.com/ssherman/weighted_list_rank']"
      assert_selector "a[href='https://github.com/ssherman/the-greatest/']"
    end

    test "describes the recency adjustment as hitting recent items, not old ones" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_text(/same year/i)
      assert_no_text(/classic .{0,40}unfairly penalized/i)
    end

    test "books renders the western tilt section" do
      render_inline(PageComponent.new(data: @data, domain: :books))

      assert_text(/western/i)
      assert_selector "a[href='/global-canon']"
    end

    test "music does not render the western tilt section" do
      music = Services::RankingConfiguration::ExplainerData.call(
        configurations: [ranking_configurations(:music_albums_global)]
      ).data

      render_inline(PageComponent.new(data: music, domain: :music))

      assert_no_selector "a[href='/global-canon']"
    end

    test "renders the live stat counts" do
      # Under the shared fixtures, active_lists_count is 0 for books_global (the
      # books_ranked_list fixture's list is not active-status), which would make
      # assert_text number_with_delimiter(0) a vacuous substring match against
      # any "0" on the page. Build enough ACTIVE ranked lists here that the
      # count is a distinctive, non-zero number instead -- following the same
      # approach explainer_data_test.rb uses for the same underlying problem.
      create_active_ranked_lists(count: 11)

      data = Services::RankingConfiguration::ExplainerData.call(
        configurations: [ranking_configurations(:books_global)]
      ).data
      assert_equal 11, data.active_lists_count

      render_inline(PageComponent.new(data: data, domain: :books))

      # ViewComponent::TestCase does not mix in ActionView's number helpers, so
      # number_with_delimiter (as used in the component template) is not
      # available here; ActiveSupport::NumberHelper is the same formatting
      # logic without the view context dependency.
      #
      # Scoped to .stat-value rather than a bare assert_text: the same count
      # is also echoed in the "consensus" bullet and (on books) the western-tilt
      # prose, so an unscoped assert_text stays green even with the stat tile
      # deleted -- it would just be matching one of those other occurrences.
      formatted = ActiveSupport::NumberHelper.number_to_delimited(data.active_lists_count)
      assert_selector ".stat-value", text: formatted, exact_text: true
    end

    private

    def create_active_ranked_lists(count:)
      count.times do |n|
        list = ::Books::List.create!(name: "Stat Count Padding List #{n}", status: :active)
        ::RankedList.create!(list: list, ranking_configuration: ranking_configurations(:books_global), weight: 50)
      end
    end
  end
end

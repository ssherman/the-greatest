require "test_helper"

module Books
  class CalculateAuthorRankingsJobTest < ActiveSupport::TestCase
    setup do
      @config = ranking_configurations(:books_authors_global)
    end

    test "calculates rankings for the primary author configuration" do
      Books::Authors::RankingConfiguration.any_instance
        .expects(:calculate_rankings)
        .returns(ItemRankings::Calculator::Result.new(success?: true, data: [], errors: []))

      Books::CalculateAuthorRankingsJob.new.perform
    end

    test "raises when the calculation fails" do
      Books::Authors::RankingConfiguration.any_instance
        .expects(:calculate_rankings)
        .returns(ItemRankings::Calculator::Result.new(success?: false, data: nil, errors: ["boom"]))

      assert_raises(RuntimeError) { Books::CalculateAuthorRankingsJob.new.perform }
    end

    test "raises when there is no primary author configuration" do
      @config.update!(primary: false)

      assert_raises(RuntimeError) { Books::CalculateAuthorRankingsJob.new.perform }
    end
  end
end

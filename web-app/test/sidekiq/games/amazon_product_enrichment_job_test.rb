# frozen_string_literal: true

require "test_helper"

class Games::AmazonProductEnrichmentJobTest < ActiveSupport::TestCase
  def setup
    @game = games_games(:breath_of_the_wild)
  end

  test "perform calls AmazonProductService with game" do
    ::Services::Games::AmazonProductService.expects(:call).with(game: @game).returns(
      {success: true, data: "Enrichment completed"}
    )

    Games::AmazonProductEnrichmentJob.new.perform(@game.id)
  end

  test "perform handles service failure gracefully" do
    ::Services::Games::AmazonProductService.expects(:call).with(game: @game).returns(
      {success: false, error: "API error"}
    )

    # Should not raise
    Games::AmazonProductEnrichmentJob.new.perform(@game.id)
  end
end

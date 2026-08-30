class Books::DefaultController < ApplicationController
  include Cacheable

  layout "books/application"

  before_action :cache_for_index_page, only: [:rankings]

  # A real list, pinned so the worked example's surrounding copy can name its
  # numbers. ExplainerData falls back to the heaviest active list if this one is
  # ever archived, so the page cannot break on a data change.
  EXAMPLE_LIST_ID = 43

  def rankings
    result = Services::RankingConfiguration::ExplainerData.call(
      configurations: [Books::RankingConfiguration.default_primary],
      example_list_id: EXAMPLE_LIST_ID
    )

    raise ActiveRecord::RecordNotFound, result.errors.join(", ") unless result.success?

    @data = result.data
  end
end

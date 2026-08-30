class Games::DefaultController < ApplicationController
  include Cacheable

  layout "games/application"

  before_action :cache_for_index_page, only: [:rankings]

  def index
  end

  EXAMPLE_LIST_ID = 11_376

  def rankings
    result = Services::RankingConfiguration::ExplainerData.call(
      configurations: [Games::RankingConfiguration.default_primary],
      example_list_id: EXAMPLE_LIST_ID
    )

    raise ActiveRecord::RecordNotFound, result.errors.join(", ") unless result.success?

    @data = result.data
  end
end

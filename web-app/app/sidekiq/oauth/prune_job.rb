module Oauth
  # Daily sweep of the OAuth tables; see Services::Oauth::Pruner for what goes.
  class PruneJob
    include Sidekiq::Job

    def perform
      counts = Services::Oauth::Pruner.call.data
      Rails.logger.info(
        "event=oauth_prune applications=#{counts[:applications]} grants=#{counts[:grants]} tokens=#{counts[:tokens]}"
      )
    end
  end
end

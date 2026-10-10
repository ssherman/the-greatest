# frozen_string_literal: true

module Recommendations
  # The store keys the export, the trainer and the loader agree on (spec 2
  # §2). The Python side has the same five in recommender/store.py; change
  # both or neither.
  module Paths
    module_function

    def interactions(domain, name)
      "recommendations/#{domain}/interactions/#{safe(name)}.csv.gz"
    end

    def interactions_latest(domain)
      "recommendations/#{domain}/interactions/latest"
    end

    def model(domain, version)
      "recommendations/#{domain}/model/#{safe(version)}.csv.gz"
    end

    def model_manifest(domain, version)
      "recommendations/#{domain}/model/#{safe(version)}.json"
    end

    def model_latest(domain)
      "recommendations/#{domain}/model/latest"
    end

    def safe(name)
      name = name.to_s
      raise ArgumentError, "invalid store name #{name.inspect}" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) && !name.include?("..")

      name
    end
  end
end

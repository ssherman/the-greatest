# frozen_string_literal: true

module Recommendations
  module Config
    def self.resolve(overrides = {})
      Rails.application.config.x.recommendations.merge(overrides || {})
    end
  end
end

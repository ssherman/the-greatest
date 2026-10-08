# frozen_string_literal: true

module Recommendations
  module Config
    # Defaults from the initializer with overrides applied. Override keys are
    # symbolized, and a key the initializer does not define raises: a misspelled
    # knob must fail loudly, not leave the default in place.
    def self.resolve(overrides = {})
      defaults = Rails.application.config.x.recommendations
      overrides = (overrides || {}).to_h.symbolize_keys
      unknown = overrides.keys - defaults.keys
      raise ArgumentError, "Unknown recommendation config key(s): #{unknown.join(", ")}" if unknown.any?

      defaults.merge(overrides)
    end
  end
end

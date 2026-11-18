# frozen_string_literal: true

module Books
  module PublisherIntake
    # The registry of publisher strategies, by key.
    module Sources
      REGISTRY = {
        "hachette_us" => Sources::HachetteUs
      }.freeze

      def self.registry = REGISTRY

      def self.fetch(key)
        registry[key.to_s]&.new
      end

      # Instances for the enabled keys that are registered, in settings order.
      # An unknown key is logged and skipped, so a typo never stops the run.
      def self.enabled
        ::Books::PublisherIntake.settings.enabled_sources.filter_map do |key|
          instance = fetch(key)
          Rails.logger.warn("PublisherIntake: enabled source #{key.inspect} is not registered; skipped") if instance.nil?
          instance
        end
      end
    end
  end
end

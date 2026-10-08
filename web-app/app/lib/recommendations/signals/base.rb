# frozen_string_literal: true

module Recommendations
  module Signals
    # The contract every candidate source honours (spec §5.3). Signals never see
    # each other; fusion is the only place their lists meet.
    class Base
      attr_reader :adapter, :config

      def initialize(adapter:, config:)
        @adapter = adapter
        @config = config
      end

      def name
        self.class.name.demodulize.underscore.to_sym
      end

      def available?
        true
      end

      def weight(_positive_count)
        raise NotImplementedError
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        raise NotImplementedError
      end
    end
  end
end

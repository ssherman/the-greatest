# frozen_string_literal: true

module Recommendations
  module Signals
    # Readers-like-you. Spec 2 fills this in from the home-server model tables;
    # until then it is unavailable and contributes nothing. The weight ramp is
    # defined here already so fusion needs no change when it arrives.
    class Collaborative < Base
      def available?
        false
      end

      def weight(positive_count)
        n = positive_count.to_f
        n / (n + config[:collaborative_half_point])
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        []
      end
    end
  end
end

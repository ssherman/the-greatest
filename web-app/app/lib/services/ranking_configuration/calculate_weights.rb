module Services
  module RankingConfiguration
    class CalculateWeights
      def self.call(ranking_configuration)
        new(ranking_configuration).call
      end

      def initialize(ranking_configuration)
        @ranking_configuration = ranking_configuration
      end

      def call
        calculator = Rankings::BulkWeightCalculator.new(@ranking_configuration)
        results = calculator.call

        if results[:errors].any?
          failure("Weight calculation completed with #{results[:errors].count} errors. #{results[:updated]} weights updated out of #{results[:processed]} processed.")
        else
          success("Successfully calculated weights for #{results[:updated]} ranked lists out of #{results[:processed]} processed.")
        end
      end

      private

      def success(message)
        {success: true, message: message}
      end

      def failure(message)
        {success: false, error: message}
      end
    end
  end
end

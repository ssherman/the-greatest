# frozen_string_literal: true

module Rankings
  class WeightCalculator
    # Factory method to get the appropriate calculator version
    def self.for_version(version)
      case version
      when 1
        WeightCalculatorV1
      else
        raise ArgumentError, "Unsupported algorithm version: #{version}"
      end
    end

    # Factory method to get calculator for a ranked list based on its configuration
    def self.for_ranked_list(ranked_list)
      version = ranked_list.ranking_configuration.algorithm_version
      calculator_class = for_version(version)
      calculator_class.new(ranked_list)
    end

    attr_reader :ranked_list

    def initialize(ranked_list)
      @ranked_list = ranked_list
    end

    # Main entry point - calculates and saves the weight
    def call
      weight = calculate_weight
      ranked_list.weight = weight
      ranked_list.save!
      weight
    end

    protected

    def list
      @list ||= ranked_list.list
    end

    def ranking_configuration
      @ranking_configuration ||= ranked_list.ranking_configuration
    end

    # Base weight to start calculations from
    def base_weight
      100
    end

    # Minimum weight floor
    def minimum_weight
      ranking_configuration.min_list_weight
    end

    # Abstract method to be implemented by version-specific calculators
    def calculate_weight
      raise NotImplementedError, "Subclasses must implement #calculate_weight"
    end
  end
end

# frozen_string_literal: true

module Recommendations
  # The "your taste" block on the results side panel: the strongest genres,
  # subjects and locations the engine used, each with a bar scaled to the
  # strongest weight of its type, plus the counts that fed the profile.
  class TasteComponent < ViewComponent::Base
    TYPES = [["genre", "Genres", :genres], ["subject", "Subjects", :subjects], ["location", "Places", :locations]].freeze

    def initialize(profile:, names:, max_per_type: 5)
      @profile = profile
      @names = names
      @max_per_type = max_per_type
    end

    # [[testid_type, heading, [[name, percent], ...]], ...] with empty types dropped.
    def groups
      TYPES.filter_map do |key, heading, reader|
        pairs = @profile.public_send(reader).select { |id, _| @names.key?(id) }.first(@max_per_type)
        next if pairs.empty?

        top = pairs.map(&:last).max
        rows = pairs.map { |id, weight| [@names.fetch(id), ((weight / top) * 100).round] }
        [key, heading, rows]
      end
    end

    def counts_line
      c = @profile.counts
      "Built from #{c[:favorites].to_i} favorites, #{c[:read].to_i} read and #{c[:rated].to_i} rated books"
    end
  end
end

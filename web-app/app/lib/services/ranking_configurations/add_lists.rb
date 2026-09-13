# frozen_string_literal: true

# Adds lists to a user-owned ranking configuration in one INSERT. Only
# active lists of the entry's type count -- the calculator ignores every
# other status -- and lists already present are skipped rather than erroring,
# so the picker's "Add selected", each diff row's Add and "Add all" share
# this one path.
module Services
  module RankingConfigurations
    class AddLists
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(config:, entry:, list_ids:)
        new(config: config, entry: entry, list_ids: list_ids).call
      end

      def initialize(config:, entry:, list_ids:)
        @config = config
        @entry = entry
        @list_ids = Array(list_ids).map { |id| Integer(id.to_s, exception: false) }.compact.select(&:positive?).uniq
      end

      def call
        candidates = entry.list_class.constantize
          .where(status: :active, id: list_ids)
          .where.not(id: config.ranked_lists.select(:list_id))
          .pluck(:id)
        return Result.new(success?: true, data: {added: 0}, errors: []) if candidates.empty?

        now = Time.current
        ::RankingConfiguration.transaction do
          ::RankedList.insert_all(candidates.map { |list_id|
            {list_id: list_id, ranking_configuration_id: config.id, created_at: now, updated_at: now}
          })
          config.update!(needs_refresh: true)
        end

        Result.new(success?: true, data: {added: candidates.size}, errors: [])
      end

      private

      attr_reader :config, :entry, :list_ids
    end
  end
end

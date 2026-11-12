# frozen_string_literal: true

# Turns a global ranking configuration's current ranked_items into one
# RankingArchive row. The daily monthly-archive job and the admin "Archive
# now" action both come through here.
#
# The ranking is read in a single statement, which is what makes it a
# consistent snapshot while a refresh is rewriting ranked_items. Capture never
# touches the configuration and never requests a refresh.
#
# Model constants are root-anchored: Services::RankingConfiguration is an
# existing module, so a bare RankingConfiguration here would resolve to it.
module Services
  module RankingArchives
    class Capture
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      UNSUPPORTED = "This ranking cannot be archived."
      NOT_GLOBAL = "Only global rankings can be archived."
      EMPTY = "This ranking has no ranked items, so nothing was archived."
      ALREADY_ARCHIVED = "An archive already exists for this month."

      MONTH_INDEX = "index_ranking_archives_on_config_and_period"

      def self.call(config:, name:, period: nil, captured_at: Time.current)
        new(config: config, name: name, period: period, captured_at: captured_at).call
      end

      def initialize(config:, name:, period: nil, captured_at: Time.current)
        @config = config
        @name = name
        @period = period
        @captured_at = captured_at
      end

      def call
        archive_class = config.ranking_archive_class
        return failure(UNSUPPORTED) if archive_class.nil?
        return failure(NOT_GLOBAL) unless config.global?

        rows = ranked_rows(archive_class)
        return failure(EMPTY) if rows.empty?

        archive = archive_class.new(
          ranking_configuration_id: config.id,
          name: name,
          period: period,
          captured_at: captured_at,
          item_ids: rows.map(&:first),
          positions: rows.map(&:second),
          scores: rows.map { |row| row.third || 0 }
        )

        if archive.save
          Result.new(success?: true, data: archive, errors: [])
        else
          Result.new(success?: false, data: archive, errors: archive.errors.full_messages)
        end
      rescue ActiveRecord::RecordNotUnique => error
        failure(error.message.include?(MONTH_INDEX) ? ALREADY_ARCHIVED : error.message)
      end

      private

      attr_reader :config, :name, :period, :captured_at

      def ranked_rows(archive_class)
        ::RankedItem.where(ranking_configuration_id: config.id, item_type: archive_class.item_type)
          .where.not(rank: nil).order(:rank, :item_id).pluck(:item_id, :rank, :score)
      end

      def failure(message)
        Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end

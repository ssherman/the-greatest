module Services
  module BooksMigration
    # Copies each archived legacy ranking_configuration into one Books::RankingArchive
    # row (three parallel arrays). Legacy book ids were preserved in this app, so ids
    # are stored as they are and never resolved here; merged and deleted books are
    # handled at display time through RecordRedirect.
    #
    # Two passes so ~600,000 ranked rows are never held at once:
    #   1. classify every distinct book id (live / redirected / deleted / unknown);
    #      any unknown id aborts the run before anything is written;
    #   2. in one transaction, re-read each configuration without an archive and create it.
    # An existing archive (legacy_ranking_configuration_id) is never touched, so the run
    # is re-runnable and safe after sync_init.
    class RankingArchiveMigrator
      MODEL = "Books::RankingArchive"
      ITEM_TYPE = "Books::Book"
      SLICE = 10_000
      UNKNOWN_SAMPLE = 50

      def self.call
        new.call
      end

      def call
        configs = legacy_configs
        existing = ::Books::RankingArchive.where.not(legacy_ranking_configuration_id: nil)
          .pluck(:legacy_ranking_configuration_id).to_set

        skipped_existing = 0
        skipped_empty = []
        ids = Set.new
        to_create = []

        configs.each do |config|
          if existing.include?(config["id"])
            skipped_existing += 1
            next
          end
          config_ids = legacy_ranked_rows(config["id"]).map(&:first)
          if config_ids.empty?
            skipped_empty << config["id"]
          else
            ids.merge(config_ids)
            to_create << config
          end
        end

        counts, unknown = classify(ids)
        data = {model: MODEL, count: 0, skipped_existing: skipped_existing, skipped_empty: skipped_empty, books: counts}
        if unknown.any?
          return {success: false, error: "#{unknown.size} book ids are neither a book nor a redirect",
                  data: data.merge(unknown_ids: unknown.sort.first(UNKNOWN_SAMPLE))}
        end

        created = 0
        ::Books::RankingArchive.transaction do
          to_create.each do |config|
            create_archive(config)
            created += 1
          end
        end
        {success: true, data: data.merge(count: created)}
      end

      private

      # Seam: String-keyed attributes of archived, global legacy configurations.
      def legacy_configs
        LegacyBooks::RankingConfiguration.where(archived: true, global: true).order(:id).map(&:attributes)
      end

      # Seam: [[book_id, combined_position, score], ...]. calculated_score is never read.
      def legacy_ranked_rows(legacy_id)
        LegacyBooks::RankedBook.where(ranking_configuration_id: legacy_id)
          .where.not(combined_position: nil)
          .order(:combined_position, :book_id)
          .pluck(:book_id, :combined_position, :score)
      end

      def create_archive(config)
        rows = legacy_ranked_rows(config["id"])
        ::Books::RankingArchive.create!(
          name: config["name"],
          description: config["description"],
          captured_at: config["published_at"] || config["created_at"],
          hidden: config["published_at"].nil?,
          legacy_ranking_configuration_id: config["id"],
          item_ids: rows.map { |row| row[0] },
          positions: rows.map { |row| row[1] },
          scores: rows.map { |row| row[2] || 0 }
        )
      end

      # Returns [{live:, redirected:, deleted:, unknown:}, unknown_ids]. Live wins over
      # a stale redirect row.
      def classify(ids)
        counts = {live: 0, redirected: 0, deleted: 0, unknown: 0}
        unknown = []
        ids.to_a.each_slice(SLICE) do |slice|
          live = ::Books::Book.where(id: slice).pluck(:id).to_set
          rest = slice.reject { |id| live.include?(id) }
          redirects = ::RecordRedirect.where(item_type: ITEM_TYPE, from_id: rest).pluck(:from_id, :to_id).to_h
          counts[:live] += live.size
          rest.each do |id|
            if !redirects.key?(id)
              counts[:unknown] += 1
              unknown << id
            elsif redirects[id].nil?
              counts[:deleted] += 1
            else
              counts[:redirected] += 1
            end
          end
        end
        [counts, unknown]
      end
    end
  end
end

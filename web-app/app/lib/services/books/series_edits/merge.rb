# frozen_string_literal: true

module Services
  module Books
    module SeriesEdits
      # Merges one series into another. The source keeps its row and identifiers (so its
      # Goodreads id still resolves, through Series#canonical, to the target) and ends
      # soft-deleted with merged_into pointing at the target. Series previously merged
      # into the source are repointed so a lookup never follows a chain.
      #
      # A book already in the target keeps the target's link untouched; the source's
      # link for it is dropped.
      class Merge
        def self.refusal(source:, target:)
          return "A series can't be merged into itself." if source.id == target.id
          return "Deleted series can't be merged." if source.deleted? || target.deleted?
          "Merged series can't be merge targets." if target.merged_into_id.present?
        end

        def self.call(target:, source:, dry_run: false)
          new(target, source, dry_run).call
        end

        def initialize(target, source, dry_run)
          @target = target
          @source = source
          @dry_run = dry_run
        end

        def call
          message = self.class.refusal(source: @source, target: @target)
          return refused(message) if message
          return success(*counts) if @dry_run

          moved = dropped = nil
          ::Books::Series.transaction do
            # Lock in id order (no deadlock between opposite merges), then re-check
            # against the fresh rows: a concurrent merge or delete may have run.
            [@source, @target].sort_by(&:id).each(&:lock!)
            message = self.class.refusal(source: @source, target: @target)
            return refused(message) if message

            moved, dropped = counts
            move_links
            ::Books::Series.where(merged_into_id: @source.id).update_all(merged_into_id: @target.id)
            adopt_representative
            @source.update!(deleted: true, merged_into: @target)
          end
          success(moved, dropped)
        end

        private

        def shared_book_ids
          ::Books::SeriesBook.where(series_id: @target.id).select(:book_id)
        end

        def counts
          links = ::Books::SeriesBook.where(series_id: @source.id)
          dropped = links.where(book_id: shared_book_ids).count
          [links.count - dropped, dropped]
        end

        def move_links
          links = ::Books::SeriesBook.where(series_id: @source.id)
          @moved_book_ids = links.where.not(book_id: shared_book_ids).pluck(:book_id)
          links.where.not(book_id: shared_book_ids).update_all(series_id: @target.id)
          links.delete_all
        end

        def adopt_representative
          return if @target.representative_book_id
          return unless @moved_book_ids.include?(@source.representative_book_id)

          @target.update!(representative_book_id: @source.representative_book_id)
        end

        def success(moved, dropped)
          Result.new(success?: true, data: {moved: moved, dropped: dropped}, errors: [])
        end

        def refused(message)
          Result.new(success?: false, errors: [message], code: :unprocessable)
        end
      end
    end
  end
end

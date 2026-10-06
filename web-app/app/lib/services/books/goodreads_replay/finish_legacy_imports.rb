# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Finishes the legacy imports that failed or never finished (Goodreads
      # import spec §12.8) through the member pipeline. Each becomes a member
      # import of the same user, with a copy of the upload the replay loaded,
      # and runs like an upload: it writes list items and reviews, creates
      # unmatched books provisional, and waits for an admin's approval.
      #
      # Legacy statuses are read live, because the loader never refreshes
      # them. A legacy import is skipped when:
      # - the user later completed a legacy import, or any upload here, whose
      #   file could bring back books they have since removed;
      # - a newer unfinished import of theirs is finished instead;
      # - the replay has no readable file for it;
      # - an admin rejected the import that finished it.
      #
      # Safe to call again, but in production only on the final books
      # migration pass: the list items and reviews it writes survive a
      # truncate, and would end up on whatever books later take the deleted
      # provisional books' ids. A finishing import with rows has run and is
      # left alone. One whose rows a truncate emptied runs again from its kept
      # file, pending review, its old provenance gone. Writes skip on
      # conflict, so items the legacy import already wrote are not written
      # twice.
      class FinishLegacyImports
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        LegacyImport = Data.define(:id, :user_id, :status, :created_at)
        STARTS = %i[started would_start].freeze
        # Outcomes that mean this import, not an older one, is the user's.
        CLAIMS = %i[started would_start running already_run rejected user_busy].freeze

        # Every legacy import, with its status as the legacy app holds it now.
        class LegacyImports
          include Enumerable

          def each
            ::LegacyBooks::GoodreadsImport.select(:id, :user_id, :status, :created_at).find_each do |import|
              yield LegacyImport.new(
                id: import.id, user_id: import.user_id, created_at: import.created_at,
                status: ::LegacyBooks::GoodreadsImport::STATUSES.fetch(import.status, import.status.to_s)
              )
            end
          end
        end

        def self.call(legacy_imports: LegacyImports.new, ids: nil, limit: nil, dry_run: false)
          new(legacy_imports: legacy_imports, ids: ids, limit: limit, dry_run: dry_run).call
        end

        def initialize(legacy_imports:, ids:, limit:, dry_run:)
          @legacy_imports = legacy_imports
          @ids = ids
          @limit = limit
          @dry_run = dry_run
        end

        def call
          imports = @legacy_imports.to_a
          @last_completed = imports.select { |import| import.status == "complete" }
            .group_by(&:user_id).transform_values { |list| list.map(&:created_at).max }
          @claimed_users = Set.new
          outcomes = {}
          unfinished(imports).each do |legacy|
            break if @limit && outcomes.values.count { |outcome| STARTS.include?(outcome) } >= @limit

            # An import not picked by id is never started, but it is still
            # looked at, so a newer import of the same user still claims them.
            picked = @ids.nil? || @ids.include?(legacy.id)
            outcome = finish(legacy, dry_run: @dry_run || !picked)
            @claimed_users << legacy.user_id if CLAIMS.include?(outcome)
            outcomes[legacy.id] = outcome if picked
          end
          Result.new(success?: true, data: {outcomes: outcomes, tally: outcomes.values.tally}, errors: [])
        end

        private

        # Newest first. With ids, the picked imports and every other
        # unfinished import of their users.
        def unfinished(imports)
          imports = imports.reject { |import| import.status == "complete" }
          if @ids
            users = imports.select { |import| @ids.include?(import.id) }.map(&:user_id).to_set
            imports = imports.select { |import| users.include?(import.user_id) }
          end
          imports.sort_by { |import| [import.created_at, import.id] }.reverse
        end

        def finish(legacy, dry_run:)
          last = @last_completed[legacy.user_id]
          return :later_import_completed if last && last > legacy.created_at
          return :newer_import_finishing if @claimed_users.include?(legacy.user_id)

          user = ::User.find_by(id: legacy.user_id)
          return :missing_user unless user
          return :member_import_completed if user.goodreads_imports.member.complete.where(finishes_legacy_import_id: nil).exists?

          replay = ::Books::GoodreadsImport.legacy_replay.find_by(legacy_import_id: legacy.id)
          return :no_file unless replay&.file&.attached?

          existing = ::Books::GoodreadsImport.find_by(finishes_legacy_import_id: legacy.id)
          return :rejected if existing&.review_rejected?
          return :running if existing&.in_progress?
          return :already_run if existing&.rows&.exists?

          bytes = upload(replay)
          return :no_file unless bytes

          parsed = ::Books::Goodreads::ExportFile.parse(bytes)
          return :unreadable unless parsed.success? && parsed.data[:rows].any?
          return :user_busy if user.goodreads_imports.in_progress.exists?
          return :would_start if dry_run

          start(user, legacy, existing, replay, bytes)
        end

        # The replay's copy of the upload, or nil when storage no longer has
        # it; that import is skipped and the rest still run.
        def upload(replay)
          replay.file.download
        rescue ActiveStorage::FileNotFoundError
          nil
        end

        def start(user, legacy, existing, replay, bytes)
          import = ActiveRecord::Base.transaction(requires_new: true) do
            existing ? restart(existing) : create(user, legacy, replay, bytes)
          end
          ::Books::Goodreads::RunImportJob.perform_async(import.id)
          :started
        rescue ActiveRecord::RecordNotUnique
          # The user started an upload since the check above.
          :user_busy
        end

        def create(user, legacy, replay, bytes)
          user.goodreads_imports.create!(source: :member, status: :queued, finishes_legacy_import_id: legacy.id).tap do |import|
            import.file.attach(io: StringIO.new(bytes), filename: replay.file.filename.to_s, content_type: "text/csv",
              identify: false)
          end
        end

        # A re-migration truncated this import's rows and the books its
        # provenance names, so it starts over and waits for a new approval.
        def restart(import)
          import.records.delete_all
          import.update!(status: :queued, error: nil, started_at: nil, finished_at: nil, review_status: :pending,
            reviewed_by: nil, reviewed_at: nil, ai_calls_count: 0)
          import
        end
      end
    end
  end
end

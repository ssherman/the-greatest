# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Runs a failed or stuck member import again (Goodreads import spec §10,
      # "Retry"; §13). Rows that failed after parsing and wrote nothing go back
      # to pending, so the run resolves and writes them; rows that never
      # parsed stay failed. The run continues from where the import stopped.
      class Rerun
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(import:)
          new(import: import).call
        end

        def initialize(import:)
          @import = import
        end

        def call
          return refuse("Only member imports are rerun here.") unless @import.member?
          return refuse("Only a failed or stuck import can be rerun.") unless @import.failed? || @import.stuck?
          return refuse("A rejected import is not rerun.") if @import.review_rejected?

          ActiveRecord::Base.transaction do
            @import.rows.failed.where.not(goodreads_edition_id: nil).where("applied = '{}'::jsonb")
              .update_all(outcome: ::Books::GoodreadsImportRow.outcomes[:pending], error: nil, updated_at: Time.current)
            # started_at restarts with the new run, so the import is not
            # flagged stuck (and re-offered for rerun or reject) at once.
            @import.update!(status: :queued, error: nil, started_at: nil, finished_at: nil)
          end
          ::Books::Goodreads::RunImportJob.perform_async(@import.id)
          Result.new(success?: true, data: {import: @import}, errors: [])
        rescue ActiveRecord::RecordNotUnique
          refuse("The member has another import in progress.")
        end

        private

        def refuse(message)
          Result.new(success?: false, data: {}, errors: [message])
        end
      end
    end
  end
end

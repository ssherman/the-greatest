# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The one place the replay changes catalog data (Goodreads import spec
      # §12.7, §12.9). Applies every approved verdict in the spec's order:
      # author merges, then book merges (the book merger moves book_authors only
      # when the target has none), then relinks, identifier strips, and
      # mark_provisional last.
      #
      # Every pass re-applies all approved verdicts, because a books
      # re-migration undoes the last pass's changes. That is safe because each
      # handler is idempotent and does nothing when its records are gone or its
      # change is already there.
      #
      # Refuses to run while config.x.goodreads_replay.auto_apply is off: the
      # first full replay writes verdicts and applies nothing.
      class ApplyVerdicts
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze
        HANDLERS = {
          merge_authors: Apply::MergeAuthors,
          merge_books: Apply::MergeBooks,
          relink: Apply::Relink,
          strip_identifier: Apply::StripIdentifier,
          mark_provisional: Apply::MarkProvisional
        }.freeze

        def self.call(auto_apply: Rails.configuration.x.goodreads_replay.auto_apply)
          new(auto_apply: auto_apply).call
        end

        def initialize(auto_apply:)
          @auto_apply = auto_apply
        end

        def call
          unless @auto_apply
            return Result.new(success?: false, data: {tally: {}},
              errors: ["auto_apply is off (config.x.goodreads_replay.auto_apply); nothing was applied"])
          end

          tally = Hash.new(0)
          configurations = Set.new
          HANDLERS.each do |kind, handler|
            ::Books::RepairVerdict.approved.where(kind: kind).find_each do |verdict|
              tally["#{kind} #{apply(verdict, handler, configurations)}"] += 1
            end
          end
          configurations.each { |id| ::CalculateRankingsJob.perform_async(id) }
          Result.new(success?: true, data: {tally: tally.to_h, ranking_configuration_ids: configurations.to_a}, errors: [])
        end

        private

        def apply(verdict, handler, configurations)
          result = handler.call(verdict: verdict)
          outcome = result.data[:outcome]
          configurations.merge(Array(result.data[:ranking_configuration_ids]))
          verdict.update!(applied_at: (outcome == :applied) ? Time.current : verdict.applied_at, error: nil)
          outcome
        rescue *POSTGRES_ERRORS
          raise
        rescue => e
          verdict.update!(error: "#{e.class}: #{e.message}")
          :failed
        end
      end
    end
  end
end

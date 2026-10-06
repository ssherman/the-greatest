# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # One finder run for one row (books list wizard spec §3), with the row
        # as the decision's subject. A confident match links the row now; a
        # book another row holds is never linked twice (§4).
        class MatchRow
          # A match whose finder lost a source (Open Library under load answers
          # 503) is capped to medium, which would flag the row "unsure" for a
          # transient fault. So it is retried: three attempts in all, the first
          # run plus two retries waiting RETRY_DELAYS seconds. Only the last
          # attempt's result is applied, with the failed source in the row's error.
          MAX_ATTEMPTS = 3
          RETRY_DELAYS = [20, 60].freeze

          def self.call(list_item:, adapter:, single_row: false, attempt: 1)
            new(list_item, adapter, single_row, attempt).call
          end

          # Also used when a row job runs out of retries. Clears everything an
          # earlier run decided, so a failed re-match does not keep stale answers.
          def self.failure_attributes(message)
            {"bucket" => "flagged", "reasons" => ["match_failed"], "error" => message.to_s.truncate(500),
             "matched_at" => Time.current.iso8601, "match_decision_id" => nil, "decided_by" => nil,
             "confidence" => nil, "ol_keys" => [], "ol_work_key" => nil, "target_record_id" => nil,
             "import_error" => nil}
          end

          def initialize(item, adapter, single_row, attempt = 1)
            @item = item
            @adapter = adapter
            @single_row = single_row
            @attempt = attempt
            @record = nil
            @sources_failed = []
          end

          def call
            attributes = begin
              decide
            rescue ::ActiveRecord::ActiveRecordError
              raise
            rescue => e
              Rails.logger.warn("List wizard match failed for list item #{@item.id}: #{e.class}: #{e.message}")
              @record = nil
              self.class.failure_attributes(e.message)
            end
            list = @item.list
            # The finder can take seconds; the admin may have settled the row
            # (or restart deleted it) meanwhile. Apply only to a row still pending.
            fresh = ::ListItem.find_by(id: @item.id)
            if fresh && RowState.new(fresh).pending?
              @item = fresh
              if retry_source?
                # Stay pending and skip progress: the step must not finish with
                # this row undecided.
                ::Lists::Wizard::MatchRowJob.perform_in(RETRY_DELAYS.fetch(@attempt - 1), @item.id, @single_row, @attempt + 1)
                return
              end
              save(attributes)
            end
            MatchProgress.call(list: list, single_row: @single_row)
          end

          private

          def decide
            match = @adapter.finder.call(query: @adapter.query_for(@item), subject: @item)
            outcome = Outcome.classify(match)
            @sources_failed = Array(match.sources_failed)
            attributes = {
              "bucket" => outcome.bucket, "reasons" => outcome.reasons,
              "match_decision_id" => match.decision&.id, "decided_by" => match.decided_by&.to_s,
              "confidence" => match.confidence&.to_s, "ol_keys" => @adapter.recheck_keys(match),
              "ol_work_key" => outcome.external_key, "target_record_id" => outcome.target_record_id,
              "matched_at" => Time.current.iso8601, "error" => failed_source_error, "import_error" => nil
            }
            @record = match.record if outcome.bucket == "matched"
            attributes
          end

          def retry_source?
            @sources_failed.any? && @attempt < MAX_ATTEMPTS
          end

          def failed_source_error
            "Source failed: #{@sources_failed.join(", ")}" if @sources_failed.any?
          end

          def save(attributes)
            state = RowState.new(@item).merge(attributes)
            RowState.unlink(@item)
            if @record.nil?
              @item.save!
            elsif RowState.holder_of(@item.list, @record, except: @item)
              state.flag!("on_list_twice")
            else
              state.link!(@record)
            end
          rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid => e
            # Another job linked the book after we looked: flag, don't crash.
            raise unless @record
            raise if e.is_a?(::ActiveRecord::RecordInvalid) && !@item.errors.include?(:listable_id)

            RowState.new(@item).flag!("on_list_twice")
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # One finder run for one row (books list wizard spec §3), with the row
        # as the decision's subject. A confident match links the row now; a
        # book another row holds is never linked twice (§4).
        class MatchRow
          def self.call(list_item:, adapter:, single_row: false)
            new(list_item, adapter, single_row).call
          end

          # Also used when a row job runs out of retries. Clears everything an
          # earlier run decided, so a failed re-match does not keep stale answers.
          def self.failure_attributes(message)
            {"bucket" => "flagged", "reasons" => ["match_failed"], "error" => message.to_s.truncate(500),
             "matched_at" => Time.current.iso8601, "match_decision_id" => nil, "decided_by" => nil,
             "confidence" => nil, "ol_keys" => [], "ol_work_key" => nil, "target_record_id" => nil,
             "import_error" => nil}
          end

          def initialize(item, adapter, single_row)
            @item = item
            @adapter = adapter
            @single_row = single_row
            @record = nil
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
              save(attributes)
            end
            MatchProgress.call(list: list, single_row: @single_row)
          end

          private

          def decide
            match = @adapter.finder.call(query: @adapter.query_for(@item), subject: @item)
            outcome = Outcome.classify(match)
            attributes = {
              "bucket" => outcome.bucket, "reasons" => outcome.reasons,
              "match_decision_id" => match.decision&.id, "decided_by" => match.decided_by&.to_s,
              "confidence" => match.confidence&.to_s, "ol_keys" => @adapter.recheck_keys(match),
              "ol_work_key" => outcome.external_key, "target_record_id" => outcome.target_record_id,
              "matched_at" => Time.current.iso8601, "error" => nil, "import_error" => nil
            }
            @record = match.record if outcome.bucket == "matched"
            attributes
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

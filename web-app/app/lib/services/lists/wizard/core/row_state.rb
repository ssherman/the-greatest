# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # A list item's wizard state, kept in metadata["wizard"] (books list
        # wizard spec §7). merge and settle change item.metadata and never save;
        # flag! and link! are the two shared compound writes and do save.
        class RowState
          KEY = "wizard"
          DECIDED_BUCKETS = %w[matched create flagged].freeze
          REASON_LABELS = {
            "unsure" => "The finder was not sure",
            "not_found" => "No match found",
            "ai_only_pick" => "Only the AI picked this Open Library work",
            "on_list_twice" => "Another row on this list lands on the same book",
            "match_failed" => "The lookup failed",
            "import_failed" => "The book could not be created",
            "changed_since_match" => "A matching book appeared after Match"
          }.freeze
          INITIAL = {"bucket" => "pending", "reasons" => [], "settled" => false}.freeze
          PENDING = {"bucket" => "pending", "reasons" => [], "target_record_id" => nil, "ol_work_key" => nil,
                     "import_error" => nil, "error" => nil, "match_decision_id" => nil, "decided_by" => nil,
                     "confidence" => nil, "ol_keys" => [], "matched_at" => nil, "import_result" => nil}.freeze

          attr_reader :item

          def self.unsettled(list)
            list.list_items.reload.reject { |item| new(item).settled? }
          end

          # A "kept" row is settled or linked to a book (spec §8). Re-parse, restart
          # and re-match act on the rest, so none of them can unlink a book.
          def self.replaceable(list)
            unsettled(list).reject { |item| item.listable_id.present? }
          end

          # Rows Match works on: the replaceable ones, plus any row mid-match
          # (pending), settled or not, so a lost job never strands one.
          def self.matchable(list)
            list.list_items.reload.select do |item|
              state = new(item)
              (state.present? && state.pending?) ? true : (!state.settled? && item.listable_id.blank?)
            end
          end

          def self.holder_of(list, record, except: nil)
            scope = list.list_items.where(listable: record)
            scope = scope.where.not(id: except.id) if except
            scope.order(:position, :id).first
          end

          def self.label_for(reason)
            REASON_LABELS.fetch(reason.to_s) { reason.to_s.humanize }
          end

          def self.unlink(item)
            item.listable_id = nil
            item.verified = false
          end

          def initialize(item)
            @item = item
          end

          def present? = @item.metadata.is_a?(Hash) && @item.metadata[KEY].is_a?(Hash)

          def data = present? ? @item.metadata[KEY] : {}

          def bucket = data["bucket"]

          def reasons = Array(data["reasons"])

          def pending? = bucket == "pending"

          def decided? = DECIDED_BUCKETS.include?(bucket)

          def flagged? = bucket == "flagged"

          def removed? = bucket == "removed"

          # A row with no wizard state predates the wizard and is not its to change.
          def settled? = !present? || data["settled"] == true

          def settled_by_id = data["settled_by_id"]

          def ol_keys = Array(data["ol_keys"])

          def ol_work_key = data["ol_work_key"].presence

          def target_record_id = data["target_record_id"]

          def match_decision_id = data["match_decision_id"]

          def decided_by = data["decided_by"]

          def import_result = data["import_result"]

          def import_error = data["import_error"]

          def error = data["error"]

          def matched_at
            value = data["matched_at"]
            value.present? ? Time.zone.parse(value) : nil
          end

          def merge(attributes)
            base = @item.metadata.is_a?(Hash) ? @item.metadata : {}
            @item.metadata = base.merge(KEY => data.merge(attributes.to_h.transform_keys(&:to_s)))
            self
          end

          def settle(by:)
            merge("settled" => true, "settled_by_id" => by&.id, "settled_at" => Time.current.iso8601)
          end

          # Flag the row for a person: add the reason (once), move it to the
          # flagged bucket, drop its link and verification, save.
          def flag!(reason)
            merge("bucket" => "flagged", "reasons" => (reasons + [reason.to_s]).uniq)
            self.class.unlink(@item)
            @item.save!
            self
          end

          # Point the row at a record and mark it verified, save.
          def link!(record)
            @item.listable = record
            @item.verified = true
            @item.save!
            self
          end
        end
      end
    end
  end
end

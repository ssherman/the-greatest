# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # The counts the Review header (spec §4) and the Done screen (spec §6) show.
        class Summary
          def initialize(list)
            @list = list
          end

          def review_counts
            states = wizard_rows.map(&:last)
            {
              "matched" => states.count { |state| state.bucket == "matched" },
              "create" => states.count { |state| state.bucket == "create" },
              "flagged" => states.count(&:flagged?),
              "settled" => states.count(&:settled?)
            }
          end

          def flagged_count
            wizard_rows.count { |_item, state| state.flagged? }
          end

          # Rows with no book, removed rows excluded (spec §5). The one place this
          # rule lives: the Done screen and the list admin page both call it.
          def unlinked_count
            all_rows.count { |item, _state| item.listable_id.nil? }
          end

          def done_counts
            rows = all_rows
            {
              "matched" => rows.count { |item, state| state.present? && item.listable_id && state.import_result.nil? && state.settled_by_id.nil? },
              "created" => rows.count { |_item, state| state.import_result == "created" },
              "admin_linked" => rows.count { |item, state| item.listable_id && state.import_result.nil? && state.settled_by_id.present? },
              "unlinked" => unlinked_count,
              "changed_since_match" => rows.count { |_item, state| state.import_result == "linked_existing" },
              # NEW pairs this list's decisions raised: Services::DuplicateCandidates::Flag
              # keeps the first decision on a pair that already existed and only
              # bumps its occurrences, so a pre-existing pair is not counted.
              "duplicate_pairs" => ::DuplicateCandidate.where(match_decision_id: rows.filter_map { |_item, state| state.match_decision_id }).count
            }
          end

          private

          def all_rows
            @all_rows ||= @list.list_items.to_a.map { |item| [item, RowState.new(item)] }.reject { |_item, state| state.removed? }
          end

          def wizard_rows
            all_rows.select { |_item, state| state.present? }
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §4: the Review actions. Every action settles the
        # row and records itself on the row's MatchDecision (verdict, reviewer,
        # time), so it also shows on the match audit pages.
        class RowActions
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def initialize(list_item:, user:)
            @item = list_item
            @user = user
          end

          def link(record)
            return failure("That book was not found.") if record.nil?

            holder = RowState.holder_of(@item.list, record, except: @item)
            return failure("That book is already on this list, at position #{holder.position || "?"}.") if holder

            ::ActiveRecord::Base.transaction do
              record_review(verdict: same_record?(record) ? :confirmed : :rejected, note: "Linked #{record.class.name}##{record.id} in the list wizard")
              settle("bucket" => "matched", "reasons" => [], "target_record_id" => record.id, "ol_work_key" => nil, "import_error" => nil)
              state.link!(record)
            end
            success("Row linked.")
          rescue ::ActiveRecord::RecordNotUnique, ::ActiveRecord::RecordInvalid
            failure("That book is already on this list.")
          end

          def create_from_external(external_key)
            snapshots = candidates.select { |snapshot| snapshot["external_key"] == external_key }
            return failure("That work is not one of this row's candidates.") if snapshots.empty?
            if snapshots.none? { |snapshot| snapshot["record_id"].nil? }
              return failure("A book we hold already carries that work; link the book instead.")
            end

            ::ActiveRecord::Base.transaction do
              agreed = decision&.record_id.nil? && decision&.selected_candidate&.dig("external_key") == external_key
              record_review(verdict: agreed ? :confirmed : :rejected, note: "Create from Open Library #{external_key} in the list wizard")
              settle("bucket" => "create", "reasons" => [], "ol_work_key" => external_key,
                "ol_keys" => (state.ol_keys + [external_key]).uniq, "target_record_id" => nil, "import_error" => nil)
              save_unlinked
            end
            success("The row will be created from that work at Import.")
          end

          # The admin chose the row's own text over any Open Library work, so the
          # Match-time keys go: Import must neither stamp nor resolve them.
          def create_from_text
            ::ActiveRecord::Base.transaction do
              agreed = decision.present? && decision.record_id.nil? && decision.selected_candidate.nil?
              record_review(verdict: agreed ? :confirmed : :rejected, note: "Create from the row's text in the list wizard")
              settle("bucket" => "create", "reasons" => [], "ol_work_key" => nil, "ol_keys" => [],
                "target_record_id" => nil, "import_error" => nil)
              save_unlinked
            end
            success("The row will be created from its text at Import.")
          end

          def edit_and_rematch(title:, subtitle:, authors:, year:)
            title = title.to_s.strip
            return failure("Title can't be blank.") if title.empty?

            ::ActiveRecord::Base.transaction do
              record_review(verdict: :rejected, note: "Edited and re-matched in the list wizard")
              @item.metadata = (@item.metadata || {}).merge(
                "title" => title,
                "subtitle" => subtitle.to_s.strip.presence,
                "authors" => authors.to_s.split(/\r?\n/).map(&:strip).compact_blank,
                "year" => Signature.year(year)
              )
              settle(RowState::PENDING)
              save_unlinked
            end
            ::Lists::Wizard::MatchRowJob.perform_async(@item.id, true)
            success("The row is being matched again.")
          end

          # Unlinked and unverified, so RowState.holder_of never counts it.
          def remove
            ::ActiveRecord::Base.transaction do
              record_review(verdict: :rejected, note: "Removed from the list in the list wizard")
              settle("bucket" => "removed", "reasons" => [])
              save_unlinked
            end
            success("Row removed.")
          end

          private

          def state = RowState.new(@item)

          def decision
            return @decision if defined?(@decision)

            @decision = ::MatchDecision.find_by(id: state.match_decision_id)
          end

          def candidates = Array(decision&.candidates)

          def same_record?(record)
            decision.present? && decision.record_type == record.class.name && decision.record_id == record.id
          end

          def record_review(verdict:, note:)
            return if decision.nil?

            decision.verdict = verdict
            decision.review!(by: @user, note: note)
          end

          def settle(attributes)
            state.merge(attributes).settle(by: @user)
          end

          def save_unlinked
            RowState.unlink(@item)
            @item.save!
          end

          def success(message) = Result.new(success?: true, data: {message: message}, errors: [])

          def failure(message) = Result.new(success?: false, data: {}, errors: [message])
        end
      end
    end
  end
end

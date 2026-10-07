# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: every row lands in exactly one bucket.
        class Outcome
          Result = Struct.new(:bucket, :reasons, :target_record_id, :external_key, keyword_init: true)

          def self.classify(match)
            new(match).classify
          end

          def initialize(match)
            @match = match
          end

          def classify
            if matched_confidently?
              Result.new(bucket: "matched", reasons: [], target_record_id: @match.record.id, external_key: nil)
            elsif creatable?
              Result.new(bucket: "create", reasons: [], target_record_id: nil, external_key: @match.external.external_key)
            else
              Result.new(bucket: "flagged", reasons: reasons, target_record_id: nil, external_key: nil)
            end
          end

          private

          def matched_confidently?
            @match.matched? && %i[certain high].include?(@match.confidence) && !@match.needs_review?
          end

          def creatable?
            @match.unmatched? && @match.decided_by == :rule && !@match.needs_review? && accepted_external?
          end

          def accepted_external?
            external = @match.external
            !external.nil? && external.external? && external.external_accepted?
          end

          def reasons
            found = []
            found << "unsure" if @match.needs_review?
            found << "not_found" if @match.candidates.empty? || ai_picked_none?
            found << "ai_only_pick" if ai_picked_unaccepted_external?
            found << "unsure" if found.empty?
            found.uniq
          end

          def ai_picked_none?
            @match.decided_by == :ai && @match.unmatched? && @match.external.nil?
          end

          def ai_picked_unaccepted_external?
            @match.decided_by == :ai && @match.unmatched? && !@match.external.nil? && !accepted_external?
          end
        end
      end
    end
  end
end

module Services
  module Ai
    module Tasks
      module Matching
        # Which record in an external source describes one of ours, or none
        # (spec §5.2). The same "select one or none" call as
        # SelectCandidateTask, with its schema, role and validation, but
        # worded for linking rather than de-duplicating: every candidate is
        # external, and no link is better than a wrong link.
        class SelectExternalRecordTask < SelectCandidateTask
          attr_reader :source_name

          def initialize(source_name:, entity_noun:, query_line:, candidate_lines:, parent: nil, guidance: "", provider: nil, model: nil)
            @source_name = source_name
            super(entity_noun: entity_noun, query_line: query_line, candidate_lines: candidate_lines,
                  parent: parent, guidance: guidance, provider: provider, model: model)
          end

          private

          def system_message
            <<~SYSTEM
              You link one #{entity_noun} in our catalog to the record in #{source_name} that describes the same #{entity_noun}, or to none.
              You are given our #{entity_noun} and a numbered list of #{source_name} records.

              Select the one record that describes our #{entity_noun}, or 0 if none does.
              - Select 0 unless the evidence ties the record to ours: a matching work, a shared identifier, or matching life dates together with a description or occupation that fits. A shared name alone is not enough, and neither are matching dates alone.
              - No link is better than a wrong link. When two records fit equally well, select 0.
              - A record marked "shares <identifier>" carries the same identifier as our #{entity_noun}. Treat that as strong evidence, not proof.
              - A record marked "year conflict" has a birth or death year more than one year away from ours.
              - Two records may describe the same #{entity_noun} (duplicates in #{source_name}). Report every such group in same_entity_groups, as lists of record numbers.
              #{guidance}
              Confidence is "high" when the evidence is unambiguous, "medium" when one detail is missing or slightly off, and "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Our #{entity_noun}: #{query_line}", "", "#{source_name} records:"]
            candidate_lines.each_with_index { |line, index| lines << "#{index + 1}. #{line}" }
            lines << ""
            lines << "Answer with selected_index (the record number, or 0 for none), confidence, reasoning, and same_entity_groups."
            lines.join("\n")
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        # Decides what each books subject category should become (spec §2, §4.2).
        # The head may only merge true synonyms; the rare tail may also fold into
        # a broader known subject (the owner's long-tail decision, 2026-10-11).
        class SubjectTask < BaseCleanupTask
          ACTIONS = %w[keep rename merge delete is_location].freeze

          private

          def noun = "subjects"

          def system_message
            <<~SYSTEM
              You are cleaning up the subject categories of a book catalog. A subject names a topic or theme a book is about ("Slavery", "Medicine", "War", "Grief").

              For each subject choose an action:
              - "keep": a good subject whose name already follows the rules.
              - "rename": a good subject whose name breaks the rules; give the new name in "name".
              - "merge": the same subject as one of the known subjects below; give its exact name in "merge_into".
              - "delete": junk or not a subject: a truncated fragment, a placeholder ("Book titles", "Packages"), a genre ("Science Fiction"), a format ("Anthology") or an audience ("Young Adult").
              - "is_location": a place, which belongs with locations.
              Merge only true synonyms and variant spellings ("Decision Making" and "Decision-Making"; "Womens Studies" and "Women's Studies").
              #{merge_scope_rule}
              A vague but real theme ("Identity", "Family") is a keep.

              Naming rules: Title Case with minor words lowercase unless first, "and" not "&", straight apostrophes, no trailing punctuation, a noun or noun phrase.

              #{known_names_block}
            SYSTEM
          end

          def merge_scope_rule
            if tier == :tail
              "This subject is rare. If it is too narrow to stand on its own and one known subject clearly covers it, merge it into that subject (\"Spacecraft Missions\" into \"Space Exploration\"). Never merge into a subject that only overlaps."
            else
              "Never merge a narrower subject into a broader one, or a broader into a narrower one: \"Grief\" is not \"Death\"."
            end
          end

          def response_schema = ResponseSchema

          def normalize(raw)
            action = string(raw, :action)
            return nil unless ACTIONS.include?(action)

            {key: string(raw, :key), action: action, name: string(raw, :name), merge_into: string(raw, :merge_into).presence, reason: string(raw, :reason)}
          end

          class SubjectResult < OpenAI::BaseModel
            required :key, String, doc: "The subject's number from the list"
            required :action, String, doc: "keep, rename, merge, delete or is_location"
            required :name, String, doc: "The name it should have (same as now for keep)"
            required :merge_into, String, nil?: true, doc: "Exact name of the known subject to merge into, or null"
            required :reason, String, doc: "One short sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[SubjectResult], doc: "One result per subject"
          end
        end
      end
    end
  end
end

module Services
  module Ai
    module Tasks
      module Matching
        # One structured call: here is the incoming entity, here are up to
        # six candidates, select the one that is the same entity or 0.
        # Follows the "select one or none" pattern (Wang et al. 2024), which
        # beats pairwise yes/no on both accuracy and cost. The task takes a
        # serializable case (lines of text) so a future agent loop can
        # replace this class without touching the finder.
        class SelectCandidateTask < BaseTask
          attr_reader :entity_noun, :query_line, :candidate_lines, :guidance

          VALID_CONFIDENCE = %w[high medium low].freeze

          def initialize(entity_noun:, query_line:, candidate_lines:, parent: nil, guidance: "", provider: nil, model: nil)
            @entity_noun = entity_noun
            @query_line = query_line
            @candidate_lines = candidate_lines
            @guidance = guidance.to_s
            super(parent: parent, provider: provider, model: model)
          end

          private

          # A finder may run with no subject; AiChat.parent is optional.
          def validate_parent!
          end

          def task_provider = :openai

          def task_model = "gpt-5-mini"

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You decide whether an incoming #{entity_noun} already exists in a catalog.
              You are given the incoming #{entity_noun} and a numbered list of candidates. Candidates marked "in catalog" are records already held; the others come from an external source and are not held yet.

              Select the one candidate that is the same #{entity_noun} as the incoming one, or 0 if none is.
              - A translation, an alternate spelling, a subtitle difference or a reissue of the same #{entity_noun} counts as the same one.
              - A different edition or volume, a sequel, a remake, or a collection that merely contains it is NOT the same one.
              - A candidate marked "shares <identifier>" carries the same identifier as the incoming #{entity_noun}. Treat that as strong evidence, not proof: identifiers in this catalog are sometimes wrong.
              - Two candidates may themselves be the same #{entity_noun}. Report every such group in same_entity_groups, as lists of candidate numbers.
              - When two candidates are the same #{entity_noun} and one is marked "ranked", select the ranked one.
              #{guidance}
              Confidence is "high" when the evidence is unambiguous, "medium" when one detail is missing or slightly off, and "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Incoming #{entity_noun}: #{query_line}", "", "Candidates:"]
            candidate_lines.each_with_index { |line, index| lines << "#{index + 1}. #{line}" }
            lines << ""
            lines << "Answer with selected_index (the candidate number, or 0 for none), confidence, reasoning, and same_entity_groups."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            index = data[:selected_index]
            confidence = data[:confidence]
            count = candidate_lines.size

            unless VALID_CONFIDENCE.include?(confidence)
              return failure("Unexpected confidence value: #{confidence.inspect}")
            end
            unless index.is_a?(Integer) && index.between?(0, count)
              return failure("selected_index #{index.inspect} is outside 0..#{count}")
            end

            Services::Ai::Result.new(
              success: true,
              data: {
                selected_index: index,
                confidence: confidence,
                reasoning: data[:reasoning].to_s,
                same_entity_groups: clean_groups(data[:same_entity_groups], count)
              },
              ai_chat: chat
            )
          end

          def clean_groups(groups, count)
            Array(groups).filter_map do |group|
              members = members_of(group).select { |m| m.is_a?(Integer) && m.between?(1, count) }.uniq.sort
              members if members.size >= 2
            end.uniq
          end

          def members_of(group)
            if group.respond_to?(:members)
              Array(group.members)
            elsif group.is_a?(Hash)
              Array(group[:members] || group["members"])
            else
              []
            end
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Group < OpenAI::BaseModel
            required :members, OpenAI::ArrayOf[Integer], doc: "Candidate numbers that are the same entity as each other"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :selected_index, Integer, doc: "The number of the candidate that is the same entity as the incoming one, or 0 if none is"
            required :confidence, String, doc: "high, medium or low"
            required :reasoning, String, doc: "One or two sentences"
            required :same_entity_groups, OpenAI::ArrayOf[Group], doc: "Groups of candidate numbers that are the same entity as each other; empty when there are none"
          end
        end
      end
    end
  end
end

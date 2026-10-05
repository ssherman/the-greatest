module Services
  module Ai
    module Tasks
      module Books
        # One structured call over a group of author records that share a
        # normalized name (Goodreads import spec §12.5): which of them are the
        # same person? The legacy app created many authors by name alone, so a
        # group can be one person entered many times, several different people,
        # or a mix. Each line comes from AuthorProfile#line, plus identifiers.
        class GroupSameAuthorsTask < BaseTask
          VALID_CONFIDENCE = %w[high medium low].freeze

          attr_reader :author_lines

          def initialize(author_lines:, parent: nil, provider: nil, model: nil)
            @author_lines = author_lines
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :fast

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You are cleaning up an author catalog. You are given a numbered list of author records that share a name.
              Some may be one person entered more than once; others are different people who happen to share the name.

              Group the records that are the same person. Leave a record out of every group when it is a different person from all the others.
              - Judge by their books, life dates, other names and identifiers. Matching names alone prove nothing.
              - Two people with the same name are different authors unless their dates or their books connect them.
              - A pen name is a separate author from the person who uses it, and from other people using the same pen name.
              - Different identifiers of the same kind (two different Wikidata ids) mean different people.
              - A publisher, company or collective is the same entity only as the same organization.
              For each group give confidence: "high" when the books or dates make it unambiguous, "medium" when it is likely, "low" when you are guessing.
            SYSTEM
          end

          def user_prompt
            lines = ["Authors:"]
            author_lines.each_with_index { |line, index| lines << "#{index + 1}. #{line}" }
            lines << ""
            lines << "Answer with groups (each with its members' numbers and a confidence) and reasoning."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            groups = Array(data[:groups])
            invalid = groups.map { |group| value(group, :confidence) }.reject { |confidence| VALID_CONFIDENCE.include?(confidence) }
            return failure("Unexpected confidence value: #{invalid.first.inspect}") if invalid.any?

            Services::Ai::Result.new(success: true, data: {groups: clean(groups), reasoning: data[:reasoning].to_s}, ai_chat: chat)
          end

          # Members in range, each in at most one group (the first that names
          # it), groups of two or more.
          def clean(groups)
            taken = Set.new
            groups.filter_map do |group|
              members = Array(value(group, :members)).select { |m| m.is_a?(Integer) && m.between?(1, author_lines.size) }
                .uniq.sort.reject { |m| taken.include?(m) }
              next if members.size < 2

              taken.merge(members)
              {members: members, confidence: value(group, :confidence)}
            end
          end

          def value(group, key)
            group.respond_to?(key) ? group.public_send(key) : (group[key] || group[key.to_s])
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Group < OpenAI::BaseModel
            required :members, OpenAI::ArrayOf[Integer], doc: "Numbers of the records that are one and the same person"
            required :confidence, String, doc: "high, medium or low"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :groups, OpenAI::ArrayOf[Group], doc: "Groups of records that are the same person; empty when all are different people"
            required :reasoning, String, doc: "One or two sentences"
          end
        end
      end
    end
  end
end

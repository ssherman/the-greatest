module Services
  module Ai
    module Tasks
      module Books
        # For each free-text subject or location a judge proposed that matched no
        # category exactly: which of the listed candidates, if any, is it? One
        # call per book. The caller checks every id against the candidates it
        # sent, so a stray id is never applied.
        class CategoryChoiceTask < BaseTask
          attr_reader :book_line, :questions

          def initialize(parent:, book_line:, questions:, provider: nil, model: nil)
            @book_line = book_line
            @questions = questions
            super(parent: parent, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def task_role = :fast

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You are matching names proposed for one book to the categories of a book catalog. For each proposed name, pick the candidate that means the same subject or place, or none.
              - Pick a candidate only when it is the same thing, or the same thing under another name. A broader, narrower or merely related category is not a match: answer null.
              - A place name is ambiguous across countries (Georgia the state and Georgia the country). Each location candidate is shown with its containing places after "›"; use them and the book to choose, and answer null when none fits.
              - Answer with the candidate's id exactly as listed. Never invent an id.
              - Return one entry per proposed name, repeating the name exactly as given.
            SYSTEM
          end

          def user_prompt
            lines = ["Book: #{book_line}", ""]
            questions.each_with_index do |question, index|
              header = "#{index + 1}. Proposed #{question[:category_type]}: \"#{question[:proposed]}\""
              header += " (hint: #{question[:hint]})" if question[:hint].present?
              lines << header
              question[:candidates].each { |candidate| lines << "   #{candidate[:id]}: #{candidate[:label]}" }
              lines << ""
            end
            lines << "Answer with each proposed name and the id of the matching candidate, or null."
            lines.join("\n")
          end

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def process_and_persist(provider_response)
            parsed = JSON.parse(provider_response[:parsed].to_json, symbolize_names: true)
            choices = Array(parsed && parsed[:choices]).map do |choice|
              {proposed: choice[:proposed].to_s, category_id: Integer(choice[:category_id], exception: false)}
            end
            Services::Ai::Result.new(success: true, data: {choices: choices}, ai_chat: chat)
          end

          class Choice < OpenAI::BaseModel
            required :proposed, String, doc: "The proposed name, exactly as given"
            required :category_id, Integer, nil?: true, doc: "The matching candidate's id, or null for none"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :choices, OpenAI::ArrayOf[Choice], doc: "One per proposed name"
          end
        end
      end
    end
  end
end

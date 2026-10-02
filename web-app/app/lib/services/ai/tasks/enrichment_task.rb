module Services
  module Ai
    module Tasks
      # A task that reports facts about its parent without writing them. The
      # runner hands the parsed facts to an applier, which owns the write
      # policy; this class owns the prompt, the schema and the mode.
      #
      # mode :knowledge asks the model what it knows (the standard role);
      # mode :research forces a web search first (the research role).
      class EnrichmentTask < BaseTask
        MODES = %i[knowledge research].freeze
        CONFIDENCES = %w[high medium low].freeze

        class IntegerFact < OpenAI::BaseModel
          required :value, Integer, nil?: true, doc: "The value, or null when unknown"
          required :confidence, String, doc: "high, medium or low"
        end

        class StringFact < OpenAI::BaseModel
          required :value, String, nil?: true, doc: "The value, or null when unknown"
          required :confidence, String, doc: "high, medium or low"
        end

        class StringListFact < OpenAI::BaseModel
          required :value, OpenAI::ArrayOf[String], doc: "The values; an empty list when unknown"
          required :confidence, String, doc: "high, medium or low"
        end

        attr_reader :mode

        def initialize(parent:, mode: :knowledge, provider: nil, model: nil)
          unless MODES.include?(mode)
            raise ArgumentError, "mode must be one of #{MODES.join(", ")}, got #{mode.inspect}"
          end

          @mode = mode
          super(parent: parent, provider: provider, model: model)
        end

        def research? = mode == :research

        private

        def task_role = research? ? :research : knowledge_role

        # Override for a task whose knowledge call does not need recall.
        def knowledge_role = :standard

        def force_tool? = research?

        def response_format = {type: "json_object"}

        def process_and_persist(provider_response)
          Services::Ai::Result.new(
            success: true,
            data: {facts: normalize(provider_response[:parsed]), citations: Array(provider_response[:citations])},
            ai_chat: chat
          )
        end

        # The SDK's coerced schema is a BaseModel whose #to_h is shallow: nested
        # facts stay model objects. A JSON round trip flattens every level.
        def normalize(parsed)
          return {} if parsed.nil?

          JSON.parse(parsed.to_json, symbolize_names: true)
        end
      end
    end
  end
end

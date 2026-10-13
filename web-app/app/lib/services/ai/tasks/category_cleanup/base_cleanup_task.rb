# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module CategoryCleanup
        # Shared plumbing for the cleanup passes (spec §4.2): a numbered batch of
        # categories in, one result per category out, keyed by its number so a
        # dropped or reordered row is detected. Batch size is the caller's choice
        # (one per call for the head; spec §4.4 calibrates the tail).
        class BaseCleanupTask < BaseTask
          Entry = Struct.new(:key, :name, :links, :samples, :alternative_names, keyword_init: true)

          attr_reader :entries, :known_names, :tier

          def initialize(entries:, known_names:, tier:, parent: nil, provider: nil, model: nil)
            @entries = entries
            @known_names = known_names
            @tier = tier.to_sym
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :standard

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def user_prompt
            lines = ["#{noun.capitalize} to review:"]
            entries.each do |entry|
              lines << "[#{entry.key}] #{entry.name.inspect} (#{entry.links} #{"book".pluralize(entry.links)})"
              lines << "  Sample books: #{entry.samples.join("; ")}" if entry.samples.any?
              lines << "  Other names: #{entry.alternative_names.join(", ")}" if entry.alternative_names.any?
            end
            lines << ""
            lines << "Return exactly one result per #{noun.singularize}, with its number in \"key\"."
            lines.join("\n")
          end

          def known_names_block
            "Known #{noun} (use these exact names when they fit):\n#{known_names.join("\n")}"
          end

          # OpenaiStrategy deep-symbolizes `parsed.to_h`, but to_h is shallow on
          # OpenAI::BaseModel: the top level is a symbol-keyed Hash while each
          # element of :results stays a model instance. `value` reads both.
          def process_and_persist(provider_response)
            keys = entries.map(&:key).to_set
            results = Array(provider_response[:parsed][:results]).each_with_object({}) do |raw, by_key|
              parsed = normalize(raw)
              next if parsed.nil? || !keys.include?(parsed[:key]) || by_key.key?(parsed[:key])

              by_key[parsed[:key]] = parsed
            end
            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          # Hash first: Hash#key exists, so respond_to?(:key) is true for a Hash
          # and would call it with no arguments.
          def value(raw, key)
            return raw[key] || raw[key.to_s] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def string(raw, key) = value(raw, key).to_s.strip
        end
      end
    end
  end
end

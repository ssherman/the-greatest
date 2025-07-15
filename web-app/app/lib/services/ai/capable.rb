module Services
  module Ai
    module Capable
      def supports?(feature) = provider.capabilities.include?(feature)

      def user_prompt_with_fallbacks
        prompt = user_prompt.dup
        unless supports?(:json_schema) || response_schema.nil?
          json_instr = <<~INSTR
            IMPORTANT: respond with JSON that validates against:
            #{response_schema.new.to_json_schema.to_json}
          INSTR
          prompt.prepend(json_instr)
        end
        prompt
      end
    end
  end
end

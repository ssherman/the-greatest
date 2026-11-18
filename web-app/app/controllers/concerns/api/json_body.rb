# frozen_string_literal: true

module Api
  # Raw JSON-body reading and the two problems every write endpoint answers
  # with. Bodies are read raw, so an explicit null survives.
  module JsonBody
    private

    # The JSON object as sent. Not request.request_parameters: ParamsWrapper would
    # merge a copy of the body under a wrapper key.
    def json_body
      parsed = JSON.parse(request.raw_post.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def bad_body(detail)
      render_problem(::Api::Problem.new(:invalid_parameter, detail: detail))
    end

    def unknown_fields(unknown, allowed)
      render_problem(::Api::Problem.new(:unprocessable,
        detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Editable fields: #{allowed.join(", ")}."))
    end
  end
end

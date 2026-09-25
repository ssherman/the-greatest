class Services::Ai::Providers::OpenaiStrategy < Services::Ai::Providers::BaseStrategy
  # Responses API tool definitions by the symbol a task uses. `low` context is
  # the cheapest search tier; the enrichment probe got two citations from it.
  TOOL_DEFINITIONS = {
    web_search: {type: "web_search", search_context_size: "low"}
  }.freeze

  def capabilities = %i[json_mode json_schema function_calls]

  # Unused by tasks (they resolve models via Services::Ai::Roles); kept to satisfy ProviderStrategy.
  def default_model = Services::Ai::Roles.resolve(:fast).model

  def provider_key = :openai

  protected

  def client
    @client ||= OpenAI::Client.new
  end

  def make_api_call(parameters)
    client.responses.create(parameters)
  end

  def format_response(response, schema)
    # output is an array that may contain reasoning, message, web_search_call and tool_call items
    web_search_calls = response.output.count { |item| item.type.to_s == "web_search_call" }
    message_item = response.output.find { |item| item.type == :message }

    unless message_item
      tool_calls = response.output.select { |item| item.type == :tool_call }
      if tool_calls.any?
        return {
          content: nil,
          parsed: nil,
          tool_calls: tool_calls.map { |tc| {id: tc.id, name: tc.name, arguments: tc.arguments} },
          citations: [],
          web_search_calls: web_search_calls,
          id: response.id,
          model: response.model,
          usage: response.usage
        }
      else
        raise "OpenAI response contains neither message nor tool_call items"
      end
    end

    content_item = message_item.content.first
    parsed_data = if content_item.respond_to?(:parsed) && !content_item.parsed.nil?
      content_item.parsed.to_h.deep_symbolize_keys
    else
      parse_response(content_item.text, schema)
    end

    {
      content: content_item.text,
      parsed: parsed_data,
      citations: extract_citations(content_item),
      web_search_calls: web_search_calls,
      id: response.id,
      model: response.model,
      usage: response.usage
    }
  end

  def build_parameters(model:, messages:, temperature:, response_format:, schema:, reasoning: nil, tools: [], force_tool: false)
    system_messages = messages.select { |m| (m[:role] || m["role"]) == "system" }
    conversation_messages = messages.reject { |m| (m[:role] || m["role"]) == "system" }
    clean_messages = conversation_messages.map { |msg| {role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]} }

    parameters = {model: model, temperature: temperature, service_tier: "flex"}

    if system_messages.any?
      parameters[:instructions] = system_messages.first[:content] || system_messages.first["content"]
    end

    parameters[:input] = (clean_messages.length == 1 && clean_messages.first[:role] == "user") ? clean_messages.first[:content] : clean_messages
    parameters[:reasoning] = reasoning if reasoning

    if schema && schema < OpenAI::BaseModel
      parameters[:text] = schema
    elsif response_format
      parameters[:response_format] = response_format
    end

    definitions = tools.map { |tool| tool_definition(tool) }
    if definitions.any?
      parameters[:tools] = definitions
      parameters[:tool_choice] = {type: definitions.first[:type]} if force_tool
    end

    parameters
  end

  private

  def tool_definition(tool)
    TOOL_DEFINITIONS.fetch(tool.to_sym) { raise ArgumentError, "Unknown AI tool: #{tool.inspect}" }
  end

  # url_citation annotations from the message, in order, de-duplicated, with
  # the tracking parameter OpenAI appends removed. A content item with no
  # annotations method (a mock, an older SDK shape) yields [].
  def extract_citations(content_item)
    return [] unless content_item.respond_to?(:annotations)

    Array(content_item.annotations)
      .select { |annotation| annotation.type.to_s == "url_citation" && annotation.respond_to?(:url) }
      .map { |annotation| strip_tracking(annotation.url.to_s) }
      .uniq
  end

  # String-level, not URI-parsed: URI.parse rejects a non-ASCII path (raising
  # on the same URLs it's supposed to clean), and a decode/re-encode round
  # trip mangles bytes it shouldn't touch (escapes "/", turns "%20" into "+",
  # turns a bare flag into "flag="). Splitting on literal "#", "?" and "&" and
  # rejoining leaves every other byte exactly as it was.
  def strip_tracking(url)
    before_fragment, fragment_marker, fragment = url.partition("#")
    path, query_marker, query = before_fragment.partition("?")
    return url if query_marker.empty?

    kept = query.split("&").reject { |segment| segment.split("=", 2).first == "utm_source" }
    rebuilt = kept.empty? ? path : "#{path}?#{kept.join("&")}"
    fragment_marker.empty? ? rebuilt : "#{rebuilt}#{fragment_marker}#{fragment}"
  end
end

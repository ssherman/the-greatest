class Services::Ai::Providers::OpenaiStrategy < Services::Ai::Providers::BaseStrategy
  def capabilities = %i[json_mode json_schema function_calls]

  def default_model = "gpt-5-mini"

  def provider_key = :openai

  protected

  def client
    @client ||= OpenAI::Client.new
  end

  def make_api_call(parameters)
    client.responses.create(parameters)
  end

  def format_response(response, schema)
    # Extract from Responses API structure
    # output is an array that may contain reasoning, message, and tool_call items
    # Find the message item (type: :message)
    message_item = response.output.find { |item| item.type == :message }

    # Handle cases where there's no message (e.g., tool calls only)
    unless message_item
      # Look for tool_call items
      tool_calls = response.output.select { |item| item.type == :tool_call }

      if tool_calls.any?
        # Return structured response for tool calls
        return {
          content: nil,
          parsed: nil,
          tool_calls: tool_calls.map { |tc| {id: tc.id, name: tc.name, arguments: tc.arguments} },
          id: response.id,
          model: response.model,
          usage: response.usage
        }
      else
        # No message and no tool calls - this shouldn't happen, but handle gracefully
        raise "OpenAI response contains neither message nor tool_call items"
      end
    end

    # Get the first content item from the message
    content_item = message_item.content.first

    # For typed responses (with text: parameter), OpenAI provides parsed data
    # For regular responses, we need to manually parse the JSON
    parsed_data = if content_item.respond_to?(:parsed) && !content_item.parsed.nil?
      # Typed response with schema validation - use OpenAI's parsed data
      content_item.parsed
    else
      # Regular response - manually parse JSON
      parse_response(content_item.text, schema)
    end

    {
      content: content_item.text,  # Raw text from API
      parsed: parsed_data,  # Parsed data (from OpenAI or manual parsing)
      id: response.id,
      model: response.model,
      usage: response.usage
    }
  end

  def build_parameters(model:, messages:, temperature:, response_format:, schema:, reasoning: nil)
    # Separate system messages from conversation messages
    system_messages = messages.select { |m| (m[:role] || m["role"]) == "system" }
    conversation_messages = messages.reject { |m| (m[:role] || m["role"]) == "system" }

    # Clean messages: strip timestamps and other non-standard fields
    clean_messages = conversation_messages.map do |msg|
      {
        role: msg[:role] || msg["role"],
        content: msg[:content] || msg["content"]
      }
    end

    parameters = {
      model: model,
      temperature: temperature,
      service_tier: "flex"
    }

    # Add instructions if there's a system message
    if system_messages.any?
      system_content = system_messages.first[:content] || system_messages.first["content"]
      parameters[:instructions] = system_content
    end

    # Add input (just the conversation messages)
    # Use string for single message, array for multiple
    parameters[:input] = if clean_messages.length == 1 && clean_messages.first[:role] == "user"
      clean_messages.first[:content]
    else
      clean_messages
    end

    # Add reasoning parameter if provided (OpenAI-specific)
    parameters[:reasoning] = reasoning if reasoning

    # Use OpenAI::BaseModel with Responses API 'text' parameter
    if schema && schema < OpenAI::BaseModel
      parameters[:text] = schema
    elsif response_format
      parameters[:response_format] = response_format
    end

    parameters
  end
end

class Services::Ai::Providers::OpenaiStrategy < Services::Ai::Providers::BaseStrategy
  def capabilities = %i[json_mode json_schema function_calls]

  def default_model = "gpt-5"

  def provider_key = :openai

  protected

  def client
    @client ||= OpenAI::Client.new
  end

  def make_api_call(parameters)
    client.chat.completions.create(parameters)
  end

  def format_response(response, schema)
    # Return structured response wrapper
    choice = response.choices.first
    {
      content: choice.message.content,  # Raw JSON string from API
      parsed: parse_response(choice.message.content, schema),  # Parsed and validated data
      id: response.id,
      model: response.model,
      usage: response.usage
    }
  end

  def build_parameters(model:, messages:, temperature:, response_format:, schema:)
    parameters = super

    # Use RubyLLM schema if provided
    if schema && schema < RubyLLM::Schema
      parameters[:response_format] = {
        type: "json_schema",
        json_schema: JSON.parse(schema.new.to_json)
      }
    elsif response_format
      parameters[:response_format] = response_format
    end

    parameters
  end
end

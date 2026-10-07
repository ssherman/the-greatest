# frozen_string_literal: true

# Stubs the OpenAI strategy so a list-items validator task "answers" with the
# given invalid positions, without a network call.
module ValidatorResponseStub
  private

  def stub_validator_response(invalid:)
    data = {invalid: invalid, reasoning: "test"}
    strategy = mock("strategy")
    strategy.stubs(:send_message!).returns({content: data.to_json, parsed: data, id: "chatcmpl-1", model: "gpt-5",
      usage: {prompt_tokens: 1, completion_tokens: 1, total_tokens: 2}})
    strategy.stubs(:provider_key).returns("openai")
    strategy.stubs(:default_model).returns("gpt-5")
    strategy.stubs(:capabilities).returns([:json_mode, :json_schema])
    Services::Ai::Providers::OpenaiStrategy.stubs(:new).returns(strategy)
  end
end

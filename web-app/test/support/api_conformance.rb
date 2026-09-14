# Helpers for API integration tests.
module ApiConformance
  def bearer(secret) = {"Authorization" => "Bearer #{secret}"}

  # Validates only the RESPONSE against the OpenAPI document. For the tests
  # that deliberately send an invalid request (page=0): assert_api_conform
  # validates the request too and would fail on exactly the input under test.
  def assert_api_response_conform(status:)
    assert_equal status, response.status, "#{request.request_method} #{request.fullpath}"
    validated = OpenapiFirst::Test[:default].validate_response(request, response, raise_error: false)
    assert validated.valid?, validated.error&.exception_message
  end
end

# OpenapiFirst::Test::Methods.included(base) picks Minitest assertions
# (assert_api_conform) only when base already includes Minitest::Assertions --
# ActionDispatch::IntegrationTest does, a bare module does not. Including it
# here rather than inside ApiConformance is what selects the Minitest helpers
# instead of the plain (raising) ones.
module ActionDispatch
  class IntegrationTest
    include OpenapiFirst::Test::Methods
    include ApiConformance
  end
end

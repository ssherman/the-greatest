# Helpers for API integration tests.
module ApiConformance
  def bearer(secret) = {"Authorization" => "Bearer #{secret}"}

  # Validates only the RESPONSE against the OpenAPI document. For the tests
  # that deliberately send an invalid request (page=0) -- assert_api_conform
  # would fail on the request half, which is the point of the test.
  # Defined in Task 11 once openapi_first is wired up; until then this is a
  # status assertion only.
  def assert_api_response_conform(status:)
    assert_equal status, response.status
  end
end

module ActionDispatch
  class IntegrationTest
    include ApiConformance
  end
end

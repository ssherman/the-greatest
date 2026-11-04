require "test_helper"

# Each operation in the OpenAPI documents declares the scope it needs, and a
# later layer (the MCP tools) filters on that declaration. So the declaration
# has to equal what the routed controller actually enforces, or a tool would be
# offered to a token that the REST endpoint then refuses (or the reverse).
class OperationScopeContractTest < ActiveSupport::TestCase
  HOST_URL = "https://dev-new.thegreatestbooks.org"

  %i[public admin].each do |document|
    ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(document)).each do |op|
      test "#{document} #{op.operation_id} declares the scope its controller enforces" do
        # A tuple, because one side is nil for getOpenapi and Minitest 6 rejects `assert_equal nil, x`.
        assert_equal [op.operation_id, enforced_scope_for(op)], [op.operation_id, op.scope],
          "#{op.operation_id} (#{op.http_method.upcase} #{op.path}) declares a scope that differs from its controller's"
      end
    end
  end

  test "every operation declares security explicitly" do
    %i[public admin].each do |document|
      ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(document)).each do |op|
        assert op.definition.key?("security"), "#{op.operation_id} has no security key"
      end
    end
  end

  test "getOpenapi is the only public operation without a scope" do
    unscoped = ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(:public)).select { |op| op.scope.nil? }

    assert_equal ["getOpenapi"], unscoped.map(&:operation_id)
  end

  test "every admin operation declares a scope" do
    ::Api::OpenapiDocument.operations(::Api::OpenapiDocument.raw(:admin)).each do |op|
      assert_not_nil op.scope, "#{op.operation_id} has no scope"
    end
  end

  private

  def enforced_scope_for(op)
    recognised = Rails.application.routes.recognize_path(sample_url(op.path), method: op.http_method)
    controller = "#{recognised[:controller]}_controller".camelize.constantize
    return nil unless controller < ::Api::V1::BaseController

    if controller.action_scopes
      controller.action_scopes[recognised[:action]]
    else
      controller.required_scope
    end
  end

  def sample_url(path)
    filled = path.gsub(/\{(id|category_id)\}/, "1").gsub(/\{[^}]+\}/, "x")
    "#{HOST_URL}#{filled}"
  end
end

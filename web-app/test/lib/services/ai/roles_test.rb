require "test_helper"

module Services
  module Ai
    class RolesTest < ActiveSupport::TestCase
      test "resolves the four roles from config" do
        assert_equal %i[fast standard premium research], Roles.names
      end

      test "a role carries provider, model and tools" do
        role = Roles.resolve(:research)

        assert_equal :research, role.name
        assert_equal :openai, role.provider
        assert_equal "gpt-6-astra", role.model
        assert_equal [:web_search], role.tools
        assert role.frozen?
      end

      test "roles without tools resolve to an empty tools array" do
        assert_equal [], Roles.resolve(:fast).tools
      end

      test "accepts a string name" do
        assert_equal Roles.resolve(:standard), Roles.resolve("standard")
      end

      test "an unknown role raises" do
        error = assert_raises(Roles::UnknownRole) { Roles.resolve(:nope) }
        assert_includes error.message, "nope"
        assert_includes error.message, "fast"
      end

      test "every configured provider is one AiChat can record" do
        Roles.names.each do |name|
          assert AiChat.providers.key?(Roles.resolve(name).provider.to_s), "#{name} names an unknown provider"
        end
      end

      test "no configured model is the retired gpt-5-mini" do
        Roles.names.each do |name|
          refute_equal "gpt-5-mini", Roles.resolve(name).model
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class SignatureTest < ActiveSupport::TestCase
          test "case, curly quotes, spacing and creator order do not change a signature" do
            assert_equal Signature.call("The Hitchhiker’s Guide", ["Douglas Adams", "Eoin Colfer"]),
              Signature.call("  the hitchhiker's   guide ", ["eoin colfer", "DOUGLAS ADAMS"])
          end

          test "a different title or a different creator does" do
            base = Signature.call("Emma", ["Jane Austen"])

            assert_not_equal base, Signature.call("Persuasion", ["Jane Austen"])
            assert_not_equal base, Signature.call("Emma", ["Emma Tennant"])
          end

          test "normalize answers nil for nil and drops blank creators" do
            assert_nil Signature.normalize(nil)
            assert_equal ["emma", ["jane austen"]], Signature.call("Emma", ["Jane Austen", "", nil])
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

# For tests that plan or advance a run without wanting its steps to execute:
# Sidekiq runs jobs inline in tests, so an unstubbed dispatch would run the
# whole workflow. Returns the mocha expectation, so a test can narrow it
# (`.with(...)`) or assert on it (`.once`).
module Workflows
  module DispatchHelper
    def stub_workflow_dispatch
      Workflows::Dispatcher.stubs(:dispatch)
    end
  end
end

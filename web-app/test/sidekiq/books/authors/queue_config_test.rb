# frozen_string_literal: true

require "test_helper"

class Books::Authors::QueueConfigTest < ActiveSupport::TestCase
  test "the chain's queue is listed in sidekiq.yml, last, so its jobs run and never queue ahead of others" do
    queues = YAML.load_file(Rails.root.join("config/sidekiq.yml"))[:queues].map(&:to_s)

    assert_equal ["author_chain"], ::Services::Books::Authors::QueuedChain.queues
    assert_equal "author_chain", queues.last
  end
end

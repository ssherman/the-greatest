# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # The words every description prompt bans and every description
        # review looks for, in one place so the writer and the reviewer never
        # disagree about the list.
        module BannedWords
          WORDS = %w[delve tapestry testament poignant seminal groundbreaking timeless gripping compelling journey
            navigate resonate profound haunting luminous].freeze
          PHRASE = '"explores themes of"'

          # A writing rule's form: '..., luminous, or "explores themes of"'.
          def self.prose = "#{WORDS.join(", ")}, or #{PHRASE}"

          # A review code's form: '..., luminous, "explores themes of"'.
          def self.list = (WORDS + [PHRASE]).join(", ")
        end
      end
    end
  end
end

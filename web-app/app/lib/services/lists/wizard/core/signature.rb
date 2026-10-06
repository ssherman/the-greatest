# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # How the wizard compares row text: the finder's normalization (quotes,
        # Unicode width, spacing, case) on the title and each creator, creators
        # sorted. Re-parse uses it to skip a row a kept row already covers.
        module Signature
          def self.normalize(text)
            return nil if text.nil?

            ::Services::Text::NameNormalizer.call(::Services::Text::QuoteNormalizer.call(text.to_s)).downcase
          end

          def self.call(title, creators)
            [normalize(title).to_s, Array(creators).map { |name| normalize(name) }.compact_blank.sort]
          end
        end
      end
    end
  end
end

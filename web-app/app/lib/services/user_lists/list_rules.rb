# frozen_string_literal: true

module Services
  module UserLists
    # The rules for a user list's name and description, shared by the API and the web pages.
    module ListRules
      NAME_MAX = 100
      DESCRIPTION_MAX = 1_000

      # Stripped name, or nil when it is blank, too long or holds a NUL.
      def self.normalize_name(raw)
        name = raw.is_a?(String) ? raw.strip : nil
        return nil if name.nil? || name.empty? || name.length > NAME_MAX || name.include?("\u0000")

        name
      end

      # Stripped description (blank becomes nil), or :invalid. nil clears it.
      def self.normalize_description(raw)
        return nil if raw.nil?

        text = raw.is_a?(String) ? raw.strip : nil
        return :invalid if text.nil? || text.length > DESCRIPTION_MAX || text.include?("\u0000")

        text.presence
      end
    end
  end
end

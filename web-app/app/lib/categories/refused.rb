# frozen_string_literal: true

module Categories
  # A merge or delete that would break an invariant (spec §1.3). The message is
  # shown to admins as-is.
  class Refused < StandardError; end
end

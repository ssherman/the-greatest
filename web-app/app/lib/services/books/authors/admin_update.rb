# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The one save an admin makes on an author's editable fields; see
      # Services::Books::AdminUpdate, which holds the shared rules. Here
      # alternate_names is a plain array attribute, assigned like the rest.
      class AdminUpdate
        def self.call(author:, attrs:, user:, via:, explicit_nulls: [])
          Services::Books::AdminUpdate.persist(record: author, attrs: attrs, user: user, via: via, explicit_nulls: explicit_nulls)
        end
      end
    end
  end
end

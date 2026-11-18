# frozen_string_literal: true

module Books
  module PublisherIntake
    # outcome: :found | :not_found | :blocked | :unparseable | :unavailable.
    # facts is a hash keyed by Books::PublisherTitle column names (symbols);
    # sibling_keys are the ISBNs of other formats the page listed.
    Reading = Data.define(:outcome, :facts, :sibling_keys)
  end
end

module Services
  module BooksMigration
    # Pure decision: legacy list_con attrs -> reuse an existing Global::Penalty or
    # create a Books::Penalty. Dynamic list_cons resolve by dynamic_type (the legacy
    # name is ignored — it can be mistyped); percentage_western has no seeded global
    # (owner: book-specific) so it always creates. Static list_cons reuse a Global by
    # exact name or via GLOBAL_ALIASES (books->items / quote-only rewrites), else create.
    class PenaltyResolver
      LEGACY_DYNAMIC_TYPE = {
        0 => "number_of_voters",
        1 => "percentage_western",
        2 => "voter_names_unknown",
        3 => "voter_count_unknown",
        4 => "category_specific"
      }.freeze

      GLOBAL_ALIASES = {
        "List: contains over 500 books(Quantity over Quality)" => "List: contains over 500 items(Quantity over Quality)",
        "List: Creator of the list, sells the books on the list" => "List: Creator of the list, sells the items on the list",
        'List: criteria is not just "best/favorite"' => "List: criteria is not just best/favorite"
      }.freeze

      def initialize(globals_by_name:, globals_by_dynamic_type:)
        @globals_by_name = globals_by_name
        @globals_by_dynamic_type = globals_by_dynamic_type
      end

      def call(attrs)
        dynamic_type = attrs["dynamic_type"]
        name = attrs["name"]

        if dynamic_type
          label = LEGACY_DYNAMIC_TYPE.fetch(dynamic_type)
          return [:create_books, {name: name, dynamic_type: "percentage_western"}] if label == "percentage_western"
          [:reuse, @globals_by_dynamic_type.fetch(label)]
        else
          global = @globals_by_name[GLOBAL_ALIASES.fetch(name, name)]
          global ? [:reuse, global] : [:create_books, {name: name, dynamic_type: nil}]
        end
      end
    end
  end
end

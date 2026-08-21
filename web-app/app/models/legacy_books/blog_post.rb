module LegacyBooks
  class BlogPost < Record
    self.table_name = "blog_posts"

    # ActionText stores the body under name "content" keyed by the polymorphic
    # record. The legacy class name is "BlogPost", which is what record_type
    # holds -- NOT this namespaced constant.
    has_one :rich_text_content,
      -> { where(name: "content") },
      class_name: "LegacyBooks::RichText",
      foreign_key: :record_id,
      as: :record

    def body_html = rich_text_content&.body

    # By default Rails derives the polymorphic type from this class's own
    # name ("LegacyBooks::BlogPost"), which would match zero rows -- the
    # legacy app was not namespaced, so record_type holds the literal
    # "BlogPost". This is the standard Rails 6+ hook for exactly this case.
    def self.polymorphic_name
      "BlogPost"
    end
  end
end

# == Schema Information
#
# Table name: blog_posts
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(FALSE), not null
#  front_page :boolean          default(FALSE), not null
#  pinned     :boolean          default(FALSE), not null
#  slug       :string
#  tags       :string           default([]), is an Array
#  title      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  blog_id    :bigint           not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_blog_posts_on_blog_id  (blog_id)
#  index_blog_posts_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (blog_id => blogs.id)
#  fk_rails_...  (user_id => users.id)
#
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

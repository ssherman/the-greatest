# frozen_string_literal: true

module Api
  module V1
    module Admin
      # A news topic as an admin API client sees it. Key order here IS the order
      # in config/api/v1/admin_openapi.yaml.
      class NewsTopicResource
        def initialize(topic)
          @topic = topic
        end

        # The reference a post row carries.
        def to_h = {id: @topic.id, name: @topic.name, slug: @topic.slug}

        # The topics list: the reference plus how many posts of any status carry it.
        def to_counted_h(posts_count) = to_h.merge(posts_count: posts_count)
      end
    end
  end
end

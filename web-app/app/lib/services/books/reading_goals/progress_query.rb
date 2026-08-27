module Services
  module Books
    module ReadingGoals
      class ProgressQuery
        PER_PAGE = 24

        Progress = Struct.new(
          :items, :count, :percentage, :complete, :bar_percentage,
          keyword_init: true
        )

        def self.call(goal:, page: 1)
          new(goal: goal, page: page).call
        end

        def initialize(goal:, page: 1)
          @goal = goal
          @page = [page.to_i, 1].max
        end

        def call
          relation = projected_items
          count = relation.count
          percentage = count.zero? ? 0.0 : (count.fdiv(goal.target_count) * 100).round(1)

          Progress.new(
            items: relation.offset((page - 1) * PER_PAGE).limit(PER_PAGE).to_a,
            count: count,
            percentage: percentage,
            complete: count >= goal.target_count,
            bar_percentage: [percentage, 100.0].min
          )
        end

        private

        attr_reader :goal, :page

        def projected_items
          list = ::Books::UserList.find_by(user: goal.user, list_type: :read)
          return ::UserListItem.none if list.nil?

          list.user_list_items
            .where(listable_type: "Books::Book", completed_on: goal.starts_on..goal.ends_on)
            .includes(listable: ::Books::UserList.listable_display_includes + [{primary_image: {file_attachment: :blob}}])
            .reorder(completed_on: :desc, id: :desc)
        end
      end
    end
  end
end

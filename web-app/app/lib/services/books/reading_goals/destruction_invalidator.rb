module Services
  module Books
    module ReadingGoals
      class DestructionInvalidator
        def self.for_book(book:)
          new.for_book(book:)
        end

        def self.for_user(user:)
          new.for_user(user:)
        end

        def for_book(book:)
          lock_users(read_memberships(book).distinct.pluck("user_lists.user_id"))

          read_memberships(book)
            .where.not(completed_on: nil)
            .includes(user_list: :user)
            .flat_map { |entry| urls_for_user_on(entry.user_list.user, entry.completed_on) }
            .uniq
        end

        def for_user(user:)
          ::User.lock.find(user.id).books_reading_goals.public_goals.order(:id).flat_map { |goal| urls_for(goal) }
        end

        private

        def read_memberships(book)
          book.user_list_items
            .joins(:user_list)
            .merge(::Books::UserList.read)
        end

        def lock_users(ids)
          ::User.lock.where(id: ids).order(:id).load
        end

        def urls_for_user_on(user, completed_on)
          user.books_reading_goals.public_goals
            .where("starts_on <= ? AND ends_on >= ?", completed_on, completed_on)
            .order(:id)
            .flat_map { |goal| urls_for(goal) }
        end

        def urls_for(goal)
          count = ProgressQuery.call(goal: goal).count
          CachedUrls.call(goal: goal, count: count)
        end
      end
    end
  end
end

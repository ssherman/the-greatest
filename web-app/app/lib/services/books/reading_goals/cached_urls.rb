module Services
  module Books
    module ReadingGoals
      class CachedUrls
        def self.call(goal:, count:)
          new(goal: goal, count: count).call
        end

        def initialize(goal:, count:)
          @goal = goal
          @count = count
        end

        def call
          hosts.flat_map { |host| urls_for(host) }.uniq
        end

        private

        attr_reader :goal, :count

        def hosts
          Rails.application.config.domains[:books]
            .to_s.split(",").reject(&:blank?)
        end

        def urls_for(host)
          base = "https://#{host}/reading_goals/#{goal.id}"
          [base] + (2..pages).map { |page| "#{base}/page/#{page}" }
        end

        def pages
          [1, count.to_i.fdiv(ProgressQuery::PER_PAGE).ceil].max
        end
      end
    end
  end
end

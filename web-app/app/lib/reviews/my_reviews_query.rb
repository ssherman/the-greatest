# frozen_string_literal: true

module Reviews
  # Filtering and sorting for /my/reviews.
  #
  # Everything happens in SQL. MyListsController#ranking_sorted loads a whole
  # collection and sorts it in Ruby, which is fine for a list but not here: the
  # measured ceiling is 2,331 reviews for one user, with p90 at 241. Sorting in
  # Ruby would mean loading a user's entire history to render 25 rows.
  #
  # Scoped to exactly ONE reviewable class. A domain with several reviewable types
  # (music will have albums and songs) renders a type switcher instead of widening
  # this query, because sorting by title or rank across two tables means a UNION
  # that pages and counts badly.
  class MyReviewsQuery
    DEFAULT_SORT = "recent"
    SORTS = %w[recent rating_high rating_low rank title].freeze
    KINDS = %w[written rating_only].freeze
    RATINGS = (1..5)

    attr_reader :user, :reviewable_class, :params

    def initialize(user:, reviewable_class:, params: {})
      @user = user
      @reviewable_class = reviewable_class
      @params = params
    end

    def call
      scope = base_scope
      scope = scope.where(rating: rating) if rating
      scope = scope.where.not(body: nil) if kind == "written"
      scope = scope.where(body: nil) if kind == "rating_only"
      scope = reviewable_class.review_text_search(scope, term) if term
      apply_sort(scope)
    end

    def available_sorts
      ranking_configuration ? SORTS : SORTS - ["rank"]
    end

    def sort
      requested = params[:sort].to_s
      available_sorts.include?(requested) ? requested : DEFAULT_SORT
    end

    # A crafted `?rating[]=1` or `?rating[a]=1` hands back an Array or an
    # ActionController::Parameters instead of a scalar -- neither responds to
    # `#to_i`, so this must check the type before converting rather than
    # rescuing after the fact.
    def rating
      value = params[:rating]
      return nil unless value.is_a?(String) || value.is_a?(Integer)

      value = value.to_i
      RATINGS.include?(value) ? value : nil
    end

    def kind
      KINDS.include?(params[:kind].to_s) ? params[:kind].to_s : nil
    end

    def term
      params[:q].to_s.strip.presence
    end

    private

    def base_scope
      table = reviewable_class.table_name
      user.reviews
        .where(reviewable_type: reviewable_class.name)
        .joins("INNER JOIN #{table} ON #{table}.id = reviews.reviewable_id")
    end

    def apply_sort(scope)
      case sort
      when "rating_high" then scope.order(rating: :desc, id: :desc)
      when "rating_low" then scope.order(rating: :asc, id: :desc)
      when "title" then scope.order(Arel.sql("#{reviewable_class.review_title_order} ASC"), id: :desc)
      when "rank" then scope.joins(rank_join).order(Arel.sql("ranked_items.rank ASC NULLS LAST"), id: :desc)
      else scope.order(created_at: :desc, id: :desc)
      end
    end

    # LEFT OUTER so an unranked item still appears -- an INNER JOIN here would
    # silently drop every review of something the site has not ranked, which on a
    # personal history reads as data loss.
    def rank_join
      config = ranking_configuration
      <<~SQL.squish
        LEFT OUTER JOIN ranked_items
          ON ranked_items.item_id = reviews.reviewable_id
         AND ranked_items.item_type = #{ActiveRecord::Base.connection.quote(reviewable_class.name)}
         AND ranked_items.ranking_configuration_id = #{config.id.to_i}
      SQL
    end

    def ranking_configuration
      return @ranking_configuration if defined?(@ranking_configuration)

      @ranking_configuration = reviewable_class.ranking_configuration_class&.default_primary
    end
  end
end

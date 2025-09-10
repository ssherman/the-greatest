# Ranking Strategy Documentation

## Overview

This document provides comprehensive documentation of a weighted list ranking system designed for "The Greatest Books" application. The ranking strategy uses an exponential scoring algorithm with configurable parameters to aggregate multiple ranked lists into a single consolidated ranking.

## Key Features

- **Weighted List Aggregation**: Combines multiple ranked lists with different weights
- **Exponential Scoring Strategy**: Uses exponential decay for position-based scoring
- **Score Penalties**: Applies penalties based on publication date differences
- **Bonus Pool Distribution**: Distributes bonus points among top-performing items
- **Caching System**: Redis-based caching for performance optimization
- **Two Calculator Versions**: Original and enhanced V2 with additional features

## Architecture

The ranking system is built using several key components:

1. **Rankings::List** - Represents a weighted list containing ranked items
2. **Rankings::Item** - Represents individual items with position and optional penalties
3. **Rankings::Calculator** - Original calculator implementation
4. **Rankings::CalculatorV2** - Enhanced calculator with additional features

## Source Code

### Rankings::List

```ruby
# frozen_string_literal: true

module Rankings
  class List
    include WeightedListRank::List
    attr_reader :id, :weight, :items

    def initialize(id, weight, items)
      @id = id
      @weight = weight
      @items = items
    end
  end
end
```

**Purpose**: Represents a single ranked list with a unique identifier, weight factor, and collection of ranked items. The weight determines how much influence this list has in the final aggregated ranking.

### Rankings::Item

```ruby
# frozen_string_literal: true

module Rankings
  class Item
    include WeightedListRank::Item
    attr_reader :id, :position, :score_penalty

    def initialize(id, position, score_penalty = nil)
      @id = id
      @position = position
      @score_penalty = score_penalty
    end
  end
end
```

**Purpose**: Represents an individual item within a ranked list. Each item has a unique identifier, position in the list, and an optional score penalty that can reduce its final score based on various criteria (e.g., publication date differences).

### Rankings::Calculator (Original)

```ruby
# frozen_string_literal: true

require "redis"
require "json"
require "weighted_list_rank"
require_relative "list"
require_relative "item"

module Rankings
  class Calculator
    attr_reader :ranking_configuration, :redis, :exponent

    def initialize(ranking_configuration:, list_limit: nil)
      @ranking_configuration = ranking_configuration
      @redis = Redis.new
      @exponent = @ranking_configuration.exponent.to_f
    end

    delegate :max_age_for_penalty, to: :ranking_configuration
    delegate :max_penalty_percentage, to: :ranking_configuration
    delegate :apply_list_dates_penalty, to: :ranking_configuration
    delegate :bonus_pool_percentage, to: :ranking_configuration

    def calculate_for_list(ranked_list, ignore_cache: false)
      cache_key = "rankings:list:#{ranked_list.list_id}"

      if !ignore_cache
        cached_rankings = redis.get(cache_key)
        return JSON.parse(cached_rankings, symbolize_names: true) if cached_rankings
      end

      # Prepare the list
      items = prepare_items(ranked_list)

      list = Rankings::List.new(ranked_list.list_id, ranked_list.weight, items)

      # Calculate the ranking using the existing strategy
      exponential_strategy = WeightedListRank::Strategies::Exponential.new(exponent:, bonus_pool_percentage:)
      ranking_context = WeightedListRank::RankingContext.new(exponential_strategy)
      ranking_data = ranking_context.rank([list])

      # Cache the new ranking data for this list
      redis.set(cache_key, ranking_data.to_json)
      ranking_data
    end

    def calculate(ignore_cache: false)
      cache_key = "rankings:#{ranking_configuration.id}"

      if !ignore_cache
        cached_rankings = redis.get(cache_key)
        return JSON.parse(cached_rankings, symbolize_names: true) if cached_rankings
      end

      lists = fetch_and_prepare_lists

      exponential_strategy = WeightedListRank::Strategies::Exponential.new(exponent:, bonus_pool_percentage:)
      ranking_context = WeightedListRank::RankingContext.new(exponential_strategy)
      rankings_data = ranking_context.rank(lists)

      # Cache the new rankings data
      redis.set(cache_key, rankings_data.to_json)
      rankings_data
    end

    protected
      def fetch_and_prepare_lists
        ranked_lists = ranking_configuration.ranked_lists
                          .joins(:list)
                          .includes(:list)
                          .includes(list: :list_items)
                          .includes(list: { list_items: :book })
                          .where(lists: { status: :active })
                          .order(weight: :desc)

        lists = []
        ranked_lists.each do |ranked_list|
          items = prepare_items(ranked_list)
          list = Rankings::List.new(ranked_list.list_id, ranked_list.weight, items)
          lists << list
        end

        lists
      end

      def prepare_items(ranked_list)
        ranked_list.list_items.map do |list_item|
          score_penalty = calculate_score_penalty(ranked_list.list, list_item.book) if apply_list_dates_penalty
          Rankings::Item.new(list_item.book_id, list_item.position, score_penalty).tap do |item|
            if score_penalty
              Rails.logger.debug("Penalty applied #{score_penalty}: Book ID: #{list_item.book_id}, Title: #{list_item.book.title}, First Year Published: #{list_item.book.first_year_published}, List Year Published: #{ranked_list.list.year_published}, List ID: #{ranked_list.list_id}")
            end
          end
        end
      end

      def calculate_score_penalty(list, book)
        return (max_penalty_percentage / 100.0) if list.yearly_award? || book.first_year_published.nil?
        return nil unless list.year_published && book.first_year_published

        year_difference = list.year_published - book.first_year_published

        penalty = if year_difference <= 0
          max_penalty_percentage / 100.0
        elsif year_difference > max_age_for_penalty
          nil
        else
          # Reverse the penalty calculation
          p = ((max_age_for_penalty - year_difference).to_f / max_age_for_penalty) * max_penalty_percentage
          p / 100.0
        end
        penalty == 0 ? nil : penalty
      end
  end
end
```

**Purpose**: The original calculator implementation that handles the core ranking logic. It fetches ranked lists, applies score penalties based on publication dates, and uses an exponential strategy to calculate final rankings. Includes Redis caching for performance optimization.

### Rankings::CalculatorV2 (Enhanced)

```ruby
# frozen_string_literal: true

require_relative "calculator"

module Rankings
  class CalculatorV2 < Calculator
    attr_reader :average_list_length

    def initialize(ranking_configuration:, list_limit: nil)
      puts "Initializing CalculatorV2 with ranking_configuration: #{ranking_configuration.id}"
      super
      @average_list_length = ::List.median_list_count
    end

    def calculate_for_list(ranked_list, ignore_cache: false)
      cache_key = "rankings:v2:list:#{ranked_list.list_id}"

      if !ignore_cache
        cached_rankings = redis.get(cache_key)
        return JSON.parse(cached_rankings, symbolize_names: true) if cached_rankings
      end

      # Prepare the list
      items = prepare_items(ranked_list)

      list = Rankings::List.new(ranked_list.list_id, ranked_list.weight, items)

      # Calculate the ranking using the updated strategy
      exponential_strategy = WeightedListRank::Strategies::Exponential.new(
        exponent: @exponent,
        bonus_pool_percentage: @ranking_configuration.bonus_pool_percentage,
        average_list_length: @average_list_length,
        include_unranked_items: true
      )
      ranking_context = WeightedListRank::RankingContext.new(exponential_strategy, list_count_penalties: { 1 => 0.5, 2 => 0.25 })
      ranking_data = ranking_context.rank([list])

      # Cache the new ranking data for this list
      redis.set(cache_key, ranking_data.to_json)
      ranking_data
    end

    def calculate(ignore_cache: false)
      cache_key = "rankings:v2:#{ranking_configuration.id}"

      if !ignore_cache
        cached_rankings = redis.get(cache_key)
        return JSON.parse(cached_rankings, symbolize_names: true) if cached_rankings
      end

      lists = fetch_and_prepare_lists

      exponential_strategy = WeightedListRank::Strategies::Exponential.new(
        exponent: @exponent,
        bonus_pool_percentage: @ranking_configuration.bonus_pool_percentage,
        average_list_length: @average_list_length,
        include_unranked_items: true
      )
      ranking_context = WeightedListRank::RankingContext.new(exponential_strategy, list_count_penalties: { 1 => 0.5, 2 => 0.25 })
      rankings_data = ranking_context.rank(lists)

      # Cache the new rankings data
      redis.set(cache_key, rankings_data.to_json)
      rankings_data
    end
  end
end
```

**Purpose**: Enhanced version of the calculator that extends the original with additional features:
- **Average List Length**: Considers the median list count for more balanced scoring
- **Include Unranked Items**: Allows items not explicitly ranked to participate in scoring
- **List Count Penalties**: Applies penalties based on how many lists an item appears in (1 list = 50% penalty, 2 lists = 25% penalty)

## Key Configuration Parameters

### Exponential Strategy Parameters
- **exponent**: Controls the exponential decay rate for position-based scoring
- **bonus_pool_percentage**: Percentage of total points allocated to bonus pool distribution
- **average_list_length**: Used in V2 for normalized scoring across different list lengths

### Penalty System Parameters
- **max_age_for_penalty**: Maximum age difference (in years) before penalties stop applying
- **max_penalty_percentage**: Maximum penalty that can be applied (as percentage)
- **apply_list_dates_penalty**: Boolean flag to enable/disable date-based penalties

### List Count Penalties (V2 Only)
- Items appearing in only 1 list receive a 50% penalty
- Items appearing in only 2 lists receive a 25% penalty
- Items in 3+ lists receive no penalty

## Usage Patterns

### Basic Ranking Calculation
```ruby
calculator = Rankings::Calculator.new(ranking_configuration: config)
rankings = calculator.calculate(ignore_cache: false)
```

### Single List Calculation
```ruby
calculator = Rankings::CalculatorV2.new(ranking_configuration: config)
list_rankings = calculator.calculate_for_list(ranked_list, ignore_cache: true)
```

## Caching Strategy

The system uses Redis for caching with different cache keys:
- **Original Calculator**: `rankings:#{configuration_id}` and `rankings:list:#{list_id}`
- **V2 Calculator**: `rankings:v2:#{configuration_id}` and `rankings:v2:list:#{list_id}`

Cache can be bypassed by setting `ignore_cache: true` in method calls.

## Dependencies

- **weighted_list_rank**: Core ranking algorithm gem
- **redis**: Caching layer
- **json**: Data serialization
- **Rails**: Framework dependencies (logging, delegation)

## Score Penalty Logic

The penalty system works as follows:

1. **Yearly Awards**: Always receive maximum penalty
2. **Missing Publication Dates**: Receive maximum penalty
3. **Age-Based Penalties**: 
   - Books published after the list date receive maximum penalty
   - Books older than `max_age_for_penalty` receive no penalty
   - Books in between receive graduated penalties based on age difference

The penalty calculation uses a reverse linear scale where newer books (closer to list publication date) receive higher penalties, encouraging recognition of older, more established works.

## Performance Considerations

- Redis caching significantly improves performance for repeated calculations
- Database queries are optimized with appropriate includes and joins
- V2 calculator adds computational overhead with additional features but provides more sophisticated ranking logic

## RankingConfiguration Key Methods

The `RankingConfiguration` model contains several critical methods that work with the ranking calculators:

### refresh_book_rankings

```ruby
def refresh_book_rankings
  # Disable reindexing during bulk update
  RankedBook.disable_reindex_callbacks = true

  ActiveRecord::Base.transaction do
    rankings = calculator.calculate(ignore_cache: true)
    previous_score = nil
    last_assigned_position = 0

    # Pre-load books to avoid N+1 queries
    ranked_books_indexed = self.ranked_books.includes(:book).index_by(&:book_id)

    applied_list_limit = false
    if apply_global_age_penalty?
      # First pass to apply penalties and sort
      adjusted_rankings = rankings.map do |ranking|
        total_score = ranking[:total_score]

        if list_limit
          # Extract score_details array and sort by :score in descending order
          score_details = ranking[:score_details].sort_by { |detail| -detail[:score] }

          # Sum up the score of the top 5 lists
          total_score = score_details.first(list_limit).sum { |detail| detail[:score] }
          applied_list_limit = true
        end

        book_id = ranking[:id]
        book = ranked_books_indexed[book_id].book
        penalized_score = self.class.apply_global_age_penalty(total_score, book, self)

        ranking.merge!(total_score: penalized_score)
      end.sort_by { |r| -r[:total_score] }  # Sort by total_score in descending order
      rankings = adjusted_rankings
    end

    if !applied_list_limit && list_limit
      rankings.map! do |ranking|
        # Extract score_details array and sort by :score in descending order
        score_details = ranking[:score_details].sort_by { |detail| -detail[:score] }

        # Sum up the score of the top 5 lists
        total_score = score_details.first(list_limit).sum { |detail| detail[:score] }
        ranking.merge!(total_score:)
      end
    end

    rankings.sort_by { |r| -r[:total_score] }.each_with_index do |ranking, index|
      ranked_book = ranked_books_indexed[ranking[:id]]
      if ranked_book.nil?
        ranked_book = self.ranked_books.find_or_create_by!(book_id: ranking[:id])
        msg = "ranked_book is nil for ranking: #{ranking.inspect} with id: #{ranking[:id]}"
        puts msg
        Rails.logger.warn(msg)
      end
      total_score = ranking[:total_score]

      # If the current book's score matches the previous score, use the last assigned position.
      # Otherwise, set it to the current index + 1 and update the last assigned position.
      if total_score == previous_score
        ranked_book.combined_position = last_assigned_position
      else
        ranked_book.combined_position = index + 1
        last_assigned_position = ranked_book.combined_position
      end

      number_of_lists = ranking[:score_details].length
      Rails.logger.debug("number_of_lists for ranked_book id: #{ranked_book.id} is: #{number_of_lists}")

      ranked_book.score = total_score
      previous_score = total_score # Update previous_score for the next iteration

      ranked_book.save!
    end
  end
  trigger_page_cache_destroyer_job
ensure
  # Always re-enable reindexing, even if an error occurs
  RankedBook.disable_reindex_callbacks = false
end
```

**Purpose**: This is the core method that processes rankings from the calculator and updates the database with final scores and positions. It handles tie-breaking, applies global age penalties, enforces list limits, and manages database transactions.

### calculator

```ruby
def calculator
  @calculator ||= if algorithm_version >= 3
    Rankings::CalculatorV2.new(ranking_configuration: self)
  else
    Rankings::Calculator.new(ranking_configuration: self)
  end
end
```

**Purpose**: Factory method that returns the appropriate calculator instance based on the algorithm version. Version 3+ uses CalculatorV2 with enhanced features.

### apply_global_age_penalty (Class Method)

```ruby
def self.apply_global_age_penalty(original_score, book, ranking_configuration)
  # Calculate penalty percentage using the class method from RankingConfiguration
  penalty_percentage = RankingConfiguration.calculate_penalty_percentage(book, ranking_configuration)

  penalty_factor = 1.0 - (penalty_percentage / 100.0)  # Converts penalty into a factor to be multiplied by the original score
  penalized_score = original_score * penalty_factor
  penalized_score
end
```

**Purpose**: Applies a global age-based penalty to book scores based on publication date and configuration settings.

### calculate_penalty_percentage (Class Method)

```ruby
def self.calculate_penalty_percentage(book, ranking_configuration)
  return ranking_configuration.max_penalty_percentage if book.first_year_published.nil?
  return 0 if book.first_year_published == 0

  max_age = ranking_configuration.max_age_for_penalty
  max_penalty = ranking_configuration.max_penalty_percentage

  age = Time.zone.now.year - book.first_year_published
  return 0 if age >= max_age

  max_penalty * (1 - (age.to_f / max_age))
end
```

**Purpose**: Calculates the penalty percentage for a book based on its age. Newer books receive higher penalties, encouraging recognition of older, established works.

### trigger_page_cache_destroyer_job

```ruby
def trigger_page_cache_destroyer_job
  PageCacheDestroyerJob.perform_async
end
```

**Purpose**: Triggers a background job to clear cached pages when rankings are updated, ensuring users see fresh data.

## Key Workflow

The typical ranking workflow follows this pattern:

1. **Configuration Setup**: RankingConfiguration defines parameters (exponent, penalties, weights)
2. **Calculator Selection**: `calculator` method chooses appropriate calculator version
3. **Raw Calculation**: Calculator processes lists and items using exponential strategy
4. **Post-Processing**: `refresh_book_rankings` applies global penalties, list limits, and tie-breaking
5. **Database Update**: Final scores and positions are saved to RankedBook records
6. **Cache Invalidation**: Page caches are cleared to reflect new rankings

This ranking strategy provides a flexible, configurable system for aggregating multiple ranked lists while accounting for various factors like list weights, publication dates, and list participation patterns.

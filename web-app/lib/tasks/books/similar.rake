# frozen_string_literal: true

# Development tuning harness for the Similar Books feature. Read-only: it runs
# queries and prints, and never writes to the database or the index.
#
# Both Services::Books::SimilarBooks and Search::Books::Search::BookSimilar merge
# per-call overrides over config/initializers/book_similarity.rb, so one process can
# run every knob combination back to back. That is the whole reason this task can
# exist -- tuning otherwise means editing the initializer and restarting per value.
module BooksSimilarCompare
  module_function

  # Four books with clean slugs and known behaviour: Gatsby is the diagnostic (it
  # returns obscure literary fiction), the other three are the controls that already
  # return good results. A change that fixes Gatsby and breaks these is not a fix.
  CONTROL_SLUGS = %w[the-great-gatsby dune 1984 the-selfish-gene].freeze

  def base_config
    Rails.application.config.x.book_similarity
  end

  def resolve_books(raw)
    slugs = raw.presence&.split(",")&.map(&:strip)&.reject(&:empty?) || CONTROL_SLUGS

    slugs.filter_map do |slug|
      # find_by!(slug:), never friendly.find -- 137 books have purely numeric slugs
      # and friendly_id resolves slugs before primary keys.
      book = ::Books::Book.includes(:categories, book_authors: :author).find_by(slug: slug)
      warn "  ! no book with slug #{slug.inspect}" if book.nil?
      book
    end
  end

  # "a=1,b=2; a=3" => [{}, {a: 1, b: 2}, {a: 3}]
  # The leading {} is variant A, the shipped defaults, so every run is a comparison
  # rather than a lone set of results with nothing to judge it against.
  def parse_variants(raw)
    specs = [{}]
    return specs if raw.blank?

    raw.split(";").each do |chunk|
      overrides = chunk.split(",").each_with_object({}) do |pair, acc|
        key, value = pair.split("=", 2).map(&:strip)
        acc[key.to_sym] = cast(value) if key.present? && !value.nil?
      end
      specs << overrides if overrides.any?
    end
    specs
  end

  def cast(value)
    case value
    when /\A-?\d+\z/ then value.to_i
    when /\A-?\d*\.\d+\z/ then value.to_f
    when "true" then true
    when "false" then false
    else value
    end
  end

  def label(overrides)
    return "shipped defaults" if overrides.empty?
    overrides.map { |k, v| "#{k}=#{v}" }.join("  ")
  end

  def commas(number)
    number.to_i.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
  end

  def truncate(text, width)
    text = text.to_s
    (text.length > width) ? "#{text[0, width - 1]}…" : text
  end

  # Wraps a comma-joined list under a fixed prefix rather than truncating it. The
  # dropped-category list is the single most diagnostic line this task prints -- a
  # trailing ellipsis there hides exactly the large categories being reasoned about.
  def wrapped(prefix, parts, width: 100)
    return "#{prefix}(none)" if parts.empty?

    indent = " " * prefix.length
    lines = [prefix.dup]
    parts.each_with_index do |part, index|
      piece = index.zero? ? part : ", #{part}"
      if lines.last.length + piece.length > width && lines.last.strip != prefix.strip
        lines << "#{indent}#{part}"
      else
        lines.last << piece
      end
    end
    lines.join("\n")
  end

  # How many hits apply_author_cap actually discarded. It cannot be derived from
  # hits.size - qualified.size: qualified is already .first(limit), so that
  # subtraction reports the limit truncating the window and calls it a cap removal
  # (75 hits - 25 shown = "50 capped", which was wrong every single time).
  # Walking the window in score order until every qualified book is accounted for
  # counts only the ones genuinely skipped above the last one shown.
  def cap_stats(hits, qualified)
    qualified_ids = qualified.map(&:id).to_set
    matched = 0
    removed = 0

    hits.each do |hit|
      if qualified_ids.include?(hit[:id].to_i)
        matched += 1
        break if matched == qualified.size
      else
        removed += 1
      end
    end
    [removed, matched + removed]
  end

  def category_label(category)
    "#{category.name}(#{commas(category.item_count)})"
  end

  # The denominator the query divides by: script_score reads
  # similarity_category_count, which Books::Book#as_indexed_json defines as the
  # active categories whose type is in SIMILARITY_CATEGORY_TYPES.
  def similarity_category_count(book)
    book.categories.count { |c| c.deleted == false && ::Books::Book::SIMILARITY_CATEGORY_TYPES.include?(c.category_type) }
  end

  def author_names(book)
    book.book_authors.filter_map { |ba| ba.author&.name }.join(", ")
  end
end

namespace :books do
  namespace :similar do
    desc "Compare Similar Books results across knob settings (read-only dev tuning harness)"
    task compare: :environment do
      include BooksSimilarCompare

      books = BooksSimilarCompare.resolve_books(ENV["BOOKS"])
      abort "No books resolved -- check BOOKS=" if books.empty?

      # Default sweep steps max_category_item_count, the only mechanism in the design
      # that acts on category rarity (a term query on a keyword field scores a flat
      # ConstantScore = its boost, so nothing downstream weighs it) -- which makes it
      # the highest-leverage knob rather than a refinement.
      variants = BooksSimilarCompare.parse_variants(
        ENV.fetch("VARIANTS", "max_category_item_count=10000; max_category_item_count=5000")
      )
      show = ENV.fetch("SHOW", "10").to_i

      puts "Similar Books comparison"
      puts "  books:    #{books.map(&:slug).join(", ")}"
      puts "  variants: #{variants.map { |v| BooksSimilarCompare.label(v) }.join("  |  ")}"
      puts "  showing:  top #{show} of the /similar page window (limit=#{BooksSimilarCompare.base_config[:page_limit]})"
      puts

      books.each do |book|
        BooksSimilarCompare.report_book(book, variants, show)
      end
    end
  end
end

module BooksSimilarCompare
  module_function

  def report_book(book, variants, show)
    puts "=" * 100
    puts "#{book.title} - #{author_names(book)} (#{book.first_published_year || "year unknown"})"
    puts "  #{similarity_category_count(book)} scoring categories, slug #{book.slug}"
    puts

    baseline_ids = nil

    variants.each_with_index do |overrides, index|
      letter = ("A".ord + index).chr
      # Tune against the window the /similar page actually requests: limit drives the
      # query's `size` (limit * over_fetch), so displaying 10 out of a limit-5 run
      # would be judging a different query from the one the page issues.
      opts = {limit: base_config[:page_limit]}.merge(overrides)
      merged = base_config.merge(opts)

      puts "  -- #{letter} - #{label(overrides)} #{"-" * [70 - label(overrides).length, 3].max}"
      report_selected_categories(book, merged)

      searched_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      hits = ::Search::Books::Search::BookSimilar.call(book, opts)
      search_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - searched_at) * 1000).round

      served_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = ::Services::Books::SimilarBooks.call(book, **opts)
      total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - served_at) * 1000).round

      qualified = result.data[:books]
      if hits.empty? || qualified.empty?
        puts "     no results"
        puts
        next
      end

      baseline_ids ||= qualified.first(5).map(&:id)
      report_results(book, merged, hits, qualified, show)
      report_footer(hits, qualified, baseline_ids, index, search_ms, total_ms, merged)
      puts
    end
  end

  # max_category_item_count works purely by selecting which categories enter the
  # query -- nothing downstream weighs rarity -- so which ones the ceiling dropped
  # IS the mechanism, and is the first thing to look at when results seem wrong.
  def report_selected_categories(book, merged)
    selected = ::Search::Books::Search::BookSimilar.categories_by_type(book, merged)
    selected_ids = selected.values.flatten.map(&:id).to_set
    active = book.categories.select { |c| c.deleted == false }

    ::Books::Book::SIMILARITY_CATEGORY_TYPES.each do |type|
      of_type = active.select { |c| c.category_type == type }.sort_by { |c| [c.item_count.to_i, c.id] }
      next if of_type.empty?

      kept, dropped = of_type.partition { |c| selected_ids.include?(c.id) }
      puts wrapped("     #{type.ljust(9)} ", kept.map { |c| category_label(c) })
      puts wrapped("     #{" " * 9} dropped: ", dropped.map { |c| category_label(c) }) if dropped.any?
    end
  end

  def report_results(book, merged, hits, qualified, show)
    qualified_ids = qualified.map(&:id).to_set
    scores = hits.each_with_object({}) { |hit, acc| acc[hit[:id].to_i] = hit[:score] }

    selected = ::Search::Books::Search::BookSimilar.categories_by_type(book, merged)
    selected_by_id = selected.values.flatten.index_by(&:id)

    detail = ::Books::Book.where(id: hits.map { |h| h[:id].to_i }).includes(:categories, book_authors: :author).index_by(&:id)

    rank = 0
    hits.each do |hit|
      id = hit[:id].to_i
      candidate = detail[id]
      next if candidate.nil?

      if qualified_ids.include?(id)
        break if rank >= show
        rank += 1
        marker = format("%4d", rank)
      else
        # In the hit window but not in the qualified list: apply_author_cap removed it.
        # Worth showing rather than hiding, because it is exactly what max_per_author
        # controls -- and a run where the cap is discarding good books reads very
        # differently from one where it is discarding an author's back catalogue.
        next if rank.zero? || rank >= show
        marker = "  --"
      end

      shared = candidate.categories
        .select { |c| selected_by_id.key?(c.id) }
        .sort_by { |c| [c.item_count.to_i, c.id] }
        .map { |c| category_label(c) }

      title = truncate("#{candidate.title} - #{author_names(candidate)}", 58)
      puts format("  %s  %6.2f  %-58s %-6s [%2d cats]",
        marker, scores[id] || 0.0, title, candidate.first_published_year || "?", similarity_category_count(candidate))
      puts "              shares: #{truncate(shared.join(", "), 84)}" if shared.any?
      puts "              CAPPED by max_per_author=#{merged[:max_per_author]}" if marker == "  --"
    end
  end

  def report_footer(hits, qualified, baseline_ids, index, search_ms, total_ms, merged)
    scores = hits.map { |h| h[:score] }.compact.sort.reverse
    removed, scanned = cap_stats(hits, qualified)

    puts format("     window: %d hits, scores %.2f (top) .. %.2f (median) .. %.2f (low) | min_score=%s",
      hits.size, scores.first || 0, scores[scores.size / 2] || 0, scores.last || 0, merged[:min_score])
    puts format("     author cap removed %d of the top %d hits (max_per_author=%d) | over_fetch=%d loaded %d rows to show %d",
      removed, scanned, merged[:max_per_author], merged[:over_fetch], hits.size, qualified.size)
    puts format("     timing: opensearch %dms, service total %dms (postgres+cap ~%dms)",
      search_ms, total_ms, [total_ms - search_ms, 0].max)

    return if index.zero? || baseline_ids.nil?

    # Compared slot by slot, NOT as a set difference. `current - baseline` reports
    # zero for a variant that returned a strict subset of A ([1,2,3] vs [1,2,3,4,5])
    # AND zero for a completely reversed ranking ([5,4,3,2,1] vs [1,2,3,4,5]) -- it
    # is blind to both truncation and reordering, which are exactly the changes a
    # tuning run exists to reveal. It hid them while this harness was being used to
    # choose the shipped defaults.
    current = qualified.first(5).map(&:id)
    width = [baseline_ids.size, current.size].max
    differing = (0...width).count { |i| current[i] != baseline_ids[i] }
    entered = (current - baseline_ids).size
    dropped = (baseline_ids - current).size

    puts format("     top 5 vs A: %d of %d slots differ (%d new, %d dropped)",
      differing, width, entered, dropped)
  end
end

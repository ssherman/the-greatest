# frozen_string_literal: true

module Services
  module Books
    module Authors
      # What the author steps did since a time (spec §13), read after a
      # backfill batch and before a wider one: how many authors the
      # Wikidata step ran and matched and how fast, how each step's
      # decisions split and how many need review, how the ledger rows ended,
      # what the AI calls cost, and what is still waiting.
      #
      # Prices are list prices per million tokens from a 2026-09 research
      # pass, and cached input is priced in full, so the dollar figure is an
      # estimate and an upper bound; the OpenAI usage page has the bill.
      class BackfillReport
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        PRICES = {
          "gpt-6-luna" => {input: 0.10, output: 0.50},
          "gpt-6-sol" => {input: 2.00, output: 10.00},
          "gpt-6-astra" => {input: 10.00, output: 50.00}
        }.freeze
        WEB_SEARCH = 0.01
        FINDERS = {
          "Wikidata" => "Services::Books::Authors::ResolveWikidata",
          "VIAF" => "Services::Books::Authors::ResolveViaf"
        }.freeze
        KINDS = %w[books.author_wikidata books.author_viaf books.author_facts].freeze

        def self.call(since:) = new(since: since).call

        def initialize(since:)
          @since = since
        end

        def call
          data = {
            authors: wikidata_rows.distinct.count(:enrichable_id),
            matched: wikidata_rows.where(recognized: true).distinct.count(:enrichable_id),
            per_hour: per_hour,
            decisions: FINDERS.transform_values { |finder| decision_numbers(finder) },
            outcomes: KINDS.index_with { |kind| rows(kind).group(:outcome).count },
            failures: KINDS.index_with { |kind| rows(kind).where(outcome: :failed).group(:reason).count },
            ai: ai_numbers,
            remaining: Backfill.unprocessed.count,
            waiting: QueuedChain.by_job.transform_values(&:size).select { |_job, count| count.positive? },
            viaf_line_ends: ::Viaf::Schedule.new.horizon
          }
          Result.new(success?: true, data: data.merge(lines: lines(data)), errors: [])
        end

        private

        def rows(kind) = ::Enrichment.for_kind(kind).where(enrichable_type: "Books::Author", created_at: @since..)

        def wikidata_rows = rows(EnrichFromWikidata::KIND)

        def per_hour
          first, last = wikidata_rows.pick(Arel.sql("MIN(created_at)"), Arel.sql("MAX(created_at)"))
          return nil if first.nil? || last <= first

          wikidata_rows.distinct.count(:enrichable_id) / ((last - first) / 3600.0)
        end

        def decision_numbers(finder)
          scope = ::MatchDecision.where(finder: finder, subject_type: "Books::Author", created_at: @since..)
          {
            split: scope.group(:outcome, :decided_by).count.transform_keys { |outcome, decided_by| "#{outcome} #{decided_by}" },
            needs_review: scope.where(needs_review: true).count
          }
        end

        def ai_numbers
          by_model = {}
          ::AiChat.where(parent_type: "Books::Author", created_at: @since..).find_each do |chat|
            totals = (by_model[chat.model] ||= {chats: 0, input: 0, output: 0, web_searches: 0})
            totals[:chats] += 1
            Array(chat.raw_responses).each do |response|
              next unless response.is_a?(Hash)

              totals[:input] += response.dig("usage", "input_tokens").to_i
              totals[:output] += response.dig("usage", "output_tokens").to_i
              totals[:web_searches] += response["web_search_calls"].to_i
            end
          end
          by_model.each { |model, totals| totals[:cost] = cost(model, totals) }
          {by_model: by_model, cost: by_model.values.sum { |totals| totals[:cost].to_f }}
        end

        def cost(model, totals)
          price = PRICES[model]
          return nil unless price

          ((totals[:input] * price[:input]) + (totals[:output] * price[:output])) / 1_000_000.0 + (totals[:web_searches] * WEB_SEARCH)
        end

        def lines(data)
          authors = data[:authors]
          rate = authors.positive? ? (100.0 * data[:matched] / authors).round : 0
          per_author = authors.positive? ? data[:ai][:cost] / authors : nil
          out = ["Since #{@since.utc.iso8601}"]
          out << "Wikidata step: #{authors} author(s), #{data[:matched]} matched (#{rate}%)" \
            "#{", #{data[:per_hour].round(1)} an hour" if data[:per_hour]}"
          data[:decisions].each do |label, numbers|
            split = numbers[:split].map { |key, count| "#{key} #{count}" }.join(", ").presence || "none"
            out << "#{label} decisions: #{split}; #{numbers[:needs_review]} need review"
          end
          data[:outcomes].each do |kind, counts|
            failed = data[:failures][kind].map { |reason, count| "#{reason || "no reason"} #{count}" }.join(", ")
            out << "#{kind}: #{counts.map { |outcome, count| "#{outcome} #{count}" }.join(", ").presence || "none"}" \
              "#{"; failed: #{failed}" if failed.present?}"
          end
          data[:ai][:by_model].each do |model, totals|
            price = totals[:cost] ? format("$%.2f", totals[:cost]) : "no list price"
            out << "AI #{model}: #{totals[:chats]} call(s), #{totals[:input]} in / #{totals[:output]} out tokens, " \
              "#{totals[:web_searches]} web search(es), #{price}"
          end
          out << format("AI total: about $%.2f at list prices (cached input priced in full; the OpenAI usage page has the bill)", data[:ai][:cost])
          if per_author
            out << format("Per author: about $%.4f. The %d author(s) the Wikidata step has not processed would cost about $%.0f, " \
              "and take about %.1f hours for the Wikidata step at one every %ds.",
              per_author, data[:remaining], per_author * data[:remaining], data[:remaining] * Backfill::SPACING / 3600.0, Backfill::SPACING)
          end
          waiting = data[:waiting].map { |job, count| "#{job.demodulize} #{count}" }.join(", ").presence || "nothing"
          out << "Waiting in Sidekiq: #{waiting}#{"; the VIAF line runs until about #{data[:viaf_line_ends].utc.iso8601}" if data[:viaf_line_ends]}"
          out
        end
      end
    end
  end
end

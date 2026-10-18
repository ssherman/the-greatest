# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Gives each current genre exactly one fate against the owner's edited
        # lists (spec §3, §4, §5 step 3). Fails the whole batch on any answer
        # naming something off the lists; the batch is retried on the next run.
        class GenreMapTask < BaseTask
          Entry = Struct.new(:key, :name, :books, :samples, :references, :worldcat_terms, keyword_init: true)
          ACTIONS = %w[keep rename merge audience subject location delete split].freeze

          attr_reader :entries, :genres, :audiences

          def initialize(entries:, genres:, audiences:, parent: nil, provider: nil, model: nil)
            @entries = entries
            @genres = genres
            @audiences = audiences
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :premium

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def genre_names = genres.map { |g| g["name"] }

          def audience_names = audiences.map { |a| a["name"] }

          def list_names = genre_names + audience_names

          def system_message
            <<~SYSTEM
              You are mapping a book website's current genres onto its new, curated genre and audience lists. Give every current genre exactly one action:

              - "keep": it is on the genre list under exactly this name.
              - "rename": it is on the genre list under a different spelling; put the list name in "to".
              - "merge": its books belong under one list genre or audience; put that name as the only entry of "into". Use it for subgenres (Space Opera into Science Fiction), twins, and compounds whose second half adds nothing (Cozy Fantasy into Fantasy).
              - "audience": it is one of the audiences; put the audience name in "as".
              - "subject": it is a topic, a time period, LGBTQ+, or a real mood, trope or reception label (Banned Books); "as" may give a cleaner subject name. Gay fiction and Lesbian Fantasy go to the subject "LGBTQ+".
              - "location": it is a place; put the place's name in "as".
              - "delete": formats (Ebooks), noise (Own, Apple), labels with no meaning as a subject (Summer Reads, Slow Burn), creator identity (Latino, Latinx, Hispanic, AAPI), and Drama (a shelf for "dramatic" books, not plays; set "worldcat" to "Plays").
              - "split": it combines two things readers look for separately (Science Fiction Fantasy, Rom Com, History and Politics, Hockey Romance). Put its genre or audience halves in "into", primary first, and subject halves in "into_subjects". For each of its WorldCat terms, list in "worldcat_terms" which of its genre or audience halves that term supports ("History" supports only History).

              A kept or renamed genre that by definition is always also other list genres names them in "also" (Romantasy: also Romance and Fantasy). Use it only when every book of the genre is necessarily the others.

              Never rename, merge, split or delete Fiction, Nonfiction, Religion & Spirituality or Poetry: keep them. Never merge into Fiction or Nonfiction.
              When saved searches use a genre, prefer "subject" over "delete": a subject keeps those searches working.
              Every name you put in "to", "into", "also", "worldcat" or "worldcat_terms" must be copied exactly from the lists. Give a one-sentence reason.
            SYSTEM
          end

          def user_prompt
            lines = ["Genre list:"]
            genres.each { |g| lines << "- #{g["name"]}: #{g["definition"]}" }
            lines << "" << "Audience list:"
            audiences.each { |a| lines << "- #{a["name"]}: #{a["definition"]}" }
            lines << "" << "Current genres to map:"
            entries.each do |entry|
              lines << "[#{entry.key}] #{entry.name.inspect} (#{entry.books} books, used by #{entry.references} saved searches)"
              lines << "  e.g. #{entry.samples.join("; ")}" if entry.samples.any?
              lines << "  WorldCat terms: #{entry.worldcat_terms.join("; ")}" if entry.worldcat_terms.any?
            end
            lines << "" << "Return exactly one result per genre, with its number in \"key\"."
            lines.join("\n")
          end

          def process_and_persist(provider_response)
            keys = entries.map(&:key)
            results = {}
            Array(value(provider_response[:parsed], :results)).each do |raw|
              parsed = normalize(raw)
              next if !keys.include?(parsed[:key]) || results.key?(parsed[:key])

              results[parsed[:key]] = parsed
            end
            missing = keys - results.keys
            return failure("No result for #{missing.join(", ")}") if missing.any?

            results.each_value do |r|
              return failure("Unknown action #{r[:action].inspect} for #{r[:key]}") unless ACTIONS.include?(r[:action])
              named = [r[:to], r[:worldcat], *r[:into], *r[:also], *r[:worldcat_terms].values.flatten].compact
              named << r[:as] if r[:action] == "audience"
              off = named - list_names
              return failure("#{off.first.inspect} is not on the lists (genre #{r[:key]})") if off.any?
            end
            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          def normalize(raw)
            strings = ->(key) { Array(value(raw, key)).map { |v| v.to_s.strip }.reject(&:blank?) }
            terms = Array(value(raw, :worldcat_terms)).to_h { |t| [value(t, :term).to_s, Array(value(t, :targets)).map(&:to_s)] }
            {key: value(raw, :key).to_s, action: value(raw, :action).to_s, to: value(raw, :to).presence, into: strings.call(:into),
             into_subjects: strings.call(:into_subjects), as: value(raw, :as).presence, also: strings.call(:also),
             worldcat: value(raw, :worldcat).presence, worldcat_terms: terms, reason: value(raw, :reason).to_s}
          end

          def value(raw, key)
            return raw[key] || raw[key.to_s] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def failure(message) = Services::Ai::Result.new(success: false, error: message, ai_chat: chat)

          class WorldcatTerm < OpenAI::BaseModel
            required :term, String
            required :targets, OpenAI::ArrayOf[String]
          end

          class MapResult < OpenAI::BaseModel
            required :key, String, doc: "The genre's number"
            required :action, String, doc: "keep, rename, merge, audience, subject, location, delete or split"
            required :to, String, nil?: true, doc: "For rename: the list name"
            required :into, OpenAI::ArrayOf[String], doc: "For merge: one list name. For split: its genre or audience halves, primary first"
            required :into_subjects, OpenAI::ArrayOf[String], doc: "For split: its subject halves"
            required :as, String, nil?: true, doc: "For audience: the audience. For subject or location: the name"
            required :also, OpenAI::ArrayOf[String], doc: "For keep or rename: list genres it always also is"
            required :worldcat, String, nil?: true, doc: "Where this genre's WorldCat terms should point instead, or null"
            required :worldcat_terms, OpenAI::ArrayOf[WorldcatTerm], doc: "For split: which halves each WorldCat term supports"
            required :reason, String, doc: "One sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[MapResult], doc: "One per genre"
          end
        end
      end
    end
  end
end

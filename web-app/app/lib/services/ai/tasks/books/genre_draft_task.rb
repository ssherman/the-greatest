# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Drafts the tight genre list from every live genre
        # (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §3, §5).
        # Parentless: the result is a data file the owner edits.
        class GenreDraftTask < BaseTask
          Entry = Struct.new(:name, :books, :samples, :references, keyword_init: true)
          PROTECTED = ["Fiction", "Nonfiction", "Religion & Spirituality", "Poetry"].freeze

          attr_reader :entries

          def initialize(entries:, parent: nil, provider: nil, model: nil)
            @entries = entries
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

          def system_message
            <<~SYSTEM
              You are designing the genre list of a book website that ranks the greatest books. The current genres came from Goodreads shelves and mix many kinds of label. Propose a short, deliberate list.

              A genre names what kind of book it is, never what the book is about. It is either a form (short stories, plays, graphic novels, letters and diaries, picture books) or a convention readers shelve by (mystery, fantasy, memoir, true crime, cookbooks).

              Not genres, so leave them off the list:
              - Topics and time periods (Vegetarian, Trucks, Victorian, Ancient): these become subjects.
              - Places (South Dakota): these become locations.
              - Audience (Children's, Middle Grade, Young Adult, teen): audience is a separate list the site already has. "Adult" is not an audience and not a genre: a book with no audience is for general readers.
              - Moods, romance tropes and reception labels (Dark, Cozy, Slow Burn, Banned Books, Summer Reads).
              - Formats (Ebooks).
              - Creator identity (Latino, Latinx, Hispanic, AAPI).
              - LGBTQ+: it is a subject.
              - Drama: on this site it is a shelf for "dramatic" books; plays are the genre Plays.

              Fold a subgenre into its parent unless readers widely shelve by it AND it holds enough books to stand alone. "Widely shelved" means in today's book market, not only in this catalog, which leans to the canon: keep Romantasy, one of today's best-selling genres. Aim for 40 to 60 genres.

              A name that combines two genres readers look for separately (Science Fiction Fantasy, Rom Com) is not itself on the list: its halves are. A compound that names one convention (Thriller & Suspense, Comics & Graphic Novels, Folklore & Fairy Tales) can be.

              Always include Fiction, Nonfiction, Religion & Spirituality and Poetry, with exactly those names: they are the site's book types.

              Names are consistent Title Case ("Science Fiction", "Historical Fiction"). Give each genre a one-line definition.

              In "notes", say what should happen to each current genre with more than 1,000 books that is not on your list, one short line each.
            SYSTEM
          end

          def user_prompt
            lines = ["Current genres (books carrying it; saved searches or recommendation settings using it):"]
            entries.each do |entry|
              lines << "- #{entry.name} (#{entry.books} books, used by #{entry.references} saved searches or recommendation settings)"
              lines << "  e.g. #{entry.samples.join("; ")}" if entry.samples.any?
            end
            lines.join("\n")
          end

          def process_and_persist(provider_response)
            parsed = provider_response[:parsed]
            genres = Array(value(parsed, :genres)).map { |g| {name: value(g, :name).to_s.strip, definition: value(g, :definition).to_s.strip} }
            notes = Array(value(parsed, :notes)).map { |n| n.to_s.strip }.reject(&:blank?)
            names = genres.map { |g| g[:name] }

            return failure("The draft has no genres") if names.empty?
            return failure("The draft repeats #{names.tally.select { |_, n| n > 1 }.keys.join(", ")}") if names.uniq.size != names.size
            missing = PROTECTED - names
            return failure("The draft is missing #{missing.join(", ")}") if missing.any?

            Services::Ai::Result.new(success: true, data: {genres: genres, notes: notes}, ai_chat: chat)
          end

          def value(raw, key)
            return raw[key] || raw[key.to_s] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def failure(message) = Services::Ai::Result.new(success: false, error: message, ai_chat: chat)

          class DraftGenre < OpenAI::BaseModel
            required :name, String, doc: "The genre's name, Title Case"
            required :definition, String, doc: "One line"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :genres, OpenAI::ArrayOf[DraftGenre], doc: "The proposed list"
            required :notes, OpenAI::ArrayOf[String], doc: "What happens to each large genre not kept"
          end
        end
      end
    end
  end
end

module Services
  module Lists
    # Which list types each domain accepts from the public submission form, and
    # the only thing that turns a submitted type string into a class.
    #
    # A submitted type NEVER reaches constantize. Legacy did
    # params[:changeable_type].constantize, which resolves an arbitrary constant
    # from a request param; here an unlisted name simply returns nil and the
    # controller answers 400.
    class SubmissionRegistry
      TYPES = {
        books: [::Books::List],
        games: [::Games::List],
        music: [::Music::Albums::List, ::Music::Songs::List]
      }.freeze

      LABELS = {
        "Books::List" => "Book List",
        "Games::List" => "Game List",
        "Music::Albums::List" => "Album List",
        "Music::Songs::List" => "Song List"
      }.freeze

      def self.types_for(domain)
        TYPES.fetch(domain&.to_sym, [])
      end

      def self.resolve(domain, type_name)
        types_for(domain).find { |klass| klass.name == type_name }
      end

      def self.label_for(klass)
        LABELS.fetch(klass.name)
      end

      # The mailer needs the domain to pick branding, and it runs in Sidekiq where
      # Current.domain is nil. Here rather than in the mailer so it is covered by
      # this class's own tests.
      def self.domain_for(klass)
        TYPES.find { |_domain, types| types.include?(klass) }&.first
      end
    end
  end
end

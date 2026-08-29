module Services
  module Lists
    # Turns a public submission form into an unapproved List.
    #
    # Length caps live here rather than on the model on purpose: production
    # raw_content reaches 1,568,804 characters from admin paste feeding the
    # wizard, so a model-level cap would break the admin path. Only the public
    # endpoint needs bounding.
    class Submission
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      DUPLICATE_MESSAGE = "We already have this list — thanks for checking."

      CAPS = {
        name: 255,
        source: 255,
        url: 2_000,
        description: 5_000,
        raw_content: 100_000
      }.freeze

      MAX_EMAIL_LENGTH = 255

      # Everything the public form may set. Anything else submitted is dropped
      # silently -- status, submitted_by_id and estimated_quality are not the
      # submitter's to choose. Legacy permitted every ranking-weight field while
      # its form exposed none of them.
      PERMITTED = [
        :name, :source, :url, :description, :raw_content, :year_published,
        :number_of_voters, :num_years_covered, :location_specific,
        :category_specific, :yearly_award, :voter_count_estimated,
        :voter_names_unknown, :voter_count_unknown
      ].freeze

      def self.call(list_class:, attributes:, user: nil, submitter_email: nil, submitter_ip: nil)
        new(list_class: list_class, attributes: attributes, user: user,
          submitter_email: submitter_email, submitter_ip: submitter_ip).call
      end

      def initialize(list_class:, attributes:, user:, submitter_email:, submitter_ip:)
        @list_class = list_class
        @attributes = (attributes || {}).symbolize_keys.slice(*PERMITTED)
        @user = user
        @submitter_email = submitter_email
        @submitter_ip = submitter_ip
      end

      def call
        oversized = cap_errors
        return failure(oversized) if oversized.any?
        return failure([DUPLICATE_MESSAGE]) if duplicate?

        list = build_list
        return failure(list.errors.full_messages) unless list.save

        Result.new(success?: true, data: list, errors: [])
      end

      private

      def build_list
        list = @list_class.new(@attributes)
        list.status = :unapproved
        list.submitted_at = Time.current
        list.submitted_by = @user
        # Only for anonymous submitters. A signed-in account address is verified
        # and already on file; the typed one is neither.
        list.submitter_email = @user ? nil : normalized_email
        list.submitter_ip = @submitter_ip
        list.skip_content_simplification = true
        list
      end

      # REJECTED, never truncated. Silently storing half of what someone pasted
      # is how an admin ends up importing a list that stops mid-entry, with the
      # submitter given no way to know.
      def cap_errors
        errors = CAPS.filter_map do |field, cap|
          value = @attributes[field]
          next if value.blank? || value.to_s.length <= cap

          "#{field.to_s.humanize} is too long (maximum is #{cap} characters)"
        end

        if normalized_email.present? && normalized_email.length > MAX_EMAIL_LENGTH
          errors << "Email is too long (maximum is #{MAX_EMAIL_LENGTH} characters)"
        end

        errors
      end

      def normalized_email
        @normalized_email ||= @submitter_email.to_s.strip.presence
      end

      # Scoped by type: the same page can legitimately back both an albums and a
      # songs list. Compared in Ruby against a narrowed candidate set rather than
      # in SQL so the normalisation rules live in one readable, testable place.
      #
      # This is a courtesy, never an invariant -- 22 duplicate (type, url) pairs
      # already exist, so there is no unique index and none can be added.
      def duplicate?
        target = normalize_url(@attributes[:url])
        return false if target.blank?

        @list_class
          .where(type: @list_class.name)
          .where.not(url: [nil, ""])
          .pluck(:url)
          .any? { |existing| normalize_url(existing) == target }
      end

      def normalize_url(url)
        value = url.to_s.strip.downcase
        return "" if value.blank?

        value = value.sub(%r{\Ahttps?://}, "")
        value = value.sub(/\Awww\./, "")
        value.chomp("/")
      end

      def failure(errors)
        Result.new(success?: false, data: nil, errors: errors)
      end
    end
  end
end

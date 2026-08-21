# Preview all emails at http://localhost:3000/rails/mailers
class SystemMailerPreview < ActionMailer::Preview
  def smoke_test_books
    SystemMailer.smoke_test(domain: :books, to: "preview@example.org")
  end

  def smoke_test_music
    SystemMailer.smoke_test(domain: :music, to: "preview@example.org")
  end

  def smoke_test_games
    SystemMailer.smoke_test(domain: :games, to: "preview@example.org")
  end

  # The nil case is not hypothetical: every membership created before checkout
  # existed has origin_domain: nil, and increment 8's mailers will pass it.
  def smoke_test_unknown_domain
    SystemMailer.smoke_test(domain: nil, to: "preview@example.org")
  end
end

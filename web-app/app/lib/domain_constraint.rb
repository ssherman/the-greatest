class DomainConstraint
  def initialize(domain)
    @domain = domain.split(",")
  end

  def matches?(request)
    @domain.include?(request.host)
  end
end

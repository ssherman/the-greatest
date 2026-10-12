# Whole-catalog inherited-link reconcile after an admin re-parents a location.
class Categories::ReconcileAncestorsJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  def perform
    ::Categories::AncestorReconciler.call
  end
end

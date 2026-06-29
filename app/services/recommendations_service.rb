# frozen_string_literal: true

# Builds a Discover feed for a user: takes seed authors (the authors they
# follow, plus the authors of books they've already requested) and asks the
# metadata providers for more of their work, excluding anything already in the
# user's library or request queue.
class RecommendationsService
  MAX_SEED_AUTHORS = 6
  DEFAULT_LIMIT = 24

  Group = Data.define(:seed, :candidates)

  class << self
    def call(user, limit: DEFAULT_LIMIT)
      new(user, limit: limit).call
    end
  end

  def initialize(user, limit: DEFAULT_LIMIT)
    @user = user
    @limit = limit
  end

  # Returns a flat, de-duplicated list of candidate books to discover.
  def call
    return [] unless MetadataService.available?

    seen_keys = existing_work_keys
    recommendations = []

    seed_authors.each do |seed|
      MetadataService.search(seed, limit: 10).each do |candidate|
        key = candidate.work_id.to_s
        next if key.blank? || seen_keys.include?(key)
        next if existing_book?(candidate)

        seen_keys << key
        recommendations << candidate
        return recommendations if recommendations.size >= @limit
      end
    end

    recommendations
  rescue MetadataService::Error => e
    Rails.logger.warn "[RecommendationsService] failed: #{e.message}"
    recommendations || []
  end

  private

  attr_reader :user, :limit

  def seed_authors
    followed = user.author_follows.enabled.pluck(:author_name)
    requested = user.requests.includes(:book).filter_map { |request| request.book&.author }
    (followed + requested).map { |name| name.to_s.strip }.reject(&:blank?).uniq.first(MAX_SEED_AUTHORS)
  end

  # Work ids the user already has a book record for (requested or acquired).
  def existing_work_keys
    user.requests.includes(:book).flat_map { |request| request.book ? Book.work_ids_for(request.book) : [] }.to_set
  end

  def existing_book?(candidate)
    work_ids = candidate.sources.filter_map { |source| source[:work_id] }
    work_ids << candidate.work_id
    Book.find_by_any_work_id(work_ids.compact.uniq, book_type: :ebook).present? ||
      Book.find_by_any_work_id(work_ids.compact.uniq, book_type: :audiobook).present?
  end
end

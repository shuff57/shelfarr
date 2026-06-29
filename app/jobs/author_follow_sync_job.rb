# frozen_string_literal: true

# Discovers books by followed authors and (optionally) auto-requests any that
# aren't already in the library. Reuses MetadataService for discovery and
# RequestCreationService for creation, so duplicate detection is handled there.
#
# Called with no argument by the recurring schedule (processes everything due)
# or with an id to sync a single follow immediately after it is created.
class AuthorFollowSyncJob < ApplicationJob
  queue_as :default

  def perform(author_follow_id = nil)
    return unless MetadataService.available?

    if author_follow_id
      follow = AuthorFollow.find_by(id: author_follow_id)
      sync(follow) if follow&.enabled?
    else
      AuthorFollow.due.find_each { |follow| sync(follow) }
    end
  end

  private

  def sync(follow)
    Rails.logger.info "[AuthorFollowSyncJob] Checking '#{follow.author_name}' (#{follow.book_type}) for user ##{follow.user_id}"

    created = 0
    candidates_for(follow).each do |candidate|
      next unless author_matches?(candidate, follow.author_name)
      next unless format_available?(candidate, follow.book_type)

      created += 1 if request_candidate(follow, candidate)
    end

    follow.mark_checked!
    Rails.logger.info "[AuthorFollowSyncJob] '#{follow.author_name}': #{created} new request(s)"
  rescue => e
    Rails.logger.error "[AuthorFollowSyncJob] Sync failed for follow ##{follow&.id}: #{e.message}"
  end

  def candidates_for(follow)
    MetadataService.search(follow.author_name, limit: 50)
  rescue MetadataService::Error => e
    Rails.logger.warn "[AuthorFollowSyncJob] Metadata search failed for '#{follow.author_name}': #{e.message}"
    []
  end

  # The aggregator may merge editions across providers; honour the follow's
  # format unless the candidate has no format signal at all.
  def format_available?(candidate, book_type)
    case book_type.to_s
    when "ebook" then candidate.has_ebook != false
    when "audiobook" then candidate.has_audiobook != false
    else true
    end
  end

  # Only auto-request when the follow opts in; otherwise the candidate is left
  # for the Discover feed to surface.
  def request_candidate(follow, candidate)
    return false unless follow.auto_request

    result = RequestCreationService.call(
      user: follow.user,
      work_id: candidate.work_id,
      source_work_ids: candidate.sources.filter_map { |source| source[:work_id] },
      book_types: [ follow.book_type ],
      metadata_attrs: {
        title: candidate.title,
        author: candidate.author,
        cover_url: candidate.cover_url,
        year: candidate.year
      },
      notes: "Auto-requested via author follow: #{follow.author_name}",
      origin: { created_via: "follow" }
    )

    result.created_requests.any?
  end

  def author_matches?(candidate, author_name)
    normalize(candidate.author) == normalize(author_name) ||
      normalize(candidate.author).include?(normalize(author_name)) ||
      normalize(author_name).include?(normalize(candidate.author))
  end

  def normalize(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
  end
end

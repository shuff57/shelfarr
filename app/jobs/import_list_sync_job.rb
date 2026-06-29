# frozen_string_literal: true

require "nokogiri"

# Resolves a user's import list to book queries, then reuses MetadataService to
# turn each into a candidate and RequestCreationService to (optionally) request
# it. Duplicate detection is handled by RequestCreationService.
#
# Called with no argument by the recurring schedule (everything due) or with an
# id to sync a single list immediately.
class ImportListSyncJob < ApplicationJob
  queue_as :default

  HTTP_TIMEOUT = 20

  def perform(import_list_id = nil)
    return unless MetadataService.available?

    if import_list_id
      list = ImportList.find_by(id: import_list_id)
      sync(list) if list&.enabled?
    else
      ImportList.due.find_each { |list| sync(list) }
    end
  end

  private

  def sync(list)
    Rails.logger.info "[ImportListSyncJob] Syncing '#{list.name}' (#{list.list_type}) for user ##{list.user_id}"

    queries = resolve_queries(list)
    created = 0
    queries.first(list.item_limit).each do |query|
      candidate = MetadataService.search(query, limit: 1).first
      next unless candidate

      created += 1 if request_candidate(list, candidate)
    end

    list.mark_synced!("ok: #{created} requested from #{queries.size} items")
    Rails.logger.info "[ImportListSyncJob] '#{list.name}': #{created} new request(s) from #{queries.size} items"
  rescue => e
    Rails.logger.error "[ImportListSyncJob] Sync failed for list ##{list&.id}: #{e.message}"
    list&.mark_synced!("error: #{e.message}")
  end

  def resolve_queries(list)
    case list.list_type
    when "query"
      [ list.source_id.to_s ]
    when "openlibrary_subject"
      openlibrary_subject_titles(list.source_id, list.item_limit)
    when "goodreads_rss"
      goodreads_rss_titles(list.source_url)
    else
      []
    end
  end

  # https://openlibrary.org/subjects/<subject>.json — works[].title (+ author)
  def openlibrary_subject_titles(subject, limit)
    slug = subject.to_s.strip.downcase.gsub(/\s+/, "_")
    return [] if slug.blank?

    body = http_get_json("https://openlibrary.org/subjects/#{slug}.json?limit=#{limit}")
    Array(body && body["works"]).filter_map do |work|
      title = work["title"]
      next if title.blank?

      author = Array(work["authors"]).first&.dig("name")
      [ title, author ].compact_blank.join(" ")
    end
  end

  # Goodreads list/shelf RSS — <item><title> carries the book title.
  def goodreads_rss_titles(url)
    return [] if url.blank?

    doc = Nokogiri::XML(http_get(url))
    doc.remove_namespaces!
    doc.xpath("//item/title").filter_map { |node| node.text.to_s.strip.presence }
  end

  def request_candidate(list, candidate)
    return false unless list.auto_request

    result = RequestCreationService.call(
      user: list.user,
      work_id: candidate.work_id,
      source_work_ids: candidate.sources.filter_map { |source| source[:work_id] },
      book_types: [ list.book_type ],
      metadata_attrs: {
        title: candidate.title,
        author: candidate.author,
        cover_url: candidate.cover_url,
        year: candidate.year
      },
      notes: "Auto-requested via import list: #{list.name}",
      origin: { created_via: "import_list" }
    )

    result.created_requests.any?
  end

  def http_get(url)
    response = http_connection.get(url)
    raise "HTTP #{response.status}" unless response.status == 200

    response.body.to_s
  end

  def http_get_json(url)
    JSON.parse(http_get(url))
  rescue JSON::ParserError
    nil
  end

  def http_connection
    @http_connection ||= Faraday.new do |f|
      f.adapter Faraday.default_adapter
      f.headers["User-Agent"] = "Shelfarr/1.0"
      f.options.timeout = HTTP_TIMEOUT
      f.options.open_timeout = 10
    end
  end
end

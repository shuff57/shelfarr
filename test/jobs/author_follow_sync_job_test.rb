# frozen_string_literal: true

require "test_helper"

class AuthorFollowSyncJobTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
  end

  test "auto-requests a matching candidate and stamps the follow" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    candidate = build_candidate(title: "Emma", author: "Jane Austen", work_id: "hardcover:42")

    with_metadata([ candidate ]) do
      assert_difference -> { @user.requests.where(created_via: "follow").count }, 1 do
        AuthorFollowSyncJob.perform_now(follow.id)
      end
    end

    assert_not_nil follow.reload.last_checked_at
    assert Request.joins(:book).exists?(books: { author: "Jane Austen" })
  end

  test "skips candidates whose author does not match the follow" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    candidate = build_candidate(title: "Dune", author: "Frank Herbert", work_id: "hardcover:7")

    with_metadata([ candidate ]) do
      assert_no_difference -> { @user.requests.count } do
        AuthorFollowSyncJob.perform_now(follow.id)
      end
    end
  end

  test "does not request when auto_request is disabled" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook, auto_request: false)
    candidate = build_candidate(title: "Emma", author: "Jane Austen", work_id: "hardcover:42")

    with_metadata([ candidate ]) do
      assert_no_difference -> { @user.requests.count } do
        AuthorFollowSyncJob.perform_now(follow.id)
      end
    end

    assert_not_nil follow.reload.last_checked_at
  end

  test "without an id processes all due follows" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook, last_checked_at: nil)
    candidate = build_candidate(title: "Emma", author: "Jane Austen", work_id: "hardcover:42")

    with_metadata([ candidate ]) do
      assert_difference -> { @user.requests.count }, 1 do
        AuthorFollowSyncJob.perform_now
      end
    end

    assert_not_nil follow.reload.last_checked_at
  end

  test "does nothing when no metadata provider is available" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)

    MetadataService.stub :available?, false do
      assert_no_difference -> { @user.requests.count } do
        AuthorFollowSyncJob.perform_now(follow.id)
      end
    end
  end

  private

  def with_metadata(candidates)
    MetadataService.stub :available?, true do
      MetadataService.stub :search, ->(*, **) { candidates } do
        yield
      end
    end
  end

  def build_candidate(title:, author:, work_id:, has_ebook: true)
    source, source_id = work_id.split(":", 2)
    MetadataSearch::Candidate.new(
      canonical_key: work_id, title: title, author: author, year: 2000,
      description: nil, cover_url: nil, series_name: nil, series_position: nil,
      has_ebook: has_ebook, has_audiobook: false,
      sources: [ { source: source, source_id: source_id, source_name: source.titleize, source_url: nil, work_id: work_id } ],
      editions: [], confidence: 90
    )
  end
end

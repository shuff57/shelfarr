# frozen_string_literal: true

require "test_helper"

class ImportListSyncJobTest < ActiveJob::TestCase
  setup do
    @user = users(:one)
  end

  test "query list auto-requests resolved candidates and records status" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)
    candidate = build_candidate(title: "Mistborn", author: "Brandon Sanderson", work_id: "hardcover:11")

    with_metadata([ candidate ]) do
      assert_difference -> { @user.requests.where(created_via: "import_list").count }, 1 do
        ImportListSyncJob.perform_now(list.id)
      end
    end

    list.reload
    assert_not_nil list.last_synced_at
    assert_match(/ok/, list.last_sync_status)
  end

  test "does not request when auto_request is off" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook, auto_request: false)
    candidate = build_candidate(title: "Mistborn", author: "Brandon Sanderson", work_id: "hardcover:11")

    with_metadata([ candidate ]) do
      assert_no_difference -> { @user.requests.count } do
        ImportListSyncJob.perform_now(list.id)
      end
    end

    assert_not_nil list.reload.last_synced_at
  end

  test "without an id processes all due lists" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)
    candidate = build_candidate(title: "Mistborn", author: "Brandon Sanderson", work_id: "hardcover:11")

    with_metadata([ candidate ]) do
      assert_difference -> { @user.requests.count }, 1 do
        ImportListSyncJob.perform_now
      end
    end
  end

  test "does nothing when no metadata provider is available" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)

    MetadataService.stub :available?, false do
      assert_no_difference -> { @user.requests.count } do
        ImportListSyncJob.perform_now(list.id)
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

  def build_candidate(title:, author:, work_id:)
    source, source_id = work_id.split(":", 2)
    MetadataSearch::Candidate.new(
      canonical_key: work_id, title: title, author: author, year: 2010,
      description: nil, cover_url: nil, series_name: nil, series_position: nil,
      has_ebook: true, has_audiobook: false,
      sources: [ { source: source, source_id: source_id, source_name: source.titleize, source_url: nil, work_id: work_id } ],
      editions: [], confidence: 90
    )
  end
end

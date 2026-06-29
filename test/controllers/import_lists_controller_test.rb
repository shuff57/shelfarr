# frozen_string_literal: true

require "test_helper"

class ImportListsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "index and new render" do
    @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)
    get import_lists_path
    assert_response :success
    get new_import_list_path
    assert_response :success
  end

  test "create a valid list" do
    assert_difference -> { @user.import_lists.count }, 1 do
      post import_lists_path, params: { import_list: { name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: "ebook", item_limit: 25, auto_request: "1", enabled: "1" } }
    end
    assert_redirected_to import_lists_path
  end

  test "create an invalid list re-renders" do
    assert_no_difference -> { @user.import_lists.count } do
      post import_lists_path, params: { import_list: { name: "", list_type: "query", book_type: "ebook" } }
    end
    assert_response :unprocessable_entity
  end

  test "update a list" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)
    patch import_list_path(list), params: { import_list: { name: "Sci-Fi" } }
    assert_equal "Sci-Fi", list.reload.name
  end

  test "sync enqueues the job" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)
    assert_enqueued_with(job: ImportListSyncJob, args: [ list.id ]) do
      post sync_import_list_path(list)
    end
    assert_redirected_to import_lists_path
  end

  test "destroy a list" do
    list = @user.import_lists.create!(name: "Fantasy", list_type: "query", source_id: "fantasy", book_type: :ebook)
    assert_difference -> { @user.import_lists.count }, -1 do
      delete import_list_path(list)
    end
  end
end

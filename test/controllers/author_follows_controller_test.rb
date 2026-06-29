# frozen_string_literal: true

require "test_helper"

class AuthorFollowsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as(@user)
  end

  test "index lists the user's follows" do
    @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    get author_follows_path
    assert_response :success
    assert_select "td", text: /Jane Austen/
  end

  test "create adds a follow and redirects" do
    assert_difference -> { @user.author_follows.count }, 1 do
      post author_follows_path, params: { author_follow: { author_name: "Brandon Sanderson", book_type: "ebook" } }
    end
    assert_redirected_to author_follows_path
  end

  test "create with a blank name reports an error" do
    assert_no_difference -> { @user.author_follows.count } do
      post author_follows_path, params: { author_follow: { author_name: "", book_type: "ebook" } }
    end
    assert_response :redirect
  end

  test "update can pause a follow" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook, enabled: true)
    patch author_follow_path(follow), params: { author_follow: { enabled: false } }
    assert_not follow.reload.enabled?
  end

  test "destroy removes a follow" do
    follow = @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    assert_difference -> { @user.author_follows.count }, -1 do
      delete author_follow_path(follow)
    end
  end

  test "cannot touch another user's follow" do
    other = users(:two).author_follows.create!(author_name: "Secret", book_type: :ebook)
    delete author_follow_path(other)
    assert_response :not_found
    assert AuthorFollow.exists?(other.id)
  end
end

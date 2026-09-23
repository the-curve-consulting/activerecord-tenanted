require "application_system_test_case"

class TestActiveSupportTestCase < ActiveSupport::TestCase
  test "connection_class" do
    assert_equal(ApplicationRecord, ActiveRecord::Tenanted.connection_class)
  end

  test "current tenant" do
    assert_match(/#{Rails.env}-tenant/, ApplicationRecord.current_tenant)
  end

  test "non-default tenants are cleaned up at the start of the test suite" do
    # this tenant is created by bin/test-integration before the suite runs
    assert_not_includes(ApplicationRecord.tenants, "delete-me")
  end

  test "fixtures are loaded" do
    assert_operator(Note.count, :>=, 1)
  end
end

class TestActionDispatchIntegrationTest < ActionDispatch::IntegrationTest
  test "session host name" do
    current_tenant = ApplicationRecord.current_tenant
    assert_equal("#{current_tenant}.example.com", integration_session.host)
  end

  test "middleware: setup and request are in the same tenant context" do
    note = Note.create!(title: "asdf", body: "Lorem ipsum.")

    get note_url(note)

    assert_includes(@response.body, "Lorem ipsum.")
  end

  test "middleware: to untenanted domain is untenanted" do
    integration_session.host = "example.com" # no subdomain

    assert_raises(ActiveRecord::Tenanted::NoTenantError) do
      get note_url(1)
    end
  end

  test "middleware: to a nonexistent tenant domain" do
    integration_session.host = "nonexistent-tenant.example.com"

    get notes_url

    assert_response :not_found
  end

  test "middleware: creating a new tenant and requesting that domain" do
    note = ApplicationRecord.create_tenant("non-default-tenant") do
      Note.create!(title: "asdf", body: "Lorem ipsum.")
    end

    integration_session.host = "non-default-tenant.example.com"

    get note_url(note)

    assert_includes(@response.body, "Lorem ipsum.")
  end
end

class TestApplicationSystemTestCase < ApplicationSystemTestCase
  test "session host name" do
    current_tenant = ApplicationRecord.current_tenant
    uri = URI.parse(notes_url)

    assert_equal("#{current_tenant}.example.localhost", uri.host)
  end

  test "middleware: setup and request are in the same tenant context" do
    note = Note.create!(title: "asdf", body: "Lorem ipsum.")

    visit note_url(note)

    assert_text("Lorem ipsum.")
  end
end

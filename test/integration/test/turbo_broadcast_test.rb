require "application_system_test_case"

class TestTurboBroadcast < ApplicationSystemTestCase
  test "broadcast does not cross the streams" do
    # The name is short and is not taken from __method__, because it becomes part of a database
    # name, and PostgreSQL allows a database name of only 63 bytes.
    tenant2 = "broadcast-two"

    note1 = Note.create!(title: "Tenant-1", body: "note 1 version 1")
    note2 = ApplicationRecord.create_tenant(tenant2) do
      Note.create!(title: "Tenant-2", body: "note 2 version 1", id: note1.id)
    end
    assert_equal(note1.id, note2.id)

    visit note_url(note1)
    assert_text("note 1 version 1")

    note1.update!(body: "note 1 version 2")
    assert_text("note 1 version 2")

    ApplicationRecord.with_tenant(tenant2) do
      note2.update!(body: "note 2 version 2")
    end
    assert_no_text("note 2 version 2")
    assert_text("note 1 version 2")
  end
end

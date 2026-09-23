# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::PostgreSQL do
  with_scenario(:postgresql_primary_db, :primary_record) do
    #
    #  PostgreSQL refuses to drop a database while a session is connected to it, and this gem
    #  keeps a connection pool for each tenant, so a session on the database being dropped is the
    #  usual case. WITH (FORCE) ends those sessions.
    #
    #  Rails writes WITH (FORCE) itself only from the version after 8.1, and this gem supports
    #  8.1, so the adapter writes the statement. This test fails if that is given back to Rails.
    #
    describe "#drop_database" do
      test "drops a database that a connection pool still holds open" do
        TenantedApplicationRecord.create_tenant("foo")
        pool = TenantedApplicationRecord.with_tenant("foo") { User.connection_pool }

        assert_predicate(pool, :connected?) # the session that would refuse the drop

        adapter = base_config.new_tenant_config("foo").config_adapter

        assert_nothing_raised { adapter.drop_database }
        assert_not_predicate(adapter, :database_exist?)
      end

      test "does not raise when the database is not there" do
        adapter = base_config.new_tenant_config("never-created").config_adapter

        assert_nothing_raised { adapter.drop_database }
      end
    end
  end
end

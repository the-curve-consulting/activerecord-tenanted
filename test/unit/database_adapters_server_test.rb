# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseAdapters::Server do
  [ :postgresql_primary_db, :mysql_primary_db, :trilogy_primary_db ].each do |db_scenario|
    with_scenario(db_scenario, :primary_record) do
      describe "catalog queries" do
        test "share one connection for every tenant" do
          TenantedApplicationRecord.create_tenant("foo")

          queries = anonymous_queries do
            adapter_for("foo").database_exist?
            adapter_for("bar").database_exist?
            adapter_for("foo").database_ready?
            base_config.config_adapter.tenant_databases
          end

          assert_equal(1, connections_of(queries).size)
        end

        test "do not connect again for each tenant that does not exist" do
          queries = anonymous_queries do
            assert_not(TenantedApplicationRecord.tenant_exist?("missing-one"))
            assert_not(TenantedApplicationRecord.tenant_exist?("missing-two"))
            assert_not(TenantedApplicationRecord.tenant_exist?("missing-one"))
          end

          assert_equal(1, connections_of(queries).size)
        end

        test "use a new connection in a forked process" do
          parent = connections_of(anonymous_queries { adapter_for("foo").database_exist? }).first

          reader, writer = IO.pipe
          pid = fork do
            reader.close
            child = connections_of(anonymous_queries { adapter_for("foo").database_exist? }).first
            writer.write(child.equal?(parent) ? "same" : "new")
            writer.close
            exit!(0)
          end
          writer.close
          Process.wait(pid)

          assert_equal("new", reader.read)
          assert_equal([ parent ], connections_of(anonymous_queries { adapter_for("foo").database_exist? }))
        ensure
          reader&.close
        end

        test "are answered by the server when the query cache is on" do
          adapter = adapter_for("foo")
          pool = ActiveRecord::Tenanted::DatabaseAdapters::Server
            .catalog_connection_pool(adapter.send(:anonymous_db_config))
          pool.enable_query_cache!

          assert_not(adapter.database_exist?)
          adapter.create_database
          assert_predicate(adapter, :database_exist?)
        ensure
          pool&.disable_query_cache!
        end

        test "do not use the connection that holds the ready lock" do
          adapter = adapter_for("foo")

          queries = anonymous_queries do
            adapter.acquire_ready_lock do
              adapter.create_database
              assert_not(adapter.database_ready?)
            end
            assert_predicate(adapter, :database_ready?)
          end

          lock = queries.find { |_, sql| sql.match?(/pg_advisory_lock|GET_LOCK/i) }.first
          catalog = connections_of(queries.select { |_, sql| sql.match?(/pg_locks|IS_USED_LOCK/i) })

          assert_equal(1, catalog.size)
          assert_not_same(lock, catalog.first)
        end
      end
    end
  end

  private
    def adapter_for(tenant_name)
      base_config.new_tenant_config(tenant_name).config_adapter
    end

    # Each query on a connection that names no tenant database while the block runs, as a pair of
    # the connection and the SQL.
    def anonymous_queries
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        connection = payload[:connection]
        queries << [ connection, payload[:sql] ] if connection.pool.db_config.name.end_with?("_anonymous")
      end

      yield

      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def connections_of(queries)
      queries.map(&:first).uniq(&:__id__)
    end
end

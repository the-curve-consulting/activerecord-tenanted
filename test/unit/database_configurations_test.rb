# frozen_string_literal: true

require "test_helper"

describe ActiveRecord::Tenanted::DatabaseConfigurations do
  describe Rails do
    with_scenario(:primary_named_db, :primary_record) do
      test "instantiates a BaseConfig for the tenanted database" do
        assert_equal(
          {
            "tenanted" => ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig,
            "shared" => ActiveRecord::DatabaseConfigurations::HashConfig,
          },
          all_configs.each_with_object({}) { |c, h| h[c.name] = c.class }
        )
      end

      test "the BaseConfig has tasks turned off by default" do
        assert_not base_config.database_tasks?
      end
    end
  end

  describe "BaseConfig" do
    let(:database) { "database" }
    let(:config) do
      ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig.new(
        "test",
        "test_tenant",
        { adapter: adapter, database: database }
      )
    end

    describe "SQLite" do
      let(:adapter) { "sqlite3" }
      let(:dir) { Dir.mktmpdir }

      describe "database_for" do
        describe "validation" do
          test "raises if the tenant name contains a path separator" do
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo/bar") }
          end

          test "raises if the tenant name contains a quote or double-quote or back-quote" do
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo'bar") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo\"bar") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo`bar") }
          end

          test "raises if the tenant name is empty" do
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("") }
          end

          test "raises if the tenant name begins with a dot" do
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for(".") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("..") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for(".hidden") }
          end

          test "raises if the tenant name contains a character that is special in a URI" do
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo%2ebar") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo?bar") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo#bar") }
            assert_raises(ActiveRecord::Tenanted::BadTenantNameError) { config.database_for("foo[bar") }
          end

          test "accepts the RFC 3986 unreserved characters" do
            assert_nothing_raised { config.database_for("a-b_c.d~9") }
          end

          describe "length" do
            let(:database) { "storage/db/tenanted/%{tenant}/main.sqlite3" }
            let(:limit) { ActiveRecord::Tenanted::DatabaseAdapters::SQLite::MAX_PATH_COMPONENT_BYTESIZE }

            test "accepts a tenant name that fills the path component" do
              assert_nothing_raised { config.database_for("a" * limit) }
            end

            test "raises if the tenant name is longer than the path component allows" do
              assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
                config.database_for("a" * (limit + 1))
              end
            end

            describe "parallel test workers" do
              # The worker suffix is added to the last path component, which is the tenant name
              # itself when the template ends with the specifier.
              let(:database) { "storage/db/tenanted/%{tenant}" }
              let(:suffix_length) { "_99".length }

              setup { config.test_worker_id = 99 }

              test "accepts a tenant name that fills the path component with the suffix" do
                assert_nothing_raised { config.database_for("a" * (limit - suffix_length)) }
              end

              test "counts the test worker suffix, which is part of the database name" do
                assert_raises(ActiveRecord::Tenanted::BadTenantNameError) do
                  config.database_for("a" * (limit - suffix_length + 1))
                end
              end
            end
          end
        end

        def assert_all_tenants_found
          Dir.chdir(dir) do
            [ "foo", "bar", "baz" ].each do |tenant|
              path = config.config_adapter.path_for(config.database_for(tenant))
              FileUtils.mkdir_p(File.dirname(path))
              FileUtils.touch(path)
            end

            assert_equal(Set.new(config.tenants), Set.new([ "foo", "bar", "baz" ]))
          end
        end

        # A database that another configuration owns can sit where the tenant databases sit, and
        # then it matches the tenant database pattern.
        describe "a database that belongs to another configuration" do
          let(:database) { "storage/db/tenanted/%{tenant}.sqlite3" }
          let(:untenanted_database) { "storage/db/tenanted/shared.sqlite3" }

          setup do
            @configurations_was = ActiveRecord::Base.configurations
            ActiveRecord::Base.configurations = {
              "test" => {
                "test_tenant" => { "adapter" => adapter, "database" => database, "tenanted" => true },
                "shared" => { "adapter" => adapter, "database" => untenanted_database },
              },
            }
          end

          teardown { ActiveRecord::Base.configurations = @configurations_was }

          test "is not returned as a tenant" do
            Dir.chdir(dir) do
              [ config.database_for("foo"), config.database_for("bar"), untenanted_database ].each do |path|
                FileUtils.mkdir_p(File.dirname(path))
                FileUtils.touch(path)
              end

              assert_same_elements([ "foo", "bar" ], config.tenants)
            end
          end
        end

        # The tenant name is read back out of a database path with a regular expression. The rest
        # of the path is matched literally, whatever it holds.
        describe "file path that holds a regular expression metacharacter" do
          let(:database) { "storage/db/tenanted(v1)/%{tenant}/main.sqlite3" }

          test "returns the path for a tenant" do
            assert_equal("storage/db/tenanted(v1)/foo/main.sqlite3", config.database_for("foo"))
          end

          test "returns all tenants" do
            assert_all_tenants_found
          end
        end

        describe "file path" do
          let(:database) { "storage/db/tenanted/%{tenant}/main.sqlite3" }

          test "returns the path for a tenant" do
            assert_equal("storage/db/tenanted/foo/main.sqlite3", config.database_for("foo"))
          end

          test "returns all tenants" do
            assert_all_tenants_found
          end

          describe "parallel test workers" do
            setup { config.test_worker_id = 99 }

            test "returns the worker-specific path for a tenant" do
              assert_equal("storage/db/tenanted/foo/main.sqlite3_99", config.database_for("foo"))
            end

            test "parallel test worker returns all tenants" do
              assert_all_tenants_found
            end
          end
        end

        describe "absolute URI" do
          let(:database) { "file:#{dir}/storage/db/tenanted/%{tenant}/main.sqlite3" }

          test "returns the path for a tenant" do
            assert_equal("file:#{dir}/storage/db/tenanted/foo/main.sqlite3", config.database_for("foo"))
          end

          test "returns all tenants" do
            assert_all_tenants_found
          end

          describe "parallel test workers" do
            setup { config.test_worker_id = 99 }

            test "returns the worker-specific path for a tenant" do
              assert_equal("file:#{dir}/storage/db/tenanted/foo/main.sqlite3_99", config.database_for("foo"))
            end

            test "parallel test worker returns all tenants" do
              assert_all_tenants_found
            end
          end
        end

        describe "absolute URI with query params" do
          let(:database) { "file:#{dir}/storage/db/tenanted/%{tenant}/main.sqlite3?vfs=unix-dotfile" }

          test "returns the path for a tenant" do
            assert_equal("file:#{dir}/storage/db/tenanted/foo/main.sqlite3?vfs=unix-dotfile", config.database_for("foo"))
          end

          test "returns all tenants" do
            assert_all_tenants_found
          end

          describe "parallel test workers" do
            setup { config.test_worker_id = 99 }

            test "returns the worker-specific path for a tenant" do
              assert_equal("file:#{dir}/storage/db/tenanted/foo/main.sqlite3_99?vfs=unix-dotfile", config.database_for("foo"))
            end

            test "parallel test worker returns all tenants" do
              assert_all_tenants_found
            end
          end
        end

        describe "relative URI" do
          let(:database) { "file:storage/db/tenanted/%{tenant}/main.sqlite3" }

          test "returns the path for a tenant" do
            assert_equal("file:storage/db/tenanted/foo/main.sqlite3", config.database_for("foo"))
          end

          test "returns all tenants" do
            assert_all_tenants_found
          end

          describe "parallel test workers" do
            setup { config.test_worker_id = 99 }

            test "returns the worker-specific path for a tenant" do
              assert_equal("file:storage/db/tenanted/foo/main.sqlite3_99", config.database_for("foo"))
            end

            test "parallel test worker returns all tenants" do
              assert_all_tenants_found
            end
          end
        end

        describe "relative URI with query params" do
          let(:database) { "file:storage/db/tenanted/%{tenant}/main.sqlite3?vfs=unix-dotfile" }

          test "returns the path for a tenant" do
            assert_equal("file:storage/db/tenanted/foo/main.sqlite3?vfs=unix-dotfile", config.database_for("foo"))
          end

          test "returns all tenants" do
            assert_all_tenants_found
          end

          describe "parallel test workers" do
            setup { config.test_worker_id = 99 }

            test "returns the worker-specific path for a tenant" do
              assert_equal("file:storage/db/tenanted/foo/main.sqlite3_99?vfs=unix-dotfile", config.database_for("foo"))
            end

            test "parallel test worker returns all tenants" do
              assert_all_tenants_found
            end
          end
        end
      end
    end

    describe "max_connection_pools" do
      test "defaults to 50" do
        config_hash = { adapter: "sqlite3", database: "database" }
        config = ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig.new("test", "foo", config_hash)

        assert_equal(50, config.max_connection_pools)
      end

      test "can be set in the config" do
        config_hash = { adapter: "sqlite3", database: "database", max_connection_pools: 99 }
        config = ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig.new("test", "foo", config_hash)

        assert_equal(99, config.max_connection_pools)
      end
    end

    for_each_scenario do
      test "raises if a connection is attempted" do
        assert_raises(ActiveRecord::Tenanted::NoTenantError) { base_config.new_connection }
      end

      # Two runs, or two parallel workers, must not use the same database on a server that they
      # share, so the scenario databases carry a prefix that belongs to the test process.
      test "the scenario databases carry the prefix of the test process" do
        assert_includes(base_config.database, self.class.database_prefix)

        untenanted = ActiveRecord::Base.configurations
          .configs_for(env_name: "test", include_hidden: true)
          .reject { |config| config.configuration_hash[:tenanted] }

        assert_not_empty(untenanted)
        untenanted.each { |config| assert_includes(config.database, self.class.database_prefix) }
      end

      describe ".tenants" do
        test "returns an array of existing tenants" do
          assert_empty(base_config.tenants)

          TenantedApplicationRecord.create_tenant("foo")

          assert_equal([ "foo" ], base_config.tenants)

          TenantedApplicationRecord.create_tenant("bar")

          assert_same_elements([ "foo", "bar" ], base_config.tenants)

          TenantedApplicationRecord.destroy_tenant("foo")

          assert_equal([ "bar" ], base_config.tenants)
        end
      end
    end

    with_scenario(:primary_db, :primary_record) do
      test "finds a tenant whose name uses the allowed punctuation" do
        assert_empty(base_config.tenants)

        punctuated_name = "a-b_c.d~9"
        TenantedApplicationRecord.create_tenant(punctuated_name)

        assert_equal([ punctuated_name ], base_config.tenants)
      end
    end
  end

  describe "TenantConfig" do
    describe "#primary?" do
      for_each_scenario({ primary_db: [ :primary_record ], primary_named_db: [ :primary_record ] }) do
        test "returns true" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          assert_predicate(config, :primary?)
        end
      end

      with_scenario(:secondary_db, :primary_record) do
        test "returns false" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          assert_not_predicate(config, :primary?)
        end
      end
    end

    describe "implicit file creation" do
      with_scenario(:primary_db, :primary_record) do
        # This is probably not behavior we want, long-term. See notes about the sqlite3 adapter in
        # tenant.rb. This test is descriptive, not prescriptive.
        test "creates a file if one does not exist" do
          config = base_config.new_tenant_config("foo")
          conn = config.new_connection

          assert_not(File.exist?(config.database))

          conn.execute("SELECT 1")

          assert(File.exist?(config.database))
          assert_operator(File.size(config.database), :>, 0)
        end
      end
    end

    describe "schema dump" do
      with_scenario(:primary_db, :primary_record) do
        test "to the default primary dump file" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          assert_equal("schema.rb", config.schema_dump)
        end

        test "can be overridden" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }

          config_hash = config.configuration_hash.dup.tap do |h|
            h[:schema_dump] = "custom_file_name.rb"
          end.freeze
          config.instance_variable_set(:@configuration_hash, config_hash)

          assert_equal("custom_file_name.rb", config.schema_dump)
        end
      end

      with_scenario(:primary_named_db, :primary_record) do
        test "to the default primary dump file" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          assert_equal("schema.rb", config.schema_dump)
        end
      end

      with_scenario(:secondary_db, :primary_record) do
        test "to a named dump file" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          assert_equal("tenanted_schema.rb", config.schema_dump)
        end
      end

      with_scenario(:primary_uri_db, :primary_record) do
        test "the URI is preserved in the config" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          assert_operator(config.database, :start_with?, "file:")
          assert_operator(config.database, :end_with?, "?foo=bar")
        end
      end
    end

    describe "schema cache dump" do
      with_scenario(:primary_db, :primary_record) do
        test "to the default primary dump file" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          path = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config)

          expected = File.join(ActiveRecord::Tasks::DatabaseTasks.db_dir, "schema_cache.yml")
          assert_equal(expected, path)
        end

        test "can be overridden" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }

          config_hash = config.configuration_hash.dup.tap do |h|
            h[:schema_cache_path] = "db/custom_file_name.rb"
          end.freeze
          config.instance_variable_set(:@configuration_hash, config_hash)
          path = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config)

          assert_equal("db/custom_file_name.rb", path)
        end
      end

      with_scenario(:primary_named_db, :primary_record) do
        test "to the default primary dump file" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          path = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config)

          expected = File.join(ActiveRecord::Tasks::DatabaseTasks.db_dir, "schema_cache.yml")
          assert_equal(expected, path)
        end
      end

      with_scenario(:secondary_db, :primary_record) do
        test "to a named dump file" do
          config = TenantedApplicationRecord.create_tenant("foo") { User.connection_db_config }
          path = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config)

          expected = File.join(ActiveRecord::Tasks::DatabaseTasks.db_dir, "tenanted_schema_cache.yml")
          assert_equal(expected, path)
        end
      end
    end
  end
end

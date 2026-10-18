# frozen_string_literal: true

require "test_helper"

# Stands in for Rails.application, which loads db/seeds.rb.
class SeedLoader
  attr_reader :tenants

  def initialize
    @tenants = []
  end

  def load_seed
    @tenants << TenantedApplicationRecord.current_tenant
    User.create!
  end
end

describe ActiveRecord::Tenanted::DatabaseTasks do
  describe ".migrate_tenant" do
    for_each_scenario do
      setup do
        base_config.new_tenant_config("foo").config_adapter.create_database
      end

      test "database should be created" do
        config = base_config.new_tenant_config("bar")

        assert_not_predicate(config.config_adapter, :database_exist?)

        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("bar")

        assert_predicate(config.config_adapter, :database_exist?)
      end

      test "database should be migrated" do
        ActiveRecord::Migration.verbose = true

        assert_output(/migrating.*create_table/m, nil) do
          ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")
        end

        config = base_config.new_tenant_config("foo")
        ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
          assert_equal(20250203191115, conn.pool.migration_context.current_version)
        end
      end

      test "database schema file should be created" do
        config = base_config.new_tenant_config("foo")
        schema_path = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(config)

        assert_not(File.exist?(schema_path))

        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")

        assert(File.exist?(schema_path))
      end

      test "database schema cache file should be created" do
        config = base_config.new_tenant_config("foo")
        schema_cache_path = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config)

        assert_not(File.exist?(schema_cache_path))

        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")

        assert(File.exist?(schema_cache_path))
      end

      describe "when database task output is not suppressed" do
        # The test suite sets VERBOSE so that the database tasks stay quiet.
        setup { @verbose_was, ENV["VERBOSE"] = ENV["VERBOSE"], nil }
        teardown { ENV["VERBOSE"] = @verbose_was }

        test "a created database should be reported" do
          assert_output(/Created database '[^']*bar[^']*'/, nil) do
            ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("bar")
          end
        end

        test "an existing database should not be reported" do
          out, _err = capture_io do
            ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")
          end

          assert_no_match(/Created database/, out)
        end
      end

      describe "when schema dump file exists" do
        setup { with_schema_dump_file }

        test "database should load the schema dump file" do
          ActiveRecord::Migration.verbose = true

          assert_silent do
            ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")
          end

          config = base_config.new_tenant_config("foo")
          ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
            assert_equal(20250203191115, conn.pool.migration_context.current_version)
          end
        end

        describe "and there are pending migrations" do
          setup { with_new_migration_file }

          test "it runs the migrations after loading the schema" do
            ActiveRecord::Migration.verbose = true

            assert_output(/migrating.*add_column/m, nil) do
              ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")
            end

            config = base_config.new_tenant_config("foo")
            ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
              assert_equal(20250213005959, conn.pool.migration_context.current_version)
            end
          end
        end
      end

      describe "when schema dump file and schema cache dump file exist" do
        setup { with_schema_dump_file }
        setup { with_schema_cache_dump_file }

        let(:cache_dump) { ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(base_config) }

        test "a current schema cache dump file is not rewritten" do
          FileUtils.touch(cache_dump, mtime: Time.now - 60)
          mtime_was = File.mtime(cache_dump)

          ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")

          assert_equal(mtime_was, File.mtime(cache_dump))
        end

        test "a schema cache dump file with another version is rewritten" do
          File.write(cache_dump, File.read(cache_dump).sub(/^version: .*$/, "version: 20250213005959"))

          ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")

          cache = ActiveRecord::ConnectionAdapters::SchemaCache._load_from(cache_dump)
          assert_equal(20250203191115, cache.schema_version)
        end
      end

      describe "when an outdated schema cache dump file exists" do
        setup { with_schema_cache_dump_file }
        setup { with_new_migration_file }

        test "remaining migrations are applied" do
          ActiveRecord::Migration.verbose = true

          assert_output(/migrating.*add_column/m, nil) do
            ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_tenant("foo")
          end

          config = base_config.new_tenant_config("foo")
          ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
            assert_equal(20250213005959, conn.pool.migration_context.current_version)
          end
        end
      end
    end
  end

  describe ".seed_tenant" do
    for_each_scenario do
      let(:seed_loader) { SeedLoader.new }

      setup do
        Rails.application.config.active_record_tenanted.connection_class = "TenantedApplicationRecord"
        @seed_loader_was = ActiveRecord::Tasks::DatabaseTasks.seed_loader
        ActiveRecord::Tasks::DatabaseTasks.seed_loader = seed_loader

        TenantedApplicationRecord.create_tenant("foo")
        TenantedApplicationRecord.create_tenant("bar")
      end

      teardown do
        ActiveRecord::Tasks::DatabaseTasks.seed_loader = @seed_loader_was
      end

      test "loads the seeds into the tenant database" do
        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).seed_tenant("foo")

        assert_equal([ "foo" ], seed_loader.tenants)
        TenantedApplicationRecord.with_tenant("foo") { assert_equal(1, User.count) }
        TenantedApplicationRecord.with_tenant("bar") { assert_equal(0, User.count) }
      end

      test "raises if the integration is not configured" do
        Rails.application.config.active_record_tenanted.connection_class = nil

        assert_raises(ActiveRecord::Tenanted::IntegrationNotConfiguredError) do
          ActiveRecord::Tenanted::DatabaseTasks.new(base_config).seed_tenant("foo")
        end
      end
    end
  end

  describe ".seed_all" do
    for_each_scenario do
      let(:tenants) { %w[foo bar baz] }
      let(:seed_loader) { SeedLoader.new }

      setup do
        Rails.application.config.active_record_tenanted.connection_class = "TenantedApplicationRecord"
        @seed_loader_was = ActiveRecord::Tasks::DatabaseTasks.seed_loader
        ActiveRecord::Tasks::DatabaseTasks.seed_loader = seed_loader

        tenants.each do |tenant|
          TenantedApplicationRecord.create_tenant(tenant)
        end
      end

      teardown do
        ActiveRecord::Tasks::DatabaseTasks.seed_loader = @seed_loader_was
      end

      test "loads the seeds into all existing tenants" do
        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).seed_all

        assert_same_elements(tenants, seed_loader.tenants)
        tenants.each do |tenant|
          TenantedApplicationRecord.with_tenant(tenant) { assert_equal(1, User.count) }
        end
      end
    end
  end

  describe ".migrate_all" do
    for_each_scenario do
      let(:tenants) { %w[foo bar baz] }

      setup do
        tenants.each do |tenant|
          TenantedApplicationRecord.create_tenant(tenant)
        end

        with_new_migration_file
      end

      test "migrates all existing tenants" do
        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).migrate_all

        tenants.each do |tenant|
          config = base_config.new_tenant_config(tenant)
          ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
            assert_equal(20250213005959, conn.pool.migration_context.current_version)
          end
        end
      end
    end
  end

  describe ".rollback_tenant" do
    for_each_scenario do
      let(:tasks) { ActiveRecord::Tenanted::DatabaseTasks.new(base_config) }

      setup do
        %w[foo bar].each { |tenant| TenantedApplicationRecord.create_tenant(tenant) }
        with_new_migration_file
        tasks.migrate_all
      end

      test "rolls back one migration of the tenant, and no other tenant" do
        tasks.rollback_tenant("foo")

        assert_equal(20250203191115, current_version("foo"))
        assert_equal(20250213005959, current_version("bar"))
      end

      test "rolls back the number of migrations in step" do
        tasks.rollback_tenant("foo", step: 2)

        assert_equal(0, current_version("foo"))
      end

      test "dumps the schema of the rolled back database" do
        schema_path = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(base_config.new_tenant_config("foo"))

        assert_includes(File.read(schema_path), "age")

        tasks.rollback_tenant("foo")

        assert_not_includes(File.read(schema_path), "age")
      end

      test "raises for a tenant that does not exist, and does not create its database" do
        assert_raises(ActiveRecord::Tenanted::TenantDoesNotExistError) do
          tasks.rollback_tenant("missing")
        end

        assert_not_predicate(base_config.new_tenant_config("missing").config_adapter, :database_exist?)
      end
    end
  end

  describe ".rollback_all" do
    for_each_scenario do
      test "rolls back each existing tenant" do
        tasks = ActiveRecord::Tenanted::DatabaseTasks.new(base_config)
        %w[foo bar].each { |tenant| TenantedApplicationRecord.create_tenant(tenant) }
        with_new_migration_file
        tasks.migrate_all

        tasks.rollback_all

        assert_equal(20250203191115, current_version("foo"))
        assert_equal(20250203191115, current_version("bar"))
      end

      test "does not create a database when there are no tenants" do
        ActiveRecord::Tenanted::DatabaseTasks.new(base_config).rollback_all

        assert_empty(base_config.tenants)
      end
    end
  end

  describe ".wrap_rails_rollback_task" do
    setup do
      @rake_application_was = Rake.application
      Rake.application = Rake::Application.new
      @ran = []
      ran = @ran
      Rake::Task.define_task("db:rollback") { ran << :rails }
    end

    teardown do
      Rake.application = @rake_application_was
    end

    with_scenario(:primary_db, :primary_record) do
      setup do
        ran = @ran
        Rake::Task.define_task("db:rollback:#{base_config.name}") { ran << :tenanted }
        ActiveRecord::Tenanted::DatabaseTasks.wrap_rails_rollback_task([ base_config ])
      end

      test "runs the tenanted task when the tenanted database is the only database" do
        ActiveRecord::Base.configurations.stub(:configs_for, []) do
          Rake::Task["db:rollback"].invoke
        end

        assert_equal([ :tenanted ], @ran)
      end

      test "names the tenanted task when the primary database is tenanted" do
        error = assert_raises(RuntimeError) { Rake::Task["db:rollback"].invoke }

        assert_includes(error.message, "db:rollback:#{base_config.name}")
        assert_empty(@ran)
      end
    end

    with_scenario(:secondary_db, :primary_record) do
      setup do
        ActiveRecord::Tenanted::DatabaseTasks.wrap_rails_rollback_task([ base_config ])
      end

      test "runs the Rails task when the primary database is not tenanted" do
        Rake::Task["db:rollback"].invoke

        assert_equal([ :rails ], @ran)
      end
    end
  end

  private
    def current_version(tenant)
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(base_config.new_tenant_config(tenant)) do |conn|
        conn.pool.migration_context.current_version
      end
    end
end

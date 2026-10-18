# frozen_string_literal: true

require "rake"

module ActiveRecord
  module Tenanted
    class DatabaseTasks # :nodoc:
      include Rake::DSL

      class << self
        def verbose?
          ActiveRecord::Tasks::DatabaseTasks.send(:verbose?)
        end

        # Rails' db:rollback works on one database. Rails does not count a tenanted configuration,
        # so in an application whose only database is tenanted, or whose primary database is
        # tenanted, it rolls back ActiveRecord::Base and raises NoTenantError.
        def wrap_rails_rollback_task(base_configs)
          return if base_configs.empty? || !Rake::Task.task_defined?("db:rollback")

          rails_task = Rake::Task["db:rollback"]
          rails_actions = rails_task.actions.dup
          rails_task.clear_actions

          rails_task.enhance do |task, args|
            other_configs = ActiveRecord::Base.configurations.configs_for(env_name: ActiveRecord::Tasks::DatabaseTasks.env)
            tenanted_tasks = base_configs.map { |config| "db:rollback:#{config.name}" }

            if other_configs.empty? && base_configs.one?
              Rake::Task[tenanted_tasks.first].invoke
            elsif other_configs.empty? || primary_config_tenanted?
              # Rails defines db:rollback:NAME only when it sees more than one database.
              other_tasks = other_configs.map { |config| "db:rollback:#{config.name}" }.select { |name| Rake::Task.task_defined?(name) }

              raise "The tenanted databases are rolled back by their own task. Available tasks are " \
                    "#{(tenanted_tasks + other_tasks).to_sentence}."
            else
              rails_actions.each { |action| action.call(task, args) }
            end
          end
        end

        private
          # The configuration that Rails' db:rollback rolls back: the one that ActiveRecord::Base
          # connects to when the application boots.
          def primary_config_tenanted?
            ActiveRecord::Base.configurations.find_db_config(ActiveRecord::Tasks::DatabaseTasks.env)
              .is_a?(ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig)
          end
      end

      attr_reader :config

      def initialize(config)
        unless config.is_a?(ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig)
          raise TypeError, "Argument must be an instance of ActiveRecord::Tenanted::DatabaseConfigurations::BaseConfig"
        end
        @config = config
      end

      def migrate_all
        tenants.each do |tenant|
          migrate_tenant(tenant)
        end
      end

      def migrate_tenant(tenant = set_current_tenant)
        db_config = config.new_tenant_config(tenant)
        migrate(db_config)
      end

      def drop_all
        tenants.each do |tenant|
          drop_tenant(tenant)
        end
      end

      def drop_tenant(tenant = set_current_tenant)
        db_config = config.new_tenant_config(tenant)
        db_config.config_adapter.drop_database
        $stdout.puts "Dropped database '#{db_config.database}'" if verbose?
      end

      # Only the databases that exist are rolled back. The fallback to a default tenant that #tenants
      # makes is not used, because a connection to a SQLite database that is not there creates it.
      def rollback_all(step: 1)
        config.tenants.each do |tenant|
          rollback_tenant(tenant, step: step)
        end
      end

      def rollback_tenant(tenant = set_current_tenant, step: 1)
        db_config = config.new_tenant_config(tenant)

        unless db_config.config_adapter.database_exist?
          raise TenantDoesNotExistError, "The database for tenant #{tenant.inspect} does not exist."
        end

        rollback(db_config, step: step)
      end

      def seed_all
        tenants.each do |tenant|
          seed_tenant(tenant)
        end
      end

      def seed_tenant(tenant = set_current_tenant)
        connection_class.with_tenant(tenant) do
          ActiveRecord::Tasks::DatabaseTasks.load_seed
        end
        $stdout.puts "Seeded database for tenant #{tenant.inspect}" if verbose?
      end

      def tenants
        config.tenants.presence || [ get_default_tenant ].compact
      end

      def get_default_tenant
        # TODO: needs to work with multiple tenanted configs, maybe using ENV["ARTENANT_#{config.name}"]
        tenant = ENV["ARTENANT"]

        if tenant.present?
          $stdout.puts "Setting current tenant to #{tenant.inspect}" if verbose?
        elsif Rails.env.local?
          tenant = Rails.application.config.active_record_tenanted.default_tenant
          $stdout.puts "Defaulting current tenant for #{config.name.inspect} to #{tenant.inspect}" if verbose?
        else
          tenant = nil
          $stdout.puts "Cannot determine an implicit tenant: ARTENANT not set, and Rails.env is not local." if verbose?
        end

        tenant
      end

      def connection_class
        ActiveRecord::Tenanted.connection_class ||
          raise(ActiveRecord::Tenanted::IntegrationNotConfiguredError,
                "ActiveRecord::Tenanted integration is not configured via connection_class")
      end

      def set_current_tenant
        if connection_class.current_tenant.nil?
          connection_class.current_tenant = get_default_tenant
        else
          connection_class.current_tenant
        end
      end

      # This is essentially a simplified implementation of ActiveRecord::Tasks::DatabaseTasks.migrate
      def migrate(config)
        # The database must exist before a connection is made to it. #create_database is
        # idempotent, and reports whether it created the database, so there is no check here.
        if config.config_adapter.create_database
          $stdout.puts "Created database '#{config.database}'" if verbose?
        end

        ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
          pool = conn.pool

          # initialize_database
          unless pool.schema_migration.table_exists?
            schema_dump_path = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(config)
            if schema_dump_path && File.exist?(schema_dump_path)
              ActiveRecord::Tasks::DatabaseTasks.load_schema(config)
            end
          end

          # migrate
          migrated = false
          if pool.migration_context.pending_migration_versions.present?
            pool.migration_context.migrate(nil)
            pool.schema_cache.clear!
            migrated = true
          end

          # dump the schema and schema cache
          if Rails.env.development? || ENV["ARTENANT_SCHEMA_DUMP"].present?
            if migrated
              ActiveRecord::Tasks::DatabaseTasks.dump_schema(config)
            end

            cache_dump = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config)
            if migrated || schema_cache_dump_expired?(pool, cache_dump)
              ActiveRecord::Tasks::DatabaseTasks.dump_schema_cache(pool, cache_dump)
            end
          end
        end
      end

      def rollback(config, step:)
        ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |conn|
          pool = conn.pool

          pool.migration_context.rollback(step)
          pool.schema_cache.clear!

          if Rails.env.development? || ENV["ARTENANT_SCHEMA_DUMP"].present?
            ActiveRecord::Tasks::DatabaseTasks.dump_schema(config)
            ActiveRecord::Tasks::DatabaseTasks.dump_schema_cache(pool, ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(config))
          end
        end
      end

      def verbose?
        self.class.verbose?
      end

      # A schema load, or a change of branch, can leave a schema cache dump in place that does not
      # match the database. The dump is expired when it is missing, or when its version is not the
      # schema version of the database.
      def schema_cache_dump_expired?(pool, cache_dump)
        cache = ActiveRecord::ConnectionAdapters::SchemaCache._load_from(cache_dump)
        cache.nil? || cache.schema_version != pool.migration_context.current_version
      end

      def register_rake_tasks
        name = config.name

        desc "Migrate tenanted #{name} databases for current environment"
        task "db:migrate:#{name}" => "load_config" do
          verbose_was = ActiveRecord::Migration.verbose
          ActiveRecord::Migration.verbose = ActiveRecord::Tenanted::DatabaseTasks.verbose?

          tenant = ENV["ARTENANT"]
          if tenant.present?
            migrate_tenant(tenant)
          else
            migrate_all
          end
        ensure
          ActiveRecord::Migration.verbose = verbose_was
        end
        task "db:migrate" => "db:migrate:#{name}"
        task "db:prepare" => "db:migrate:#{name}"

        desc "Roll back tenanted #{name} databases for current environment (specify steps w/ STEP=n)"
        task "db:rollback:#{name}" => "load_config" do
          raise "VERSION is not supported - To rollback a specific version, use db:migrate:down" if ENV["VERSION"]

          verbose_was = ActiveRecord::Migration.verbose
          ActiveRecord::Migration.verbose = ActiveRecord::Tenanted::DatabaseTasks.verbose?

          step = ENV["STEP"] ? ENV["STEP"].to_i : 1
          tenant = ENV["ARTENANT"]
          if tenant.present?
            rollback_tenant(tenant, step: step)
          else
            rollback_all(step: step)
          end
        ensure
          ActiveRecord::Migration.verbose = verbose_was
        end

        desc "Drop tenanted #{name} databases for current environment"
        task "db:drop:#{name}" => "load_config" do
          verbose_was = ActiveRecord::Migration.verbose
          ActiveRecord::Migration.verbose = ActiveRecord::Tenanted::DatabaseTasks.verbose?

          tenant = ENV["ARTENANT"]
          if tenant.present?
            drop_tenant(tenant)
          else
            drop_all
          end
        ensure
          ActiveRecord::Migration.verbose = verbose_was
        end
        task "db:drop" => "db:drop:#{name}"

        desc "Load the seed data into tenanted #{name} databases for current environment"
        task "db:seed:#{name}" => "load_config" do
          tenant = ENV["ARTENANT"]
          if tenant.present?
            seed_tenant(tenant)
          else
            seed_all
          end
        end

        desc "Drop and recreate tenanted #{name} databases for the current environment and load the seeds"
        task "db:reset:#{name}" => [ "db:drop:#{name}", "db:migrate:#{name}", "db:seed:#{name}" ]
        task "db:reset" => "db:reset:#{name}"
      end
    end
  end
end

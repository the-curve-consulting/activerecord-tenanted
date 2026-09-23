# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseConfigurations
      class BaseConfig < ActiveRecord::DatabaseConfigurations::HashConfig
        DEFAULT_MAX_CONNECTION_POOLS = 50

        attr_accessor :test_worker_id

        def initialize(...)
          super
          @test_worker_id = nil
          @config_adapter = nil
        end

        def config_adapter
          @config_adapter ||= ActiveRecord::Tenanted::DatabaseAdapter.new(self)
        end

        def database_tasks?
          false
        end

        def database_for(tenant_name)
          tenant_name = tenant_name.to_s

          config_adapter.validate_tenant_name(tenant_name)

          database_pattern_for(tenant_name).tap do |database|
            # The database template and the test worker suffix are part of the name that the
            # database gets, so the built name is validated as well as the tenant name.
            config_adapter.validate_database_name(database)
          end
        end

        # Interpolates a glob or a regular expression into the database path. The pattern is not a
        # tenant name and is not validated as one.
        def database_pattern_for(pattern) # :nodoc:
          db = sprintf(database, tenant: pattern)

          if test_worker_id
            db = config_adapter.test_workerize(db, test_worker_id)
          end

          db
        end

        def tenants
          databases = untenanted_databases

          config_adapter.tenant_databases.reject do |tenant_name|
            databases.include?(database_pattern_for(tenant_name))
          end
        end

        def new_tenant_config(tenant_name)
          database = database_for(tenant_name) # validates the tenant name before it is used below

          config_name = "#{name}_#{tenant_name}"
          config_hash = configuration_hash.dup.tap do |hash|
            hash[:tenant] = tenant_name
            hash[:database] = database
            hash[:tenanted_config_name] = name
          end
          Tenanted::DatabaseConfigurations::TenantConfig.new(env_name, config_name, config_hash)
        end

        def new_connection
          raise NoTenantError, "Cannot use an untenanted ActiveRecord::Base connection. " \
                               "If you have a model that inherits directly from ActiveRecord::Base, " \
                               "make sure to use 'subtenant_of'. In development, you may see this error " \
                               "if constant reloading is not being done properly."
        end

        def max_connection_pools
          (configuration_hash[:max_connection_pools] || DEFAULT_MAX_CONNECTION_POOLS).to_i
        end

        private
          # The database of another configuration can match the tenant database pattern. A
          # "%{tenant}" pattern on a database server shares the server with every other database
          # of the application, and a pattern such as "storage/%{tenant}.sqlite3" shares its
          # directory. Such a database is not a tenant.
          def untenanted_databases
            ActiveRecord::Base.configurations
              .configs_for(env_name: env_name)
              .reject { |config| config.configuration_hash[:tenanted] }
              .filter_map(&:database)
          end
      end
    end
  end
end

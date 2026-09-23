# frozen_string_literal: true

require "digest"

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  The database adapter for a MySQL server. It is registered for the "mysql2" and the
      #  "trilogy" connection adapters.
      #
      #  Every tenant gets its own database on the server, and the "%{tenant}" specifier in the
      #  database name of the configuration says how the name is built.
      #
      class MySQL
        attr_reader :db_config

        def initialize(db_config)
          @db_config = db_config
        end

        # A tenant name is interpolated into the name of a database. MySQL makes a directory on
        # the server for each database, and it encodes a character that a filesystem cannot hold.
        # The name is therefore limited to letters, digits, "-" and "_", which every server and
        # every filesystem keep unchanged. This is narrower than the RFC 3986 unreserved set that
        # the SQLite adapter allows: a dot and a tilde are left out, because a dot separates the
        # database from the table in a qualified name, and because MySQL does not accept a name
        # that ends with a space or a dot. Start narrow, because a name can be widened later but
        # cannot be narrowed without breaking an application.
        TENANT_NAME_PATTERN = /\A[A-Za-z0-9_-]+\z/

        # MySQL limits the name of a database to 64 characters. The limit is on the database name,
        # so it covers the tenant name together with anything the database template and the test
        # worker suffix add to it.
        MAX_DATABASE_NAME_LENGTH = 64

        # MySQL limits the name of an advisory lock to 64 characters as well.
        MAX_LOCK_NAME_LENGTH = 64

        # The number of seconds that #acquire_ready_lock waits for the lock.
        READY_LOCK_TIMEOUT = 30

        # Stands in for the tenant name while the LIKE pattern and the scanner in
        # #tenant_databases are built. It is long and specific, so that it cannot appear in the
        # rest of a database name, and it holds only letters, so that neither Regexp.escape nor
        # the LIKE escaping changes it.
        TENANT_NAME_PLACEHOLDER = "activerecordtenantedtenantnameplaceholder"

        def tenant_databases
          like = like_pattern
          scanner = tenant_name_scanner

          with_anonymous_connection do |conn|
            database_names(conn, like).filter_map do |name|
              result = scanner.match(name)&.captures&.first

              if result.nil?
                Rails.logger.warn "ActiveRecord::Tenanted: Cannot parse tenant name from database #{name.inspect}"
                next
              end

              unless valid_tenant_name?(result)
                Rails.logger.warn "ActiveRecord::Tenanted: Skipping database with an invalid tenant name #{result.inspect}"
                next
              end

              result
            end
          end
        end

        def valid_tenant_name?(tenant_name)
          tenant_name.encoding.ascii_compatible? &&
            tenant_name.valid_encoding? &&
            TENANT_NAME_PATTERN.match?(tenant_name)
        end

        def validate_tenant_name(tenant_name)
          unless valid_tenant_name?(tenant_name)
            raise BadTenantNameError,
                  "Tenant name may contain only letters, digits, and the characters " \
                  "'-' and '_': #{tenant_name.inspect}"
          end
        end

        # Validates the database name that a tenant name is built into, and not the tenant name
        # alone, because the database template and the test worker suffix are part of the name
        # that the server must accept.
        def validate_database_name(database)
          if database.length > MAX_DATABASE_NAME_LENGTH
            raise BadTenantNameError,
                  "Tenant name makes the database name #{database.truncate(32).inspect} longer " \
                  "than #{MAX_DATABASE_NAME_LENGTH} characters"
          end
        end

        # Creates the database when it does not exist yet. The caller does not check first, so this
        # method is idempotent. It returns true only when it creates the database, so that the
        # caller can report the new database.
        def create_database
          with_anonymous_connection do |conn|
            next false if schema_exist?(conn)

            conn.create_database(database, create_database_options)
            true
          end
        end

        def drop_database
          # The Rails adapter writes DROP DATABASE IF EXISTS, so a database that is not there is
          # not an error.
          with_anonymous_connection { |conn| conn.drop_database(database) }
        end

        def database_exist?
          with_anonymous_connection { |conn| schema_exist?(conn) }
        end

        # The database is ready when it exists and nobody holds the ready lock. The lock belongs to
        # the session that took it, so the server is asked who holds it, from another connection.
        def database_ready?
          with_anonymous_connection do |conn|
            schema_exist?(conn) && !ready_lock_held?(conn)
          end
        end

        # Holds the ready lock for the whole block. The lock is released when the session that took
        # it releases it, so that session stays open until the block returns or raises.
        def acquire_ready_lock
          lock_name = ready_lock_name

          with_anonymous_connection do |conn|
            unless conn.select_value("SELECT GET_LOCK(#{conn.quote(lock_name)}, #{READY_LOCK_TIMEOUT})") == 1
              raise ActiveRecord::LockWaitTimeout,
                    "Could not acquire the ready lock for database #{database.inspect}"
            end

            begin
              yield
            ensure
              conn.select_value("SELECT RELEASE_LOCK(#{conn.quote(lock_name)})")
            end
          end
        end

        def test_workerize(db, test_worker_id)
          test_worker_suffix = "_#{test_worker_id}"

          # Rails adds the replicas of a configuration to the parallel test setup, and the base
          # configuration comes with them, so a name can reach this method twice. See
          # https://github.com/rails/rails/pull/55769
          db.end_with?(test_worker_suffix) ? db : "#{db}#{test_worker_suffix}"
        end

        private
          def database
            db_config.database
          end

          def create_database_options
            options = {}
            configuration_hash = db_config.configuration_hash

            options[:charset] = configuration_hash[:encoding] if configuration_hash[:encoding]
            options[:collation] = configuration_hash[:collation] if configuration_hash[:collation]
            options
          end

          def schema_exist?(conn)
            !conn.select_value(
              "SELECT 1 FROM information_schema.schemata " \
              "WHERE schema_name = #{conn.quote(database)} LIMIT 1"
            ).nil?
          end

          def database_names(conn, like)
            conn.select_values(
              "SELECT schema_name FROM information_schema.schemata " \
              "WHERE schema_name LIKE #{conn.quote(like)}"
            )
          end

          # The lock name is a digest, because the database name alone can be longer than a lock
          # name may be, and because a lock name is shared by every database on the server.
          def ready_lock_name
            "artenant_ready_#{Digest::SHA256.hexdigest(database)}"[0, MAX_LOCK_NAME_LENGTH]
          end

          def ready_lock_held?(conn)
            # IS_USED_LOCK returns the id of the session that holds the lock, and NULL when the
            # lock is free.
            !conn.select_value("SELECT IS_USED_LOCK(#{conn.quote(ready_lock_name)})").nil?
          end

          # The LIKE pattern selects the tenant databases on the server. Everything but the tenant
          # name is escaped, so that a name that holds "%" or "_" is matched literally. "_" is
          # common in a database name, so an unescaped pattern would return databases that are not
          # tenants.
          def like_pattern
            pattern = db_config.database_pattern_for(TENANT_NAME_PLACEHOLDER)

            escaped = pattern.gsub(/[\\%_]/) { |char| "\\#{char}" }
            escaped.gsub(TENANT_NAME_PLACEHOLDER, "%")
          end

          # The scanner reads a tenant name back out of a database name. Everything but the tenant
          # name is escaped, so that a name with a regular expression metacharacter is matched
          # literally, and the scanner is anchored, so that it cannot match part of a longer name.
          def tenant_name_scanner
            escaped = Regexp.escape(db_config.database_pattern_for(TENANT_NAME_PLACEHOLDER))

            # A template may use the %{tenant} specifier more than once. The first use captures
            # the tenant name, and a later use must match the name that was captured.
            captured = false
            pattern = escaped.gsub(TENANT_NAME_PLACEHOLDER) do
              if captured
                "\\1"
              else
                captured = true
                "(.+)"
              end
            end

            /\A#{pattern}\z/
          end

          # Connects to the server without naming a database, and yields the connection.
          #
          # ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection is not used here, because
          # it replaces the global connection pool of ActiveRecord::Base for the length of the
          # block, and a query of another thread would then reach a configuration that names no
          # database. A throwaway connection handler keeps the server connection out of the global
          # pool.
          def with_anonymous_connection(&block)
            server_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              "#{db_config.name}_anonymous",
              db_config.configuration_hash.except(:database)
            )

            handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
            pool = handler.establish_connection(server_config)

            pool.with_connection(&block)
          ensure
            handler&.clear_all_connections!(:all)
          end
      end
    end
  end
end

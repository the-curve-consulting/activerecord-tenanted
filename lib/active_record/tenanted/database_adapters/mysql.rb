# frozen_string_literal: true

require "digest"

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  The database adapter for a MySQL server. It is registered for the "mysql2" and the
      #  "trilogy" connection adapters, because both talk to the same server.
      #
      #  See Server for what this shares with the PostgreSQL adapter.
      #
      class MySQL < Server
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
            next false if database_exist_on?(conn)

            conn.create_database(database, create_database_options)
            true
          end
        end

        def drop_database
          # The Rails adapter writes DROP DATABASE IF EXISTS, so a database that is not there is
          # not an error.
          with_anonymous_connection { |conn| conn.drop_database(database) }
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

        private
          def tenant_name_message(tenant_name)
            "Tenant name may contain only letters, digits, and the characters " \
              "'-' and '_': #{tenant_name.inspect}"
          end

          def create_database_options
            options = {}
            configuration_hash = db_config.configuration_hash

            options[:charset] = configuration_hash[:encoding] if configuration_hash[:encoding]
            options[:collation] = configuration_hash[:collation] if configuration_hash[:collation]
            options
          end

          def database_exist_on?(conn)
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

          def ready_lock_held_on?(conn)
            # IS_USED_LOCK returns the id of the session that holds the lock, and NULL when the
            # lock is free.
            !conn.select_value("SELECT IS_USED_LOCK(#{conn.quote(ready_lock_name)})").nil?
          end

          # The server is reached without naming a database at all.
          def anonymous_db_config
            ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name,
              "#{db_config.name}_anonymous",
              db_config.configuration_hash.except(:database)
            )
          end
      end
    end
  end
end

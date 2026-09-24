# frozen_string_literal: true

require "digest"

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  The database adapter for a PostgreSQL server. Each tenant has a database of its own, and
      #  the "%{tenant}" specifier in the "database" key of the configuration builds the name.
      #
      #  See Server for what this shares with the MySQL adapter.
      #
      class PostgreSQL < Server
        # A tenant name becomes part of a PostgreSQL database name, so it is limited to the RFC
        # 3986 unreserved characters without the dot. A dot separates the parts of a qualified
        # identifier, and Rails splits a name on the dot when it quotes the name, so a dot would
        # build a name that Rails quotes as two identifiers.
        #
        # PostgreSQL folds an unquoted identifier to lower case, but this adapter never writes the
        # database name unquoted. Rails quotes the name in CREATE DATABASE, this adapter quotes it
        # in DROP DATABASE, and every other use sends the name as a string, either as a connection
        # parameter or as a value in a query. The case of a tenant name is therefore kept, and two
        # names that differ only in case are two tenants, as they are for SQLite. A person who
        # types such a name into psql must quote it there.
        TENANT_NAME_PATTERN = /\A[A-Za-z0-9_~-]+\z/

        # PostgreSQL limits a database name to 63 bytes and truncates a longer name without a
        # warning. The limit is on the whole name, so it covers the tenant name together with
        # whatever the database template and the test worker suffix add to it.
        MAX_DATABASE_NAME_BYTESIZE = 63

        # The database that the anonymous connection uses. Every PostgreSQL server has it. It is
        # not a template database, so a connection to it never blocks CREATE DATABASE.
        ANONYMOUS_DATABASE = "postgres"

        # Rails uses this encoding when the configuration does not name one.
        DEFAULT_ENCODING = "utf8"

        # PostgreSQL 13 and later accept WITH (FORCE) on DROP DATABASE.
        FORCE_DROP_DATABASE_VERSION = 13_00_00

        # Validates the database name that a tenant name is built into, and not the tenant name
        # alone, because the database template and the test worker suffix are part of the name
        # that the server must accept.
        def validate_database_name(database)
          if database.bytesize > MAX_DATABASE_NAME_BYTESIZE
            raise BadTenantNameError,
                  "Tenant name makes the database name #{database.truncate(32).inspect} longer " \
                  "than #{MAX_DATABASE_NAME_BYTESIZE} bytes"
          end
        end

        # Creates the database when it does not exist yet. The caller does not check first, so this
        # method is idempotent. It returns true only when it creates the database, so that the
        # caller can report the new database.
        def create_database
          with_anonymous_connection do |conn|
            # The configuration hash carries the options of the new database, such as the template
            # to copy. Rails reads the options it knows and ignores every other key, which is what
            # its own PostgreSQL database task does.
            conn.create_database(database, database_options)
          end

          true
        rescue ActiveRecord::DatabaseAlreadyExists
          false
        end

        # PostgreSQL refuses to drop a database while a session is connected to it, and this gem
        # keeps a connection pool for each tenant, so a session on the database of the tenant being
        # dropped is the usual case, not an unusual one. WITH (FORCE) ends those sessions.
        #
        # The statement is written here rather than left to Rails. Rails adds WITH (FORCE) only
        # from the version after 8.1, and this gem supports 8.1, where a drop would fail with
        # PG::ObjectInUse whenever a session was open.
        def drop_database
          with_anonymous_connection do |conn|
            statement = "DROP DATABASE IF EXISTS #{conn.quote_table_name(database)}"
            statement += " WITH (FORCE)" if conn.database_version >= FORCE_DROP_DATABASE_VERSION

            conn.execute(statement)
          end
        end

        # Holds the ready lock while the block runs. The lock belongs to the session, so the
        # connection that takes it stays open until the block is done.
        def acquire_ready_lock
          key = ready_lock_key

          with_anonymous_connection do |conn|
            # The call waits until the lock is free. The result of the lock function is not read,
            # because its type is "void", which Rails cannot cast.
            conn.execute("SELECT pg_advisory_lock(#{key.fetch(:signed)})")

            begin
              yield
            ensure
              conn.execute("SELECT pg_advisory_unlock(#{key.fetch(:signed)})")
            end
          end
        end

        private
          def tenant_name_message(tenant_name)
            "Tenant name may contain only letters, digits, and the characters " \
              "'-', '_' and '~': #{tenant_name.inspect}"
          end

          def database_options
            encoding = db_config.configuration_hash[:encoding] || DEFAULT_ENCODING
            db_config.configuration_hash.merge(encoding: encoding)
          end

          def database_names(conn, like)
            conn.select_values(<<~SQL)
              SELECT datname FROM pg_database
              WHERE datname LIKE #{conn.quote(like)} ESCAPE '\\'
            SQL
          end

          def database_exist_on?(conn)
            conn.select_value("SELECT 1 FROM pg_database WHERE datname = #{conn.quote(database)}").present?
          end

          def ready_lock_held_on?(conn)
            key = ready_lock_key

            conn.select_value(<<~SQL).present?
              SELECT 1 FROM pg_locks
              WHERE locktype = 'advisory'
                AND granted
                AND classid::bigint = #{key.fetch(:classid)}
                AND objid::bigint = #{key.fetch(:objid)}
                AND objsubid = 1
            SQL
          end

          # An advisory lock is named by a number, so the name of the database is digested into
          # one. pg_advisory_lock takes it as a signed 64 bit number, and pg_locks holds it as two
          # unsigned 32 bit halves.
          def ready_lock_key
            key = Digest::SHA256.digest(database).unpack1("Q>")

            {
              signed: key >= 2**63 ? key - 2**64 : key,
              classid: key >> 32,
              objid: key & 0xffffffff,
            }
          end

          # The server is reached on the "postgres" database, with the search path that Rails uses
          # in its own PostgreSQL database task.
          def anonymous_db_config
            config_hash = db_config.configuration_hash.merge(
              database: ANONYMOUS_DATABASE,
              schema_search_path: "public",
            )

            ActiveRecord::DatabaseConfigurations::HashConfig.new(
              db_config.env_name, "#{db_config.name}_anonymous", config_hash
            )
          end
      end
    end
  end
end

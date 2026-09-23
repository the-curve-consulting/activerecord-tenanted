# frozen_string_literal: true

require "digest"

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  Gives each tenant a database of its own on a PostgreSQL server. The server, the user, and
      #  the other connection options come from the tenanted database configuration. The
      #  "%{tenant}" specifier in the "database" key builds the name of each tenant database.
      #
      class PostgreSQL
        attr_reader :db_config

        def initialize(db_config)
          @db_config = db_config
        end

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

        # Stands in for the tenant name while the LIKE pattern and the scanner of
        # #tenant_databases are built. It is long and specific, so that it cannot appear in the
        # rest of a database name, and it holds only letters, so that Regexp.escape leaves it
        # unchanged.
        TENANT_NAME_PLACEHOLDER = "activerecordtenantedtenantnameplaceholder"

        # The database that the anonymous connection uses. Every PostgreSQL server has it. It is
        # not a template database, so a connection to it never blocks CREATE DATABASE.
        ANONYMOUS_DATABASE = "postgres"

        # Rails uses this encoding when the configuration does not name one.
        DEFAULT_ENCODING = "utf8"

        def tenant_databases
          pattern = db_config.database_pattern_for(TENANT_NAME_PLACEHOLDER)
          scanner = tenant_name_scanner(pattern)

          with_anonymous_connection do |conn|
            database_names(conn, like_pattern(pattern)).filter_map do |name|
              result = scanner.match(name)&.captures&.first

              if result.nil?
                Rails.logger.warn "ActiveRecord::Tenanted: Cannot parse tenant name from database #{name.inspect}"
                next
              end

              unless valid_tenant_name?(result)
                Rails.logger.warn "ActiveRecord::Tenanted: Skipping database with an invalid tenant name #{result.inspect} in #{name.inspect}"
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
                  "'-', '_' and '~': #{tenant_name.inspect}"
          end
        end

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
            conn.create_database(db_config.database, database_options)
          end

          true
        rescue ActiveRecord::DatabaseAlreadyExists
          false
        end

        def drop_database
          with_anonymous_connection do |conn|
            # Rails writes DROP DATABASE IF EXISTS, so a database that is not there is not an
            # error. Rails also adds WITH (FORCE) on PostgreSQL 13 and later, which ends the
            # sessions of other processes. Without FORCE the server refuses to drop a database
            # that another connection pool still holds a connection to.
            conn.drop_database(db_config.database)
          end
        end

        def database_exist?
          with_anonymous_connection { |conn| database_exist_on?(conn) }
        end

        def database_ready?
          with_anonymous_connection do |conn|
            database_exist_on?(conn) && !ready_lock_held_on?(conn)
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

        def test_workerize(db, test_worker_id)
          test_worker_suffix = "_#{test_worker_id}"

          # The suffix is added only once, because Rails can pass a name that already carries it.
          # See the same check in the SQLite adapter.
          db.end_with?(test_worker_suffix) ? db : "#{db}#{test_worker_suffix}"
        end

        private
          def database_options
            encoding = db_config.configuration_hash[:encoding] || DEFAULT_ENCODING

            db_config.configuration_hash.merge(encoding: encoding)
          end

          def database_names(conn, like)
            # The backslash is the escape character of the LIKE pattern below.
            conn.select_values(<<~SQL)
              SELECT datname FROM pg_database
              WHERE datname LIKE #{conn.quote(like)} ESCAPE '\\'
            SQL
          end

          def database_exist_on?(conn)
            conn.select_value("SELECT 1 FROM pg_database WHERE datname = #{conn.quote(db_config.database)}").present?
          end

          # The ready lock is a session advisory lock. A session that holds such a lock cannot ask
          # for it again, and a function such as pg_try_advisory_lock would report the lock as
          # free to the session that holds it. The lock table is therefore read instead, from a
          # connection of its own, so that the answer holds for any session.
          #
          # pg_locks reports a 64 bit lock key as two unsigned halves, and it reports objsubid as
          # 1 for a lock that was taken with a single 64 bit key.
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

          # Builds the key of the ready lock from the digest of the database name, so that each
          # tenant database has a lock of its own. The lock functions take a signed 64 bit number,
          # and pg_locks reports the same key as two unsigned 32 bit halves.
          def ready_lock_key
            key = Digest::SHA256.digest(db_config.database).unpack1("Q>")

            {
              signed: key >= 2**63 ? key - 2**64 : key,
              classid: key >> 32,
              objid: key & 0xffffffff,
            }
          end

          # Builds the LIKE pattern that finds the tenant databases. The tenant name becomes "%",
          # and every LIKE metacharacter in the rest of the name is escaped, so that a name with a
          # metacharacter is matched literally. The underscore is a metacharacter, and it is very
          # common in a database name.
          def like_pattern(pattern)
            pattern
              .split(TENANT_NAME_PLACEHOLDER, -1)
              .map { |part| part.gsub(/[\\%_]/) { |char| "\\#{char}" } }
              .join("%")
          end

          # The scanner reads a tenant name back out of a database name. Everything but the tenant
          # name is escaped, so that a name with a regular expression metacharacter is matched
          # literally, and the scanner is anchored, so that it cannot match part of a longer name.
          def tenant_name_scanner(pattern)
            escaped = Regexp.escape(pattern)

            # A template may use the %{tenant} specifier more than once. The first use captures
            # the tenant name, and a later use must match the name that was captured.
            captured = false
            expression = escaped.gsub(TENANT_NAME_PLACEHOLDER) do
              if captured
                "\\1"
              else
                captured = true
                "(.+)"
              end
            end

            /\A#{expression}\z/
          end

          # Connects to a database that is always there, so that a tenant database can be created,
          # dropped, or asked about. The connection uses a connection handler of its own, so the
          # global connection pool of ActiveRecord::Base is never replaced, and a query that runs
          # at the same time in another thread keeps its own connection.
          #
          # The search path is set to "public", which is what the PostgreSQL database task of
          # Rails does for the same kind of connection.
          def with_anonymous_connection(&block)
            handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
            pool = handler.establish_connection(anonymous_db_config)

            pool.with_connection(&block)
          ensure
            handler&.clear_all_connections!(:all)
          end

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

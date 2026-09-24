# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  What the adapter for a MySQL server and the adapter for a PostgreSQL server share.
      #
      #  Each tenant has a database of its own on the server. The databases of the tenants sit
      #  beside every other database of the application, so a tenant is found by a pattern, and the
      #  pattern has to be built carefully: the name of a database is read back out of it, and the
      #  rest of the name is matched as it is written.
      #
      #  The server is reached on a connection that names no tenant database. That connection is
      #  made on a connection handler of its own, so that the global pool of ActiveRecord::Base is
      #  never replaced.
      #
      #  A subclass says what is different about its server:
      #
      #    TENANT_NAME_PATTERN     the characters that a tenant name may hold
      #    #tenant_name_message    what to say about a name that does not match
      #    #validate_database_name the limit on the length of a database name
      #    #create_database, #drop_database
      #    #acquire_ready_lock
      #    #database_exist_on?     whether the database is there, on a connection
      #    #ready_lock_held_on?    whether the ready lock is held, on a connection
      #    #database_names         the databases that match a LIKE pattern, on a connection
      #    #anonymous_db_config    how to reach the server without naming a tenant database
      #
      class Server
        # Stands in for the tenant name while the LIKE pattern and the scanner are built. It is
        # long and specific, so that it cannot appear in the rest of a database name, and it holds
        # only letters, so that neither Regexp.escape nor the LIKE escaping changes it.
        TENANT_NAME_PLACEHOLDER = "activerecordtenantedtenantnameplaceholder"

        attr_reader :db_config

        def initialize(db_config)
          @db_config = db_config
        end

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
            self.class::TENANT_NAME_PATTERN.match?(tenant_name)
        end

        def validate_tenant_name(tenant_name)
          raise BadTenantNameError, tenant_name_message(tenant_name) unless valid_tenant_name?(tenant_name)
        end

        def database_exist?
          with_anonymous_connection { |conn| database_exist_on?(conn) }
        end

        # The database is ready when it is there and nobody holds the ready lock. The lock belongs
        # to the session that took it, so the server is asked who holds it, on another connection.
        def database_ready?
          with_anonymous_connection do |conn|
            database_exist_on?(conn) && !ready_lock_held_on?(conn)
          end
        end

        def test_workerize(db, test_worker_id)
          test_worker_suffix = "_#{test_worker_id}"

          # Rails can pass a name that already carries the suffix, so it is added only once. See
          # the same check in the SQLite adapter.
          db.end_with?(test_worker_suffix) ? db : "#{db}#{test_worker_suffix}"
        end

        private
          def database
            db_config.database
          end

          # The LIKE pattern selects the tenant databases of the server. Only the parts around the
          # tenant name are escaped, so a name that holds "%" or "_" is matched as it is written.
          # "_" is one character in LIKE, and it is common in the name of a database, so a pattern
          # that did not escape it would return databases that are not tenants.
          def like_pattern(pattern)
            pattern
              .split(TENANT_NAME_PLACEHOLDER, -1)
              .map { |part| part.gsub(/[\\%_]/) { |char| "\\#{char}" } }
              .join("%")
          end

          # The scanner reads a tenant name back out of the name of a database. Everything but the
          # tenant name is escaped, so a name with a regular expression metacharacter is matched as
          # it is written, and the scanner is anchored, so it cannot match part of a longer name.
          def tenant_name_scanner(pattern)
            escaped = Regexp.escape(pattern)

            # A template may use the %{tenant} specifier more than once. The first use captures the
            # tenant name, and a later use must match the name that was captured.
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

          # Connects to the server without naming a tenant database, and yields the connection.
          #
          # ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection is not used, because it
          # replaces the global connection pool of ActiveRecord::Base for the length of the block,
          # and a query of another thread would then reach a configuration that names no database.
          # A connection handler of its own keeps this connection out of the global pool.
          def with_anonymous_connection(&block)
            handler = ActiveRecord::ConnectionAdapters::ConnectionHandler.new
            pool = handler.establish_connection(anonymous_db_config)

            pool.with_connection(&block)
          ensure
            handler&.clear_all_connections!(:all)
          end
      end
    end
  end
end

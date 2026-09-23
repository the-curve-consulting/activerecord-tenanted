# frozen_string_literal: true

module ActiveRecord
  module Tenanted
    module DatabaseAdapters # :nodoc:
      #
      #  TODO: This still feels to me like it's not _quite_ right. I think we could further refactor this by:
      #
      #  1. Moving tenant_databases and validate_tenant_name to BaseConfig, and subclassing it for
      #     each database
      #  2. Moving create_database, drop_database, database_exist?, database_ready?,
      #     acquire_ready_lock, ensure_database_directory_exists, and database_path to the SQLite
      #     connection adapter, possibly into Rails
      #  3. Moving test_workerize and path_for to be SQLite connection adapter class methods,
      #     possibly into Rails
      #
      class SQLite
        attr_reader :db_config

        def initialize(db_config)
          @db_config = db_config
        end

        # A tenant name is interpolated into the database path as a single path segment, and that
        # path may be a URI (see #path_for), so a name is limited to the RFC 3986 unreserved
        # characters and may not begin with a dot. A leading dot either traverses out of the tenant
        # directory or hides the database from the glob in #tenant_databases; "%" is percent-decoded
        # by SQLite when it opens a URI filename; "?" and "#" truncate the path; and other
        # punctuation is either reserved in a URI or makes URI.parse raise.
        TENANT_NAME_PATTERN = /\A[A-Za-z0-9_~-][A-Za-z0-9._~-]*\z/

        # A filesystem limits one component of a path to 255 bytes. The limit is on the database
        # path, so it covers the tenant name together with anything the database template and the
        # test worker suffix add to it.
        MAX_PATH_COMPONENT_BYTESIZE = 255

        # Stands in for the tenant name while the scanner in #tenant_databases is built. It is
        # long and specific, so that it cannot appear in the rest of a database path, and it holds
        # only letters, so that Regexp.escape leaves it unchanged.
        TENANT_NAME_PLACEHOLDER = "activerecordtenantedtenantnameplaceholder"

        def tenant_databases
          glob = path_for(db_config.database_pattern_for("*"))
          scanner = tenant_name_scanner

          Dir.glob(glob).filter_map do |path|
            result = scanner.match(path)&.captures&.first

            if result.nil?
              Rails.logger.warn "ActiveRecord::Tenanted: Cannot parse tenant name from filename #{path.inspect}"
              next
            end

            unless valid_tenant_name?(result)
              Rails.logger.warn "ActiveRecord::Tenanted: Skipping database with an invalid tenant name #{result.inspect} in #{path.inspect}"
              next
            end

            result
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
                  "Tenant name may not begin with a dot, and may contain only letters, digits, " \
                  "and the characters '-', '.', '_' and '~': #{tenant_name.inspect}"
          end
        end

        # Validates the database name that a tenant name is built into, and not the tenant name
        # alone, because the database template and the test worker suffix are part of the name
        # that the filesystem must accept.
        def validate_database_name(database)
          too_long = path_for(database).split("/").find do |component|
            component.bytesize > MAX_PATH_COMPONENT_BYTESIZE
          end

          if too_long
            raise BadTenantNameError,
                  "Tenant name makes the database path component " \
                  "#{too_long.truncate(32).inspect} longer than " \
                  "#{MAX_PATH_COMPONENT_BYTESIZE} bytes"
          end
        end

        # Creates the database when it does not exist yet. The caller does not check first, so this
        # method is idempotent. It returns true only when it creates the database, so that the
        # caller can report the new database.
        def create_database
          ensure_database_directory_exists

          return false if database_exist?

          FileUtils.touch(database_path)
          true
        end

        def drop_database
          # Remove the SQLite database file and associated files
          FileUtils.rm_f(database_path)
          FileUtils.rm_f("#{database_path}-wal")  # Write-Ahead Logging file
          FileUtils.rm_f("#{database_path}-shm")  # Shared Memory file
        end

        def database_exist?
          File.exist?(database_path)
        end

        def database_ready?
          File.exist?(database_path) && !ActiveRecord::Tenanted::Mutex::Ready.locked?(database_path)
        end

        def acquire_ready_lock(&block)
          ActiveRecord::Tenanted::Mutex::Ready.lock(database_path, &block)
        end

        def database_path
          path_for(db_config.database)
        end

        def test_workerize(db, test_worker_id)
          test_worker_suffix = "_#{test_worker_id}"

          # The suffix goes before the query params of a URI.
          path, query = db.start_with?("file:") ? db.split("?", 2) : [ db, nil ]

          # This check is needed because of https://github.com/rails/rails/pull/55769 adding
          # replicas to the parallelization setup by using `include_hidden: true` which pulls in
          # the BaseConfig. We don't want to double-suffix the database name.
          #
          # TODO: Ideally we should have finer-grained filtering of database configurations in Rails
          # (other than simply hidden or not-hidden).
          path += test_worker_suffix unless path.end_with?(test_worker_suffix)

          query ? "#{path}?#{query}" : path
        end

        # A sqlite database path can be a file path or a URI (either relative or absolute).  We
        # can't parse it as a standard URI in all circumstances, though, see
        # https://sqlite.org/uri.html
        def path_for(database)
          if database.start_with?("file:/")
            URI.parse(database).path
          elsif database.start_with?("file:")
            URI.parse(database.sub(/\?.*$/, "")).opaque
          else
            database
          end
        end

        private
          # The scanner reads a tenant name back out of a database path. Everything but the tenant
          # name is escaped, so that a path with a regular expression metacharacter is matched
          # literally, and the scanner is anchored, so that it cannot match part of a longer path.
          def tenant_name_scanner
            path = Regexp.escape(path_for(db_config.database_pattern_for(TENANT_NAME_PLACEHOLDER)))

            # A template may use the %{tenant} specifier more than once. The first use captures
            # the tenant name, and a later use must match the name that was captured.
            captured = false
            pattern = path.gsub(TENANT_NAME_PLACEHOLDER) do
              if captured
                "\\1"
              else
                captured = true
                "(.+)"
              end
            end

            /\A#{pattern}\z/
          end

          # Rails does not make the directory of a SQLite database itself until
          # rails/rails@f1f60dc1 is in a released version, so #create_database makes it here.
          def ensure_database_directory_exists
            return unless database_path

            database_dir = File.dirname(database_path)
            unless File.directory?(database_dir)
              FileUtils.mkdir_p(database_dir)
            end
          end
      end
    end
  end
end

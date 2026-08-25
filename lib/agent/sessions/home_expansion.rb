# frozen_string_literal: true

module Agent
  module Sessions
        # Shared path expansion for Adapters::Base and Audit. Expands "~" against the
        # injected env so callers can resolve paths for a machine that is not their
        # own; joins relative paths (including "~user"-looking strings that are not a
        # real shell lookup here) under that same home; and treats an explicitly empty
        # HOME the same as an absent one.
        module HomeExpansion
          private

          def expand(path)
            case path
            when %r{\A~(/|\z)} then File.expand_path(path.sub(%r{\A~}) { home })
            when /\A~/ then File.expand_path(path, home)
            else File.absolute_path?(path) ? File.expand_path(path) : File.expand_path(path, home)
            end
          end

          def home
            value = @env["HOME"]
            value && !value.strip.empty? ? value : Dir.home
          end
        end
  end
end

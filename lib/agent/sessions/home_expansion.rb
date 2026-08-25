# frozen_string_literal: true

module Agent
  module Sessions
        # Shared ~-expansion for Adapters::Base and Audit. Expands a bare ~ or ~/...
        # against the injected env so callers can resolve paths for a machine that is
        # not their own; leaves ~user literal, since that has no answer in an injected
        # environment; and treats an explicitly empty HOME the same as an absent one.
        module HomeExpansion
          private

          def expand(path)
            case path
            when %r{\A~(/|\z)} then File.expand_path(path.sub(%r{\A~}) { home })
            when /\A~/ then path
            else File.expand_path(path)
            end
          end

          def home
            value = @env["HOME"]
            value && !value.empty? ? value : Dir.home
          end
        end
  end
end

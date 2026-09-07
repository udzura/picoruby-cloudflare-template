# frozen_string_literal: true

require_relative "template/version"

module Picoruby
  module Cloudflare
    module Template
      class Error < StandardError; end

      # The upstream mrbgem linker still interpolates build paths into a shell
      # command. Reject whitespace and shell metacharacters before invoking it.
      def self.validate_build_path!(path)
        unless path.match?(%r{\A[A-Za-z0-9_./+\-]+\z})
          raise Error, "Build paths must use ASCII letters, digits, /, _, ., + or - (upstream shell limitation): #{path}"
        end
        path
      end
    end
  end
end

require "vagrant/util/platform"

module Vagrant
  module Util
    class Which
      # Cross-platform way of finding an executable in the PATH.
      #
      #   which('ruby') #=> /usr/bin/ruby
      #
      # This code is adapted from the following post by mislav:
      #   http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
      #
      # @param [String] cmd The command to search for in the PATH.
      # @param [Hash] opts Optional flags
      #   @option [Boolean] :original_path Search within original path if available
      # @return [String] The full path to the executable or `nil` if not found.
      def self.which(cmd, **opts)
        exts = nil

        if !Platform.windows? || ENV['PATHEXT'].nil?
          # If the PATHEXT variable is empty, we're on *nix and need to find
          # the exact filename
          exts = ['']
        elsif File.extname(cmd).length != 0
          # On Windows: if filename contains an extension, we must match that
          # exact filename
          exts = ['']
        else
          # On Windows: otherwise try to match all possible executable file
          # extensions (.EXE .COM .BAT etc.)
          exts = ENV['PATHEXT'].split(';')
        end

        if opts[:original_path]
          search_path = ENV.fetch('VAGRANT_OLD_ENV_PATH', ENV['PATH'])
        else
          search_path = ENV['PATH']
        end

        if !search_path.nil?
          SilenceWarnings.silence! do
            search_path.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '').split(File::PATH_SEPARATOR).each do |path|
              exts.each do |ext|
                exe = "#{path}#{File::SEPARATOR}#{cmd}#{ext}"
                return exe if File.executable? exe
              end
            end
          end
        end

        return nil
      end
    end
  end
end

module VagrantPlugins
  module GuestCygwin
    module Cap
      class ShellExpandGuestPath
        def self.shell_expand_guest_path(machine, path)
          real_path = nil
          path = path.gsub(/ /, '\ ')
          machine.communicate.execute("echo; printf #{path}") do |type, data|
            if type == :stdout
              real_path ||= ""
              real_path += data
            end
          end

          if real_path
            # The last line is the path we care about
            real_path = real_path.split("\n").last.chomp
          end

          if !real_path
            # If no real guest path was detected, this is really strange
            # and we raise an exception because this is a bug.
            raise Vagrant::Errors::ShellExpandFailed
          end

          # Chomp the string so that any trailing newlines are killed
          return real_path.chomp
        end
      end
    end
  end
end

module VagrantPlugins
  module HostWindows
    module Cap
      class SSH
        # Set the ownership and permissions for SSH
        # private key
        #
        # @param [Vagrant::Environment] env
        # @param [Pathname] key_path
        def self.set_ssh_key_permissions(env, key_path)
          script_path = Host.scripts_path.join("set_ssh_key_permissions.ps1")
          result = Vagrant::Util::PowerShell.execute(
            script_path.to_s, "-KeyPath", key_path.to_s.gsub(' ', '` '),
            module_path: Host.modules_path.to_s
          )
          if result.exit_code != 0
            raise Vagrant::Errors::PowerShellError,
              script: script_path,
              stderr: result.stderr
          end
          result
        end
      end
    end
  end
end

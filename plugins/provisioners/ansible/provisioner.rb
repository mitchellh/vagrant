module VagrantPlugins
  module Ansible
    class Provisioner < Vagrant.plugin("2", :provisioner)
      def provision
        ssh = @machine.ssh_info
        inventory_file_path = self.setup_inventory_file
        options = %W[--private-key=#{ssh[:private_key_path]} --user=#{ssh[:username]}]
        options << "--extra-vars=" + config.extra_vars.map{|k,v| "#{k}=#{v}"}.join(' ') if config.extra_vars
        options << "--inventory-file=#{inventory_file_path}"
        options << "--ask-sudo-pass" if config.ask_sudo_pass

        if config.limit
          if not config.limit.kind_of?(Array)
            config.limit = [config.limit]
          end
          config.limit = config.limit.join(",")
          options << "--limit=#{config.limit}"
        end

        options << "--sudo" if config.sudo
        options << "--sudo-user=#{config.sudo_user}" if config.sudo_user
        options << "--verbose" if config.verbose

        # Assemble the full ansible-playbook command
        command = (%w(ansible-playbook) << options << config.playbook).flatten

        # Write stdout and stderr data, since it's the regular Ansible output
        command << {
          :env => { "ANSIBLE_FORCE_COLOR" => "true" },
          :notify => [:stdout, :stderr]
        }

        begin
          exit_status = Vagrant::Util::Subprocess.execute(*command) do |type, data|
            if type == :stdout || type == :stderr
              @machine.env.ui.info(data, :new_line => false, :prefix => false)
            end
          end

          raise Vagrant::Errors::AnsibleFailed if exit_status != 0
        rescue Vagrant::Util::Subprocess::LaunchError
          raise Vagrant::Errors::AnsiblePlaybookAppNotFound
        end
      end
      
      def setup_inventory_file()
        if config.inventory_file
          return config.inventory_file
        end
        ssh = @machine.ssh_info
        generated_inventory_file = "vagrant_ansible_inventory_#{machine.name}"
        File.open(generated_inventory_file, 'w') do |file|
          file.write("# Generated by Vagrant\n\n")
          file.write("#{machine.name} ansible_ssh_host=#{ssh[:host]} ansible_ssh_port=#{ssh[:port]}\n")
        end
        return generated_inventory_file
      end
    end
  end
end

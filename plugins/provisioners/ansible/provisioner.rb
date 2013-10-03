module VagrantPlugins
  module Ansible
    class Provisioner < Vagrant.plugin("2", :provisioner)
      def provision
        ssh = @machine.ssh_info

        # Connect with Vagrant user (unless --user or --private-key are overidden by 'raw_arguments')
        options = %W[--private-key=#{ssh[:private_key_path]} --user=#{ssh[:username]}]

        # Joker! Not (yet) supported arguments can be passed this way.
        options << "#{config.raw_arguments}" if config.raw_arguments

        # Append Provisioner options (highest precedence):
        if config.extra_vars
          extra_vars = config.extra_vars.map do |k,v|
            v = v.gsub('"', '\\"')
            if v.include?(' ')
              v = v.gsub("'", "\\'")
              v = "'#{v}'"
            end

            "#{k}=#{v}"
          end
          options << "--extra-vars=\"#{extra_vars.join(" ")}\""
        end

        options << "--inventory-file=#{self.setup_inventory_file}"
        options << "--sudo" if config.sudo
        options << "--sudo-user=#{config.sudo_user}" if config.sudo_user
        options << "#{self.get_verbosity_argument}" if config.verbose
        options << "--ask-sudo-pass" if config.ask_sudo_pass
        options << "--tags=#{as_list_argument(config.tags)}" if config.tags
        options << "--skip-tags=#{as_list_argument(config.skip_tags)}" if config.skip_tags
        options << "--limit=#{as_list_argument(config.limit)}" if config.limit
        options << "--start-at-task=#{config.start_at_task}" if config.start_at_task

        # Assemble the full ansible-playbook command
        command = (%w(ansible-playbook) << options << config.playbook).flatten

        # Write stdout and stderr data, since it's the regular Ansible output
        command << {
          :env => {
            "ANSIBLE_FORCE_COLOR" => "true",
            "ANSIBLE_HOST_KEY_CHECKING" => "#{config.host_key_checking}",
            # Ensure Ansible output isn't buffered so that we receive ouput
            # on a task-by-task basis.
            "PYTHONUNBUFFERED" => 1
          },
          :notify => [:stdout, :stderr],
          :workdir => @machine.env.root_path.to_s
        }

        begin
          result = Vagrant::Util::Subprocess.execute(*command) do |type, data|
            if type == :stdout || type == :stderr
              @machine.env.ui.info(data, :new_line => false, :prefix => false)
            end
          end

          raise Vagrant::Errors::AnsibleFailed if result.exit_code != 0
        rescue Vagrant::Util::Subprocess::LaunchError
          raise Vagrant::Errors::AnsiblePlaybookAppNotFound
        end
      end

      protected

      # Auto-generate "safe" inventory file based on Vagrantfile,
      # unless inventory_path is explicitly provided
      def setup_inventory_file
        return config.inventory_path if config.inventory_path

        ssh = @machine.ssh_info

        generated_inventory_file =
          @machine.env.root_path.join("vagrant_ansible_inventory_#{machine.name}")

        generated_inventory_file.open('w') do |file|
          file.write("# Generated by Vagrant\n\n")
          file.write("#{machine.name} ansible_ssh_host=#{ssh[:host]} ansible_ssh_port=#{ssh[:port]}\n")
        end

        return generated_inventory_file.to_s
      end

      def get_verbosity_argument
        if config.verbose.to_s =~ /^v+$/
          # Hopefully ansible-playbook accepts "silly" arguments like '-vvvvv', as '-vvv'
          return "-#{config.verbose}"
        elsif config.verbose.to_s == 'extra'
          return '-vvv'
        else
          # fall back to default verbosity (which is no verbosity)
          return ''
        end
      end

      def as_list_argument(v)
        v.kind_of?(Array) ? v.join(',') : v
      end
    end
  end
end

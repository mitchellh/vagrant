require "tempfile"

require_relative "../../../../lib/vagrant/util/template_renderer"

module VagrantPlugins
  module GuestCoreOS
    module Cap
      class ConfigureNetworks
        include Vagrant::Util

        def self.configure_networks(machine, networks)
          machine.communicate.tap do |comm|
            # Read network interface names
            interfaces = []
            comm.sudo("ifconfig | grep '(e[n,t][h,s,p][[:digit:]]([a-z][[:digit:]])?' | cut -f1 -d:") do |_, result|
              interfaces = result.split("\n")
            end

            primary_machine_config = machine.env.active_machines.first
            primary_machine = machine.env.machine(*primary_machine_config, true)

            primary_machine_ip = get_ip(primary_machine)
            current_ip = get_ip(machine)
            if current_ip == primary_machine_ip
              entry = TemplateRenderer.render("guests/coreos/etcd2.service", options: {
                my_ip: current_ip,
              })
            else
              connection_string = "#{primary_machine_ip}:7001"
              entry = TemplateRenderer.render("guests/coreos/etcd2.service", options: {
                connection_string: connection_string,
                my_ip: current_ip,
              })
            end

            Tempfile.open("vagrant-coreos-configure-networks") do |f|
              f.binmode
              f.write(entry)
              f.fsync
              f.close
              comm.upload(f.path, "/tmp/etcd2-cluster.service")
            end

            # Build a list of commands
            commands = []

            # Stop default systemd
            commands << "systemctl stop etcd2"

            # Configure interfaces
            # FIXME: fix matching of interfaces with IP addresses
            networks.each do |network|
              iface = interfaces[network[:interface].to_i]
              commands << "ifconfig #{iface} #{network[:ip]} netmask #{network[:netmask]}".squeeze(" ")
            end

            commands << <<-EOH.gsub(/^ {14}/, '')
              mv /tmp/etcd2-cluster.service /media/state/units/
              systemctl restart local-enable.service

              # Restart default etcd2
              systemctl start etcd2
            EOH

            # Run all network configuration commands in one communicator session.
            comm.sudo(commands.join("\n"))
          end
        end

        private

        def self.get_ip(machine)
          ip = nil
          machine.config.vm.networks.each do |type, opts|
            if type == :private_network && opts[:ip]
              ip = opts[:ip]
              break
            end
          end

          ip
        end
      end
    end
  end
end

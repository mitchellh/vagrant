require "set"
require "tempfile"

require_relative "../../../../lib/vagrant/util/template_renderer"

module VagrantPlugins
  module GuestDebian
    module Cap
      class ConfigureNetworks
        include Vagrant::Util

        def self.configure_networks(machine, networks)
          machine.communicate.tap do |comm|
            # First, remove any previous network modifications
            # from the interface file.
            comm.sudo("sed -e '/^#VAGRANT-BEGIN/,$ d' /etc/network/interfaces > /tmp/vagrant-network-interfaces.pre")
            comm.sudo("sed -ne '/^#VAGRANT-END/,$ p' /etc/network/interfaces | tac | sed -e '/^#VAGRANT-END/,$ d' | tac > /tmp/vagrant-network-interfaces.post")

            kernel_ifnames = []
            comm.sudo("/usr/bin/find /sys/class/net -type l -print | sort") do |type, data|
              if type == :stdout then
                data.split("\n").each do |line|
                  if (line =~ /^\/sys\/class\/net\/(enp[0-9]+s[0-9]+|eth[0-9]+)$/) then
                    kernel_ifnames << $1
                  end
                end
              end
            end

            # Accumulate the configurations to add to the interfaces file as
            # well as what interfaces we're actually configuring since we use that
            # later.
            interfaces = Set.new
            entries = []
            networks.each do |network|
              interfaces.add(network[:interface])
              entry = TemplateRenderer.render("guests/debian/network_#{network[:type]}",
                                              options: network, kernel_ifnames: kernel_ifnames)

              entries << entry
            end

            # Perform the careful dance necessary to reconfigure the network
            # interfaces.
            Tempfile.open("vagrant-debian-configure-networks") do |f|
              f.binmode
              f.write(entries.join("\n"))
              f.fsync
              f.close
              comm.upload(f.path, "/tmp/vagrant-network-entry")
            end

            # Bring down all the interfaces we're reconfiguring. By bringing down
            # each specifically, we avoid reconfiguring eth0 (the NAT interface) so
            # SSH never dies.
            interfaces.each do |interface|
              # Ubuntu 16.04+ returns an error when downing an interface that
              # does not exist. The `|| true` preserves the behavior that older
              # Ubuntu versions exhibit and Vagrant expects (GH-7155)
              comm.sudo("/sbin/ifdown #{kernel_ifnames[interface]} 2> /dev/null || true")
              comm.sudo("/sbin/ip addr flush dev #{kernel_ifnames[interface]} 2> /dev/null")
            end

            comm.sudo('cat /tmp/vagrant-network-interfaces.pre /tmp/vagrant-network-entry /tmp/vagrant-network-interfaces.post > /etc/network/interfaces')
            comm.sudo('rm -f /tmp/vagrant-network-interfaces.pre /tmp/vagrant-network-entry /tmp/vagrant-network-interfaces.post')

            # Bring back up each network interface, reconfigured
            interfaces.each do |interface|
              comm.sudo("/sbin/ifup #{kernel_ifnames[interface]}")
            end
          end
        end
      end
    end
  end
end

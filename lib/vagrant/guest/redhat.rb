module Vagrant
  module Guest
    class Redhat < Linux
      def prepare_host_only_network(net_options)
        # Remove any previous host only network additions to the
        # interface file.
        vm.ssh.execute do |ssh|
          # Clear out any previous entries
          ssh.exec!("sudo touch #{network_scripts_dir}/ifcfg-eth#{net_options[:adapter]}")
          ssh.exec!("sudo sed -e '/^#VAGRANT-BEGIN-HOSTONLY/,/^#VAGRANT-END-HOSTONLY/ d' #{network_scripts_dir}/ifcfg-eth#{net_options[:adapter]} > /tmp/vagrant-ifcfg-eth#{net_options[:adapter]}")
          ssh.exec!("sudo su -c 'cat /tmp/vagrant-ifcfg-eth#{net_options[:adapter]} > #{network_scripts_dir}/ifcfg-eth#{net_options[:adapter]}'")
        end
      end

      def enable_host_only_network(net_options)
        entry = TemplateRenderer.render('guests/redhat/network_hostonly',
                                        :net_options => net_options)
        vm.ssh.upload!(StringIO.new(entry), "/tmp/vagrant-network-entry")

        vm.ssh.execute do |ssh|
          interface_up = ssh.test?("/sbin/ifconfig eth#{net_options[:adapter]} | grep 'inet addr:'")
          ssh.exec!("sudo /sbin/ifdown eth#{net_options[:adapter]} 2> /dev/null") if interface_up
          ssh.exec!("sudo su -c 'cat /tmp/vagrant-network-entry >> #{network_scripts_dir}/ifcfg-eth#{net_options[:adapter]}'")
          ssh.exec!("sudo /sbin/ifup eth#{net_options[:adapter]}")
        end
      end

      def prepare_bridged_networks(networks)
        # Remove any previous bridged network additions from the
        # interface file.
        vm.ssh.execute do |ssh|
          networks.each do |network|
            # Clear out any previous entries
            ssh.exec!("sudo touch #{network_scripts_dir}/ifcfg-eth#{network[:adapter]}")
            ssh.exec!("sudo sed -e '/^#VAGRANT-BEGIN-BRIDGED/,/^#VAGRANT-END-BRIDGED/ d' #{network_scripts_dir}/ifcfg-eth#{network[:adapter]} > /tmp/vagrant-ifcfg-eth#{network[:adapter]}")
            ssh.exec!("sudo su -c 'cat /tmp/vagrant-ifcfg-eth#{network[:adapter]} > #{network_scripts_dir}/ifcfg-eth#{network[:adapter]}'")
          end
        end
      end

      def enable_bridged_networks(networks)
        entry = TemplateRenderer.render('guests/redhat/network_bridged',
                                        :networks => networks)

        vm.ssh.upload!(StringIO.new(entry), "/tmp/vagrant-network-entry")

        vm.ssh.execute do |ssh|
          networks.each do |network|
            interface_up = ssh.test?("/sbin/ifconfig eth#{network[:adapter]} | grep 'inet addr:'")
            ssh.exec!("sudo /sbin/ifdown eth#{network[:adapter]} 2> /dev/null") if interface_up
            ssh.exec!("sudo su -c 'cat /tmp/vagrant-network-entry >> #{network_scripts_dir}/ifcfg-eth#{network[:adapter]}'")
            ssh.exec!("sudo /sbin/ifup eth#{network[:adapter]}")
          end
        end
      end

      def prepare_bridged_networks(networks)
        # Remove any previous bridged network additions from the
        # interface file.
        vm.ssh.execute do |ssh|
          networks.each do |network|
            # Clear out any previous entries
            ssh.exec!("sudo touch #{network_scripts_dir}/ifcfg-eth#{network[:adapter]}")
            ssh.exec!("sudo sed -e '/^#VAGRANT-BEGIN-BRIDGED/,/^#VAGRANT-END-BRIDGED/ d' #{network_scripts_dir}/ifcfg-eth#{network[:adapter]} > /tmp/vagrant-ifcfg-eth#{network[:adapter]}")
            ssh.exec!("sudo su -c 'cat /tmp/vagrant-ifcfg-eth#{network[:adapter]} > #{network_scripts_dir}/ifcfg-eth#{network[:adapter]}'")
          end
        end
      end

      def enable_bridged_networks(networks)
        entry = TemplateRenderer.render('guests/redhat/network_bridged',
                                        :networks => networks)

        vm.ssh.upload!(StringIO.new(entry), "/tmp/vagrant-network-entry")

        vm.ssh.execute do |ssh|
          networks.each do |network|
            interface_up = ssh.test?("/sbin/ifconfig eth#{network[:adapter]} | grep 'inet addr:'")
            ssh.exec!("sudo /sbin/ifdown eth#{network[:adapter]} 2> /dev/null") if interface_up
            ssh.exec!("sudo su -c 'cat /tmp/vagrant-network-entry >> #{network_scripts_dir}/ifcfg-eth#{network[:adapter]}'")
            ssh.exec!("sudo /sbin/ifup eth#{network[:adapter]}")
          end
        end
      end

      # The path to the directory with the network configuration scripts.
      # This is pulled out into its own directory since there are other
      # operationg systems (SuSE) which behave similarly but with a different
      # path to the network scripts.
      def network_scripts_dir
        '/etc/sysconfig/network-scripts/'
      end

      def change_host_name(name)
        vm.ssh.execute do |ssh|
          # Only do this if the hostname is not already set
          if !ssh.test?("sudo hostname | grep '#{name}'")
            ssh.exec!("sudo sed -i 's/\\(HOSTNAME=\\).*/\\1#{name}/' /etc/sysconfig/network")
            ssh.exec!("sudo hostname #{name}")
            ssh.exec!("sudo sed -i 's@^\\(127[.]0[.]0[.]1[[:space:]]\\+\\)@\\1#{name} #{name.split('.')[0]} @' /etc/hosts")
          end
        end
      end
    end
  end
end

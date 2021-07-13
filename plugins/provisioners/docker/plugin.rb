require "vagrant"

module VagrantPlugins
  module DockerProvisioner
    class Plugin < Vagrant.plugin("2")
      name "docker"
      description <<-DESC
      Provides support for provisioning your virtual machines with
      Docker images and containers.
      DESC

      config(:docker, :provisioner) do
        require_relative "config"
        Config
      end

      guest_capability("debian", "docker_install") do
        require_relative "cap/debian/docker_install"
        Cap::Debian::DockerInstall
      end

      guest_capability("debian", "docker_start_service") do
        require_relative "cap/debian/docker_start_service"
        Cap::Debian::DockerStartService
      end

      guest_capability("fedora", "docker_install") do
        require_relative "cap/fedora/docker_install"
        Cap::Fedora::DockerInstall
      end

      guest_capability("centos", "docker_install") do
        require_relative "cap/centos/docker_install"
        Cap::Centos::DockerInstall
      end

      guest_capability("centos", "docker_start_service") do
        require_relative "cap/centos/docker_start_service"
        Cap::Centos::DockerStartService
      end

      guest_capability("oraclelinux", "docker_install") do
        require_relative "cap/oraclelinux/docker_install"
        Cap::OracleLinux::DockerInstall
      end

      guest_capability("oraclelinux", "docker_start_service") do
        require_relative "cap/oraclelinux/docker_start_service"
        Cap::OracleLinux::DockerStartService
      end

      guest_capability("linux", "docker_installed") do
        require_relative "cap/linux/docker_installed"
        Cap::Linux::DockerInstalled
      end

      guest_capability("linux", "docker_configure_vagrant_user") do
        require_relative "cap/linux/docker_configure_vagrant_user"
        Cap::Linux::DockerConfigureVagrantUser
      end

      guest_capability("linux", "docker_daemon_running") do
        require_relative "cap/linux/docker_daemon_running"
        Cap::Linux::DockerDaemonRunning
      end

      guest_capability("windows", "docker_daemon_running") do
        require_relative "cap/windows/docker_daemon_running"
        Cap::Windows::DockerDaemonRunning
      end

      provisioner(:docker) do
        require_relative "provisioner"
        Provisioner
      end
    end
  end
end

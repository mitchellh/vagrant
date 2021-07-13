require "vagrant"

module VagrantPlugins
  module PodmanProvisioner
    class Plugin < Vagrant.plugin("2")
      name "podman"
      description <<-DESC
      Provides support for provisioning your virtual machines with
      OCI images and containers using Podman.
      DESC

      config(:podman, :provisioner) do
        require_relative "config"
        Config
      end

      guest_capability("redhat", "podman_install") do
        require_relative "cap/redhat/podman_install"
        Cap::Redhat::PodmanInstall
      end

      guest_capability("centos", "podman_install") do
        require_relative "cap/centos/podman_install"
        Cap::Centos::PodmanInstall
      end

      guest_capability("oraclelinux", "podman_install") do
        require_relative "cap/oraclelinux/podman_install"
        Cap::OracleLinux::PodmanInstall
      end

      guest_capability("linux", "podman_installed") do
        require_relative "cap/linux/podman_installed"
        Cap::Linux::PodmanInstalled
      end

      provisioner(:podman) do
        require_relative "provisioner"
        Provisioner
      end
    end
  end
end

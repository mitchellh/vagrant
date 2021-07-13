require "vagrant"

module VagrantPlugins
  module SyncedFolderNFS
    # This plugin implements NFS synced folders. In order to take advantage
    # of NFS synced folders, some provider-specific assistance is required.
    # Within the middleware sequences, some data must be put into the
    # environment state bag:
    #
    #   * `nfs_host_ip` (string) - The IP of the host machine that the NFS
    #     client in the machine should talk to.
    #   * `nfs_machine_ip` (string) - The IP of the guest machine that the NFS
    #     server should serve the folders to.
    #   * `nfs_valid_ids` (array of strings) - A list of IDs that are "valid"
    #     and should not be pruned. The synced folder implementation will
    #     regularly prune NFS exports of invalid IDs.
    #
    # If any of these variables are not set, an internal exception will be
    # raised.
    #
    class Plugin < Vagrant.plugin("2")
      name "NFS synced folders"
      description <<-EOF
      The NFS synced folders plugin enables you to use NFS as a synced folder
      implementation.
      EOF

      config("nfs") do
        require_relative "config"
        Config
      end

      synced_folder("nfs", 5) do
        require_relative "synced_folder"
        SyncedFolder
      end

      synced_folder_capability("nfs", "mount_options") do
        require_relative "cap/mount_options"
        Cap::MountOptions
      end

      synced_folder_capability("nfs", "mount_type") do
        require_relative "cap/mount_options"
        Cap::MountOptions
      end

      synced_folder_capability("nfs", "mount_name") do
        require_relative "cap/mount_options"
        Cap::MountOptions
      end

      action_hook("nfs_cleanup") do |hook|
        require_relative "action_cleanup"
        hook.before(
          Vagrant::Action::Builtin::SyncedFolderCleanup,
          ActionCleanup)
      end
    end
  end
end

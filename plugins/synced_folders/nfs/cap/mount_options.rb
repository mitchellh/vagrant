require_relative "../../unix_mount_helpers"

module VagrantPlugins
  module SyncedFolderNFS
    module Cap
      module MountOptions
        extend VagrantPlugins::SyncedFolder::UnixMountHelpers

        MOUNT_TYPE = "nfs".freeze

        # Mounts options for NFS synced folder
        #
        # @param [Machine] machine
        # @param [String] name of mount
        # @param [String] path of mount on guest
        # @param [Hash] hash of mount options 
        def self.mount_options(machine, name, guest_path, options)
          original_mount_options = options.fetch(:mount_options, [])
          detected_ids = detect_owner_group_ids(machine, guest_path, original_mount_options, options)
          mount_uid = detected_ids[:uid]
          mount_gid = detected_ids[:gid]
          
          new_mount_options = []
          new_mount_options << "vers=#{options[:nfs_version]}" if options[:nfs_version]
          new_mount_options << "udp" if options[:nfs_udp]
         
          merged_mount_options = merge_mount_options(new_mount_options, original_mount_options)
          mount_options_string = merged_mount_options.join(",")
          return mount_options_string, mount_uid, mount_gid
        end

        def self.mount_type(machine)
           MOUNT_TYPE
        end

        # Mounts options for NFS synced folder
        #
        # @param [Machine] machine
        # @param [Hash] hash of mount options 
        def self.mount_name(machine, options)
          "#{options[:nfs_host_ip]}:#{options[:hostpath]}"
        end
      end
    end
  end
end

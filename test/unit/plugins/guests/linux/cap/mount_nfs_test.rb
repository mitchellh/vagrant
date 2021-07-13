require_relative "../../../../base"

describe "VagrantPlugins::GuestLinux::Cap::MountNFS" do
  let(:caps) do
    VagrantPlugins::GuestLinux::Plugin
      .components
      .guest_capabilities[:linux]
  end

  let(:machine) { double("machine") }
  let(:comm) { VagrantTests::DummyCommunicator::Communicator.new(machine) }
  let(:folder_plugin) { double("folder_plugin") }
  
  let(:mount_uid){ "1000" }
  let(:mount_gid){ "1000" }

  let(:ip) { "1.2.3.4" }
  let(:hostpath) { "/host" }
  let(:guestpath) { "/guest" }

  let(:folders) do
    {"/vagrant-nfs" =>
      Vagrant::Plugin::V2::SyncedFolder::Collection[
        { type: :nfs, guestpath: guestpath,
         hostpath: hostpath, plugin: folder_plugin}]
    }
  end

  before do
    allow(machine).to receive(:communicate).and_return(comm)

    allow(folder_plugin).to receive(:capability).with(:mount_options, any_args).
      and_return(["", mount_uid, mount_gid])
    allow(folder_plugin).to receive(:capability).with(:mount_type).and_return("nfs")
    allow(folder_plugin).to receive(:capability).with(:mount_name, any_args).and_return("#{ip}:#{hostpath}")
  end

  after do
    comm.verify_expectations!
  end

  describe ".mount_nfs_folder" do
    let(:cap) { caps.get(:mount_nfs_folder) }

    before do
      allow(machine).to receive(:guest).and_return(
        double("capability", capability: guestpath)
      )
    end

    it "mounts the folder" do
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[0]).to match(/mkdir -p #{guestpath}/)
      expect(comm.received_commands[1]).to match(/1.2.3.4:#{hostpath} #{guestpath}/)
    end

    it "emits an event" do
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[2]).to include(
        "/sbin/initctl emit --no-wait vagrant-mounted MOUNTPOINT=#{guestpath}")
    end

    it "escapes host and guest paths" do
      folders =
        {"/vagrant-nfs" =>
          Vagrant::Plugin::V2::SyncedFolder::Collection[
            { type: :nfs, guestpath: "/guest with spaces",
              hostpath: "/host's", plugin: folder_plugin}]
        }
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[1]).to match(/host\\\'s/)
      expect(comm.received_commands[1]).to match(/guest\\\ with\\\ spaces/)
    end
  end
end

require_relative "../../../../base"

require_relative "../../../../../../plugins/synced_folders/nfs/cap/mount_options"

describe VagrantPlugins::SyncedFolderNFS::Cap::MountOptions do
  include_context "unit"

  let(:caps) do
    VagrantPlugins::SyncedFolderNFS::Plugin
      .components
      .synced_folder_capabilities[:nfs]
  end
  let(:cap){ caps.get(:mount_options) }

  let(:machine) { double("machine") }
  let(:comm) { VagrantTests::DummyCommunicator::Communicator.new(machine) }
  let(:mount_owner){ "vagrant" }
  let(:mount_group){ "vagrant" }
  let(:mount_uid){ "1000" }
  let(:mount_gid){ "1000" }
  let(:mount_name){ "vagrant" }
  let(:mount_guest_path){ "/vagrant" }
  let(:folder_options) do
    {
      owner: mount_owner,
      group: mount_group,
      hostpath: "/host/directory/path"
    }
  end

  before do
    allow(machine).to receive(:communicate).and_return(comm)
    allow(machine).to receive_message_chain(:env, :host, :capability?).with(:smb_mount_options).and_return(false)
    stub_env("GEM_SKIP" => nil)
  end

  describe ".mount_options" do
    context "with valid existent owner group" do

      before do
        expect(comm).to receive(:execute).with("id -u #{mount_owner}", anything).and_yield(:stdout, mount_uid)
        expect(comm).to receive(:execute).with("getent group #{mount_group}", anything).and_yield(:stdout, "vagrant:x:#{mount_gid}:")
      end

      it "generates the expected default mount command" do
        out_opts, out_uid, out_gid = cap.mount_options(machine, mount_name, mount_guest_path, folder_options)
        expect(out_opts).to eq("")
        expect(out_uid).to eq(mount_uid)
        expect(out_gid).to eq(mount_gid)
      end
      
      it "includes provided mount options" do
        folder_options[:mount_options] =["ro"]
        out_opts, out_uid, out_gid = cap.mount_options(machine, mount_name, mount_guest_path, folder_options)
        expect(out_opts).to eq("ro")
        expect(out_uid).to eq(mount_uid)
        expect(out_gid).to eq(mount_gid)
      end

      context "with nfs options set" do
        let(:folder_options) { {
          owner: mount_owner, group: mount_group, hostpath: "/host/directory/path",
          nfs_version: 4, nfs_udp: true
        } }

        it "generates the expected default mount command" do
          out_opts, out_uid, out_gid = cap.mount_options(machine, mount_name, mount_guest_path, folder_options)
          expect(out_opts).to eq("vers=4,udp")
          expect(out_uid).to eq(mount_uid)
          expect(out_gid).to eq(mount_gid)
        end

        it "overwrites default mount options" do
          folder_options[:mount_options] =["ro", "vers=3"]
          out_opts, out_uid, out_gid = cap.mount_options(machine, mount_name, mount_guest_path, folder_options)
          expect(out_opts).to eq("vers=3,udp,ro")
          expect(out_uid).to eq(mount_uid)
          expect(out_gid).to eq(mount_gid)
        end
      end
    end


    context "with non-existent owner group" do
      it "raises an error" do
        expect(comm).to receive(:execute).with("id -u #{mount_owner}", anything).and_yield(:stdout, mount_uid)
        expect(comm).to receive(:execute).with("id -g #{mount_group}", anything).and_yield(:stdout, mount_gid)
        expect(comm).to receive(:execute).with("getent group #{mount_group}", anything).and_raise(Vagrant::Errors::VirtualBoxMountFailed, {command: '', output: ''})
        expect do
          cap.mount_options(machine, mount_name, mount_guest_path, folder_options)
        end.to raise_error Vagrant::Errors::VirtualBoxMountFailed
      end
    end
  end
end

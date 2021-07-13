require_relative "../../../../base"

describe "VagrantPlugins::GuestLinux::Cap::MountNFS" do
  let(:caps) do
    VagrantPlugins::GuestLinux::Plugin
      .components
      .guest_capabilities[:linux]
  end

  let(:machine) { double("machine") }
  let(:comm) { VagrantTests::DummyCommunicator::Communicator.new(machine) }

  before do
    allow(machine).to receive(:communicate).and_return(comm)
  end

  after do
    comm.verify_expectations!
  end

  describe ".mount_nfs_folder" do
    let(:cap) { caps.get(:mount_nfs_folder) }

    let(:ip) { "1.2.3.4" }

    let(:hostpath) { "/host" }
    let(:guestpath) { "/guest" }

    before do
      allow(machine).to receive(:guest).and_return(
        double("capability", capability: guestpath)
      )
    end

    context "with ipv6" do
      let(:ip) { "fd63:acd4:5c42:0530::1" }

      it "mounts the folder" do
        folders = {
          "/vagrant-nfs" => {
            type: :nfs,
            guestpath: "/guest",
            hostpath: "/host",
          }
        }
        cap.mount_nfs_folder(machine, ip, folders)

        expect(comm.received_commands[0]).to match(/mkdir -p #{guestpath}/)
        expect(comm.received_commands[1]).to match(/\[fd63:acd4:5c42:0530::1\]:#{hostpath} #{guestpath}/)
      end
    end

    it "mounts the folder" do
      folders = {
        "/vagrant-nfs" => {
          type: :nfs,
          guestpath: "/guest",
          hostpath: "/host",
        }
      }
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[0]).to match(/mkdir -p #{guestpath}/)
      expect(comm.received_commands[1]).to match(/1.2.3.4:#{hostpath} #{guestpath}/)
    end

    it "mounts with options" do
      folders = {
        "/vagrant-nfs" => {
          type: :nfs,
          guestpath: "/guest",
          hostpath: "/host",
          nfs_version: 2,
          nfs_udp: true,
        }
      }
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[1]).to match(/mount -o vers=2,udp/)
    end

    it "emits an event" do
      folders = {
        "/vagrant-nfs" => {
          type: :nfs,
          guestpath: "/guest",
          hostpath: "/host",
        }
      }
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[2]).to include(
        "/sbin/initctl emit --no-wait vagrant-mounted MOUNTPOINT=#{guestpath}")
    end

    it "escapes host and guest paths" do
      folders = {
        "/vagrant-nfs" => {
          guestpath: "/guest with spaces",
          hostpath: "/host's",
        }
      }
      cap.mount_nfs_folder(machine, ip, folders)

      expect(comm.received_commands[1]).to match(/host\\\'s/)
      expect(comm.received_commands[1]).to match(/guest\\\ with\\\ spaces/)
    end
  end
end

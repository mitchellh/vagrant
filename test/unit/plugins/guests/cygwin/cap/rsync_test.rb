require_relative "../../../../base"

describe "VagrantPlugins::GuestCygwin::Cap::Rsync" do
  let(:caps) do
    VagrantPlugins::GuestCygwin::Plugin
      .components
      .guest_capabilities[:cygwin]
  end

  let(:machine) { double("machine") }
  let(:comm) { VagrantTests::DummyCommunicator::Communicator.new(machine) }
  let(:guest_directory){ "/guest/directory/path" }

  before do
    allow(machine).to receive(:communicate).and_return(comm)
  end

  after do
    comm.verify_expectations!
  end

  describe ".rsync_installed" do
    let(:cap) { caps.get(:rsync_installed) }

    it "checks if the command is installed" do
      comm.expect_command("which rsync")
      cap.rsync_installed(machine)
    end
  end

  describe ".rsync_command" do
    let(:cap) { caps.get(:rsync_command) }

    it "provides the rsync command to use" do
      expect(cap.rsync_command(machine)).to eq("sudo rsync")
    end
  end

  describe ".rsync_pre" do
    let(:cap) { caps.get(:rsync_pre) }

    it "creates target directory on guest" do
      comm.expect_command("mkdir -p #{guest_directory}")
      cap.rsync_pre(machine, :guestpath => guest_directory)
    end
  end

  describe ".rsync_post" do
    let(:cap) { caps.get(:rsync_post) }
    let(:host_directory){ '.' }
    let(:owner) { "vagrant-user" }
    let(:group) { "vagrant-group" }
    let(:excludes) { false }
    let(:options) do
      {
        hostpath: host_directory,
        guestpath: guest_directory,
        owner: owner,
        group: group,
        exclude: excludes
      }
    end

    it "chowns files within the guest directory" do
      comm.expect_command(
        "find #{guest_directory} '!' -type l -a '(' ! -user #{owner} " \
          "')' -exec chown #{owner} '{}' +"
      )
      cap.rsync_post(machine, options)
    end

    context "with excludes provided" do
      let(:excludes){ ["tmp", "state/*", "path/with a/space"] }

      it "ignores files that are excluded" do
        # comm.expect_command(
        #   "find #{guest_directory} -path #{Shellwords.escape(File.join(guest_directory, excludes.first))} -prune -o " \
        #     "-path #{Shellwords.escape(File.join(guest_directory, excludes.last))} -prune -o '!' " \
        #     "-path -type l -a '(' ! -user " \
        #     "#{owner} -or ! -group #{group} ')' -exec chown #{owner}:#{group} '{}' +"
        # )
        cap.rsync_post(machine, options)
        excludes.each do |ex_path|
          expect(comm.received_commands.first).to include("-path #{Shellwords.escape(File.join(guest_directory, ex_path))} -prune")
        end
      end

      it "properly escapes excluded directories" do
        cap.rsync_post(machine, options)
        exclude_with_space = excludes.detect{|ex| ex.include?(' ')}
        escaped_exclude_with_space = Shellwords.escape(exclude_with_space)
        expect(comm.received_commands.first).not_to include(exclude_with_space)
        expect(comm.received_commands.first).to include(escaped_exclude_with_space)
      end
    end
  end
end

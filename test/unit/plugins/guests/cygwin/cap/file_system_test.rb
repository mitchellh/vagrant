require_relative "../../../../base"

describe "VagrantPlugins::GuestCygwin::Cap::FileSystem" do
  let(:caps) do
    VagrantPlugins::GuestCygwin::Plugin
      .components
      .guest_capabilities[:cygwin]
  end

  let(:machine) { double("machine", communicate: comm) }
  let(:comm) { double("comm") }

  before { allow(comm).to receive(:execute) }

  describe ".create_tmp_path" do
    let(:cap) { caps.get(:create_tmp_path) }
    let(:opts) { {} }

    it "should generate path on guest" do
      expect(comm).to receive(:execute).with(/mktemp/)
      cap.create_tmp_path(machine, opts)
    end

    it "should capture path generated on guest" do
      expect(comm).to receive(:execute).with(/mktemp/).and_yield(:stdout, "TMP_PATH")
      expect(cap.create_tmp_path(machine, opts)).to eq("TMP_PATH")
    end

    it "should strip newlines on path" do
      expect(comm).to receive(:execute).with(/mktemp/).and_yield(:stdout, "TMP_PATH\n")
      expect(cap.create_tmp_path(machine, opts)).to eq("TMP_PATH")
    end

    context "when type is a directory" do
      before { opts[:type] = :directory }

      it "should create guest path as a directory" do
        expect(comm).to receive(:execute).with(/-d/)
        cap.create_tmp_path(machine, opts)
      end
    end
  end

  describe ".decompress_tgz" do
    let(:cap) { caps.get(:decompress_tgz) }
    let(:comp) { "compressed_file" }
    let(:dest) { "path/to/destination" }
    let(:opts) { {} }

    before { allow(cap).to receive(:create_tmp_path).and_return("TMP_DIR") }
    after{ cap.decompress_tgz(machine, comp, dest, opts) }

    it "should create temporary directory for extraction" do
      expect(cap).to receive(:create_tmp_path)
    end

    it "should extract file with tar" do
      expect(comm).to receive(:execute).with(/tar/)
    end

    it "should extract file to temporary directory" do
      expect(comm).to receive(:execute).with(/TMP_DIR/)
    end

    it "should remove compressed file from guest" do
      expect(comm).to receive(:execute).with(/rm .*#{comp}/)
    end

    it "should remove extraction directory from guest" do
      expect(comm).to receive(:execute).with(/rm .*TMP_DIR/)
    end

    it "should create parent directories for destination" do
      expect(comm).to receive(:execute).with(/mkdir -p .*to'/)
    end

    context "when type is directory" do
      before { opts[:type] = :directory }

      it "should create destination directory" do
        expect(comm).to receive(:execute).with(/mkdir -p .*destination'/)
      end
    end
  end

  describe ".decompress_zip" do
    let(:cap) { caps.get(:decompress_zip) }
    let(:comp) { "compressed_file" }
    let(:dest) { "path/to/destination" }
    let(:opts) { {} }

    before { allow(cap).to receive(:create_tmp_path).and_return("TMP_DIR") }
    after{ cap.decompress_zip(machine, comp, dest, opts) }

    it "should create temporary directory for extraction" do
      expect(cap).to receive(:create_tmp_path)
    end

    it "should extract file with zip" do
      expect(comm).to receive(:execute).with(/zip/)
    end

    it "should extract file to temporary directory" do
      expect(comm).to receive(:execute).with(/TMP_DIR/)
    end

    it "should remove compressed file from guest" do
      expect(comm).to receive(:execute).with(/rm .*#{comp}/)
    end

    it "should remove extraction directory from guest" do
      expect(comm).to receive(:execute).with(/rm .*TMP_DIR/)
    end

    it "should create parent directories for destination" do
      expect(comm).to receive(:execute).with(/mkdir -p .*to'/)
    end

    context "when type is directory" do
      before { opts[:type] = :directory }

      it "should create destination directory" do
        expect(comm).to receive(:execute).with(/mkdir -p .*destination'/)
      end
    end
  end
end

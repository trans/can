require "./spec_helper"

private def run_can_render(args : Array(String)) : {Process::Status, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(
    "crystal", ["run", "--no-color", "src/can-render.cr", "--"] + args,
    env: {"CRYSTAL_CACHE_DIR" => "/tmp/crystal-cache"},
    output: output, error: error, chdir: PROJECT_ROOT
  )

  {status, output.to_s, error.to_s}
end

describe "can-render" do
  it "renders a view file with template-level uses and string assigns" do
    component = File.tempfile("can_render_component", ".can") do |f|
      f.print %(<.def tag="card" param:title="String"><section><h1>{title}</h1><.slot/></section></.def>)
    end
    page = File.tempfile("can_render_page", ".can") do |f|
      f.print %(<.use from="#{File.basename(component.path)}"/><card title={title}><p>Body</p></card>)
    end

    begin
      status, output, error = run_can_render(["-D", "title=Hello", page.path])

      status.success?.should be_true, error
      output.should eq("<section><h1>Hello</h1><p>Body</p></section>")
    ensure
      component.delete
      page.delete
    end
  end

  it "can write rendered output to a file" do
    page = File.tempfile("can_render_output_page", ".can") do |f|
      f.print %(<p>Saved</p>)
    end
    output_file = File.tempfile("can_render_output", ".html")

    begin
      status, output, error = run_can_render(["-o", output_file.path, page.path])

      status.success?.should be_true, error
      output.should eq("")
      File.read(output_file.path).should eq("<p>Saved</p>")
    ensure
      page.delete
      output_file.delete
    end
  end

  it "requires helper files that augment the generated page class" do
    helper = File.tempfile("can_render_helper", ".cr") do |f|
      f.print <<-CR
        class CanRenderPage
          def greeting : String
            "Hello from helper"
          end
        end
        CR
    end
    page = File.tempfile("can_render_helper_page", ".can") do |f|
      f.print %(<p>{greeting}</p>)
    end

    begin
      status, output, error = run_can_render(["--require", helper.path, page.path])

      status.success?.should be_true, error
      output.should eq("<p>Hello from helper</p>")
    ensure
      helper.delete
      page.delete
    end
  end
end

defmodule SymphonyElixir.TestSupport.Platform do
  @moduledoc "Windows fixtures use native executables and directory junctions without requiring elevation."

  def setup! do
    if windows?() do
      # Git Bash and Path.wildcard need slash-normalized paths, including in fixtures.
      System.put_env("TMPDIR", Path.expand(System.tmp_dir!()))
      bash = System.find_executable("bash") || raise "Git Bash is required for the Windows test suite"
      System.put_env("SYMPHONY_TEST_BASH", bash)
      root = Path.join(System.tmp_dir!(), "symphony-test-launcher-#{System.pid()}")
      File.mkdir_p!(root)
      exe = Path.join(root, "command.exe")
      source = Path.expand("../fixtures/fake_command.cs", __DIR__)

      {output, status} =
        System.cmd("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "Add-Type -Path $env:SYMPHONY_TEST_SOURCE -OutputAssembly $env:SYMPHONY_TEST_EXE -OutputType ConsoleApplication"],
          env: [{"SYMPHONY_TEST_SOURCE", source}, {"SYMPHONY_TEST_EXE", exe}],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("Cannot compile Windows fixture launcher: #{output}")
      :persistent_term.put({__MODULE__, :launcher}, exe)
      ExUnit.after_suite(fn _ -> File.rm_rf!(root) end)
    end
  end

  def path_separator, do: if(windows?(), do: ";", else: ":")

  def executable!(script) do
    File.chmod!(script, 0o755)
    if windows?(), do: File.cp!(:persistent_term.get({__MODULE__, :launcher}), script <> ".exe")
    :ok
  end

  def directory_link!(target, path) do
    if windows?() do
      {output, status} =
        System.cmd(
          "powershell.exe",
          ["-NoProfile", "-NonInteractive", "-Command", "New-Item -ItemType Junction -Path $env:SYMPHONY_TEST_LINK -Target $env:SYMPHONY_TEST_TARGET -ErrorAction Stop | Out-Null"],
          env: [{"SYMPHONY_TEST_LINK", path}, {"SYMPHONY_TEST_TARGET", target}],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("Cannot create directory-link fixture: #{output}")
      :ok
    else
      File.ln_s!(target, path)
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end

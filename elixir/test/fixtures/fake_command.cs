// Execute the adjacent extensionless shell fixture through Git Bash. A native
// executable is necessary because Windows Erlang ports cannot launch shebangs.
using System;
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Threading;

public static class FakeCommand
{
    private static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes);
            result.Append(c);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    public static int Main(string[] args)
    {
        string script = System.IO.Path.ChangeExtension(Assembly.GetExecutingAssembly().Location, null);
        var arguments = new StringBuilder(Quote(script.Replace('\\', '/')));
        foreach (string arg in args) arguments.Append(' ').Append(Quote(arg));
        var start = new ProcessStartInfo(Environment.GetEnvironmentVariable("SYMPHONY_TEST_BASH"), arguments.ToString());
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.EnvironmentVariables["MSYS2_ARG_CONV_EXCL"] = "*";
        using (var child = Process.Start(start))
        {
            var input = new Thread(() => {
                try {
                    var source = Console.OpenStandardInput();
                    var buffer = new byte[8192];
                    int count;
                    while ((count = source.Read(buffer, 0, buffer.Length)) > 0) {
                        child.StandardInput.BaseStream.Write(buffer, 0, count);
                        child.StandardInput.BaseStream.Flush();
                    }
                    child.StandardInput.Close();
                } catch (System.IO.IOException) { }
                  catch (ObjectDisposedException) { }
            });
            input.IsBackground = true;
            var output = new Thread(() => child.StandardOutput.BaseStream.CopyTo(Console.OpenStandardOutput()));
            var error = new Thread(() => child.StandardError.BaseStream.CopyTo(Console.OpenStandardError()));
            input.Start();
            output.Start();
            error.Start();
            child.WaitForExit();
            output.Join();
            error.Join();
            return child.ExitCode;
        }
    }
}

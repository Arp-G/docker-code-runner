# Needs gcc:4.9 and elixir:1.10.4 docker images (docker pull <image name>)

defmodule DockerApi do
  @base "http+unix://%2Fvar%2Frun%2Fdocker.sock/v1.12"
  @timeout 6000
  @request_timeout 120_000
  @exec_payload "{\"Detach\":false,\"Tty\":true}"
  @content_type_header [{"content-type", "application/json"}]
  @cmd %{
    "AttachStdin" => true,
    "AttachStdout" => true,
    "AttachStderr" => true,
    "Tty" => true
  }

  def start(id, lang, code_string, cmd_args \\ []) do
    {image, lang_folder, code_filename} =
      case lang do
        :gcc -> {"gcc:4.9", "c", "main.c"}
        :elixir -> {"elixir:1.10.4", "elixir", "main.exs"}
        _ -> raise ArgumentError, message: "Unsupported Language"
      end

    write_code_file(id, lang_folder, code_filename, code_string)

    container_id =
      create_container(image, id, lang_folder)
      |> start_container()
      |> exec_command(lang, code_filename, cmd_args)
      |> case do
        {:success, output, container_id} ->
          if(output == :timeout) do
            IO.puts("Timeout: Your code took more that #{@timeout / 1000} seconds to execute")
          else
            IO.puts("Successfully compiled and executed coded with output:")
            IO.puts("")
            IO.puts(output)
          end

          container_id

        {:compilation_failed, reason, container_id} ->
          IO.puts("Compilation Failed with reason:")
          IO.puts("")
          IO.puts(reason)
          container_id
      end

    container_id
    |> stop_container()
    |> delete_container()

    # Clean up files
    File.rm_rf("/tmp/code/#{lang_folder}/#{id}/")
  end

  defp write_code_file(id, lang_folder, code_filename, code_string) do
    File.mkdir_p!("/tmp/code/#{lang_folder}/#{id}/")
    File.write("/tmp/code/#{lang_folder}/#{id}/#{code_filename}", code_string, [:write])
  end

  defp create_container(image_name, id, lang_folder) do
    IO.puts("Creating container...")

    params =
      Jason.encode!(%{
        "Image" => image_name,
        "Cmd" => ["bin/bash", "-c", "tail -f /dev/null"],
        "HostConfig" => %{
          "Binds" => ["/tmp/code/#{lang_folder}/#{id}/:/tmp/code"]
        }
      })

    %HTTPoison.Response{body: body} =
      HTTPoison.post!(
        "#{@base}/containers/create",
        params,
        @content_type_header
      )

    %{"Id" => container_id} = Jason.decode!(body)

    container_id
  end

  defp exec_command(container_id, :gcc, code_filename, cmd_args) do
    executable = String.split(code_filename, ".") |> List.first()

    compile_code =
      %{
        "Cmd" => [
          "bin/bash",
          "-c",
          "gcc -o /tmp/code/#{executable} /tmp/code/#{code_filename}"
        ]
      }
      |> Map.merge(@cmd)
      |> Jason.encode!()

    container_id
    |> get_exec_instance(compile_code)
    |> exec()
    |> case do
      "" ->
        command =
          ["/tmp/code/#{executable}"]
          |> Kernel.++(cmd_args)
          |> Enum.join(" ")

        execute_code =
          %{"Cmd" => ["bin/bash", "-c", command]}
          |> Map.merge(@cmd)
          |> Jason.encode!()

        container_id
        |> get_exec_instance(execute_code)
        |> exec()
        |> case do
          :timout -> {:timout, container_id}
          output -> {:success, output, container_id}
        end

      reason ->
        {:compilation_failed, reason, container_id}
    end
  end

  defp exec_command(container_id, :elixir, code_filename, cmd_args) do
    command =
      ["elixir /tmp/code/#{code_filename}"]
      |> Kernel.++(cmd_args)
      |> Enum.join(" ")

    command =
      %{
        "Cmd" => [
          "bin/bash",
          "-c",
          command
        ]
      }
      |> Map.merge(@cmd)
      |> Jason.encode!()

    container_id
    |> get_exec_instance(command)
    |> exec()
    |> case do
      :timout ->
        {:timout, container_id}

      output ->
        {:success, output, container_id}
        # reason -> {:compilation_failed, reason, container_id}
    end
  end

  defp get_exec_instance(container_id, command) do
    IO.puts("Get Execution instance...")
    # Sets up an exec instance in a running container
    %HTTPoison.Response{body: body, status_code: status} =
      HTTPoison.post!("#{@base}/containers/#{container_id}/exec", command, @content_type_header)

    unless status == 201, do: raise(ArgumentError, message: "Unable to set an exec instance !")

    %{"Id" => exec_id} = Jason.decode!(body)

    exec_id
  end

  defp exec(exec_id) do
    IO.puts("Executing...")

    body =
      try do
        %HTTPoison.Response{body: body, status_code: 200} =
          HTTPoison.post!(
            "#{@base}/exec/#{exec_id}/start?stream=1?stdout=1",
            @exec_payload,
            @content_type_header,
            timeout: @timeout,
            recv_timeout: @timeout
          )

        body
      rescue
        HTTPoison.Error ->
          :timeout
      end

    body
  end

  # curl --unix-socket /var/run/docker.sock -X POST http:/v1.24/containers/bd90ae5f2429b4efd38544a05e69c7e1fa76a87c55e048391d2aa9725cd418d2/start
  defp start_container(container_id) do
    IO.puts("Starting container...")

    %HTTPoison.Response{status_code: 204} =
      HTTPoison.post!(
        "#{@base}/containers/#{container_id}/start",
        "",
        [],
        timeout: @request_timeout,
        recv_timeout: @request_timeout
      )

    container_id
  end

  defp stop_container(container_id) do
    IO.puts("Stopping container...")

    %HTTPoison.Response{status_code: 204} =
      HTTPoison.post!(
        "#{@base}/containers/#{container_id}/stop",
        "",
        [],
        timeout: @request_timeout,
        recv_timeout: @request_timeout
      )

    container_id
  end

  defp delete_container(container_id) do
    IO.puts("Deleting container...")

    %HTTPoison.Response{status_code: 204} =
      HTTPoison.delete!(
        "#{@base}/containers/#{container_id}",
        [],
        timeout: @request_timeout,
        recv_timeout: @request_timeout
      )
  end

  def sample_elixir_code_string do
    ~s'[x, y] = System.argv() |> Enum.map(&String.to_integer/1) |> case do [] -> [10, 20]; arr -> arr end; z = x+y; IO.puts("Sum is \#{z}")'
  end

  def sample_c_code_string do
    """
    #include <stdio.h>
    #include <unistd.h>
    #include <stdlib.h>

    int main(int argc, char * argv[]) {
      int n, c, k, space = 1;

      if (argc == 1) {
        n = 5;
      } else {
        n = atoi(argv[1]);
      }

      space = n - 1;
      for (k = 1; k <= n; k++) {
        for (c = 1; c <= space; c++)
          printf(" ");

        space--;
        for (c = 1; c <= 2 * k - 1; c++)
          printf("*");

        printf("\\n");
      }
      space = 1;
      for (k = 1; k <= n - 1; k++) {
        for (c = 1; c <= space; c++)
          printf(" ");

        space++;
        for (c = 1; c <= 2 * (n - k) - 1; c++)
          printf("*");

        printf("\\n");
      }
      //sleep(10);
      return 0;
    }
    """
  end
end

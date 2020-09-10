defmodule DockerInitialApi do
  @base "http+unix://%2Fvar%2Frun%2Fdocker.sock/v1.12"

  @timeout 30000

  def start(id) do
    id
    |> prepare_archive
    |> docker_run
    |> clean_up_tmp_files
  end

  def prepare_archive(id) do
    create_archive(id, sample_code_string(), docker_file_string())
    id
  end

  def clean_up_tmp_files(id) do
    File.rm_rf("/tmp/code/#{id}")
  end

  def docker_file_string do
    """
    FROM gcc:4.9
    WORKDIR /usr/src/myapp
    COPY main.c /usr/src/myapp
    RUN gcc -o myapp main.c -std=c99
    CMD ["./myapp"]
    """
  end

  def sample_code_string do
    # """
    # #include <stdio.h>
    # int main()
    # {
    #   int n, c, k, space = 1;
    #   n =10;
    #   space = n - 1;
    #   for (k = 1; k <= n; k++)
    #   {
    #     for (c = 1; c <= space; c++)
    #       printf(" ");

    #     space--;
    #     for (c = 1; c <= 2*k-1; c++)
    #       printf("*");

    #     printf("\\n");
    #   }
    #   space = 1;
    #   for (k = 1; k <= n - 1; k++)
    #   {
    #     for (c = 1; c <= space; c++)
    #       printf(" ");

    #     space++;
    #     for (c = 1 ; c <= 2*(n-k)-1; c++)
    #       printf("*");

    #     printf("\\n");
    #   }
    #   return 0;
    # }
    # """

    # """
    # #include <stdio.h>
    # int main() {
    #   printf("Hello, World!");
    #   return 0;
    # }
    # """

    """
    #include <stdio.h>
    #include <unistd.h>
    int main() {
      sleep(7);
      printf("Hello, World!!!");
      return 0;
    }
    """
  end

  def create_archive(id, code_string, docker_file_string) do
    File.mkdir_p!("/tmp/code/#{id}")
    File.write("/tmp/code/#{id}/main.c", code_string, [:write])
    File.write("/tmp/code/#{id}/Dockerfile", docker_file_string, [:write])

    files = [
      {'main.c', to_charlist("/tmp/code/#{id}/main.c")},
      {'Dockerfile', to_charlist("/tmp/code/#{id}/Dockerfile")}
    ]

    :ok =
      :erl_tar.create(
        "/tmp/code/#{id}/Dockerfile.tar.gz",
        files,
        [:compressed]
      )

    id
  end

  def docker_ps do
    %HTTPoison.Response{body: body} = HTTPoison.get!("#{@base}/containers/json")
    {:ok, body} = Jason.decode(body)
    body
  end

  def docker_build(image_name) do
    %HTTPoison.Response{body: _body} =
      HTTPoison.post!(
        "#{@base}/build?t=#{image_name}",
        {:file, "/tmp/code/#{image_name}/Dockerfile.tar.gz"},
        [{"content-type", "application/tar"}]
      )

    image_name
  end

  # curl --unix-socket /var/run/docker.sock -d '{"Image": "my-gcc-app"}' -H "Content-Type: application/json" -X POST http:/v1.24/containers/create
  def docker_create_container(image_name) do
    %HTTPoison.Response{body: body} =
      HTTPoison.post!(
        "#{@base}/containers/create",
        "{\"Image\": \"#{image_name}\"}",
        [{"content-type", "application/json"}]
      )

    {:ok, %{"Id" => container_id}} = Jason.decode(body)
    container_id
  end

  # curl --unix-socket /var/run/docker.sock http:/v1.24/containers/bd90ae5f2429b4efd38544a05e69c7e1fa76a87c55e048391d2aa9725cd418d2/logs?stdout=1
  def docker_logs(container_id) do
    # Need root previlages
    {:ok, json_logs} =
      File.read("/var/lib/docker/containers/#{container_id}/#{container_id}-json.log")

    IO.puts(" === OUTPUT ===")
    IO.inspect(json_logs)

    # == Alternative using REST "/logs" API ==

    # %HTTPoison.Response{body: body} = HTTPoison.get!("#{@base}/containers/#{container_id}/logs?stdout=1")
    # IO.inspect(body)
    # <<(<<1, 0, 0, 0, 0, 0, 0, _>>), body::bits>> = body
    # IO.puts("------------------")
    # IO.inspect(body)

    container_id
  end

  # curl --unix-socket /var/run/docker.sock -X POST http:/v1.24/containers/bd90ae5f2429b4efd38544a05e69c7e1fa76a87c55e048391d2aa9725cd418d2/start
  def docker_container_run(container_id) do
    HTTPoison.post!("#{@base}/containers/#{container_id}/start", "")
    container_id
  end

  # curl --unix-socket /var/run/docker.sock -X DELETE http:/v1.24/containers/6aad267bbf8e468d2c619830ca2f278a8e8f9f3a2dceccc57b78e981d7a07009
  def docker_delete_container(container_id) do
    HTTPoison.delete!("#{@base}/containers/#{container_id}")
    container_id
  end

  # docker start 1c6594faf5
  # curl --unix-socket /var/run/docker.sock -X POST http:/v1.24/containers/1c6594faf5/start
  def docker_run(id) do
    docker_build(id)
    |> docker_create_container
    |> docker_container_run
    |> docker_wait_for_container
    |> docker_logs
    |> docker_delete_container

    docker_delete_image(id)

    id
  end

  def docker_wait_for_container(container_id) do
    HTTPoison.post!("#{@base}/containers/#{container_id}/wait", "", [],
      timeout: @timeout,
      recv_timeout: @timeout
    )

    # ALTERNATE

    # current = self()

    # child =
    #   spawn(fn ->
    #     send(current, {self(), HTTPoison.post!("#{@base}/containers/#{container_id}/wait", "")})
    #   end)

    # receive do
    #   {^child, msg} -> msg
    # after
    #   1_000 -> "nothing after 1s"
    # end

    container_id
  end

  def docker_delete_image(image_name) do
    HTTPoison.delete!("#{@base}/images/#{image_name}")
  end
end

#  == LINKS, ARTICLES and NOTES OF INTEREST ==

# docker build -t my-gcc-app .
# docker run -it --rm --name my-running-app my-gcc-app
# https://docs.docker.com/engine/reference/commandline/run/
# gcc main.c && ./a.out

# curl --unix-socket /var/run/docker.sock   -X POST http:/v1.24/build?dockerfile=/home/arpan/dev/docker_exam/
# https://docs.docker.com/engine/api/v1.24/#32-images
# https://github.com/swipely/docker-api

# dynamically create a docker file and build and run

# https://stackoverflow.com/questions/43800339/how-to-build-an-image-using-docker-api#:~:text=Create%20a%20tar%20file%20which%20includes%20your%20Dockerfile.&text=Execute%20the%20API%20as%20below%20and%20for%20more%20options%2C%20refer%20this.&text=Check%20the%20docker%20images%20after%20the%20image%20is%20successfully%20built.&text=Removed%20some%20of%20the%20output%20which%20is%20not%20necessary.

# tar -cvf Dockerfile.tar.gz Dockerfile main.c

# == Challenges ==
# Timout on container,No option on docker, https://github.com/moby/moby/issues/1905#issuecomment-24795551

# Passing command line args?

# Compile failed, build failed ?



  # https://stackoverflow.com/questions/53781590/how-to-use-docker-api-engine-to-exec-cmd-in-container
  # docker exec exam_gcc gcc -o /tmp/code/123/main /tmp/code/123/main.c
# docker exec exam_gcc /tmp/code/123/main

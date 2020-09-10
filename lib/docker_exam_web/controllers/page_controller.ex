defmodule DockerExamWeb.PageController do
  use DockerExamWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end
end

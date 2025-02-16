defmodule Ash.Test.Type.DurationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Ash.Test.Domain, as: Domain

  defmodule Post do
    @moduledoc false
    use Ash.Resource, domain: Domain, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      default_accept :*
      defaults [:read, :destroy, create: :*, update: :*]
    end

    attributes do
      uuid_primary_key :id

      attribute :duration, :duration do
        public?(true)
      end
    end
  end

  test "it allows durations by default" do
    duration = Duration.new!(week: 1)

    post =
      Post
      |> Ash.Changeset.for_create(:create, %{
        duration: duration
      })
      |> Ash.create!()

    assert (post.duration == duration)
  end

  test "it does not allow invalid durations" do
    duration = "not a duration"

    assert_raise Ash.Error.Invalid, ~r"Invalid value provided for duration", fn ->
      Post
      |> Ash.Changeset.for_create(:create, %{
        duration: duration
      })
      |> Ash.create!()
    end
  end
end

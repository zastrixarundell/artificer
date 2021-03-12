defmodule Cassian.Managers.PlayManager do
  @moduledoc """
  Manager for queues.
  """

  alias Cassian.Structs.{VoiceState, Playlist}
  alias Cassian.Utils.Voice
  alias Cassian.Utils.Embed, as: EmbedUtils
  alias Cassian.Managers.MessageManager
  alias Nostrum.Struct.{Message, Embed}

  @doc """
  Add a song to the playlist.
  """
  def insert!(guild_id, channel_id, metadata) do
    Playlist.insert!(guild_id, metadata)

    VoiceState.get!(guild_id)
    |> Map.put(:channel_id, channel_id)
    |> notify_enqueued(metadata)
    |> VoiceState.put()
  end

  @doc """
  """
  def alter_index(guild_id) do
    case Playlist.show(guild_id) do
      {:ok, playlist} ->
        index = playlist.index + if playlist.reverse, do: -1, else: 1

        index =
          case playlist.repeat do
            :none ->
              index

            :one ->
              playlist.index

            :all ->
              keep_in_bounds(index, playlist.elements)

          end

        playlist
        |> Map.put(:index, index)
        |> Playlist.put()
      {:error, :noop} ->
        nil
    end
  end

  defp in_bound?(index, ordered) do
    index = index + 1
    index >= length(ordered) and index <= length(ordered)
  end

  # Keep the index in bounds, loops around.
  defp keep_in_bounds(index, ordered) do
    size = length(ordered)
    index = if index >= size, do: 0, else: index
    if index < 0, do: size - 1, else: index
  end

  @doc """
  Clear/delete the queue for a guild_id.
  """
  def clear!(guild_id) do
    Playlist.delete(guild_id)
  end

  @doc """
  Play a song if needed. Deletes the queue if it determines
  it should.
  """
  def play_if_needed(guild_id) do
    state = VoiceState.get!(guild_id)

    if state.status == :noop and Playlist.exists?(guild_id) do
      case Playlist.show(guild_id) do
        {:ok, playlist} ->
          {index, ordered} = Playlist.order_playlist(playlist)

          should_play? = playlist.repeat == :none and !in_bound?(index, ordered)

          if should_play? do
            index = keep_in_bounds(index, ordered)

            metadata = Enum.at(ordered, index)

            Voice.play_when_ready!(metadata.youtube_link, guild_id)

            notifiy_playing(state.channel_id, metadata)

            state
            |> Map.put(:status, :playing)
            |> VoiceState.put()
          end

        _ ->
          nil
      end
    end
  end

  @doc """
  Notify state a song is enqueued. Will be moved.
  """
  def notify_enqueued(state, metadata) do
    unless state.status == :noop do
      alias Cassian.Utils.Embed, as: EmbedUtils
      alias Nostrum.Struct.Embed

      embed =
        EmbedUtils.create_empty_embed!()
        |> EmbedUtils.put_color_on_embed(metadata.provider_color)
        |> Embed.put_url(metadata.youtube_link)
        |> Embed.put_title("Enqueued: #{metadata.title}")

      MessageManager.send_dissapearing_embed(embed, state.channel_id)
    end

    state
  end

  @doc """
  Notify that a song is currently playing.
  """
  def notifiy_playing(channel_id, metadata) do
    alias Cassian.Utils.Embed, as: EmbedUtils
    alias Nostrum.Struct.Embed

    embed =
      EmbedUtils.create_empty_embed!()
      |> EmbedUtils.put_color_on_embed(metadata.provider_color)
      |> Embed.put_url(metadata.youtube_link)
      |> Embed.put_title("Now playing: #{metadata.title}")

    case MessageManager.send_embed(embed, channel_id) do
      {:ok, message} ->
        MessageManager.add_control_reactions(message)
      _ ->
        nil
    end
  end

  @doc """
  Change the repeat of the playlist. If `allow_update` is false, then
  setting the repeat to the current repeat will set it to `:none`, else
  it will just set it to the specific value.
  """
  @spec change_repeat(guild_id :: Snowflake.t(), type :: :none | :one | :all, allow_update :: boolean()) :: {:ok, :none | :all | :one} | {:error, :noop}
  def change_repeat(guild_id, type, allow_update \\ false) do
    case Playlist.show(guild_id) do
      {:ok, playlist} ->
        new_status =
          if playlist.repeat == type and !allow_update do
            :none
          else
            type
          end

        playlist
        |> Map.put(:repeat, new_status)
        |> Playlist.put()

        {:ok, new_status}

      {:error, :noop} ->
        :error
    end
  end

  @doc """
  Change the direction of the playlist. Safely return if this is done.
  """
  @spec change_direction(guild_id :: Snowflake.t(), reverse :: boolean()) :: :ok | :noop
  def change_direction(guild_id, reverse) do
    case Playlist.show(guild_id) do
      {:ok, playlist} ->
        playlist
        |> Map.put(:reverse, reverse)
        |> Playlist.put()
        :ok

      {:error, :noop} ->
        :noop
    end
  end

  @doc """
  Chaange the direction of the playlist and send a notification.
  """
  @spec change_direction_with_notification(message :: %Message{}, reverse :: boolean()) :: :ok | :noop
  def change_direction_with_notification(message, reverse) do
    title_part = if reverse, do: "in reverse", else: "normally"

    case change_direction(message.guild_id, reverse) do
      :ok ->
        EmbedUtils.create_empty_embed!()
        |> Embed.put_title("Playing #{title_part}.")
        |> Embed.put_description("The current playlist will play #{title_part}.")

      :noop ->
        EmbedUtils.generate_error_embed(
          "There is no playlist.",
          "I can't change the direction of the playlist if it doesn't exist."
        )
    end
    |> MessageManager.send_dissapearing_embed(message.channel_id)
  end

  @doc """
  Change the direction of the playlist and send a notification. If the type of
  repeat is the same as the current one, it will be set to :none unless you set `allow_update` to true.
  """
  @spec change_repeat_with_notification(message :: %Message{}, type :: :none | :one | :all, allow_update :: boolean()) :: :ok | :noop
  def change_repeat_with_notification(message, type, allow_update \\ false) do
    case change_repeat(message.guild_id, type, allow_update) do
      {:ok, type} ->
        {message, description} =
          case type do
            :none ->
              {"Not repeating the playlist.", "The playlist will not be repeated."}

            :one ->
              {"Repeating one.", "Only the current song will be repeated."}

            :all ->
              {"Repeating is on.", "The whole playlist will be repeated."}
          end

        EmbedUtils.create_empty_embed!()
        |> Embed.put_title(message)
        |> Embed.put_description(description)

      :error ->
        EmbedUtils.generate_error_embed(
          "There is no playlist.",
          "I can't change the repeat of the playlist if it doesn't exist."
        )
    end
    |> MessageManager.send_dissapearing_embed(message.channel_id)
  end

  @doc """
  Switch to the next or previous song.
  """
  @spec switch_song(guild_id :: Snowflake.t(), next :: boolean()) :: :ok | :noop
  def switch_song(guild_id, next) do
    case Playlist.show(guild_id) do
      {:ok, playlist} ->
        # Next song is automatically handled when the bot stops playing music
        # so we only have to worry about going to the previous song.
        unless next do
          # So in normal mode to play the previous song you have to decrement
          # by two to play the previous one. I guess in in reverse mode you then
          # have to do the negative, i.e. increment it by two?
          new_index = playlist.index + if playlist.reverse, do: 2, else: -2

          playlist
              |> Map.put(:index, new_index)
              |> Playlist.put()
        end

        Nostrum.Voice.stop(guild_id)

      {:error, :noop} ->
        :error
    end
  end

  @doc """
  Switch to the next or previous song. Also send notification to the channel.
  """
  @spec switch_song_with_notification(message :: %Message{}, next :: boolean()) :: :ok | :noop
  def switch_song_with_notification(message, next) do
    title_part = if next, do: "next", else: "previous"

    case switch_song(message.guild_id, next) do
      :ok ->
        EmbedUtils.create_empty_embed!()
        |> Embed.put_title("Playing #{title_part} song.")

      :noop ->
        EmbedUtils.generate_error_embed(
          "There is no playlist.",
          "You can't change songs if there is no playlist."
        )
    end
    |> MessageManager.send_dissapearing_embed(message.channel_id)
  end
end

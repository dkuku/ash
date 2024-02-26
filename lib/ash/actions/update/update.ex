defmodule Ash.Actions.Update do
  @moduledoc false

  alias Ash.Actions.Helpers

  require Ash.Tracer
  require Logger

  @spec run(Ash.Api.t(), Ash.Resource.record(), Ash.Resource.Actions.action(), Keyword.t()) ::
          {:ok, Ash.Resource.record(), list(Ash.Notifier.Notification.t())}
          | {:ok, Ash.Resource.record()}
          | {:error, Ash.Changeset.t()}
          | {:error, term}
  def run(api, %{valid?: false} = changeset, _action, _opts) do
    {:error, Ash.Error.to_error_class(changeset.errors, changeset: %{changeset | api: api})}
  end

  def run(api, changeset, action, opts) do
    if changeset.atomics != [] &&
         !Ash.DataLayer.data_layer_can?(changeset.resource, {:atomic, :update}) do
      {:error,
       Ash.Error.Invalid.AtomicsNotSupported.exception(
         resource: changeset.resource,
         action_type: :update
       )}
    else
      primary_read = Ash.Resource.Info.primary_action(changeset.resource, :read)

      {fully_atomic_changeset, params} =
        cond do
          !Ash.DataLayer.data_layer_can?(changeset.resource, :expr_error) && opts[:authorize?] ->
            {{:not_atomic, "data layer does not support adding errors to a query"}, nil}

          !Ash.DataLayer.data_layer_can?(changeset.resource, :update_query) ->
            {{:not_atomic, "data layer does not support updating a query"}, nil}

          !Enum.empty?(changeset.relationships) ->
            {{:not_atomic, "cannot atomically manage relationships"}, nil}

          !primary_read ->
            {{:not_atomic, "cannot atomically update a record without a primary read action"},
             nil}

          true ->
            params =
              changeset.attributes
              |> Map.merge(changeset.casted_attributes)
              |> Map.merge(changeset.arguments)
              |> Map.merge(changeset.casted_arguments)

            res =
              Ash.Changeset.fully_atomic_changeset(
                changeset.resource,
                action,
                params,
                opts
                |> Keyword.merge(
                  assume_casted?: true,
                  notify?: true,
                  atomics: changeset.atomics || [],
                  tenant: changeset.tenant
                )
              )

            {res, params}
        end

      case fully_atomic_changeset do
        %Ash.Changeset{} = atomic_changeset ->
          atomic_changeset =
            %{atomic_changeset | data: changeset.data}
            |> Ash.Changeset.set_context(%{data_layer: %{use_atomic_update_data?: true}})
            |> Map.put(:load, changeset.load)
            |> Map.put(:select, changeset.select)
            |> Ash.Changeset.set_context(changeset.context)

          {atomic_changeset, opts} =
            Ash.Actions.Helpers.add_process_context(api, atomic_changeset, opts)

          opts =
            Keyword.merge(opts,
              atomic_changeset: atomic_changeset,
              return_records?: true,
              notify?: true,
              return_notifications?: opts[:return_notifications?],
              return_errors?: true
            )

          primary_key = Ash.Resource.Info.primary_key(atomic_changeset.resource)
          primary_key_filter = changeset.data |> Map.take(primary_key) |> Map.to_list()

          query =
            atomic_changeset.resource
            |> Ash.Query.for_read(primary_read.name, %{},
              actor: opts[:actor],
              authorize?: false,
              context: atomic_changeset.context,
              tenant: atomic_changeset.tenant,
              tracer: opts[:tracer]
            )
            |> Ash.Query.set_context(%{private: %{internal?: true}})
            |> Ash.Query.do_filter(primary_key_filter)

          case Ash.Actions.Update.Bulk.run(
                 api,
                 query,
                 fully_atomic_changeset.action,
                 params,
                 Keyword.merge(opts,
                   strategy: [:atomic],
                   authorize_query?: false,
                   return_records?: true,
                   atomic_changeset: atomic_changeset,
                   authorize_changeset_with: :error
                 )
               ) do
            %Ash.BulkResult{status: :success, records: [record], notifications: notifications} ->
              if opts[:return_notifications?] do
                {:ok, record, List.wrap(notifications)}
              else
                {:ok, record}
              end

            %Ash.BulkResult{status: :success, records: []} ->
              primary_key = Ash.Resource.Info.primary_key(atomic_changeset.resource)

              {:error,
               Ash.Error.to_error_class(
                 Ash.Error.Changes.StaleRecord.exception(
                   resource: fully_atomic_changeset.resource,
                   filters: Map.take(changeset.data, primary_key)
                 )
               )}

            %Ash.BulkResult{status: :error, errors: errors} ->
              {:error, Ash.Error.to_error_class(errors)}
          end

        other ->
          if Ash.DataLayer.data_layer_can?(changeset.resource, :update_query) &&
               action.require_atomic? &&
               match?({:not_atomic, _reason}, other) do
            {:not_atomic, reason} = other

            {:error,
             Ash.Error.Framework.MustBeAtomic.exception(
               resource: changeset.resource,
               action: action.name,
               reason: reason
             )}
          else
            {changeset, opts} = Ash.Actions.Helpers.add_process_context(api, changeset, opts)

            Ash.Tracer.span :action,
                            Ash.Api.Info.span_name(
                              api,
                              changeset.resource,
                              action.name
                            ),
                            opts[:tracer] do
              metadata = %{
                api: api,
                resource: changeset.resource,
                resource_short_name: Ash.Resource.Info.short_name(changeset.resource),
                actor: opts[:actor],
                tenant: opts[:tenant],
                action: action.name,
                authorize?: opts[:authorize?]
              }

              Ash.Tracer.set_metadata(opts[:tracer], :action, metadata)

              Ash.Tracer.telemetry_span [:ash, Ash.Api.Info.short_name(api), :update], metadata do
                case do_run(api, changeset, action, opts) do
                  {:error, error} ->
                    if opts[:tracer] do
                      stacktrace =
                        case error do
                          %{stacktrace: %{stacktrace: stacktrace}} ->
                            stacktrace || []

                          _ ->
                            {:current_stacktrace, stacktrace} =
                              Process.info(self(), :current_stacktrace)

                            stacktrace
                        end

                      Ash.Tracer.set_handled_error(opts[:tracer], Ash.Error.to_error_class(error),
                        stacktrace: stacktrace
                      )
                    end

                    {:error, error}

                  other ->
                    other
                end
              end
            end
          end
      end
    end
  rescue
    e ->
      reraise Ash.Error.to_error_class(e, changeset: changeset, stacktrace: __STACKTRACE__),
              __STACKTRACE__
  end

  @doc false
  def do_run(api, changeset, action, opts) do
    with %{valid?: true} = changeset <- Ash.Changeset.validate_multitenancy(changeset),
         %{valid?: true} = changeset <- changeset(changeset, api, action, opts),
         %{valid?: true} = changeset <- authorize(changeset, api, opts),
         {:commit, {:ok, result, instructions}} <- {:commit, commit(changeset, api, opts)} do
      add_notifications(
        changeset.resource,
        result,
        changeset.action,
        changeset,
        instructions,
        opts[:return_notifications?]
      )
    end
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:ok, result, notifications} ->
        {:ok, result, notifications}

      :ok ->
        :ok

      %Ash.Changeset{errors: errors} = changeset ->
        errors = Helpers.process_errors(changeset, errors)

        Ash.Changeset.run_after_transactions(
          {:error, Ash.Error.to_error_class(errors, changeset: changeset)},
          changeset
        )

      {:error, error} ->
        errors = Helpers.process_errors(changeset, List.wrap(error))

        Ash.Changeset.run_after_transactions(
          {:error, Ash.Error.to_error_class(errors, changeset: changeset)},
          changeset
        )

      {:commit, {:error, error}} ->
        errors = Helpers.process_errors(changeset, List.wrap(error))
        {:error, Ash.Error.to_error_class(errors, changeset: changeset)}
    end
  end

  defp authorize(changeset, api, opts) do
    if opts[:authorize?] do
      case api.can(changeset, opts[:actor],
             alter_source?: true,
             return_forbidden_error?: true,
             maybe_is: false
           ) do
        {:ok, true, changeset} ->
          changeset

        {:ok, false, error} ->
          Ash.Changeset.add_error(changeset, error)

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    else
      changeset
    end
  end

  defp add_tenant({:ok, data}, changeset) do
    if changeset.tenant do
      {:ok, %{data | __metadata__: Map.put(data.__metadata__, :tenant, changeset.tenant)}}
    else
      {:ok, data}
    end
  end

  defp add_tenant(other, _changeset) do
    other
  end

  defp add_notifications(
         resource,
         result,
         action,
         changeset,
         instructions,
         return_notifications?
       ) do
    if return_notifications? do
      if changeset.action_type == :destroy do
        {:ok, Map.get(instructions, :notifications, [])}
      else
        {:ok, result, Map.get(instructions, :notifications, [])}
      end
    else
      Ash.Actions.Helpers.warn_missed!(resource, action, instructions)

      if changeset.action_type == :destroy do
        :ok
      else
        {:ok, result}
      end
    end
  end

  defp changeset(changeset, api, action, opts) do
    changeset = %{changeset | api: api}

    if changeset.__validated_for_action__ == action.name do
      changeset
    else
      Ash.Changeset.for_update(changeset, action.name, %{}, opts)
    end
    |> Ash.Changeset.timeout(opts[:timeout] || changeset.timeout)
  end

  defp commit(changeset, api, opts) do
    can_atomic_update? =
      Ash.DataLayer.data_layer_can?(changeset.resource, {:atomic, :update})

    result =
      changeset
      |> Ash.Changeset.before_action(
        &Ash.Actions.ManagedRelationships.setup_managed_belongs_to_relationships(
          &1,
          opts[:actor],
          authorize?: opts[:authorize?],
          actor: opts[:actor]
        )
      )
      |> Ash.Changeset.with_hooks(
        fn
          %{atomics: atomics} when atomics != [] and not can_atomic_update? ->
            {:error,
             Ash.Error.Invalid.AtomicsNotSupported.exception(
               resource: changeset.resource,
               action_type: :update
             )}

          changeset ->
            changeset = Ash.Changeset.hydrate_atomic_refs(changeset, opts[:actor])

            case Ash.Actions.ManagedRelationships.setup_managed_belongs_to_relationships(
                   changeset,
                   opts[:actor],
                   actor: opts[:actor],
                   authorize?: opts[:authorize?]
                 ) do
              {:error, error} ->
                {:error, error}

              {changeset, manage_instructions} ->
                changeset =
                  changeset
                  |> Ash.Changeset.require_values(
                    :update,
                    true
                  )
                  |> Ash.Changeset.require_values(
                    :update,
                    false,
                    changeset.action.require_attributes
                  )

                changeset = set_tenant(changeset)

                if changeset.valid? do
                  if changeset.action.manual do
                    {mod, action_opts} = changeset.action.manual

                    if result = changeset.context[:private][:action_result] do
                      result
                    else
                      mod.update(
                        changeset,
                        action_opts,
                        %{
                          actor: opts[:actor],
                          tenant: changeset.tenant,
                          authorize?: opts[:authorize?],
                          api: changeset.api
                        }
                      )
                      |> validate_manual_action_return_result!(
                        changeset.resource,
                        changeset.action
                      )
                    end
                    |> manage_relationships(api, changeset,
                      actor: opts[:actor],
                      authorize?: opts[:authorize?]
                    )
                  else
                    cond do
                      result = changeset.context[:private][:action_result] ->
                        result
                        |> add_tenant(changeset)
                        |> manage_relationships(api, changeset,
                          actor: opts[:actor],
                          authorize?: opts[:authorize?]
                        )

                      changeset.context.changed? ->
                        changeset =
                          Ash.Changeset.set_defaults(changeset, :update, true)

                        changeset.resource
                        |> Ash.DataLayer.update(changeset)
                        |> case do
                          {:ok, data} ->
                            {:ok, %{data | __metadata__: changeset.data.__metadata__}}

                          {:error, error} ->
                            {:error, error}
                        end
                        |> Ash.Actions.Helpers.rollback_if_in_transaction(
                          changeset.resource,
                          changeset
                        )
                        |> add_tenant(changeset)
                        |> manage_relationships(api, changeset,
                          actor: opts[:actor],
                          authorize?: opts[:authorize?]
                        )

                      true ->
                        {:ok, changeset.data}
                        |> add_tenant(changeset)
                        |> manage_relationships(api, changeset,
                          actor: opts[:actor],
                          authorize?: opts[:authorize?]
                        )
                    end
                  end
                  |> case do
                    {:ok, result} ->
                      {:ok, result, %{notifications: manage_instructions.notifications}}

                    {:ok, result, notifications} ->
                      {:ok, result,
                       Map.update!(
                         notifications,
                         :notifications,
                         &(&1 ++ manage_instructions.notifications)
                       )}

                    {:error, error} ->
                      {:error, Ash.Changeset.add_error(changeset, error)}
                  end
                else
                  {:error, changeset}
                end
            end
        end,
        transaction?: Keyword.get(opts, :transaction?, true) && changeset.action.transaction?,
        rollback_on_error?: opts[:rollback_on_error?],
        notification_metadata: opts[:notification_metadata],
        return_notifications?: opts[:return_notifications?],
        transaction_metadata: %{
          type: :update,
          metadata: %{
            record: changeset.data,
            resource: changeset.resource,
            action: changeset.action.name,
            actor: opts[:actor]
          }
        }
      )

    case result do
      {:ok, updated, changeset, instructions} ->
        {:ok, updated, instructions}
        |> Helpers.load(changeset, api,
          actor: opts[:actor],
          authorize?: opts[:authorize?],
          tracer: opts[:tracer]
        )
        |> Helpers.notify(changeset, opts)
        |> Helpers.select(changeset)
        |> Helpers.restrict_field_access(changeset)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp validate_manual_action_return_result!({:ok, %resource{}} = result, resource, _) do
    result
  end

  defp validate_manual_action_return_result!(
         {:ok, %resource{}, notifications} = result,
         resource,
         _
       )
       when is_list(notifications) do
    result
  end

  defp validate_manual_action_return_result!({:error, _error} = result, _resource, _) do
    result
  end

  defp validate_manual_action_return_result!(other, resource, action) do
    raise Ash.Error.Framework.AssumptionFailed,
      message: """
      Manual action #{inspect(action.name)} on #{inspect(resource)} returned an invalid result.

      Expected one of the following:

      * {:ok, %Resource{}}
      * {:ok, %Resource{}, notifications}
      * {:error, error}

      Got:

      #{inspect(other)}
      """
  end

  defp manage_relationships(
         {:ok, updated, %{notifications: notifications}},
         api,
         changeset,
         engine_opts
       ) do
    case manage_relationships({:ok, updated}, api, changeset, engine_opts) do
      {:ok, updated, info} ->
        {:ok, updated, Map.update(info, :notifications, notifications, &(&1 ++ notifications))}

      other ->
        other
    end
  end

  defp manage_relationships({:ok, updated}, api, changeset, engine_opts) do
    with {:ok, loaded} <-
           Ash.Actions.ManagedRelationships.load(api, updated, changeset, engine_opts),
         {:ok, with_relationships, new_notifications} <-
           Ash.Actions.ManagedRelationships.manage_relationships(
             loaded,
             changeset,
             engine_opts[:actor],
             engine_opts
           ) do
      {:ok, with_relationships, %{notifications: new_notifications}}
    end
  end

  defp manage_relationships(other, _, _, _), do: other

  defp set_tenant(changeset) do
    if changeset.tenant &&
         Ash.Resource.Info.multitenancy_strategy(changeset.resource) == :attribute do
      attribute = Ash.Resource.Info.multitenancy_attribute(changeset.resource)

      {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(changeset.resource)
      attribute_value = apply(m, f, [changeset.tenant | a])

      Ash.Changeset.force_change_attribute(changeset, attribute, attribute_value)
    else
      changeset
    end
  end
end

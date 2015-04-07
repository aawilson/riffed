defmodule Rift.Struct do
  @moduledoc ~S"""
  Parse your thrift files and build some Elixir-y structs and conversions functions for you.

  Assuming you have the following Thrift strucs defined in src/request_types.erl:

        struct User {
          1: i32 id,
          2: string firstName,
          3: string lastName;
        }

        struct Request {
          1: User user,
          2: list<string> cookies,
          3: map<string, string> params;
        }


  You import them thusly:

    defmodule Request do
       use Rift.Struct, request_types: [:Request, :User]
    end

  Note that the use statment takes a keyword list whose names are thrift modules and whose values are
  the structs that you would like to import.

  Your request module now has User and Request submodules, and the top level module has conversion
  functions added to it so you can do the following:

        Request.to_elixir({:User, 32, "Steve", "Cohen"})
        > %Request.User{id: 32, firstName: "Steve", lastName: "Cohen"}

        user = Request.User.new(firstName: "Richard", lastName: "Feynman", id: 3221)
        > %Request.User{id: 3221, firstName: "Richard", lastName: "Feynman"}
        Request.to_erlang(user)
        > {:User, 3221, "Richard", "Feynman"}

  ### Note:
  Keys not set will have the initial value of :undefined.

  """

  defmodule StructData do
    defstruct struct_modules: [], tuple_converters: [], struct_converters: []

    def append(data=%StructData{}, struct_module, tuple_stanza, struct_function) do
      %StructData{struct_modules: [struct_module | data.struct_modules],
                  tuple_converters: [tuple_stanza | data.tuple_converters],
                  struct_converters: [struct_function | data.struct_converters]}
    end
  end

  defmacro __using__(opts) do
    Module.register_attribute(__CALLER__.module, :callbacks, accumulate: true)

    quote do
      use Rift.Callbacks
      use Rift.Enumeration
      require Rift.Struct
      import Rift.Struct

      @thrift_options unquote(opts)
      @before_compile Rift.Struct
    end
  end


  defp build_struct_args(struct_meta) do
    Enum.map(struct_meta, fn({_, _, _, name, _}) -> {name, :undefined} end)
  end

  defp downcase_first(s) when is_bitstring(s) do
    <<first, rest :: binary>> = s
    String.downcase(List.to_string([first])) <> rest
  end

  defp downcase_first(a) when is_atom(a) do
    a
    |> Atom.to_string
    |> downcase_first
    |> String.to_atom
  end

  defp build_struct_and_conversion_function(struct_data=%StructData{}, container_module, struct_module_name, thrift_module)  do
    {:struct, meta} = :erlang.apply(thrift_module, :struct_info_ext, [struct_module_name])
    struct_args = build_struct_args(meta)
    fq_module_name = Module.concat([container_module, struct_module_name])
    record_name = downcase_first(struct_module_name)
    record_file = "src/#{thrift_module}.hrl"

    tuple_to_elixir = build_tuple_to_elixir(container_module, fq_module_name, meta, struct_module_name)
    struct_to_erlang = build_struct_to_erlang(container_module, fq_module_name, meta, struct_module_name, record_name)

    struct_module = quote do
      defmodule unquote(fq_module_name) do
        require Record

        Record.defrecord(unquote(record_name),
                         Record.extract(unquote(struct_module_name),
                                        from: unquote(record_file)))
        defstruct unquote(struct_args)

        def new(opts \\ unquote(struct_args)) do
          Enum.reduce(opts, %unquote(fq_module_name){}, fn({k, v}, s) -> Map.put(s, k, v) end)
        end
      end
    end

    StructData.append(struct_data, struct_module, tuple_to_elixir, struct_to_erlang)
  end

  defp build_tuple_to_elixir(container_module, module_name, meta, thrift_name) do
    # Builds a conversion function that take a tuple and converts it into an Elixir struct

    pos_args = [thrift_name] ++ Enum.map(meta, fn({_, _, _, name, _}) ->
                                           Macro.var(name, module_name) end)
    pos_args = {:{}, [], pos_args}

    keyword_args = Enum.map(
      meta, fn({_ ,_ ,type ,name ,_}) ->
        # the meta format is {index, :undefined, type, name, :undefined}
        var = Macro.var(name, module_name)
        quote do
          {unquote(name), unquote(container_module).to_elixir(unquote(type), unquote(var))}
        end
      end)

    enum_conversions = Enum.map(
      meta, fn({_, _, _type, name, _}) ->
        var = Macro.var(name, module_name)
        quote do
          unquote(var) = convert_to_enum(unquote(thrift_name), unquote(name), unquote(var))
        end
      end)

    quote do
      def to_elixir(unquote(pos_args)) do
        unquote_splicing(enum_conversions)
        unquote(module_name).new(unquote(keyword_args)) |> after_to_elixir
      end
    end
  end

  defp build_struct_to_erlang(dest_module, struct_module, meta, record_name, record_fn_name) do
    # Builds a conversion function that turns an Elixir struct into an erlang record
    # The output is quote:

    kwargs = Enum.map(meta, fn({_, _, type, name, _}) ->
                        # The meta format is {index, :undefined, type, name, :undefined}
                        field_variable = Macro.var(name, struct_module)
                        quote do
                          {unquote(name), unquote(dest_module).to_erlang(unquote(type), s.unquote(field_variable)())}
                        end

                       end)

    quote do
      def to_erlang(s=%unquote(struct_module){}) do
        require unquote(struct_module)
        s = convert_enums_to_erlang(s)
        unquote(struct_module).unquote(record_fn_name)(unquote(kwargs))
        |> put_elem(0, unquote(record_name))
        |> after_to_erlang
      end
    end
  end


  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :thrift_options)

    struct_data = Enum.reduce(
      options,
      %StructData{},
      fn({thrift_module, struct_names}, data) ->
        Enum.reduce(struct_names, data,
          fn(struct_name, data) ->
            build_struct_and_conversion_function(data, env.module, struct_name, thrift_module)
          end)
      end)

    callbacks = Rift.Callbacks.build(env.module)
    enums = Rift.Enumeration.build(env.module)

    quote do
      unquote_splicing(struct_data.struct_modules)
      unquote_splicing(struct_data.tuple_converters)
      unquote_splicing(enums.modules)


      unquote(Rift.Callbacks.default_to_elixir)

      unquote_splicing(struct_data.struct_converters)

      unquote(Rift.Callbacks.default_to_erlang)
      unquote_splicing(enums.conversion_fns)
      unquote(callbacks)

    end
  end

end

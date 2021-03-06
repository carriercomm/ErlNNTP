-module (db_handler).
-include ("types.hrl").
-include ("log_macros.hrl").
-export ([write_article/2, read_article/1, add_new_group/2, get_group_info/1, get_article_numbers_from_group/1, get_article_numbers_from_group_r/3, get_first_number_from_group/1, get_group_names/0, get_group_descrs/0, get_group_list_entries/0, get_header_values/2]).
-export ([start_link/0, init/1, handle_cast/2, handle_call/3]).
-behaviour(gen_server).

start_link() ->
    EmongoConfDir = code:priv_dir(emongo),
    {ok, [[{emongo,[{pools, Pools}]}]]}= file:consult (EmongoConfDir ++"/example.config"),
    application:set_env(emongo, pools, Pools),
    ok = application:start(emongo),
    gen_server:start_link({local, ?MODULE}, ?MODULE, null, []).

init(null) ->
    {ok, null}.

do_request (Request) ->
    {ok, Pid} = gen_server:start (?MODULE, null, []),
    gen_server:call (Pid, Request).

do_action (Action) ->
    {ok, Pid} = gen_server:start (?MODULE, null, []),
    gen_server:cast (Pid, Action).

handle_cast ({add_group, GroupName, Description}, LoopData) ->
    GroupDocument = [{"name", GroupName},{"articles_count", 0}, {"low_bound",0}, {"high_bound",0}, {"short_descr", Description}, {"status","y"}],
    ok = emongo:insert (test1, "groups", GroupDocument),
    {noreply, LoopData};
 
 
handle_cast ({write, Message, ParsedMessage}, LoopData) ->
    Newsgroups = email_parser:email_get_header_i(ParsedMessage, "Newsgroups"),
    DateTime = try common_funcs:parse_datetime(email_parser:email_get_header_i ("Date")) of
                    V -> V
               catch
                    _:_ -> common_funcs:get_unix_timestamp(now())
               end,
    {Head, Body} = email_parser:split_message (Message),
    Headers = get_needed_headers(ParsedMessage),
    io:format ("HEADERS ~p~n", [Headers]),
    case proplists:lookup ("Message-ID", Headers) of
        {_Key, ""} ->
            MessageId = get_message_id(),
            NewHead = "Message-ID: " ++ MessageId ++ "\r\n" ++ Head,
            NewHeaders = lists:keyreplace ("Message-ID", 1, Headers, {"MESSAGE_ID", MessageId}),
            lists:map (
               fun (Group) ->
                {ok, ArticleNum} = sequence_srv:get_next_number(Group),
                Article= #article{head = NewHead, number=ArticleNum, id=MessageId, group=Group, time=DateTime, body=Body},
                db_routines:write_article (Article, NewHeaders),
                db_routines:inc_counters_in_group(Group, ArticleNum)
               end,
               Newsgroups);
        {_Key, Value} ->
            MessageId = Value,
            lists:map (
               fun (Group) ->
                {ok, ArticleNum} = sequence_srv:get_next_number(Group),
                Article= #article{head = Head, number=ArticleNum, id=MessageId, group=Group, time=DateTime, body=Body},
                db_routines:write_article (Article, Headers),
                db_routines:inc_counters_in_group(Group, ArticleNum)
               end,
               Newsgroups)
    end,
    {noreply, LoopData}.

handle_call ({article_numbers, GroupName}, _From, LoopData) ->
    Numbers = db_routines:get_all_group_article_numbers (GroupName), 
    {reply, {ok, Numbers}, LoopData};
 
handle_call ({article_numbers, GroupName, RangeFrom, RangeTo}, _From, LoopData) ->
    Numbers = db_routines:get_all_group_article_numbers_r (GroupName, RangeFrom, RangeTo),
    {reply, {ok, Numbers}, LoopData};

handle_call({first_number, GroupName}, _From, LoopData) ->
    Number = db_routines:get_group_first_number(GroupName), 
    {reply, {ok, round(Number)}, LoopData};

handle_call (group_names, _From, LoopData) ->
    Groups = db_routines:get_group_names(), 
    {reply, {ok, Groups}, LoopData};

handle_call (group_short_descrs, _From, LoopData) ->
    Descrs = db_routines:get_group_short_descrs(),
    {reply, {ok, Descrs}, LoopData};

handle_call (group_list_entries, _From, LoopData) ->
    Groups = db_routines:get_group_list_entries(),
    {reply, {ok, Groups}, LoopData};

handle_call ({get_group_info, GroupName}, _From, LoopData) ->
    ?LOG_INFO(io_lib:format("Processing request for group ~p \n", [GroupName])),
    {ok,Reply} = db_routines:get_group_info (GroupName),
    {reply, {ok,Reply}, LoopData};

handle_call ({read, GroupName, ArticleNum}, _From, LoopData) ->
    Article = db_routines:get_article (GroupName, ArticleNum),
    {reply, {ok, Article}, LoopData};

handle_call ({header_values, GroupName, ArticleNum}, _From, LoopData) ->
    Headers = db_routines:get_headers ({GroupName, ArticleNum}),
    HeaderValues = [Value || {_Name, Value} <- Headers],
    {reply, {ok, lists:append (HeaderValues, ["0","0"])}, LoopData}.

%%Client functions

write_article (Message, Parsed_Message) ->
    do_action({write, Message, Parsed_Message}),
    ok.

%%read_article ({article_id, ArticleID} ) ->
%%    ok;

read_article ({group_and_article_number, Group, ArticleNum}) ->
    {ok, _Article} = do_request({read, Group, ArticleNum}).

add_new_group (GroupName, Description) ->
    do_action ({add_group, GroupName, Description}).

get_group_info (GroupName) ->
    ?LOG_INFO (io_lib:format("Making request for group info ~p\n", [GroupName])),
    {ok, Group} = do_request({get_group_info, string:to_lower(GroupName)}),
    {group, Group}.

get_article_numbers_from_group (GroupName) ->
    {ok, Numbers} = do_request({article_numbers, GroupName}),
    lists:map (fun (X) ->
                 integer_to_list(X)
               end,
               Numbers).

get_article_numbers_from_group_r (GroupName, RangeFrom, RangeTo) ->
    {ok, Numbers} = do_request ({article_numbers, GroupName, RangeFrom, RangeTo}),
    lists:map (fun (X) ->
                integer_to_list(X)
               end,
               Numbers).

get_first_number_from_group (GroupName) ->
    {ok, Number} = do_request({first_number, GroupName}),
    Number.

get_group_names() ->
    {ok, Groups} = do_request (group_names),
    Groups.

get_group_descrs() ->
    {ok, Descrs} = do_request (group_short_descrs),
    Descrs.

get_group_list_entries () ->
    {ok, Groups} = do_request (group_list_entries),
    Groups.

get_header_values(GroupName, ArticleNum) ->
    {ok, Headers} = do_request ({header_values, GroupName, ArticleNum}),
    Headers.

get_message_id () ->
    DomainPart = "ltd.com",
    {A1, A2, A3} = now(),
    random:seed (A1,A2,A3),
    LocalPart = random:uniform (10000000),
    _Result = "<"++ integer_to_list(LocalPart) ++ "@" ++ DomainPart ++ ">".

get_needed_headers (ParsedMessage) ->
    Needed_headers  = ["Subject", "From", "Date", "Message-ID", "References"],
    io:format ("ParsedMessage=~p~n",[ParsedMessage]),
    lists:map (fun (HeaderName) ->
                    try email_parser:get_string_header_i (ParsedMessage, HeaderName) of
                        Value ->
                            {HeaderName, Value}
                    catch 
                        _:_ ->
                            {HeaderName, ""}
                    end
               end,
               Needed_headers).

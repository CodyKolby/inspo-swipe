create or replace function public.pipeline_select(p_secret text, p_table text, p_limit integer default 1000)
 returns jsonb language plpgsql security definer set search_path to '' as $function$
declare res jsonb;
begin
  if p_secret is null or not exists (select 1 from private.pipeline_secret s where s.secret = p_secret) then
    raise exception 'bad pipeline secret' using errcode = '42501';
  end if;
  if p_table not in ('videos','swipes','swipe_events','searches','creators','taste_notes',
                     'hooks','hook_swipes','hook_swipe_events','clips','edits','critic_notes',
                     'hook_library','hook_scout_library') then
    raise exception 'table % not allowed', p_table;
  end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (select * from public.%I limit %s) t', p_table, greatest(1, least(p_limit, 50000))) into res;
  return res;
end $function$;

create or replace function public.pipeline_upsert(p_secret text, p_table text, p_rows jsonb)
 returns integer language plpgsql security definer set search_path to '' as $function$
declare
  r jsonb; cols text[]; pk text; sql text; n int := 0;
begin
  if p_secret is null or not exists (select 1 from private.pipeline_secret s where s.secret = p_secret) then
    raise exception 'bad pipeline secret' using errcode = '42501';
  end if;
  pk := case p_table when 'videos' then 'id' when 'creators' then 'handle' when 'swipes' then 'video_id'
                     when 'searches' then null when 'taste_notes' then null when 'swipe_events' then null
                     when 'hooks' then 'id' when 'hook_swipes' then 'hook_id' when 'hook_swipe_events' then null
                     when 'clips' then 'id' when 'edits' then 'id' when 'critic_notes' then null
                     else 'x' end;
  if pk = 'x' then raise exception 'table % not allowed', p_table; end if;
  if jsonb_typeof(p_rows) = 'object' then p_rows := jsonb_build_array(p_rows); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    select array_agg(c.column_name::text order by c.ordinal_position) into cols
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = p_table and r ? c.column_name
       and c.is_identity = 'NO';
    if cols is null then continue; end if;
    sql := format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1)',
                  p_table,
                  (select string_agg(quote_ident(x), ',') from unnest(cols) x),
                  (select string_agg(quote_ident(x), ',') from unnest(cols) x),
                  p_table);
    if pk is not null then
      sql := sql || format(' on conflict (%I) do ', pk) ||
        coalesce((select 'update set ' || string_agg(format('%I = excluded.%I', x, x), ',') from unnest(cols) x where x <> pk), 'nothing');
    end if;
    if pk is not null and exists (select 1 from information_schema.columns c where c.table_schema='public' and c.table_name=p_table and c.column_name=pk) and (r ? pk) then
      declare found_row boolean; begin
        execute format('select exists (select 1 from public.%I where %I = $1)', p_table, pk) into found_row using r->>pk;
        if found_row then
          sql := format('update public.%I t set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1)) where t.%I = $1->>%L',
                        p_table,
                        (select string_agg(quote_ident(x), ',') from unnest(cols) x where x <> pk),
                        (select string_agg(quote_ident(x), ',') from unnest(cols) x where x <> pk),
                        p_table, pk, pk);
          if array_length(cols, 1) = 1 then sql := 'select 1'; end if;
        end if;
      end;
    end if;
    execute sql using r;
    n := n + 1;
  end loop;
  return n;
end $function$;

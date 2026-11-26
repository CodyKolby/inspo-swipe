-- Hook scout flow: hooks, hook swipes, clips, edits, critic notes, views for Hook Critic.
create type public.hook_status as enum ('found','liked','disliked','submitted','editing','edited','approved','rejected','posted');
create type public.edit_status as enum ('pending_review','approved','rejected');

create table public.hooks (
  id text primary key,                       -- platform_nativeId, e.g. tiktok_7312...
  url text not null,
  platform text not null default 'tiktok',
  creator text, creator_nickname text, creator_followers bigint,
  stats jsonb not null default '{}'::jsonb,  -- {views, likes, comments, shares, saves}
  posted_at timestamptz, added_at timestamptz not null default now(), duration_s numeric,
  hook_text text,                            -- on-screen hook, exact original wording
  hook_language text,                        -- e.g. en, pl, es
  hook_text_en text,                         -- English translation (= hook_text if already English)
  hook_pattern text,                         -- pattern name, e.g. "My X said Y if I Z"
  hook_template text,                        -- fill-in template, e.g. "My ___ said ___ if I ___"
  caption text, hashtags text[] not null default '{}',
  frame_url text, frame_time_s numeric, frame_description text,
  why_picked text, explore boolean not null default false,
  status public.hook_status not null default 'found',
  status_changed_at timestamptz not null default now(),
  submitted_at timestamptz,
  raw jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index hooks_status_idx on public.hooks (status, added_at desc);

create table public.hook_swipes (
  hook_id text primary key references public.hooks(id) on delete cascade,
  decision text not null check (decision in ('like','superlike','dislike')),
  reasons text[] not null default '{}', note text not null default '',
  swiped_at timestamptz not null default now(), updated_at timestamptz
);

create table public.hook_swipe_events (
  id bigint generated always as identity primary key,
  hook_id text not null,
  action text not null check (action in ('swipe','edit','undo','submit','unsubmit')),
  decision text, reasons text[], note text, client_ts timestamptz,
  created_at timestamptz not null default now()
);
create index hook_swipe_events_hook_idx on public.hook_swipe_events (hook_id, created_at);

create table public.clips (
  id text primary key,                       -- short slug, e.g. clip_01_running
  title text not null,
  description text not null,                 -- what Dominik is doing, e.g. "running and singing"
  activity text, setting text, mood text,
  text_space text,                           -- where the frame is empty enough for hook text (top/middle/bottom)
  storage text,                              -- r2 | drive
  url text, storage_key text,
  duration_s numeric, width int, height int,
  notes text, active boolean not null default true,
  raw jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table public.edits (
  id text primary key default gen_random_uuid()::text,
  hook_id text not null references public.hooks(id) on delete cascade,
  clip_id text references public.clips(id) on delete set null,
  adapted_hook_text text not null, language text not null default 'pl',
  adapted_hook_text_en text,
  caption text, hashtags text[] not null default '{}',
  video_url text, storage_key text, thumbnail_url text, duration_s numeric,
  status public.edit_status not null default 'pending_review',
  review_note text, reviewed_at timestamptz,
  target_platforms text[] not null default '{tiktok,instagram}',
  routed_to jsonb not null default '{"tiktok":"edits_chef","instagram":"trial_reels_agnt"}'::jsonb,
  posted jsonb not null default '{}'::jsonb,  -- {tiktok:{by,url,posted_at}, instagram:{...}}
  editor_notes text, raw jsonb,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index edits_hook_idx on public.edits (hook_id);
create index edits_clip_idx on public.edits (clip_id);
create index edits_status_idx on public.edits (status, created_at desc);

create table public.critic_notes (
  id bigint generated always as identity primary key,
  target_type text not null check (target_type in ('video','hook','edit')),
  target_id text not null,
  author text not null default 'hook_critic',
  verdict text check (verdict in ('APPROVE','REDO','NOTE')),
  scores jsonb,                              -- {stopping_power, clarity, curiosity, fit, natural_polish, avg}
  note text not null, rewrite text,
  created_at timestamptz not null default now()
);
create index critic_notes_target_idx on public.critic_notes (target_type, target_id, created_at desc);

-- updated_at
create or replace function public.tg_touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger hooks_touch before update on public.hooks for each row execute function public.tg_touch_updated_at();
create trigger clips_touch before update on public.clips for each row execute function public.tg_touch_updated_at();
create trigger edits_touch before update on public.edits for each row execute function public.tg_touch_updated_at();
create or replace function public.tg_hook_status_changed() returns trigger language plpgsql set search_path = '' as $$
begin if new.status is distinct from old.status then new.status_changed_at := now(); end if; return new; end $$;
create trigger hooks_status_changed before update on public.hooks for each row execute function public.tg_hook_status_changed();

-- A swipe moves the hook between found / liked / disliked (never touches later stages).
create or replace function public.tg_hook_swipe_status() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    update public.hooks set status = 'found' where id = old.hook_id and status in ('liked','disliked');
    return old;
  end if;
  update public.hooks set status = (case when new.decision = 'dislike' then 'disliked' else 'liked' end)::public.hook_status
   where id = new.hook_id and status in ('found','liked','disliked');
  return new;
end $$;
create trigger hook_swipes_status after insert or update or delete on public.hook_swipes
  for each row execute function public.tg_hook_swipe_status();

-- App RPCs (anon). Only allowed transitions.
create or replace function public.app_submit_hooks(p_ids text[]) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with u as (update public.hooks set status = 'submitted', submitted_at = now() where id = any(p_ids) and status = 'liked' returning id)
  insert into public.hook_swipe_events (hook_id, action) select id, 'submit' from u;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.app_unsubmit_hooks(p_ids text[]) returns integer
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  with u as (update public.hooks set status = 'liked', submitted_at = null where id = any(p_ids) and status = 'submitted' returning id)
  insert into public.hook_swipe_events (hook_id, action) select id, 'unsubmit' from u;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.app_review_edit(p_edit_id text, p_decision text, p_note text default '', p_platforms text[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare e public.edits; plats text[]; route jsonb;
begin
  if p_decision not in ('approve','reject') then raise exception 'decision must be approve or reject'; end if;
  select * into e from public.edits where id = p_edit_id for update;
  if not found then raise exception 'edit % not found', p_edit_id; end if;
  if e.status <> 'pending_review' then raise exception 'edit % already reviewed (%)', p_edit_id, e.status; end if;
  if p_decision = 'approve' then
    plats := coalesce((select array_agg(distinct x order by x) from unnest(coalesce(p_platforms, e.target_platforms)) x where x in ('tiktok','instagram')), '{}');
    if cardinality(plats) = 0 then raise exception 'pick at least one platform'; end if;
    select coalesce(jsonb_object_agg(x, case x when 'tiktok' then 'edits_chef' else 'trial_reels_agnt' end), '{}'::jsonb) into route from unnest(plats) x;
    update public.edits set status = 'approved', review_note = nullif(trim(coalesce(p_note,'')), ''), reviewed_at = now(),
           target_platforms = plats, routed_to = route where id = p_edit_id returning * into e;
    update public.hooks set status = 'approved' where id = e.hook_id;
  else
    update public.edits set status = 'rejected', review_note = nullif(trim(coalesce(p_note,'')), ''), reviewed_at = now()
     where id = p_edit_id returning * into e;
    update public.hooks set status = 'rejected' where id = e.hook_id
       and not exists (select 1 from public.edits x where x.hook_id = e.hook_id and x.status in ('pending_review','approved'));
  end if;
  return to_jsonb(e);
end $$;

-- RLS + grants
alter table public.hooks enable row level security;
alter table public.hook_swipes enable row level security;
alter table public.hook_swipe_events enable row level security;
alter table public.clips enable row level security;
alter table public.edits enable row level security;
alter table public.critic_notes enable row level security;
revoke all on public.hooks, public.hook_swipes, public.hook_swipe_events, public.clips, public.edits, public.critic_notes from anon, authenticated;
grant select on public.hooks, public.clips, public.edits, public.critic_notes to anon;
grant select, insert, update, delete on public.hook_swipes to anon;
grant insert on public.hook_swipe_events to anon;
create policy anon_read_hooks on public.hooks for select to anon using (true);
create policy anon_read_clips on public.clips for select to anon using (true);
create policy anon_read_edits on public.edits for select to anon using (true);
create policy anon_read_critic_notes on public.critic_notes for select to anon using (true);
create policy anon_read_hook_swipes on public.hook_swipes for select to anon using (true);
create policy anon_insert_hook_swipes on public.hook_swipes for insert to anon with check (true);
create policy anon_update_hook_swipes on public.hook_swipes for update to anon using (true) with check (true);
create policy anon_delete_hook_swipes on public.hook_swipes for delete to anon using (true);
create policy anon_insert_hook_swipe_events on public.hook_swipe_events for insert to anon with check (true);
revoke all on function public.app_submit_hooks(text[]), public.app_unsubmit_hooks(text[]), public.app_review_edit(text,text,text,text[]) from public;
grant execute on function public.app_submit_hooks(text[]), public.app_unsubmit_hooks(text[]), public.app_review_edit(text,text,text,text[]) to anon;
revoke all on function public.tg_hook_swipe_status(), public.tg_touch_updated_at(), public.tg_hook_status_changed() from public, anon, authenticated;

-- Views for Hook Critic (security_invoker: obey the RLS of the underlying tables)
create view public.hook_library with (security_invoker = true) as
select v.id, v.url, v.platform, v.creator, v.creator_followers, v.stats, v.posted_at, v.duration_s,
       v.caption, v.hashtags, v.hook as scout_hook, v.format,
       v.description->>'one_liner' as one_liner,
       v.description->>'language' as language,
       v.description->'hook'->>'on_screen_text_original' as hook_on_screen_text,
       v.description->'hook'->>'on_screen_text_en' as hook_on_screen_text_en,
       v.description->'hook'->>'spoken_original' as hook_spoken,
       v.description->'hook'->>'spoken_en' as hook_spoken_en,
       v.description->'hook'->>'visual' as hook_visual,
       v.description->'hook'->>'sound' as hook_sound,
       v.description->'hook'->>'tension_created' as hook_tension,
       coalesce(jsonb_path_query_array(v.description->'timeline', '$[*] ? (@.t_start < 3)'), '[]'::jsonb) as timeline_first_3s,
       v.description->>'mechanic' as mechanic,
       v.description->'structure' as structure,
       v.description->>'payoff_and_loop' as payoff_and_loop,
       v.description->'music_slot' as music_slot,
       v.description->'red_flags' as red_flags,
       v.description->'scores' as scores,
       (v.description->'scores'->'hook'->>'score')::int as score_hook,
       v.description->'scores'->'hook'->>'reason' as score_hook_reason,
       s.decision, s.reasons, s.note, s.swiped_at,
       (select coalesce(jsonb_agg(jsonb_build_object('verdict', c.verdict, 'scores', c.scores, 'note', c.note, 'rewrite', c.rewrite, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
          from public.critic_notes c where c.target_type = 'video' and c.target_id = v.id) as critic_notes,
       v.described_at, v.added_at
  from public.videos v left join public.swipes s on s.video_id = v.id;

create view public.hook_scout_library with (security_invoker = true) as
select h.id, h.url, h.platform, h.creator, h.creator_followers, h.stats, h.posted_at, h.duration_s,
       h.hook_text, h.hook_language, h.hook_text_en, h.hook_pattern, h.hook_template,
       h.caption, h.hashtags, h.frame_url, h.frame_description, h.status, h.status_changed_at,
       s.decision, s.reasons, s.note, s.swiped_at,
       (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'clip_id', e.clip_id, 'adapted_hook_text', e.adapted_hook_text, 'language', e.language,
                 'status', e.status, 'review_note', e.review_note, 'target_platforms', e.target_platforms, 'posted', e.posted, 'created_at', e.created_at) order by e.created_at desc), '[]'::jsonb)
          from public.edits e where e.hook_id = h.id) as edits,
       (select coalesce(jsonb_agg(jsonb_build_object('verdict', c.verdict, 'scores', c.scores, 'note', c.note, 'rewrite', c.rewrite, 'created_at', c.created_at) order by c.created_at desc), '[]'::jsonb)
          from public.critic_notes c where c.target_type = 'hook' and c.target_id = h.id) as critic_notes,
       h.added_at
  from public.hooks h left join public.hook_swipes s on s.hook_id = h.id;

revoke all on public.hook_library, public.hook_scout_library from anon, authenticated;
grant select on public.hook_library, public.hook_scout_library to anon;

-- applied separately as revoke_app_rpcs_authenticated
revoke execute on function public.app_submit_hooks(text[]), public.app_unsubmit_hooks(text[]), public.app_review_edit(text,text,text,text[]) from authenticated;

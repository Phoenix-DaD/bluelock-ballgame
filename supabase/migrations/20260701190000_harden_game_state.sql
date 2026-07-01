create index if not exists friends_friend_id_idx on public.friends(friend_id);
create index if not exists friends_user_id_idx on public.friends(user_id);
create index if not exists parties_leader_id_idx on public.parties(leader_id);
create index if not exists multiplayer_rooms_host_id_idx on public.multiplayer_rooms(host_id);
create index if not exists ranked_history_user_id_idx on public.ranked_history(user_id);
create index if not exists ranked_history_room_id_idx on public.ranked_history(room_id);

drop policy if exists "Users can view own stats" on public.player_stats;
drop policy if exists "Users can insert own stats" on public.player_stats;
drop policy if exists "Users can update own stats" on public.player_stats;
create policy "Users can view own stats"
  on public.player_stats for select
  to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can view own characters" on public.player_characters;
drop policy if exists "Users can insert own characters" on public.player_characters;
drop policy if exists "Users can update own characters" on public.player_characters;
drop policy if exists "Users can delete own characters" on public.player_characters;
create policy "Users can view own characters"
  on public.player_characters for select
  to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists friends_select on public.friends;
drop policy if exists friends_insert on public.friends;
drop policy if exists friends_update on public.friends;
drop policy if exists friends_delete on public.friends;
create policy friends_select
  on public.friends for select
  to authenticated
  using (user_id = (select auth.uid()) or friend_id = (select auth.uid()));
create policy friends_insert
  on public.friends for insert
  to authenticated
  with check (user_id = (select auth.uid()) and friend_id <> (select auth.uid()) and status = 'pending');
create policy friends_update
  on public.friends for update
  to authenticated
  using (friend_id = (select auth.uid()))
  with check (user_id <> (select auth.uid()) and friend_id = (select auth.uid()) and status in ('accepted', 'blocked'));
create policy friends_delete
  on public.friends for delete
  to authenticated
  using (user_id = (select auth.uid()) or friend_id = (select auth.uid()));

create or replace function public.prevent_friend_participant_changes()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.user_id is distinct from old.user_id or new.friend_id is distinct from old.friend_id then
    raise exception 'Friend participants cannot be changed' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_friend_participant_changes on public.friends;
create trigger prevent_friend_participant_changes
before update on public.friends
for each row
execute function public.prevent_friend_participant_changes();

create schema if not exists private;

create or replace function private.ensure_player_data()
returns public.player_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  stats_row public.player_stats;
  today date := current_date;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  insert into public.player_stats (user_id, daily_rolls, bonus_rolls, last_roll_reset)
  values (uid, 5, 0, today)
  on conflict (user_id) do nothing;

  select * into stats_row
  from public.player_stats
  where user_id = uid
  for update;

  if stats_row.last_roll_reset is distinct from today then
    update public.player_stats
    set daily_rolls = 5,
        last_roll_reset = today
    where user_id = uid
    returning * into stats_row;
  end if;

  return stats_row;
end;
$$;

create or replace function private.roll_egoist()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  stats_row public.player_stats;
  char_row public.player_characters;
  total_rolls integer;
  roll_value double precision;
  chosen_rarity text;
  chosen_key text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  stats_row := private.ensure_player_data();

  select * into stats_row
  from public.player_stats
  where user_id = uid
  for update;

  total_rolls := coalesce(stats_row.daily_rolls, 0) + coalesce(stats_row.bonus_rolls, 0);
  if total_rolls <= 0 then
    raise exception 'No rolls remaining' using errcode = 'P0001';
  end if;

  roll_value := random() * 100;
  if roll_value < 5 then
    chosen_rarity := 'Legendary';
    chosen_key := (array['rin', 'nagi', 'barou'])[floor(random() * 3)::int + 1];
  elsif roll_value < 20 then
    chosen_rarity := 'Epic';
    chosen_key := 'bachira';
  elsif roll_value < 50 then
    chosen_rarity := 'Rare';
    chosen_key := 'chigiri';
  else
    chosen_rarity := 'Common';
    chosen_key := 'isagi';
  end if;

  delete from public.player_characters where user_id = uid;
  insert into public.player_characters (user_id, character_key, rarity)
  values (uid, chosen_key, chosen_rarity)
  returning * into char_row;

  if coalesce(stats_row.daily_rolls, 0) > 0 then
    update public.player_stats
    set daily_rolls = daily_rolls - 1
    where user_id = uid
    returning * into stats_row;
  else
    update public.player_stats
    set bonus_rolls = bonus_rolls - 1
    where user_id = uid
    returning * into stats_row;
  end if;

  return jsonb_build_object('character', to_jsonb(char_row), 'stats', to_jsonb(stats_row));
end;
$$;

create or replace function private.find_player_by_display_name(p_display_name text)
returns table(user_id uuid, display_name text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  return query
  select ps.user_id, ps.display_name
  from public.player_stats ps
  where ps.display_name = p_display_name
    and ps.user_id <> auth.uid()
  limit 1;
end;
$$;

create or replace function public.ensure_player_data()
returns public.player_stats
language sql
security invoker
set search_path = public, private
as $$ select private.ensure_player_data(); $$;

create or replace function public.roll_egoist()
returns jsonb
language sql
security invoker
set search_path = public, private
as $$ select private.roll_egoist(); $$;

create or replace function public.find_player_by_display_name(p_display_name text)
returns table(user_id uuid, display_name text)
language sql
security invoker
set search_path = public, private
as $$ select * from private.find_player_by_display_name(p_display_name); $$;

revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

revoke all on function private.ensure_player_data() from public, anon;
revoke all on function private.roll_egoist() from public, anon;
revoke all on function private.find_player_by_display_name(text) from public, anon;
grant execute on function private.ensure_player_data() to authenticated;
grant execute on function private.roll_egoist() to authenticated;
grant execute on function private.find_player_by_display_name(text) to authenticated;

revoke all on function public.ensure_player_data() from public, anon;
revoke all on function public.roll_egoist() from public, anon;
revoke all on function public.find_player_by_display_name(text) from public, anon;
grant execute on function public.ensure_player_data() to authenticated;
grant execute on function public.roll_egoist() to authenticated;
grant execute on function public.find_player_by_display_name(text) to authenticated;

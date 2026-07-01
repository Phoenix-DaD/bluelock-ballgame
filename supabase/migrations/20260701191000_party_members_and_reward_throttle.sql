alter table public.player_stats
  add column if not exists last_vs_result_at timestamp with time zone;

create table if not exists public.party_members (
  party_id uuid not null references public.parties(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text,
  joined_at timestamp with time zone default now(),
  primary key (party_id, user_id)
);

alter table public.party_members enable row level security;

create index if not exists party_members_user_id_idx on public.party_members(user_id);
create index if not exists party_members_party_id_idx on public.party_members(party_id);

insert into public.party_members (party_id, user_id, display_name)
select p.id, (m.value ->> 'user_id')::uuid, nullif(m.value ->> 'display_name', '')
from public.parties p
cross join lateral jsonb_array_elements(coalesce(p.members, '[]'::jsonb)) as m(value)
where (m.value ->> 'user_id') is not null
on conflict (party_id, user_id) do nothing;

drop policy if exists party_members_select on public.party_members;
drop policy if exists party_members_insert on public.party_members;
drop policy if exists party_members_update on public.party_members;
drop policy if exists party_members_delete on public.party_members;

create policy party_members_select
  on public.party_members for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (select 1 from public.parties p where p.id = party_members.party_id and p.leader_id = (select auth.uid()))
  );

create policy party_members_insert
  on public.party_members for insert
  to authenticated
  with check (
    exists (
      select 1 from public.parties p
      where p.id = party_members.party_id
        and p.leader_id = (select auth.uid())
        and p.status = 'open'
    )
  );

create policy party_members_update
  on public.party_members for update
  to authenticated
  using (exists (select 1 from public.parties p where p.id = party_members.party_id and p.leader_id = (select auth.uid())))
  with check (exists (select 1 from public.parties p where p.id = party_members.party_id and p.leader_id = (select auth.uid())));

create policy party_members_delete
  on public.party_members for delete
  to authenticated
  using (
    user_id = (select auth.uid())
    or exists (select 1 from public.parties p where p.id = party_members.party_id and p.leader_id = (select auth.uid()))
  );

drop policy if exists parties_select on public.parties;
create policy parties_select
  on public.parties for select
  to authenticated
  using (
    leader_id = (select auth.uid())
    or exists (select 1 from public.party_members pm where pm.party_id = parties.id and pm.user_id = (select auth.uid()))
    or exists (
      select 1
      from jsonb_array_elements(parties.members) as m(value)
      where (m.value ->> 'user_id') = ((select auth.uid())::text)
    )
  );

create or replace function private.record_vs_result(
  p_result text,
  p_difficulty text default 'medium',
  p_clean_sheet boolean default false
)
returns public.player_stats
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  stats_row public.player_stats;
  yen_reward integer := 0;
  spin_reward integer := 0;
  min_claim_gap interval := interval '45 seconds';
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if p_result not in ('win', 'loss') then
    raise exception 'Invalid result' using errcode = '22023';
  end if;
  if p_difficulty not in ('easy', 'medium', 'hard') then
    raise exception 'Invalid difficulty' using errcode = '22023';
  end if;

  stats_row := private.ensure_player_data();

  select * into stats_row
  from public.player_stats
  where user_id = uid
  for update;

  if stats_row.last_vs_result_at is not null and now() - stats_row.last_vs_result_at < min_claim_gap then
    raise exception 'Match result submitted too quickly. Please finish a real match before claiming another reward.' using errcode = 'P0001';
  end if;

  if p_result = 'win' then
    yen_reward := case p_difficulty when 'easy' then 100 when 'medium' then 300 else 500 end;
    spin_reward := case p_difficulty when 'easy' then 0 when 'medium' then 1 else 2 end;
    if p_clean_sheet then
      spin_reward := spin_reward + 1;
    end if;

    update public.player_stats
    set wins = coalesce(wins, 0) + 1,
        total_games = coalesce(total_games, 0) + 1,
        bonus_rolls = coalesce(bonus_rolls, 0) + spin_reward,
        yen = coalesce(yen, 0) + yen_reward,
        last_vs_result_at = now()
    where user_id = uid
    returning * into stats_row;
  else
    update public.player_stats
    set losses = coalesce(losses, 0) + 1,
        total_games = coalesce(total_games, 0) + 1,
        last_vs_result_at = now()
    where user_id = uid
    returning * into stats_row;
  end if;

  return stats_row;
end;
$$;

create or replace function public.record_vs_result(
  p_result text,
  p_difficulty text default 'medium',
  p_clean_sheet boolean default false
)
returns public.player_stats
language sql
security invoker
set search_path = public, private
as $$ select private.record_vs_result(p_result, p_difficulty, p_clean_sheet); $$;

revoke all on function private.record_vs_result(text, text, boolean) from public, anon;
grant execute on function private.record_vs_result(text, text, boolean) to authenticated;
revoke all on function public.record_vs_result(text, text, boolean) from public, anon;
grant execute on function public.record_vs_result(text, text, boolean) to authenticated;

create or replace function private.get_open_party()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  party_row public.parties;
  members_json jsonb := '[]'::jsonb;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select * into party_row
  from public.parties
  where leader_id = uid
    and status = 'open'
  order by created_at desc
  limit 1;

  if party_row.id is null then
    select p.* into party_row
    from public.party_members pm
    join public.parties p on p.id = pm.party_id
    where pm.user_id = uid
      and p.status = 'open'
    order by p.created_at desc
    limit 1;
  end if;

  if party_row.id is null then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('user_id', pm.user_id, 'display_name', pm.display_name) order by pm.joined_at), '[]'::jsonb)
  into members_json
  from public.party_members pm
  where pm.party_id = party_row.id;

  return jsonb_build_object('party', to_jsonb(party_row), 'members', members_json);
end;
$$;

create or replace function public.get_open_party()
returns jsonb
language sql
security invoker
set search_path = public, private
as $$ select private.get_open_party(); $$;

revoke all on function private.get_open_party() from public, anon;
grant execute on function private.get_open_party() to authenticated;
revoke all on function public.get_open_party() from public, anon;
grant execute on function public.get_open_party() to authenticated;

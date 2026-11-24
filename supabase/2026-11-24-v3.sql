-- v3: closing stage (lock while scoring), round timer, unique names per room, late join, rejoin codes
alter table public.invest_rooms drop constraint if exists invest_rooms_stage_check;
alter table public.invest_rooms add constraint invest_rooms_stage_check check (stage in ('lobby','round','closing','reveal','final'));
alter table public.invest_rooms add column if not exists deadline timestamptz;
create unique index if not exists invest_players_room_name_key on public.invest_players (room_id, lower(btrim(name)));
drop policy if exists players_join on public.invest_players;
create policy players_join on public.invest_players for insert to anon with check (private.token_hash() is not null and balance = 2000000 and exists (select 1 from public.invest_rooms r where r.id = invest_players.room_id and r.stage <> 'final'));
create table if not exists private.rejoin_codes (player_id uuid primary key references public.invest_players(id) on delete cascade, code text not null, tries int not null default 0, created_at timestamptz not null default now());
alter table private.rejoin_codes enable row level security;
create or replace function public.issue_rejoin_code(p_player uuid) returns text language plpgsql security definer set search_path = '' as $$ declare v_room uuid; v_code text; begin select room_id into v_room from public.invest_players where id = p_player; if v_room is null or not private.is_host(v_room) then raise exception 'Not allowed'; end if; v_code := lpad(floor(random() * 10000)::int::text, 4, '0'); insert into private.rejoin_codes (player_id, code, tries, created_at) values (p_player, v_code, 0, now()) on conflict (player_id) do update set code = excluded.code, tries = 0, created_at = now(); return v_code; end $$;
create or replace function public.claim_player(p_room_code text, p_name text, p_code text) returns uuid language plpgsql security definer set search_path = '' as $$ declare v_player uuid; v_ok boolean; t text := private.token_hash(); begin if t is null then raise exception 'A valid game session is required'; end if; select p.id into v_player from public.invest_players p join public.invest_rooms r on r.id = p.room_id where r.code = upper(btrim(p_room_code)) and lower(btrim(p.name)) = lower(btrim(p_name)); if v_player is null then return null; end if; select (c.code = btrim(p_code) and c.tries < 5 and c.created_at > now() - interval '30 minutes') into v_ok from private.rejoin_codes c where c.player_id = v_player; if v_ok is not true then update private.rejoin_codes set tries = tries + 1 where player_id = v_player; return null; end if; insert into private.player_owners (player_id, token_hash) values (v_player, t) on conflict (player_id) do update set token_hash = excluded.token_hash; delete from private.rejoin_codes where player_id = v_player; return v_player; end $$;
revoke all on function public.issue_rejoin_code(uuid) from public;
revoke all on function public.claim_player(text, text, text) from public;
grant execute on function public.issue_rejoin_code(uuid) to anon;
grant execute on function public.claim_player(text, text, text) to anon;
notify pgrst, 'reload schema';

-- ============================================================
-- RCM Quest v5 - Shared Backend for Employee Site + Admin Site
-- ============================================================
-- Run this in a NEW/EMPTY Supabase project's SQL Editor.
-- Enable Anonymous Sign-Ins in Supabase Authentication first.
--
-- IMPORTANT:
-- The requested prototype admin gate is Name + Email only.
-- That is convenient but not strong identity verification.
-- For production administration, replace this with Microsoft Entra ID / SSO.

create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  email text primary key,
  display_name text not null,
  active boolean not null default true
);

insert into public.admin_users(email,display_name,active)
values ('shafeeks@healthreconconnect.com','Shafeek Sadiq',true)
on conflict (email) do update set display_name=excluded.display_name, active=true;

create table if not exists public.challenges (
  id text primary key,
  label text not null,
  title text not null,
  topic text not null,
  description text,
  starts_on date not null,
  ends_on date not null,
  status text not null check (status in ('draft','published','archived')),
  created_by_email text,
  updated_at timestamptz not null default now()
);

create table if not exists public.challenge_entries (
  id bigint generated always as identity primary key,
  challenge_id text not null references public.challenges(id) on delete cascade,
  answer text not null,
  clue text not null,
  direction text not null check(direction in ('across','down')),
  row_no integer not null,
  col_no integer not null,
  clue_number integer not null
);

create table if not exists public.attempts (
  id uuid primary key default gen_random_uuid(),
  challenge_id text not null references public.challenges(id) on delete cascade,
  user_id uuid not null,
  display_name text not null,
  email text not null,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  elapsed_ms bigint,
  created_at timestamptz not null default now()
);

create unique index if not exists attempts_challenge_email_uq
  on public.attempts(challenge_id, lower(email));

create index if not exists attempts_board_idx
  on public.attempts(challenge_id, completed_at, elapsed_ms);

alter table public.admin_users enable row level security;
alter table public.challenges enable row level security;
alter table public.challenge_entries enable row level security;
alter table public.attempts enable row level security;

-- Employees can read leaderboard rows after an anonymous authenticated session.
drop policy if exists "read attempts" on public.attempts;
create policy "read attempts" on public.attempts for select to authenticated using(true);

create or replace function public.is_requested_admin(p_name text,p_email text)
returns boolean
language sql
security definer
set search_path=public
as $$
 select exists(
   select 1 from public.admin_users
   where lower(email)=lower(trim(p_email))
     and lower(display_name)=lower(trim(p_name))
     and active=true
 );
$$;

grant execute on function public.is_requested_admin(text,text) to authenticated;

create or replace function public.get_active_challenge()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare c public.challenges%rowtype; e jsonb;
begin
 select * into c
 from public.challenges
 where status='published'
   and current_date between starts_on and ends_on
 order by starts_on desc
 limit 1;

 if c.id is null then return jsonb_build_object('challenge',null,'entries','[]'::jsonb); end if;

 select coalesce(jsonb_agg(jsonb_build_object(
   'answer',answer,'clue',clue,'direction',direction,'row',row_no,'col',col_no,'number',clue_number
 ) order by clue_number),'[]'::jsonb) into e
 from public.challenge_entries where challenge_id=c.id;

 return jsonb_build_object(
   'challenge',jsonb_build_object(
     'id',c.id,'label',c.label,'title',c.title,'topic',c.topic,'description',c.description,
     'starts_on',c.starts_on,'ends_on',c.ends_on,'status',c.status
   ),
   'entries',e
 );
end;
$$;

grant execute on function public.get_active_challenge() to authenticated;

create or replace function public.start_attempt(
 p_challenge_id text,p_display_name text,p_email text
)
returns table(attempt_id uuid,started_at timestamptz,completed_at timestamptz,elapsed_ms bigint)
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid:=auth.uid(); v_email text:=lower(trim(p_email)); r public.attempts%rowtype; open_ok boolean;
begin
 if uid is null then raise exception 'Session required'; end if;
 if v_email not like '%@healthreconconnect.com' then raise exception 'Only HRC email addresses are permitted'; end if;

 select exists(select 1 from public.challenges where id=p_challenge_id and status='published' and current_date between starts_on and ends_on)
 into open_ok;
 if not open_ok then raise exception 'Challenge is not currently open'; end if;

 insert into public.attempts(challenge_id,user_id,display_name,email)
 values(p_challenge_id,uid,left(trim(p_display_name),120),v_email)
 on conflict(challenge_id,(lower(email))) do update
 set user_id=excluded.user_id,display_name=excluded.display_name
 returning * into r;

 return query select r.id,r.started_at,r.completed_at,r.elapsed_ms;
end;
$$;
grant execute on function public.start_attempt(text,text,text) to authenticated;

create or replace function public.finish_attempt(p_challenge_id text)
returns table(attempt_id uuid,started_at timestamptz,completed_at timestamptz,elapsed_ms bigint)
language plpgsql
security definer
set search_path=public
as $$
declare uid uuid:=auth.uid(); r public.attempts%rowtype;
begin
 update public.attempts
 set completed_at=coalesce(completed_at,now()),
     elapsed_ms=coalesce(elapsed_ms,floor(extract(epoch from(now()-started_at))*1000)::bigint)
 where challenge_id=p_challenge_id and user_id=uid
 returning * into r;
 if r.id is null then raise exception 'Attempt not started'; end if;
 return query select r.id,r.started_at,r.completed_at,r.elapsed_ms;
end;
$$;
grant execute on function public.finish_attempt(text) to authenticated;

create or replace function public.get_leaderboard(p_challenge_id text)
returns table(display_name text,elapsed_ms bigint)
language sql
security definer
set search_path=public
as $$
 select display_name,elapsed_ms from public.attempts
 where challenge_id=p_challenge_id and completed_at is not null and elapsed_ms is not null
 order by elapsed_ms asc limit 200;
$$;
grant execute on function public.get_leaderboard(text) to authenticated;

create or replace function public.get_challenge_history()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare out_json jsonb;
begin
 select coalesce(jsonb_agg(x order by x->>'starts_on' desc),'[]'::jsonb) into out_json
 from (
   select jsonb_build_object(
     'challenge_id',c.id,'label',c.label,'title',c.title,'topic',c.topic,'starts_on',c.starts_on,
     'winners',coalesce((
       select jsonb_agg(jsonb_build_object('display_name',q.display_name,'elapsed_ms',q.elapsed_ms) order by q.elapsed_ms)
       from (select display_name,elapsed_ms from public.attempts a where a.challenge_id=c.id and a.completed_at is not null order by elapsed_ms limit 3) q
     ),'[]'::jsonb)
   ) x
   from public.challenges c
   where c.status='archived' or c.ends_on<current_date
 ) s;
 return out_json;
end;
$$;
grant execute on function public.get_challenge_history() to authenticated;

-- ---------------- ADMIN FUNCTIONS ----------------

create or replace function public.admin_list_challenges(p_admin_name text,p_admin_email text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare out_json jsonb;
begin
 if not public.is_requested_admin(p_admin_name,p_admin_email) then raise exception 'Admin access denied'; end if;
 select coalesce(jsonb_agg(obj order by (obj->>'starts_on') desc),'[]'::jsonb) into out_json
 from (
   select jsonb_build_object(
    'id',c.id,'label',c.label,'title',c.title,'topic',c.topic,'description',c.description,
    'starts_on',c.starts_on,'ends_on',c.ends_on,'status',c.status,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
       'answer',e.answer,'clue',e.clue,'direction',e.direction,'row',e.row_no,'col',e.col_no,'number',e.clue_number
    ) order by e.clue_number) from public.challenge_entries e where e.challenge_id=c.id),'[]'::jsonb)
   ) obj from public.challenges c
 ) q;
 return out_json;
end;
$$;
grant execute on function public.admin_list_challenges(text,text) to authenticated;

create or replace function public.admin_save_challenge(p_admin_name text,p_admin_email text,p_payload jsonb)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare cid text:=p_payload->>'id'; ent jsonb;
begin
 if not public.is_requested_admin(p_admin_name,p_admin_email) then raise exception 'Admin access denied'; end if;

 if p_payload->>'status'='published' then
   update public.challenges set status='archived',updated_at=now() where status='published' and id<>cid;
 end if;

 insert into public.challenges(id,label,title,topic,description,starts_on,ends_on,status,created_by_email,updated_at)
 values(
   cid,p_payload->>'label',p_payload->>'title',p_payload->>'topic',p_payload->>'description',
   (p_payload->>'starts_on')::date,(p_payload->>'ends_on')::date,p_payload->>'status',
   lower(p_admin_email),now()
 )
 on conflict(id) do update set
   label=excluded.label,title=excluded.title,topic=excluded.topic,description=excluded.description,
   starts_on=excluded.starts_on,ends_on=excluded.ends_on,status=excluded.status,updated_at=now();

 delete from public.challenge_entries where challenge_id=cid;
 for ent in select * from jsonb_array_elements(coalesce(p_payload->'entries','[]'::jsonb))
 loop
   insert into public.challenge_entries(challenge_id,answer,clue,direction,row_no,col_no,clue_number)
   values(cid,ent->>'answer',ent->>'clue',ent->>'direction',(ent->>'row')::int,(ent->>'col')::int,(ent->>'number')::int);
 end loop;
 return true;
end;
$$;
grant execute on function public.admin_save_challenge(text,text,jsonb) to authenticated;

create or replace function public.admin_delete_challenge(p_admin_name text,p_admin_email text,p_challenge_id text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
 if not public.is_requested_admin(p_admin_name,p_admin_email) then raise exception 'Admin access denied'; end if;
 delete from public.challenges where id=p_challenge_id;
 return true;
end;
$$;
grant execute on function public.admin_delete_challenge(text,text,text) to authenticated;

create or replace function public.admin_get_leaderboard(p_admin_name text,p_admin_email text,p_challenge_id text)
returns table(display_name text,email text,elapsed_ms bigint)
language plpgsql
security definer
set search_path=public
as $$
begin
 if not public.is_requested_admin(p_admin_name,p_admin_email) then raise exception 'Admin access denied'; end if;
 return query select a.display_name,a.email,a.elapsed_ms from public.attempts a where a.challenge_id=p_challenge_id and a.completed_at is not null order by a.elapsed_ms;
end;
$$;
grant execute on function public.admin_get_leaderboard(text,text,text) to authenticated;

create or replace function public.admin_reset_leaderboard(p_admin_name text,p_admin_email text,p_challenge_id text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
 if not public.is_requested_admin(p_admin_name,p_admin_email) then raise exception 'Admin access denied'; end if;
 delete from public.attempts where challenge_id=p_challenge_id;
 return true;
end;
$$;
grant execute on function public.admin_reset_leaderboard(text,text,text) to authenticated;

-- Seed the first published challenge after setup from the Admin Console.

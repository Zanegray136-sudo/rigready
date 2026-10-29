-- =====================================================================
-- RigReady database setup
-- Run this ONCE in a new Supabase project: SQL Editor → New query → paste → Run
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- People & roles ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text,
  email       text,
  role        text not null default 'pending' check (role in ('pending','tech','admin')),
  created_at  timestamptz not null default now()
);

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('tech','admin'));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- New sign-ups get a profile. The very first account becomes admin; everyone after is "pending" until approved.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role)
  values (new.id, new.email,
          coalesce(nullif(new.raw_user_meta_data->>'name', ''), split_part(new.email, '@', 1)),
          case when exists (select 1 from public.profiles) then 'pending' else 'admin' end);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- Only admins can change someone's role (people can still edit their own name).
create or replace function public.guard_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only admins can change access levels';
  end if;
  return new;
end $$;

create trigger profiles_guard_role
  before update on public.profiles for each row execute function public.guard_role();

-- ---------- Items (fixtures & consoles) ----------
create table public.assets (
  id            uuid primary key default gen_random_uuid(),
  tag           text not null,                 -- the value in your QR code
  serial        text,
  category      text not null default 'Fixture',
  make          text,
  model         text,
  location      text,
  status        text not null default 'OK' check (status in ('OK','Faulty','In repair','Out of service','Retired')),
  faulty_since  timestamptz,                   -- drives the "faulty over 2 months" alert
  lamp_hours    numeric,
  fixture_hours numeric,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.profiles(id) on delete set null
);
create unique index assets_tag_unique on public.assets (lower(tag));

-- Keeps faulty_since accurate no matter how status is changed.
create or replace function public.assets_track_status() returns trigger
language plpgsql as $$
begin
  if new.status in ('Faulty','In repair','Out of service') then
    if tg_op = 'UPDATE' and old.status in ('Faulty','In repair','Out of service') then
      new.faulty_since := coalesce(old.faulty_since, now());
    elsif tg_op = 'UPDATE' then
      new.faulty_since := now();
    else
      new.faulty_since := coalesce(new.faulty_since, now());
    end if;
  else
    new.faulty_since := null;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger assets_status
  before insert or update on public.assets for each row execute function public.assets_track_status();

-- ---------- Service schedules ----------
create table public.schedules (
  id              uuid primary key default gen_random_uuid(),
  asset_id        uuid references public.assets(id) on delete cascade,  -- one item…
  make            text,                                                 -- …or every item of a make/model
  model           text,
  task            text not null,
  interval_days   int check (interval_days > 0),
  interval_hours  numeric check (interval_hours > 0),
  hours_basis     text not null default 'lamp' check (hours_basis in ('lamp','fixture')),
  created_at      timestamptz not null default now(),
  check (interval_days is not null or interval_hours is not null),
  check (asset_id is not null or (make is not null and model is not null))
);

-- ---------- Maintenance log ----------
create table public.logs (
  id            uuid primary key default gen_random_uuid(),
  asset_id      uuid not null references public.assets(id) on delete cascade,
  kind          text not null check (kind in ('Fault','Repair','Service','Inspection','Note')),
  title         text not null,
  details       text,
  parts         text,
  lamp_hours    numeric,
  fixture_hours numeric,
  status_after  text,
  schedule_id   uuid references public.schedules(id) on delete set null,
  photos        text[] not null default '{}',
  location      text,                          -- where the light was when this was logged
  tech_name     text,                          -- name from imported records (no account)
  source        text,                          -- e.g. 'excel-import'
  created_by    uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now()
);
create index logs_asset_idx on public.logs (asset_id, created_at desc);

-- ---------- Manuals ----------
create table public.manuals (
  id          uuid primary key default gen_random_uuid(),
  make        text not null,
  model       text,              -- blank = applies to every model from this make
  title       text not null,
  url         text,
  file_path   text,
  created_by  uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);

-- ---------- Access rules ----------
grant select, insert, update, delete on public.profiles, public.assets, public.schedules, public.logs, public.manuals to authenticated;

alter table public.profiles  enable row level security;
alter table public.assets    enable row level security;
alter table public.schedules enable row level security;
alter table public.logs      enable row level security;
alter table public.manuals   enable row level security;

create policy "profiles: read"   on public.profiles for select to authenticated using (public.is_member() or id = auth.uid());
create policy "profiles: update" on public.profiles for update to authenticated using (id = auth.uid() or public.is_admin());
create policy "profiles: delete" on public.profiles for delete to authenticated using (public.is_admin());

create policy "assets: read"   on public.assets for select to authenticated using (public.is_member());
create policy "assets: add"    on public.assets for insert to authenticated with check (public.is_member());
create policy "assets: edit"   on public.assets for update to authenticated using (public.is_member());
create policy "assets: delete" on public.assets for delete to authenticated using (public.is_admin());

create policy "schedules: read"   on public.schedules for select to authenticated using (public.is_member());
create policy "schedules: add"    on public.schedules for insert to authenticated with check (public.is_member());
create policy "schedules: edit"   on public.schedules for update to authenticated using (public.is_member());
create policy "schedules: delete" on public.schedules for delete to authenticated using (public.is_admin());

create policy "logs: read"   on public.logs for select to authenticated using (public.is_member());
create policy "logs: add"    on public.logs for insert to authenticated with check (public.is_member() and created_by = auth.uid());
create policy "logs: edit"   on public.logs for update to authenticated using (public.is_admin() or created_by = auth.uid());
create policy "logs: delete" on public.logs for delete to authenticated using (public.is_admin());

create policy "manuals: read"   on public.manuals for select to authenticated using (public.is_member());
create policy "manuals: add"    on public.manuals for insert to authenticated with check (public.is_member());
create policy "manuals: edit"   on public.manuals for update to authenticated using (public.is_admin());
create policy "manuals: delete" on public.manuals for delete to authenticated using (public.is_admin());

-- ---------- File storage (photos & manual PDFs) ----------
insert into storage.buckets (id, name, public) values ('photos','photos',false), ('manuals','manuals',false)
on conflict (id) do nothing;

create policy "files: read"   on storage.objects for select to authenticated using (bucket_id in ('photos','manuals') and public.is_member());
create policy "files: upload" on storage.objects for insert to authenticated with check (bucket_id in ('photos','manuals') and public.is_member());
create policy "files: delete" on storage.objects for delete to authenticated using (bucket_id in ('photos','manuals') and public.is_admin());

-- ---------- Spare parts ----------
create table if not exists public.parts (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  make           text,
  part_number    text,          -- manufacturer / fixture part number
  supplier_code  text,          -- e.g. ShowTech code
  fits           text,          -- which models it fits
  quantity       int  not null default 0 check (quantity >= 0),
  min_qty        int  not null default 0 check (min_qty >= 0),   -- low-stock alert level (0 = off)
  condition      text,
  unit_price     numeric,
  location       text,
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- Every stock movement: check-outs (negative), new stock (positive), returns, corrections
create table if not exists public.part_moves (
  id           uuid primary key default gen_random_uuid(),
  part_id      uuid not null references public.parts(id) on delete cascade,
  change       int  not null check (change <> 0),
  kind         text not null check (kind in ('checkout','restock','return','adjust')),
  person_name  text,                                                 -- who took it
  person_id    uuid references public.profiles(id) on delete set null,
  asset_id     uuid references public.assets(id) on delete set null, -- fixture it went into
  notes        text,
  created_by   uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now()
);
create index if not exists part_moves_part_idx  on public.part_moves (part_id, created_at desc);
create index if not exists part_moves_asset_idx on public.part_moves (asset_id);

-- Stock levels follow the movements, and can never go below zero
create or replace function public.part_moves_apply() returns trigger
language plpgsql security definer set search_path = public as $$
declare q int;
begin
  if tg_op = 'INSERT' then
    update public.parts set quantity = quantity + new.change, updated_at = now() where id = new.part_id returning quantity into q;
    return new;
  else
    update public.parts set quantity = quantity - old.change, updated_at = now() where id = old.part_id;
    return old;
  end if;
exception when check_violation then
  raise exception 'Not enough in stock for that.' using errcode = '23514';
end $$;
drop trigger if exists part_moves_stock on public.part_moves;
create trigger part_moves_stock after insert or delete on public.part_moves
  for each row execute function public.part_moves_apply();

grant select, insert, update, delete on public.parts, public.part_moves to authenticated;
alter table public.parts      enable row level security;
alter table public.part_moves enable row level security;

drop policy if exists "parts: read"   on public.parts;
drop policy if exists "parts: add"    on public.parts;
drop policy if exists "parts: edit"   on public.parts;
drop policy if exists "parts: delete" on public.parts;
create policy "parts: read"   on public.parts for select to authenticated using (public.is_member());
create policy "parts: add"    on public.parts for insert to authenticated with check (public.is_member());
create policy "parts: edit"   on public.parts for update to authenticated using (public.is_member());
create policy "parts: delete" on public.parts for delete to authenticated using (public.is_admin());

drop policy if exists "moves: read"   on public.part_moves;
drop policy if exists "moves: add"    on public.part_moves;
drop policy if exists "moves: delete" on public.part_moves;
create policy "moves: read"   on public.part_moves for select to authenticated using (public.is_member());
create policy "moves: add"    on public.part_moves for insert to authenticated with check (public.is_member() and created_by = auth.uid());
create policy "moves: delete" on public.part_moves for delete to authenticated using (public.is_admin());

-- Repairs sent out (ShowTech etc.)
create table if not exists public.repair_jobs (
  id             uuid primary key default gen_random_uuid(),
  asset_id       uuid not null references public.assets(id) on delete cascade,
  repairer       text not null default 'ShowTech',
  job_no         text,
  fault          text,
  sent_at        date not null default current_date,
  expected_back  date,
  returned_at    date,
  outcome        text check (outcome in ('Fixed','Still faulty','Written off')),
  cost           numeric check (cost >= 0),
  notes          text,
  created_by     uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now()
);
create index if not exists repair_jobs_asset_idx   on public.repair_jobs (asset_id, sent_at desc);
create index if not exists repair_jobs_open_idx    on public.repair_jobs (sent_at) where returned_at is null;
create index if not exists repair_jobs_created_idx on public.repair_jobs (created_by);

grant select, insert, update, delete on public.repair_jobs to authenticated;
alter table public.repair_jobs enable row level security;
drop policy if exists "repairs: read"   on public.repair_jobs;
drop policy if exists "repairs: add"    on public.repair_jobs;
drop policy if exists "repairs: edit"   on public.repair_jobs;
drop policy if exists "repairs: delete" on public.repair_jobs;
create policy "repairs: read"   on public.repair_jobs for select to authenticated using ((select public.is_member()));
create policy "repairs: add"    on public.repair_jobs for insert to authenticated with check ((select public.is_member()));
create policy "repairs: edit"   on public.repair_jobs for update to authenticated using ((select public.is_member()));
create policy "repairs: delete" on public.repair_jobs for delete to authenticated using ((select public.is_admin()));

alter table public.part_moves add column if not exists unit_price numeric;

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
  hours         numeric,
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
  hours_at      numeric,
  status_after  text,
  schedule_id   uuid references public.schedules(id) on delete set null,
  photos        text[] not null default '{}',
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

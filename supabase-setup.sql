-- =====================================================================
-- PLOTMARK CRM — database setup (run once)
-- Supabase → SQL Editor → New query → paste everything → Run
-- Safe to run again: it skips what already exists.
-- =====================================================================

-- ---------- 1. Team members (one row per login) ----------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  email       text,
  role        text not null default 'broker' check (role in ('admin','broker')),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- When someone is added under Authentication → Users, give them a profile.
-- The very first person becomes the admin automatically.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    new.email,
    case when exists (select 1 from public.profiles where role = 'admin') then 'broker' else 'admin' end
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helpers used by the security rules
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active);
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role = 'admin');
$$;

-- ---------- 2. CRM tables ---------------------------------------------
create table if not exists public.contacts (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  phone         text,
  email         text,
  purpose       text check (purpose in ('Buy','Rent','Off-plan','Sell','Let')),
  source        text default 'Website',
  status        text not null default 'New'
                check (status in ('New','Contacted','Qualified','Viewing','Negotiating','Client','Nurture','Lost')),
  budget        numeric,
  beds          text default 'Any',
  communities   text[] not null default '{}',
  nationality   text,
  kyc           text not null default 'Not started' check (kyc in ('Not started','In progress','Done')),
  broker        uuid references public.profiles(id) on delete set null,
  next_step     date,
  last_contact  timestamptz,
  notes         text,
  created_by    uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.properties (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  ref            text,
  purpose        text not null check (purpose in ('Sale','Rent','Off-plan')),
  status         text not null default 'Draft'
                 check (status in ('Draft','Live','Under offer','Sold','Rented','Withdrawn')),
  community      text,
  building       text,
  type           text default 'Apartment',
  beds           text,
  size_sqft      numeric,
  price          numeric,
  owner_id       uuid references public.contacts(id) on delete set null,
  developer      text,
  permit         text,
  permit_expiry  date,
  form_a         boolean not null default false,
  broker         uuid references public.profiles(id) on delete set null,
  notes          text,
  created_by     uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  -- RERA rule: a ready listing cannot be Live without a Trakheesi permit
  constraint live_needs_permit check (status <> 'Live' or purpose = 'Off-plan' or coalesce(permit,'') <> '')
);

create table if not exists public.deals (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  type            text not null check (type in ('Sale','Rental','Off-plan')),
  stage           text not null default 'New'
                  check (stage in ('New','Viewing','Offer','Agreement','Closing','Won','Lost')),
  contact_id      uuid references public.contacts(id) on delete set null,
  property_id     uuid references public.properties(id) on delete set null,
  value           numeric not null default 0,
  comm_pct        numeric,
  split_pct       numeric not null default 0,
  expected_close  date,
  broker          uuid references public.profiles(id) on delete set null,
  notes           text,
  stage_at        timestamptz not null default now(),
  closed_at       timestamptz,
  created_by      uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table if not exists public.viewings (
  id           uuid primary key default gen_random_uuid(),
  starts_at    timestamptz not null,
  status       text not null default 'Scheduled' check (status in ('Scheduled','Done','Cancelled','No-show')),
  contact_id   uuid references public.contacts(id) on delete cascade,
  property_id  uuid references public.properties(id) on delete cascade,
  broker       uuid references public.profiles(id) on delete set null,
  feedback     text,
  created_by   uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.tasks (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  due         date,
  done        boolean not null default false,
  done_at     timestamptz,
  contact_id  uuid references public.contacts(id) on delete cascade,
  deal_id     uuid references public.deals(id) on delete cascade,
  broker      uuid references public.profiles(id) on delete set null,
  notes       text,
  created_by  uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Contact history: calls, emails, WhatsApp, meetings, notes, website enquiries
create table if not exists public.activities (
  id          uuid primary key default gen_random_uuid(),
  contact_id  uuid not null references public.contacts(id) on delete cascade,
  kind        text not null default 'Note'
              check (kind in ('Call','Email','WhatsApp','Meeting','Note','Website enquiry','System')),
  body        text not null,
  created_by  uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);

create index if not exists contacts_status_idx   on public.contacts(status);
create index if not exists contacts_broker_idx   on public.contacts(broker);
create index if not exists contacts_email_idx    on public.contacts(lower(email));
create index if not exists properties_status_idx on public.properties(status);
create index if not exists deals_stage_idx       on public.deals(stage);
create index if not exists viewings_starts_idx   on public.viewings(starts_at);
create index if not exists tasks_due_idx         on public.tasks(due) where not done;
create index if not exists activities_contact_idx on public.activities(contact_id, created_at desc);

-- Keep updated_at current automatically
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['contacts','properties','deals','viewings','tasks'] loop
    execute format('drop trigger if exists touch_%1$s on public.%1$s', t);
    execute format('create trigger touch_%1$s before update on public.%1$s
                    for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- Deals: record when the stage changes and when a deal is won
create or replace function public.deal_stage_dates()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.stage is distinct from old.stage then
    new.stage_at = now();
    if new.stage = 'Won' then new.closed_at = now(); end if;
  end if;
  return new;
end $$;
drop trigger if exists deal_stage_dates on public.deals;
create trigger deal_stage_dates before insert or update on public.deals
  for each row execute function public.deal_stage_dates();

-- ---------- 3. Security rules (Row Level Security) ---------------------
-- Active team members can see and edit all CRM records.
-- Only the admin can delete records and manage the team.
alter table public.profiles   enable row level security;
alter table public.contacts   enable row level security;
alter table public.properties enable row level security;
alter table public.deals      enable row level security;
alter table public.viewings   enable row level security;
alter table public.tasks      enable row level security;
alter table public.activities enable row level security;

drop policy if exists "team reads profiles"     on public.profiles;
drop policy if exists "admin manages profiles"  on public.profiles;
drop policy if exists "user edits own name"     on public.profiles;
create policy "team reads profiles"    on public.profiles for select to authenticated using (public.is_staff());
create policy "admin manages profiles" on public.profiles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "user edits own name"    on public.profiles for update to authenticated
  using (id = auth.uid() and public.is_staff())
  with check (id = auth.uid() and role = (select p.role from public.profiles p where p.id = auth.uid())
              and active = (select p.active from public.profiles p where p.id = auth.uid()));

do $$
declare t text;
begin
  foreach t in array array['contacts','properties','deals','viewings','tasks','activities'] loop
    execute format('drop policy if exists "team reads" on public.%I', t);
    execute format('drop policy if exists "team adds" on public.%I', t);
    execute format('drop policy if exists "team edits" on public.%I', t);
    execute format('drop policy if exists "admin deletes" on public.%I', t);
    execute format('create policy "team reads"    on public.%I for select to authenticated using (public.is_staff())', t);
    execute format('create policy "team adds"     on public.%I for insert to authenticated with check (public.is_staff())', t);
    execute format('create policy "team edits"    on public.%I for update to authenticated using (public.is_staff()) with check (public.is_staff())', t);
    execute format('create policy "admin deletes" on public.%I for delete to authenticated using (public.is_admin())', t);
  end loop;
end $$;

-- Table access for signed-in users only (the public gets nothing directly)
revoke all on public.profiles, public.contacts, public.properties, public.deals,
              public.viewings, public.tasks, public.activities from anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.contacts, public.properties, public.deals,
      public.viewings, public.tasks, public.activities to authenticated;

-- ---------- 4. Website enquiries → CRM -------------------------------
-- The website calls this one function. It can only ADD an enquiry;
-- it cannot read anything. Repeat enquiries from the same email are
-- added to that person's history instead of creating a duplicate.
create or replace function public.submit_website_lead(
  p_name text, p_email text, p_phone text default null,
  p_interest text default null, p_message text default null, p_page text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_purpose text;
  v_email text := lower(trim(coalesce(p_email,'')));
begin
  if length(trim(coalesce(p_name,''))) < 2 or length(p_name) > 120 then raise exception 'Please enter your name'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then raise exception 'Please enter a valid email'; end if;
  if length(coalesce(p_message,'')) > 3000 or length(coalesce(p_phone,'')) > 40 then raise exception 'Message too long'; end if;
  -- simple flood protection: at most 30 website enquiries in 10 minutes
  if (select count(*) from public.activities where kind = 'Website enquiry'
        and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Too many requests, please try again shortly';
  end if;

  v_purpose := case lower(coalesce(p_interest,''))
    when 'buy' then 'Buy' when 'buying' then 'Buy'
    when 'rent' then 'Rent' when 'renting' then 'Rent'
    when 'off-plan' then 'Off-plan' when 'offplan' then 'Off-plan'
    when 'sell' then 'Sell' when 'selling' then 'Sell'
    when 'let' then 'Let' when 'letting' then 'Let'
    else null end;

  select id into v_id from public.contacts where lower(email) = v_email order by created_at limit 1;
  if v_id is null then
    insert into public.contacts (name, email, phone, purpose, source, status, created_by)
    values (trim(p_name), v_email, nullif(trim(coalesce(p_phone,'')),''), v_purpose, 'Website', 'New', null)
    returning id into v_id;
  else
    update public.contacts
       set phone = coalesce(phone, nullif(trim(coalesce(p_phone,'')),'')),
           status = case when status in ('Lost','Nurture') then 'New' else status end
     where id = v_id;
  end if;

  insert into public.activities (contact_id, kind, body, created_by)
  values (v_id, 'Website enquiry',
          concat_ws(E'\n',
            case when p_interest is not null then 'Interested in: ' || left(p_interest,60) end,
            nullif(trim(coalesce(p_message,'')),''),
            case when p_page is not null then 'Sent from: ' || left(p_page,200) end),
          null);
  return 'ok';
end $$;

revoke all on function public.submit_website_lead(text,text,text,text,text,text) from public;
grant execute on function public.submit_website_lead(text,text,text,text,text,text) to anon, authenticated;

-- Done. You should see "Success. No rows returned".

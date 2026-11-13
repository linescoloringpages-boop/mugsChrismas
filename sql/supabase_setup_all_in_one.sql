-- =====================================================================
-- AnthemCup store - Supabase setup
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- It is safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Who is the admin?  (change the email here if you ever need to)
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select coalesce(lower(auth.jwt() ->> 'email') = 'shalomdahar@gmail.com', false);
$$;

-- ---------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------

-- Store settings: always exactly one row (id = 1) holding all settings as JSON.
create table if not exists public.store_settings (
  id          integer primary key default 1 check (id = 1),
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

insert into public.store_settings (id, data)
values (1, '{}'::jsonb)
on conflict (id) do nothing;

-- Orders: one row per order. "data" holds the full order (customer, items, payment...).
create table if not exists public.orders (
  id          text primary key,
  created_at  timestamptz not null default now(),
  handled     boolean not null default false,
  handled_at  timestamptz,
  data        jsonb not null
);

create index if not exists orders_created_at_idx on public.orders (created_at desc);

-- ---------------------------------------------------------------------
-- 3. Turn on Row Level Security (nobody gets in unless a rule allows it)
-- ---------------------------------------------------------------------
alter table public.store_settings enable row level security;
alter table public.orders         enable row level security;

-- ---------------------------------------------------------------------
-- 4. Rules for store_settings
--    - everybody (customers) can READ the settings
--    - only the admin can create / change them
-- ---------------------------------------------------------------------
drop policy if exists "settings: everyone can read"  on public.store_settings;
drop policy if exists "settings: admin can insert"   on public.store_settings;
drop policy if exists "settings: admin can update"   on public.store_settings;

create policy "settings: everyone can read"
  on public.store_settings for select
  to anon, authenticated
  using (true);

create policy "settings: admin can insert"
  on public.store_settings for insert
  to authenticated
  with check (public.is_admin());

create policy "settings: admin can update"
  on public.store_settings for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 5. Rules for orders
--    - customers can only PLACE a new (not handled) order; they can never read,
--      change or delete any order
--    - only the admin can read, update ("handled") and delete orders
-- ---------------------------------------------------------------------
drop policy if exists "orders: anyone can place"   on public.orders;
drop policy if exists "orders: admin can read"     on public.orders;
drop policy if exists "orders: admin can update"   on public.orders;
drop policy if exists "orders: admin can delete"   on public.orders;

create policy "orders: anyone can place"
  on public.orders for insert
  to anon, authenticated
  with check (
    handled = false
    and handled_at is null
    and id ~ '^ORD-[A-Z0-9]{6,40}$'
    and octet_length(data::text) < 30000
  );

create policy "orders: admin can read"
  on public.orders for select
  to authenticated
  using (public.is_admin());

create policy "orders: admin can update"
  on public.orders for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "orders: admin can delete"
  on public.orders for delete
  to authenticated
  using (public.is_admin());

-- ---------------------------------------------------------------------
-- 6. Permissions (the rules above still decide who can do what)
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;

grant select                         on public.store_settings to anon, authenticated;
grant insert, update                 on public.store_settings to authenticated;

grant insert                         on public.orders to anon;
grant select, insert, update, delete on public.orders to authenticated;


-- =====================================================================
-- PART 2
-- =====================================================================

-- ====== AnthemCup: run this ONCE in Supabase > SQL Editor > New query > Run ======
-- (supabase_setup.sql must already have been run: it is the one that creates is_admin())

-- =====================================================================
-- AnthemCup store - storage for customers' design files
-- Run this ONCE in Supabase > SQL Editor > New query > Run.
-- (Run supabase_setup.sql first - it creates the is_admin() function used below.)
-- It is safe to run more than once.
-- =====================================================================

-- 1. A bucket called "designs".
--    * public = true  -> a file can be opened by anyone who has its exact link
--      (the links are long random addresses that only appear in your order emails and Orders tab)
--    * only JPG / PNG files, at most 20 MB each
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('designs', 'designs', true, 20971520, array['image/jpeg', 'image/png'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 2. Who may do what with the files
drop policy if exists "designs: anyone can upload"   on storage.objects;
drop policy if exists "designs: admin can list"      on storage.objects;
drop policy if exists "designs: admin can delete"    on storage.objects;

-- Customers can ONLY upload new files, and only to this exact path shape:
--   orders/<order number>/<32 random characters>-print-1.jpg   (or -preview-2.jpg ...)
-- They can not list, replace, or delete anything.
create policy "designs: anyone can upload"
  on storage.objects for insert
  to anon, authenticated
  with check (
    bucket_id = 'designs'
    and name ~ '^orders/ORD-[A-Z0-9]{6,40}/[a-f0-9]{32}-(print|preview)-[0-9]{1,3}\.(jpg|png)$'
  );

-- Only you (the admin) can list and delete the files.
create policy "designs: admin can list"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'designs' and public.is_admin());

create policy "designs: admin can delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'designs' and public.is_admin());


-- =====================================================================
-- AnthemCup store - visitor counter
-- Run this ONCE in Supabase > SQL Editor > New query > Run.
-- (Run supabase_setup.sql first - it creates the is_admin() function used below.)
-- It is safe to run more than once.
--
-- What is stored per visit: the time, a random code that the visitor's browser makes up
-- (not an IP address, not a name), and the page. Nothing else.
-- =====================================================================

create table if not exists public.visits (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  visitor     text not null,
  page        text not null default '/'
);
create index if not exists visits_created_idx on public.visits (created_at desc);

alter table public.visits enable row level security;

drop policy if exists "visits: anyone can add"   on public.visits;
drop policy if exists "visits: admin can read"   on public.visits;
drop policy if exists "visits: admin can delete" on public.visits;

-- visitors can only ADD a visit (never read or change any)
create policy "visits: anyone can add"
  on public.visits for insert
  to anon, authenticated
  with check (visitor ~ '^[a-f0-9]{16,40}$' and char_length(page) <= 60);

create policy "visits: admin can read"
  on public.visits for select
  to authenticated
  using (public.is_admin());

create policy "visits: admin can delete"
  on public.visits for delete
  to authenticated
  using (public.is_admin());

grant insert on public.visits to anon, authenticated;
grant select, delete on public.visits to authenticated;

-- The numbers shown in Admin > Visitors (days are counted in Israel time)
create or replace function public.visit_stats(p_days integer default 30)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  tz text := 'Asia/Jerusalem';
  today date := (now() at time zone 'Asia/Jerusalem')::date;
  res json;
begin
  if not public.is_admin() then
    raise exception 'not allowed';
  end if;
  select json_build_object(
    'total',        (select count(*) from visits),
    'unique_total', (select count(distinct visitor) from visits),
    'today_v',      (select count(*) from visits where (created_at at time zone tz)::date = today),
    'today_u',      (select count(distinct visitor) from visits where (created_at at time zone tz)::date = today),
    'v7',           (select count(*) from visits where (created_at at time zone tz)::date > today - 7),
    'u7',           (select count(distinct visitor) from visits where (created_at at time zone tz)::date > today - 7),
    'v30',          (select count(*) from visits where (created_at at time zone tz)::date > today - 30),
    'u30',          (select count(distinct visitor) from visits where (created_at at time zone tz)::date > today - 30),
    'days',         (select coalesce(json_agg(d order by d.day desc), '[]'::json) from (
                       select (created_at at time zone tz)::date as day, count(*) as visits, count(distinct visitor) as uniques
                       from visits
                       where (created_at at time zone tz)::date > today - greatest(p_days, 1)
                       group by 1) d)
  ) into res;
  return res;
end;
$$;

revoke all on function public.visit_stats(integer) from public;
revoke all on function public.visit_stats(integer) from anon;
grant execute on function public.visit_stats(integer) to authenticated;


-- =====================================================================
-- AnthemCup store - customer reviews with photos
-- Run this ONCE in Supabase > SQL Editor > New query > Run.
-- (Run supabase_setup.sql first - it creates the is_admin() function used below.)
-- It is safe to run more than once. (Supabase may warn about "destructive operations"
-- because of the "drop policy if exists" lines - that is harmless, they only refresh the rules.)
--
-- How it works: customers can only ADD a review (always "pending"); only approved reviews are
-- visible to the public; only you (admin) can approve, hide or delete them.
-- =====================================================================

create table if not exists public.customer_reviews (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  name        text not null,
  rating      int  not null default 5,
  body        text not null,
  photos      text[] not null default '{}',
  status      text not null default 'pending'
);
create index if not exists customer_reviews_status_idx on public.customer_reviews (status, created_at desc);

alter table public.customer_reviews enable row level security;

drop policy if exists "reviews: anyone can add"       on public.customer_reviews;
drop policy if exists "reviews: public reads approved" on public.customer_reviews;
drop policy if exists "reviews: admin all"            on public.customer_reviews;

create policy "reviews: anyone can add"
  on public.customer_reviews for insert
  to anon, authenticated
  with check (
    status = 'pending'
    and char_length(name) between 1 and 60
    and char_length(body) between 1 and 600
    and rating between 1 and 5
    and coalesce(array_length(photos, 1), 0) <= 3
  );

create policy "reviews: public reads approved"
  on public.customer_reviews for select
  to anon, authenticated
  using (status = 'approved');

create policy "reviews: admin all"
  on public.customer_reviews for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- photo storage (public read so photos can be shown on the site)
insert into storage.buckets (id, name, public)
values ('review-photos', 'review-photos', true)
on conflict (id) do update set public = true;

drop policy if exists "review-photos: anyone can upload" on storage.objects;
drop policy if exists "review-photos: public read"       on storage.objects;
drop policy if exists "review-photos: admin delete"      on storage.objects;

create policy "review-photos: anyone can upload"
  on storage.objects for insert
  to anon, authenticated
  with check (bucket_id = 'review-photos' and name ~ '^r/[a-f0-9]{16,40}\.jpg$');

create policy "review-photos: public read"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'review-photos');

create policy "review-photos: admin delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'review-photos' and public.is_admin());

-- My Meal Tracker — Supabase database schema
-- Prototype-ready role-based hospital meal workflow.
-- IMPORTANT: Run this in Supabase SQL Editor before using live mode.

create extension if not exists pgcrypto;

-- =========================
-- ROLE / PROFILE MODEL
-- =========================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null check (role in ('patient','attender','manager','dietitian','fb_staff','kitchen_staff','delivery_staff')),
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.my_role()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

create table if not exists public.doctors (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  specialty text,
  doctor_code text unique,
  phone text,
  created_at timestamptz not null default now()
);

create table if not exists public.dietitians (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  focus_area text,
  dietitian_code text unique,
  phone text,
  created_at timestamptz not null default now()
);

create table if not exists public.staff (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  role text not null check (role in ('fb_staff','kitchen_staff','delivery_staff','manager')),
  department text,
  active boolean not null default true,
  unique(display_name, role),
  created_at timestamptz not null default now()
);

-- =========================
-- PATIENT / ATTENDER
-- =========================
create table if not exists public.patients (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  room text,
  ward text,
  floor integer not null default 0 check (floor between -1 and 6),
  diet text,
  allergy text,
  clinical_notes text,
  doctor_id uuid references public.doctors(id) on delete set null,
  dietitian_id uuid references public.dietitians(id) on delete set null,
  diet_plan_version text,
  diet_plan_approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.attenders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  display_name text not null,
  relation text,
  room text,
  floor integer not null default 0 check (floor between -1 and 6),
  created_at timestamptz not null default now()
);

create table if not exists public.patient_preferences (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references public.patients(id) on delete cascade,
  warm_food boolean default true,
  mild_spice boolean default true,
  quiet_delivery boolean default true,
  soft_cutlery boolean default false,
  portion_preference text,
  hydration_target_ml integer default 2000,
  notes text,
  updated_at timestamptz not null default now(),
  unique(patient_id)
);

-- =========================
-- MENU / NUTRITION
-- =========================
create table if not exists public.menu_items (
  id uuid primary key default gen_random_uuid(),
  audience text not null check (audience in ('patient','attender','both')),
  diet text,
  category text not null,
  meal_type text not null,
  name text not null,
  description text,
  prep_minutes integer not null default 0,
  kcal integer not null default 0,
  protein_g numeric(7,2) not null default 0,
  serving_time text,
  requires_dietitian boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- =========================
-- ORDERS / WORKFLOW
-- =========================
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,
  patient_id uuid references public.patients(id) on delete set null,
  attender_id uuid references public.attenders(id) on delete set null,
  menu_item_id uuid references public.menu_items(id) on delete set null,
  meal_type text not null,
  meal_name text not null,
  diet text,
  order_mode text not null default 'planned' check (order_mode in ('early','planned','after_meal','voice')),
  scheduled_at timestamptz,
  prep_minutes integer,
  kcal integer,
  protein_g numeric(7,2),
  status text not null default 'Order placed',
  dietitian_status text not null default 'pending' check (dietitian_status in ('pending','approved','rejected','not_required')),
  fb_status text not null default 'waiting',
  kitchen_status text not null default 'waiting',
  delivery_status text not null default 'waiting',
  assigned_staff_id uuid references public.staff(id) on delete set null,
  placed_by uuid references auth.users(id) on delete set null,
  placed_at timestamptz not null default now(),
  notes text,
  updated_at timestamptz not null default now()
);

create table if not exists public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  actor_role text,
  event_type text not null,
  from_status text,
  to_status text,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  order_id uuid references public.orders(id) on delete cascade,
  title text not null,
  body text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

-- Helpful indexes
create index if not exists idx_orders_patient on public.orders(patient_id, created_at desc);
create index if not exists idx_orders_attender on public.orders(attender_id, created_at desc);
create index if not exists idx_orders_status on public.orders(status, created_at desc);
create index if not exists idx_orders_scheduled on public.orders(scheduled_at);
create index if not exists idx_events_order on public.order_events(order_id, created_at desc);
create index if not exists idx_menu_active on public.menu_items(active, audience, diet, meal_type);

-- updated_at helper
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end; $$;

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated before update on public.profiles for each row execute function public.touch_updated_at();
drop trigger if exists trg_patients_updated on public.patients;
create trigger trg_patients_updated before update on public.patients for each row execute function public.touch_updated_at();
drop trigger if exists trg_orders_updated on public.orders;
create trigger trg_orders_updated before update on public.orders for each row execute function public.touch_updated_at();

-- Automatically add an order event for each new order.
create or replace function public.log_new_order_event()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.order_events(order_id,actor_id,actor_role,event_type,to_status,notes)
  values(new.id,new.placed_by,coalesce((select role from profiles where id=new.placed_by),'system'),'order_placed',new.status,new.notes);
  return new;
end; $$;

drop trigger if exists trg_log_new_order on public.orders;
create trigger trg_log_new_order after insert on public.orders for each row execute function public.log_new_order_event();

-- =========================
-- RLS
-- =========================
-- Idempotent policy reset for re-running this script
do $$ begin
  execute 'drop policy if exists profiles_self_select on public.profiles';
  execute 'drop policy if exists profiles_self_update on public.profiles';
  execute 'drop policy if exists profiles_manager_all on public.profiles';
  execute 'drop policy if exists doctors_read_authenticated on public.doctors';
  execute 'drop policy if exists doctors_manager_write on public.doctors';
  execute 'drop policy if exists dietitians_read_authenticated on public.dietitians';
  execute 'drop policy if exists dietitians_manager_write on public.dietitians';
  execute 'drop policy if exists staff_read_authenticated on public.staff';
  execute 'drop policy if exists staff_manager_write on public.staff';
  execute 'drop policy if exists patients_read_scoped on public.patients';
  execute 'drop policy if exists patients_manager_write on public.patients';
  execute 'drop policy if exists attenders_read_scoped on public.attenders';
  execute 'drop policy if exists attenders_manager_write on public.attenders';
  execute 'drop policy if exists preferences_patient_read on public.patient_preferences';
  execute 'drop policy if exists preferences_patient_write on public.patient_preferences';
  execute 'drop policy if exists preferences_patient_update on public.patient_preferences';
  execute 'drop policy if exists menu_read_authenticated on public.menu_items';
  execute 'drop policy if exists menu_manager_write on public.menu_items';
  execute 'drop policy if exists orders_read_scoped on public.orders';
  execute 'drop policy if exists orders_patient_insert on public.orders';
  execute 'drop policy if exists orders_ops_update on public.orders';
  execute 'drop policy if exists events_read_scoped on public.order_events';
  execute 'drop policy if exists events_ops_insert on public.order_events';
  execute 'drop policy if exists notifications_own on public.notifications';
  execute 'drop policy if exists notifications_own_update on public.notifications';
end $$;

alter table public.profiles enable row level security;
alter table public.doctors enable row level security;
alter table public.dietitians enable row level security;
alter table public.staff enable row level security;
alter table public.patients enable row level security;
alter table public.attenders enable row level security;
alter table public.patient_preferences enable row level security;
alter table public.menu_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_events enable row level security;
alter table public.notifications enable row level security;

-- Profiles
 drop policy if exists profiles_self_select on public.profiles;
create policy profiles_self_select on public.profiles for select to authenticated using (id=auth.uid() or public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff'));
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles for update to authenticated using (id=auth.uid() and active=true) with check (id=auth.uid() and active=true);
drop policy if exists profiles_manager_all on public.profiles;
create policy profiles_manager_all on public.profiles for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');

-- Lookup / care team tables
create policy doctors_read_authenticated on public.doctors for select to authenticated using (true);
create policy doctors_manager_write on public.doctors for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');
create policy dietitians_read_authenticated on public.dietitians for select to authenticated using (true);
create policy dietitians_manager_write on public.dietitians for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');
create policy staff_read_authenticated on public.staff for select to authenticated using (true);
create policy staff_manager_write on public.staff for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');

-- Patients
create policy patients_read_scoped on public.patients for select to authenticated using (
  user_id=auth.uid() or public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff')
);
create policy patients_manager_write on public.patients for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');

-- Attenders
create policy attenders_read_scoped on public.attenders for select to authenticated using (
  user_id=auth.uid() or public.my_role() in ('manager','fb_staff','kitchen_staff','delivery_staff')
);
create policy attenders_manager_write on public.attenders for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');

-- Preferences
create policy preferences_patient_read on public.patient_preferences for select to authenticated using (
  exists(select 1 from public.patients p where p.id=patient_id and p.user_id=auth.uid()) or public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff')
);
create policy preferences_patient_write on public.patient_preferences for insert to authenticated with check (
  exists(select 1 from public.patients p where p.id=patient_id and p.user_id=auth.uid())
);
create policy preferences_patient_update on public.patient_preferences for update to authenticated using (
  exists(select 1 from public.patients p where p.id=patient_id and p.user_id=auth.uid()) or public.my_role()='manager'
) with check (
  exists(select 1 from public.patients p where p.id=patient_id and p.user_id=auth.uid()) or public.my_role()='manager'
);

-- Menu: all signed-in users can read; managers can maintain.
create policy menu_read_authenticated on public.menu_items for select to authenticated using (active=true or public.my_role()='manager');
create policy menu_manager_write on public.menu_items for all to authenticated using (public.my_role()='manager') with check (public.my_role()='manager');

-- Orders
create policy orders_read_scoped on public.orders for select to authenticated using (
  (patient_id is not null and exists(select 1 from public.patients p where p.id=patient_id and p.user_id=auth.uid()))
  or (attender_id is not null and exists(select 1 from public.attenders a where a.id=attender_id and a.user_id=auth.uid()))
  or public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff')
);
create policy orders_patient_insert on public.orders for insert to authenticated with check (
  (patient_id is not null and exists(select 1 from public.patients p where p.id=patient_id and p.user_id=auth.uid()))
  or (attender_id is not null and exists(select 1 from public.attenders a where a.id=attender_id and a.user_id=auth.uid()))
  or public.my_role()='manager'
);
create policy orders_ops_update on public.orders for update to authenticated using (
  public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff')
) with check (
  public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff')
);

-- Events
create policy events_read_scoped on public.order_events for select to authenticated using (
  exists(select 1 from public.orders o where o.id=order_id and (
    (o.patient_id is not null and exists(select 1 from public.patients p where p.id=o.patient_id and p.user_id=auth.uid()))
    or (o.attender_id is not null and exists(select 1 from public.attenders a where a.id=o.attender_id and a.user_id=auth.uid()))
    or public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff')
  ))
);
create policy events_ops_insert on public.order_events for insert to authenticated with check (
  actor_id=auth.uid() and public.my_role() in ('manager','dietitian','fb_staff','kitchen_staff','delivery_staff','patient','attender')
);

-- Notifications
create policy notifications_own on public.notifications for select to authenticated using (user_id=auth.uid() or public.my_role()='manager');
create policy notifications_own_update on public.notifications for update to authenticated using (user_id=auth.uid() or public.my_role()='manager') with check (user_id=auth.uid() or public.my_role()='manager');

-- =========================
-- REALTIME
-- =========================
-- These are the tables the HTML client subscribes to.
-- Supabase Realtime uses the supabase_realtime publication for Postgres Changes.
-- Ignore the duplicate-object error if a table is already listed in the publication.
do $$
begin
  begin alter publication supabase_realtime add table public.orders; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.order_events; exception when duplicate_object then null; end;
end $$;

-- =========================
-- DEMO DATA FOR CARE TEAM + MENU
-- =========================
insert into public.doctors(display_name,specialty,doctor_code)
values
('Dr. Meena Iyer','Cardiology','DOC-001'),
('Dr. Arvind Rao','Internal Medicine','DOC-002'),
('Dr. Shalini Rao','Oncology','DOC-003'),
('Dr. Naveen Shah','Neurology','DOC-004')
on conflict (doctor_code) do nothing;

insert into public.dietitians(display_name,focus_area,dietitian_code)
values
('Dr. Asha Menon','Clinical Nutrition','DT-001'),
('Dr. Kavita Rao','Renal & Therapeutic Diets','DT-002'),
('Dr. Nikhil Varma','High-Protein & Recovery Nutrition','DT-003')
on conflict (dietitian_code) do nothing;

insert into public.staff(display_name,role,department)
values
('Suresh Kumar','fb_staff','F&B Service'),
('Mohan Das','fb_staff','F&B Service'),
('Kiran Kumar','fb_staff','F&B Service'),
('Priyanka S','delivery_staff','Patient Delivery'),
('Anil Joseph','kitchen_staff','Main Kitchen'),
('Deepa R','kitchen_staff','Main Kitchen')
on conflict do nothing;

insert into public.menu_items(audience,diet,category,meal_type,name,description,prep_minutes,kcal,protein_g,serving_time,requires_dietitian)
values
('patient','Diabetic Care','Scheduled Meal','Breakfast','Oats porridge','Low-added-sugar oats with milk',9,180,8,'07:30',true),
('patient','Diabetic Care','Individual Food','Snack','Guava bowl','Fresh guava portion',3,68,2,'10:30',true),
('patient','Diabetic Care','Beverage','Beverage','Unsweetened herbal tea','No added sugar',4,5,0,'16:00',true),
('patient','Cardiac Low-Sodium','Scheduled Meal','Lunch','Brown rice & dal','Low-sodium dal with brown rice',16,340,15,'12:30',true),
('patient','Renal-Friendly','Scheduled Meal','Dinner','Soft vegetable rice','Portion-controlled renal-friendly bowl',15,310,9,'19:30',true),
('patient','Liquid Diet','Scheduled Meal','Snack','Clear vegetable broth','Smooth clear liquid serving',6,55,2,'16:00',true),
('patient','Pureed Soft Diet','Scheduled Meal','Lunch','Pureed lentil bowl','Smooth lentil puree',12,220,10,'12:30',true),
('patient','Vegetarian High-Protein','Scheduled Meal','Breakfast','Moong chilla with paneer','Protein-rich soft breakfast',14,310,18,'07:30',true),
('attender','Attender High-Protein','Breakfast','Breakfast','High-protein egg & spinach wrap','Egg, spinach and wholegrain wrap',10,320,24,'08:00',false),
('attender','Attender High-Protein','Lunch','Lunch','Grilled chicken quinoa bowl','Chicken, quinoa and vegetables',18,520,38,'13:00',false),
('attender','Attender High-Protein','Snacks','Snack','Greek yogurt & fruit cup','Greek yogurt with fruit',6,180,15,'16:00',false),
('attender','Attender High-Protein','Dinner','Dinner','Paneer quinoa dinner bowl','Paneer, quinoa and vegetables',17,470,32,'19:30',false),
('attender','Attender High-Protein','Beverage','Juice','Berry protein smoothie','Berry blend with yogurt',7,230,18,'16:30',false),
('attender','Attender High-Protein','Salad','Salad','Chicken avocado salad','Chicken, greens and avocado',9,390,35,'19:00',false)
on conflict do nothing;

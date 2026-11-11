-- =====================================================================
--  SOGEI Gestion — base Supabase
--  À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
--  Peut être relancé sans risque (idempotent).
-- =====================================================================

-- 1) Profils et rôles ---------------------------------------------------
--   admin   : tout voir, tout modifier, gérer les comptes utilisateurs
--   gerant  : tout voir, tout modifier (sauf gérer les comptes)
--   equipe  : tout sauf la caisse et les acomptes (pas d'accès aux montants de caisse)
--   lecture : voir sans modifier
--   attente : compte créé, pas encore validé par le gérant (aucun accès)
create table if not exists public.profils (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  nom        text,
  role       text not null default 'attente',
  created_at timestamptz not null default now()
);

-- Liste des rôles autorisés (mise à jour si la table existait déjà)
alter table public.profils drop constraint if exists profils_role_check;
alter table public.profils add constraint profils_role_check check (role in ('admin','gerant','equipe','lecture','attente'));

-- 2) Données de l'appli : une ligne par élément (client, facture, jour de pointage…)
create table if not exists public.items (
  coll       text not null,
  id         text not null,
  data       jsonb,
  deleted    boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid(),
  primary key (coll, id)
);
create index if not exists items_updated_at_idx on public.items (updated_at);

-- 3) Table lue par le réveil automatique (GitHub Actions)
create table if not exists public.reveil (id int primary key default 1, note text default 'ping');
insert into public.reveil (id) values (1) on conflict do nothing;

-- 4) Fonctions -----------------------------------------------------------
create or replace function public.mon_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.profils where user_id = auth.uid()), 'attente');
$$;

-- Le premier compte créé devient admin ; les suivants attendent la validation de l'admin.
create or replace function public.nouveau_profil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profils (user_id, email, nom, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'nom', split_part(new.email,'@',1)),
          case when exists (select 1 from public.profils) then 'attente' else 'admin' end)
  on conflict (user_id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.nouveau_profil();

-- Il faut toujours au moins un admin
create or replace function public.garde_gerant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin' and new.role <> 'admin'
     and (select count(*) from public.profils where role = 'admin') <= 1 then
    raise exception 'Il faut au moins un administrateur.';
  end if;
  return new;
end $$;
drop trigger if exists garde_gerant on public.profils;
create trigger garde_gerant before update on public.profils
  for each row execute function public.garde_gerant();

-- Profils des comptes déjà existants (si un compte a été créé avant ce script)
insert into public.profils (user_id, email, nom, role)
select u.id, u.email, split_part(u.email,'@',1), 'attente' from auth.users u
on conflict (user_id) do nothing;
-- Il faut un admin : à défaut, le compte le plus ancien parmi les gérants (ou tous) le devient
update public.profils set role = 'admin'
where not exists (select 1 from public.profils where role = 'admin')
  and user_id = (select user_id from public.profils
                 order by (role = 'gerant') desc, created_at limit 1);

-- Horodatage serveur à chaque écriture
create or replace function public.items_horodatage() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists items_horodatage on public.items;
create trigger items_horodatage before insert or update on public.items
  for each row execute function public.items_horodatage();

-- 5) Sécurité (RLS) --------------------------------------------------------
alter table public.profils enable row level security;
alter table public.items   enable row level security;
alter table public.reveil  enable row level security;

drop policy if exists "profils lecture" on public.profils;
create policy "profils lecture" on public.profils for select to authenticated
  using (user_id = auth.uid() or public.mon_role() = 'admin');
drop policy if exists "profils gerant" on public.profils;
create policy "profils gerant" on public.profils for update to authenticated
  using (public.mon_role() = 'admin') with check (public.mon_role() = 'admin');
drop policy if exists "profils nom" on public.profils;
create policy "profils nom" on public.profils for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and role = public.mon_role());

drop policy if exists "items lecture" on public.items;
create policy "items lecture" on public.items for select to authenticated
  using (public.mon_role() in ('admin','gerant','lecture')
         or (public.mon_role() = 'equipe' and coll not in ('caisse','avances')));
drop policy if exists "items ajout" on public.items;
create policy "items ajout" on public.items for insert to authenticated
  with check (public.mon_role() in ('admin','gerant')
              or (public.mon_role() = 'equipe' and coll not in ('caisse','avances','settings')));
drop policy if exists "items modif" on public.items;
create policy "items modif" on public.items for update to authenticated
  using (public.mon_role() in ('admin','gerant')
         or (public.mon_role() = 'equipe' and coll not in ('caisse','avances','settings')))
  with check (public.mon_role() in ('admin','gerant')
         or (public.mon_role() = 'equipe' and coll not in ('caisse','avances','settings')));

drop policy if exists "reveil lecture" on public.reveil;
create policy "reveil lecture" on public.reveil for select to anon, authenticated using (true);

-- 6) Droits d'accès (les nouvelles tables ne sont pas exposées automatiquement)
grant usage on schema public to anon, authenticated;
grant select, insert, update on public.items   to authenticated;
grant select, update         on public.profils to authenticated;
grant select                 on public.reveil  to anon, authenticated;
grant execute on function public.mon_role() to authenticated;
-- Fonctions internes : pas appelables depuis l'extérieur
revoke execute on function public.mon_role() from public, anon;
revoke execute on function public.garde_gerant() from public, anon, authenticated;
revoke execute on function public.nouveau_profil() from public, anon, authenticated;
revoke execute on function public.items_horodatage() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='rls_auto_enable') then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end $$;

-- 7) Temps réel : les autres téléphones sont prévenus des changements
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='items') then
    alter publication supabase_realtime add table public.items;
  end if;
end $$;

select 'OK — base SOGEI prête (admin : ' || coalesce((select string_agg(email, ', ') from public.profils where role='admin'),'aucun pour l’instant') || ')' as resultat;

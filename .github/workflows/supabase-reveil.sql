-- À exécuter une fois dans Supabase (SQL Editor) : table lue par le réveil automatique.
create table if not exists public.reveil (id int primary key default 1, note text default 'ping');
insert into public.reveil (id) values (1) on conflict do nothing;
alter table public.reveil enable row level security;
create policy "lecture publique du réveil" on public.reveil for select using (true);

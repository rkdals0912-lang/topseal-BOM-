-- TOPSEAL BOM Web App - Supabase schema
-- 현재 HTML의 state.productDb를 JSONB로 저장하여 기존 계산/검색 구조를 최대한 유지합니다.
--
-- 주의: 아래 RLS 정책은 로그인 없는 무료 테스트용입니다.
-- Public GitHub Pages 주소를 아는 사람이 BOM을 읽고/수정/삭제할 수 있습니다.
-- 사내 실사용 전에는 Supabase Auth + authenticated RLS로 전환하세요.

create extension if not exists pgcrypto;

create table if not exists public.bom_products (
  id uuid primary key default gen_random_uuid(),
  product_key text not null unique,
  product_code text not null default '',
  product_name text not null default '',
  bom_version text not null default '',
  is_default_bom boolean not null default false,
  product_json jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_bom_products_code on public.bom_products(product_code);
create index if not exists idx_bom_products_name on public.bom_products(product_name);
create index if not exists idx_bom_products_version on public.bom_products(bom_version);

create or replace function public.set_bom_products_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_bom_products_updated_at on public.bom_products;
create trigger trg_bom_products_updated_at
before update on public.bom_products
for each row execute function public.set_bom_products_updated_at();

alter table public.bom_products enable row level security;

revoke all on table public.bom_products from anon, authenticated;
grant select, insert, update, delete on table public.bom_products to anon, authenticated;

drop policy if exists "bom_products_anon_select" on public.bom_products;
drop policy if exists "bom_products_anon_insert" on public.bom_products;
drop policy if exists "bom_products_anon_update" on public.bom_products;
drop policy if exists "bom_products_anon_delete" on public.bom_products;

create policy "bom_products_anon_select"
on public.bom_products for select to anon
using (true);

create policy "bom_products_anon_insert"
on public.bom_products for insert to anon
with check (true);

create policy "bom_products_anon_update"
on public.bom_products for update to anon
using (true) with check (true);

create policy "bom_products_anon_delete"
on public.bom_products for delete to anon
using (true);

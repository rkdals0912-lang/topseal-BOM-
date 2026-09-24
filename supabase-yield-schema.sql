-- TOPSEAL BOM - 수율 / LSL 보정 스키마 (추가분)
-- 기존 supabase-schema.sql 실행 후, SQL Editor에서 이어서 실행하세요. (재실행 안전)
--
-- 설계 원칙
--  * 반제품은 별도 테이블을 만들지 않고 기존 public.bom_products(product_code)를 그대로 사용
--  * 라인코드(B_O200)로 시작하는 product_code를 뷰에서 자동 연결
--  * 기존 앱과 동일하게 anon 전체 허용 RLS (로그인 없는 테스트용 - 사내 운영 전 Auth 전환 필요)

-- 1. 제품 라인 -------------------------------------------------------------
create table if not exists public.product_lines (
  line_code    text primary key check (line_code ~ '^B_'),   -- 예: B_O200
  line_name    text not null,                                   -- 예: O200
  target_yield numeric(5,2) not null default 98.00,
  lsl_standard numeric(5,2) not null default 95.00,
  sigma_level  numeric(4,2) not null default 3 check (sigma_level > 0),  -- 관리한계 σ 수준(k)
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 이미 product_lines를 만든 기존 DB에는 이 문장만 추가로 실행하세요.
alter table public.product_lines
  add column if not exists sigma_level numeric(4,2) not null default 3 check (sigma_level > 0);

-- 라인명만 넣어도 B_ 코드 자동 생성 (line_code를 비워두는 대신 함수 제공)
create or replace function public.add_product_line(p_name text,
  p_target numeric default 98, p_lsl numeric default 95)
returns public.product_lines
language sql
as $$
  insert into public.product_lines(line_code, line_name, target_yield, lsl_standard)
  values ('B_' || upper(trim(p_name)), upper(trim(p_name)), p_target, p_lsl)
  on conflict (line_code) do update
    set target_yield = excluded.target_yield, lsl_standard = excluded.lsl_standard
  returning *;
$$;

-- 2. 생산 실적 -------------------------------------------------------------
create table if not exists public.production_records (
  id            bigint generated always as identity primary key,
  line_code     text not null references public.product_lines(line_code) on update cascade,
  prod_date     date not null,
  lot_no        text not null default '',
  batch_size_kg numeric(12,3) not null check (batch_size_kg > 0),
  actual_output_kg numeric(12,3) not null check (actual_output_kg >= 0),
  actual_yield  numeric(7,3) generated always as
                  (round(actual_output_kg / batch_size_kg * 100, 3)) stored,
  note          text not null default '',
  created_at    timestamptz not null default now()
);
create index if not exists idx_prod_rec_line_date on public.production_records(line_code, prod_date);

-- 3. 분기별 LSL 보정 -------------------------------------------------------
create table if not exists public.lsl_adjustments (
  id               bigint generated always as identity primary key,
  year             int  not null check (year between 2000 and 2100),
  quarter          text not null check (quarter in ('Q1','Q2','Q3','Q4')),
  line_code        text not null references public.product_lines(line_code) on update cascade,
  base_yield       numeric(5,2) not null,     -- 기존 수율 기준값(%)
  actual_avg_yield numeric(6,3) not null,     -- 실제 평균 수율(%)
  lsl_adjustment   numeric(6,3) not null,     -- LSL 보정값(%p), 소수 3자리
  adjusted_yield   numeric(6,3) generated always as (actual_avg_yield - lsl_adjustment) stored,
  valid_from       date generated always as
                     (make_date(year, (substr(quarter,2,1)::int - 1) * 3 + 1, 1)) stored,
  valid_to         date generated always as
                     ((make_date(year, (substr(quarter,2,1)::int - 1) * 3 + 1, 1)
                       + interval '3 months' - interval '1 day')::date) stored,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (year, quarter, line_code)
);

-- updated_at 트리거 (기존 set_bom_products_updated_at 재사용 가능하나 독립 함수로 정의)
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists trg_product_lines_updated_at on public.product_lines;
create trigger trg_product_lines_updated_at before update on public.product_lines
for each row execute function public.set_updated_at();

drop trigger if exists trg_lsl_adjustments_updated_at on public.lsl_adjustments;
create trigger trg_lsl_adjustments_updated_at before update on public.lsl_adjustments
for each row execute function public.set_updated_at();

-- 4. 뷰 --------------------------------------------------------------------
-- 4-1. 라인 ↔ BOM 품목 자동 연결
--  * starts_with 사용 (LIKE는 '_'가 와일드카드라 B_O200 이 BXO200 도 매칭함)
--  * B_O20 / B_O200 처럼 접두사가 겹치면 가장 긴 라인코드에 연결
create or replace view public.view_line_bom_products as
select distinct on (bp.id)
       pl.line_code, pl.line_name,
       bp.id as bom_product_id, bp.product_code, bp.product_name,
       bp.bom_version, bp.is_default_bom
from public.bom_products bp
join public.product_lines pl on starts_with(bp.product_code, pl.line_code)
order by bp.id, length(pl.line_code) desc;

-- 4-2. 라인·분기별 실적 평균 (Batch 가중 평균: 총취출량/총Batch)
create or replace view public.view_quarterly_yield as
select line_code,
       extract(year from prod_date)::int as year,
       'Q' || extract(quarter from prod_date)::int as quarter,
       count(*)                                   as batch_count,
       sum(batch_size_kg)                         as total_batch_kg,
       sum(actual_output_kg)                      as total_output_kg,
       round(sum(actual_output_kg) / sum(batch_size_kg) * 100, 3) as weighted_avg_yield,
       round(avg(actual_yield), 3)                as simple_avg_yield,
       min(actual_yield) as min_yield, max(actual_yield) as max_yield
from public.production_records
group by 1, 2, 3;

-- 4-3. 차트용 통합 뷰: 목표 / 실제평균 / LSL기준 / 보정값 / 보정후 수율
create or replace view public.view_yield_chart as
select q.year, q.quarter, pl.line_code, pl.line_name,
       pl.target_yield, pl.lsl_standard,
       q.weighted_avg_yield as actual_avg_yield,
       coalesce(a.lsl_adjustment, 0) as lsl_adjustment,
       coalesce(a.adjusted_yield, q.weighted_avg_yield) as adjusted_yield,
       q.batch_count
from public.product_lines pl
left join public.view_quarterly_yield q on q.line_code = pl.line_code
left join public.lsl_adjustments a
       on a.line_code = q.line_code and a.year = q.year and a.quarter = q.quarter;

-- 5. RLS (기존 bom_products와 동일한 anon 테스트 정책) ---------------------
do $$
declare t text;
begin
  foreach t in array array['product_lines','production_records','lsl_adjustments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
    execute format('drop policy if exists "%s_anon_all" on public.%I', t, t);
    execute format('create policy "%s_anon_all" on public.%I for all to anon using (true) with check (true)', t, t);
  end loop;
end $$;

-- 뷰는 호출자 권한으로 RLS 적용
alter view public.view_line_bom_products set (security_invoker = true);
alter view public.view_quarterly_yield   set (security_invoker = true);
alter view public.view_yield_chart       set (security_invoker = true);
grant select on public.view_line_bom_products, public.view_quarterly_yield,
                public.view_yield_chart to anon, authenticated;

-- 6. 샘플 (필요 시 주석 해제) ----------------------------------------------
-- select public.add_product_line('O200', 98.0, 95.0);
-- insert into public.production_records(line_code, prod_date, batch_size_kg, actual_output_kg)
-- values ('B_O200', '2026-08-10', 1000, 968.5);
-- insert into public.lsl_adjustments(year, quarter, line_code, base_yield, actual_avg_yield, lsl_adjustment)
-- values (2026, 'Q3', 'B_O200', 98.0, 96.8, 0.800);
-- select * from public.view_yield_chart where year = 2026 and quarter = 'Q3';

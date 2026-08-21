create extension if not exists pg_stat_statements;
create extension if not exists pgcrypto;

create table if not exists tasks (
    id uuid primary key default gen_random_uuid(),
    status text not null default 'todo' check (status in ('todo', 'doing', 'done')),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create or replace function seed_tasks() returns void
language plpgsql
as $$
begin
    if exists (select 1 from tasks) then
        return;
    end if;
    insert into tasks (title, status, created_at, updated_at)
    select
        (array['Write the demo runbook', 'Fix the flaky readiness probe', 'Review the ingress config', 'Update Go dependencies', 'Refactor the cache layer', 'Ship the release notes', 'Tune the golden dashboard', 'Rotate the trial credentials', 'Groom the task backlog', 'Draft the postmortem'])[1 + (i % 10)] || ' #' || i,
        (array['todo', 'doing', 'done'])[1 + floor(random() * 3)::int],
        created,
        least(created + random() * interval '3 days', now())
    from (
        select i, now() - random() * interval '14 days' as created
        from generate_series(1, 50) as i
    ) seeded;
end;
$$;

select seed_tasks();

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'monitor') then
        create role monitor with login password 'monitor';
    end if;
end;
$$;

grant pg_monitor to monitor;
grant connect on database tasklog to monitor;
grant usage on schema public to monitor;
grant select on all tables in schema public to monitor;

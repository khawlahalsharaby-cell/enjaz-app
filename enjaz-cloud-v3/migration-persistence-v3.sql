-- Enjaz V3: persistent personal data keyed to the signed-in Supabase auth user.
-- Run once in Supabase Dashboard > SQL Editor after the existing supabase.sql and migration-v2.sql.
-- The JSON state holds daily tasks, completion timestamps, history, goals and goal history.

create table if not exists public.enjaz_personal_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  state jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint enjaz_personal_state_json_object check (jsonb_typeof(state) = 'object')
);

alter table public.enjaz_personal_state enable row level security;

drop policy if exists "users can read own enjaz personal state" on public.enjaz_personal_state;
create policy "users can read own enjaz personal state"
  on public.enjaz_personal_state for select to authenticated
  using (auth.uid() = user_id);

drop policy if exists "users can create own enjaz personal state" on public.enjaz_personal_state;
create policy "users can create own enjaz personal state"
  on public.enjaz_personal_state for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "users can update own enjaz personal state" on public.enjaz_personal_state;
create policy "users can update own enjaz personal state"
  on public.enjaz_personal_state for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

grant select, insert, update on public.enjaz_personal_state to authenticated;

-- Move existing competition tasks onto the simple, consistent scoring rule:
-- regular task = 1 point; featured task = 2 points. Goals have their own progress percentage.
-- Old task IDs/titles/status/timestamps are retained. The legacy priority/difficulty fields
-- are kept for compatibility with the existing weekly-summary function.
do $$
begin
  if to_regclass('public.enjaz_competitions') is not null then
    update public.enjaz_competitions c
    set state = jsonb_set(
      c.state,
      '{participants}',
      coalesce((
        select jsonb_agg(
          person.value || jsonb_build_object(
            'tasks', coalesce((
              select jsonb_agg(
                task.value || jsonb_build_object(
                  'points',
                    case
                      when coalesce(task.value->>'points','') ~ '^[12]$'
                        then (task.value->>'points')::integer
                      when coalesce(task.value->>'priority','') ~ '^[1-3]$'
                        then least(2, greatest(1, (task.value->>'priority')::integer))
                      when coalesce(task.value->>'priority','') like '%عال%'
                        then 2
                      else 1
                    end,
                  'priority',
                    case
                      when coalesce(task.value->>'points','') ~ '^[12]$'
                        then (task.value->>'points')::integer
                      when coalesce(task.value->>'priority','') ~ '^[1-3]$'
                        then least(2, greatest(1, (task.value->>'priority')::integer))
                      when coalesce(task.value->>'priority','') like '%عال%'
                        then 2
                      else 1
                    end,
                  'difficulty', 1
                ) order by task.ordinality
              )
              from jsonb_array_elements(coalesce(person.value->'tasks','[]'::jsonb))
                with ordinality as task(value, ordinality)
            ), '[]'::jsonb)
          ) order by person.ordinality
        )
        from jsonb_array_elements(coalesce(c.state->'participants','[]'::jsonb))
          with ordinality as person(value, ordinality)
      ), '[]'::jsonb),
      true
    )
    where jsonb_typeof(c.state->'participants') = 'array';
  end if;
end $$;

comment on table public.enjaz_personal_state is
  'One private personal-state record per Supabase Auth user. RLS restricts each account to its own data.';

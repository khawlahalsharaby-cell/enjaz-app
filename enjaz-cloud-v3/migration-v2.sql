-- إنجاز V2: منافسات فردية مرنة ومنافسات بالفرق، مع حفظ آمن لكل عضوة.
-- شغّلي هذا الملف مرة واحدة في Supabase > SQL Editor > Run.
-- يحافظ على جدول المنافسات الحالي والبيانات السابقة.

create or replace function public.enjaz_create_competition_v2(
  p_code text,
  p_name text,
  p_kind text,
  p_teams jsonb default '[]'::jsonb,
  p_team_id text default null,
  p_today text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_name text := left(trim(coalesce(p_name, '')), 35);
  v_kind text := lower(trim(coalesce(p_kind, 'individual')));
  v_teams jsonb := coalesce(p_teams, '[]'::jsonb);
  v_today text := coalesce(nullif(p_today, ''), to_char(current_date, 'YYYY-MM-DD'));
  v_state jsonb;
begin
  if auth.uid() is null then raise exception 'سجّلي دخولًا أولًا'; end if;
  if v_code !~ '^[A-Z0-9]{4,8}$' then raise exception 'رمز المنافسة غير صالح'; end if;
  if v_name = '' then raise exception 'اكتبي اسمك'; end if;
  if v_kind not in ('individual', 'teams') then raise exception 'نوع المنافسة غير صحيح'; end if;
  if jsonb_typeof(v_teams) <> 'array' then raise exception 'قائمة الفرق غير صالحة'; end if;
  if v_kind = 'individual' then
    v_teams := '[]'::jsonb;
    p_team_id := null;
  else
    if jsonb_array_length(v_teams) < 2 then raise exception 'أضيفي فريقين على الأقل'; end if;
    if not exists(select 1 from jsonb_array_elements(v_teams) t where t->>'id' = p_team_id) then
      raise exception 'اختاري الفريق الذي تنتمين إليه';
    end if;
  end if;
  v_state := jsonb_build_object(
    'kind', v_kind,
    'owner_id', auth.uid()::text,
    'teams', v_teams,
    'date', v_today,
    'week_start', date_trunc('week', v_today::date)::date::text,
    'weekly_summary', null,
    'history', '[]'::jsonb,
    'participants', jsonb_build_array(jsonb_build_object(
      'user_id', auth.uid()::text,
      'name', v_name,
      'team_id', p_team_id,
      'tasks', '[]'::jsonb,
      'goals', '[]'::jsonb,
      'joined_at', now()
    ))
  );
  insert into public.enjaz_competitions(code, state) values (v_code, v_state);
  return jsonb_build_object('code', v_code, 'state', v_state);
end;
$$;

create or replace function public.enjaz_get_competition_info_v2(p_code text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_state jsonb; v_code text := upper(trim(coalesce(p_code, '')));
begin
  select state into v_state from public.enjaz_competitions where code = v_code;
  if v_state is null then raise exception 'لم نجد منافسة بهذا الرمز'; end if;
  return jsonb_build_object(
    'code', v_code,
    'kind', coalesce(v_state->>'kind', 'individual'),
    'teams', coalesce(v_state->'teams', '[]'::jsonb),
    'participant_count', jsonb_array_length(coalesce(v_state->'participants', '[]'::jsonb))
  );
end;
$$;

create or replace function public.enjaz_join_competition_v2(
  p_code text,
  p_name text,
  p_team_id text default null,
  p_today text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_name text := left(trim(coalesce(p_name, '')), 35);
  v_uid text := auth.uid()::text;
  v_state jsonb;
  v_people jsonb;
  v_kind text;
  v_owner text;
  v_teams jsonb;
  v_person jsonb;
begin
  if auth.uid() is null then raise exception 'سجّلي دخولًا أولًا'; end if;
  if v_name = '' then raise exception 'اكتبي اسمك'; end if;
  select state into v_state from public.enjaz_competitions where code = v_code for update;
  if v_state is null then raise exception 'رمز المنافسة غير صحيح'; end if;

  v_people := coalesce(v_state->'participants', '[]'::jsonb);
  v_kind := coalesce(v_state->>'kind', 'individual');
  v_teams := coalesce(v_state->'teams', '[]'::jsonb);
  select p->>'user_id' into v_owner from jsonb_array_elements(v_people) a(p) limit 1;
  v_state := v_state || jsonb_build_object(
    'kind', v_kind,
    'owner_id', coalesce(v_state->>'owner_id', v_owner, v_uid),
    'teams', v_teams
  );

  select p into v_person from jsonb_array_elements(v_people) a(p) where p->>'user_id' = v_uid limit 1;
  if v_person is not null then
    return jsonb_build_object('code', v_code, 'state', v_state);
  end if;

  if v_kind = 'teams' then
    if not exists(select 1 from jsonb_array_elements(v_teams) t where t->>'id' = p_team_id) then
      raise exception 'اختاري فريقًا صالحًا قبل الانضمام';
    end if;
  else
    p_team_id := null;
  end if;

  v_person := jsonb_build_object(
    'user_id', v_uid,
    'name', v_name,
    'team_id', p_team_id,
    'tasks', '[]'::jsonb,
    'goals', '[]'::jsonb,
    'joined_at', now()
  );
  v_people := v_people || jsonb_build_array(v_person);
  v_state := jsonb_set(v_state, '{participants}', v_people, true);
  update public.enjaz_competitions set state = v_state, updated_at = now() where code = v_code;
  return jsonb_build_object('code', v_code, 'state', v_state);
end;
$$;

-- تحفظ هذه الوظيفة مهام وأهداف العضوة الحالية فقط، وتدمجها بالحالة المحفوظة في الخادم.
-- بذلك لا تستبدل تحديثات مشاركة أخرى إذا عملن في الوقت نفسه.
create or replace function public.enjaz_save_competition_v2(
  p_code text,
  p_tasks jsonb,
  p_goals jsonb,
  p_today text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_today text := coalesce(nullif(p_today, ''), to_char(current_date, 'YYYY-MM-DD'));
  v_uid text := auth.uid()::text;
  v_state jsonb;
  v_people jsonb;
  v_history jsonb;
  v_trimmed_history jsonb;
  v_person jsonb;
  v_new_people jsonb := '[]'::jsonb;
  v_owner text;
  v_found boolean := false;
  v_date text;
  v_week_start text;
  v_new_week_start text;
  v_weekly_people jsonb;
  v_weekly_summary jsonb;
begin
  if auth.uid() is null then raise exception 'سجّلي دخولًا أولًا'; end if;
  if jsonb_typeof(coalesce(p_tasks, '[]'::jsonb)) <> 'array' then raise exception 'قائمة المهام غير صالحة'; end if;
  if jsonb_typeof(coalesce(p_goals, '[]'::jsonb)) <> 'array' then raise exception 'قائمة الأهداف غير صالحة'; end if;
  select state into v_state from public.enjaz_competitions where code = v_code for update;
  if v_state is null then raise exception 'المنافسة غير موجودة'; end if;
  v_people := coalesce(v_state->'participants', '[]'::jsonb);
  if not exists(select 1 from jsonb_array_elements(v_people) a(p) where p->>'user_id' = v_uid) then
    raise exception 'لم تعودي مشاركة في هذه المنافسة';
  end if;
  select p->>'user_id' into v_owner from jsonb_array_elements(v_people) a(p) limit 1;
  v_state := v_state || jsonb_build_object(
    'kind', coalesce(v_state->>'kind', 'individual'),
    'owner_id', coalesce(v_state->>'owner_id', v_owner, v_uid),
    'teams', coalesce(v_state->'teams', '[]'::jsonb)
  );
  v_date := coalesce(v_state->>'date', v_today);
  v_new_week_start := date_trunc('week', v_today::date)::date::text;
  v_week_start := coalesce(v_state->>'week_start', date_trunc('week', v_date::date)::date::text);
  v_weekly_summary := v_state->'weekly_summary';

  -- إغلاق اليوم السابق مرة واحدة عند أول حفظ بعد تغير التاريخ.
  if v_date <> v_today then
    v_history := jsonb_build_array(jsonb_build_object('date', v_date, 'participants', v_people)) || coalesce(v_state->'history', '[]'::jsonb);

    -- عند الانتقال لأسبوع جديد نحفظ ملخصًا ثابتًا للأسبوع السابق، يشمل المهام والأهداف الطويلة.
    if v_week_start <> v_new_week_start then
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', x.user_id,
        'name', x.name,
        'tasks_added', x.tasks_added,
        'completed', x.completed,
        'points', x.points,
        'goals', x.goals
      )), '[]'::jsonb)
      into v_weekly_people
      from (
        select cp.person->>'user_id' as user_id,
          cp.person->>'name' as name,
          coalesce(st.tasks_added, 0) as tasks_added,
          coalesce(st.completed, 0) as completed,
          coalesce(st.points, 0) as points,
          coalesce(cp.person->'goals', '[]'::jsonb) as goals
        from jsonb_array_elements(v_people) as cp(person)
        left join lateral (
          select count(*)::integer as tasks_added,
            count(*) filter (where t.task->>'done' = 'true')::integer as completed,
            coalesce(sum(case when t.task->>'done' = 'true' then
              (case
                when coalesce(t.task->>'priority', '') ~ '^[1-3]$' then (t.task->>'priority')::integer
                when coalesce(t.task->>'priority', '') like '%عال%' then 3
                when coalesce(t.task->>'priority', '') like '%منخفض%' then 1
                else 2
              end) * (case when coalesce(t.task->>'difficulty', '') ~ '^[1-3]$' then (t.task->>'difficulty')::integer else 2 end)
              else 0 end), 0) as points
          from jsonb_array_elements(v_history) as d(entry)
          cross join lateral jsonb_array_elements(coalesce(d.entry->'participants', '[]'::jsonb)) as hp(person)
          cross join lateral jsonb_array_elements(coalesce(hp.person->'tasks', '[]'::jsonb)) as t(task)
          where hp.person->>'user_id' = cp.person->>'user_id'
            and d.entry->>'date' >= v_week_start
            and d.entry->>'date' < v_new_week_start
        ) st on true
      ) x;
      v_weekly_summary := jsonb_build_object(
        'start', v_week_start,
        'end', (v_new_week_start::date - 1)::text,
        'participants', coalesce(v_weekly_people, '[]'::jsonb)
      );
      v_week_start := v_new_week_start;
    end if;

    select coalesce(jsonb_agg(e.value order by e.ord), '[]'::jsonb) into v_trimmed_history
      from jsonb_array_elements(v_history) with ordinality e(value, ord) where e.ord <= 7;
    v_people := '[]'::jsonb;
    for v_person in select value from jsonb_array_elements(coalesce(v_state->'participants', '[]'::jsonb)) loop
      v_person := jsonb_set(v_person, '{tasks}', '[]'::jsonb, true);
      v_people := v_people || jsonb_build_array(v_person);
    end loop;
    v_state := jsonb_set(v_state, '{history}', v_trimmed_history, true);
    v_state := jsonb_set(v_state, '{date}', to_jsonb(v_today), true);
    v_state := jsonb_set(v_state, '{participants}', v_people, true);
    v_state := jsonb_set(v_state, '{week_start}', to_jsonb(v_week_start), true);
    v_state := jsonb_set(v_state, '{weekly_summary}', coalesce(v_weekly_summary, 'null'::jsonb), true);
  else
    if v_state->>'week_start' is null then
      v_state := jsonb_set(v_state, '{week_start}', to_jsonb(v_week_start), true);
    end if;
    if v_state->'weekly_summary' is null then
      v_state := jsonb_set(v_state, '{weekly_summary}', 'null'::jsonb, true);
    end if;
  end if;

  v_people := '[]'::jsonb;
  for v_person in select value from jsonb_array_elements(coalesce(v_state->'participants', '[]'::jsonb)) loop
    if v_person->>'user_id' = v_uid then
      v_person := jsonb_set(v_person, '{tasks}', coalesce(p_tasks, '[]'::jsonb), true);
      v_person := jsonb_set(v_person, '{goals}', coalesce(p_goals, '[]'::jsonb), true);
      v_found := true;
    end if;
    v_new_people := v_new_people || jsonb_build_array(v_person);
  end loop;
  if not v_found then raise exception 'لم تعودي مشاركة في هذه المنافسة'; end if;
  v_state := jsonb_set(v_state, '{participants}', v_new_people, true);
  update public.enjaz_competitions set state = v_state, updated_at = now() where code = v_code;
  return v_state;
end;
$$;

create or replace function public.enjaz_manage_participant_v2(
  p_code text,
  p_action text,
  p_target_user_id text,
  p_name text default null,
  p_team_id text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(trim(coalesce(p_code, '')));
  v_uid text := auth.uid()::text;
  v_state jsonb;
  v_people jsonb;
  v_new_people jsonb := '[]'::jsonb;
  v_person jsonb;
  v_owner text;
  v_found boolean := false;
begin
  if auth.uid() is null then raise exception 'سجّلي دخولًا أولًا'; end if;
  select state into v_state from public.enjaz_competitions where code = v_code for update;
  if v_state is null then raise exception 'المنافسة غير موجودة'; end if;
  v_people := coalesce(v_state->'participants', '[]'::jsonb);
  v_owner := coalesce(v_state->>'owner_id', (select p->>'user_id' from jsonb_array_elements(v_people) a(p) limit 1));

  if p_action = 'rename' then
    if p_target_user_id <> v_uid then raise exception 'يمكنك تعديل اسمك فقط'; end if;
    if trim(coalesce(p_name, '')) = '' then raise exception 'الاسم لا يمكن أن يكون فارغًا'; end if;
  elsif p_action = 'remove' then
    if v_owner <> v_uid then raise exception 'إزالة المشاركات متاحة لصاحبة المنافسة فقط'; end if;
    if p_target_user_id = v_owner then raise exception 'لا يمكن إزالة صاحبة المنافسة'; end if;
  elsif p_action = 'assign_team' then
    if v_owner <> v_uid then raise exception 'تغيير الفريق متاح لصاحبة المنافسة فقط'; end if;
    if coalesce(v_state->>'kind', 'individual') <> 'teams' then raise exception 'هذه منافسة فردية وليست بالفرق'; end if;
    if not exists(select 1 from jsonb_array_elements(coalesce(v_state->'teams', '[]'::jsonb)) t where t->>'id' = p_team_id) then raise exception 'الفريق غير موجود'; end if;
  else
    raise exception 'طلب الإدارة غير معروف';
  end if;

  for v_person in select value from jsonb_array_elements(v_people) loop
    if v_person->>'user_id' = p_target_user_id then
      v_found := true;
      if p_action = 'remove' then continue; end if;
      if p_action = 'rename' then v_person := jsonb_set(v_person, '{name}', to_jsonb(left(trim(p_name), 35)), true); end if;
      if p_action = 'assign_team' then v_person := jsonb_set(v_person, '{team_id}', to_jsonb(p_team_id), true); end if;
    end if;
    v_new_people := v_new_people || jsonb_build_array(v_person);
  end loop;
  if not v_found then raise exception 'المشاركة غير موجودة'; end if;
  v_state := jsonb_set(v_state, '{participants}', v_new_people, true);
  v_state := v_state || jsonb_build_object('owner_id', coalesce(v_state->>'owner_id', v_owner), 'kind', coalesce(v_state->>'kind', 'individual'), 'teams', coalesce(v_state->'teams', '[]'::jsonb));
  update public.enjaz_competitions set state = v_state, updated_at = now() where code = v_code;
  return v_state;
end;
$$;

grant execute on function public.enjaz_create_competition_v2(text,text,text,jsonb,text,text) to authenticated;
grant execute on function public.enjaz_get_competition_info_v2(text) to authenticated;
grant execute on function public.enjaz_join_competition_v2(text,text,text,text) to authenticated;
grant execute on function public.enjaz_save_competition_v2(text,jsonb,jsonb,text) to authenticated;
grant execute on function public.enjaz_manage_participant_v2(text,text,text,text,text) to authenticated;

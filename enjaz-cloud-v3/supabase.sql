-- إنجاز: إعداد المنافسة المشتركة
-- فعّلي Anonymous Sign-ins من Supabase > Authentication > Sign In / Providers.
create table if not exists public.enjaz_competitions (
  code text primary key,
  state jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.enjaz_competitions enable row level security;

create or replace function public.enjaz_is_member(p_code text)
returns boolean language sql security definer set search_path = public stable as $$
  select exists (
    select 1 from public.enjaz_competitions c,
      jsonb_array_elements(coalesce(c.state->'participants','[]'::jsonb)) as x(p)
    where c.code = p_code and p->>'user_id' = auth.uid()::text
  );
$$;

 drop policy if exists "members can read their competition" on public.enjaz_competitions;
create policy "members can read their competition" on public.enjaz_competitions
for select to authenticated using (public.enjaz_is_member(code));

create or replace function public.enjaz_create_competition(p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_state jsonb;
begin
  if auth.uid() is null then raise exception 'سجّلي دخولًا مجهولًا أولًا'; end if;
  v_state := jsonb_build_object(
    'date', to_char(current_date, 'YYYY-MM-DD'),
    'history', '[]'::jsonb,
    'participants', jsonb_build_array(jsonb_build_object(
      'user_id', auth.uid()::text, 'name', left(trim(p_name),35), 'tasks', '[]'::jsonb
    ))
  );
  insert into public.enjaz_competitions(code,state) values (upper(p_code),v_state);
  return jsonb_build_object('code',upper(p_code),'state',v_state);
end; $$;

create or replace function public.enjaz_join_competition(p_code text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_state jsonb; v_people jsonb; v_uid text := auth.uid()::text;
begin
  if auth.uid() is null then raise exception 'سجّلي دخولًا مجهولًا أولًا'; end if;
  select state into v_state from public.enjaz_competitions where code=upper(trim(p_code)) for update;
  if v_state is null then raise exception 'رمز المنافسة غير صحيح'; end if;
  v_people := coalesce(v_state->'participants','[]'::jsonb);
  if exists(select 1 from jsonb_array_elements(v_people) as x(p) where p->>'user_id'=v_uid) then
    return jsonb_build_object('code',upper(trim(p_code)),'state',v_state);
  end if;
  if jsonb_array_length(v_people) >= 3 then raise exception 'اكتمل عدد المشاركين في هذه المنافسة'; end if;
  v_people := v_people || jsonb_build_array(jsonb_build_object('user_id',v_uid,'name',left(trim(p_name),35),'tasks','[]'::jsonb));
  v_state := jsonb_set(v_state,'{participants}',v_people);
  update public.enjaz_competitions set state=v_state,updated_at=now() where code=upper(trim(p_code));
  return jsonb_build_object('code',upper(trim(p_code)),'state',v_state);
end; $$;

create or replace function public.enjaz_save_competition(p_code text, p_state jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.enjaz_is_member(upper(trim(p_code))) then raise exception 'لستِ ضمن هذه المنافسة'; end if;
  -- لا تسمحي للعميل بإزالة أعضاء الغرفة أو تبديل هوياتهم.
  if exists (
    select 1 from jsonb_array_elements(coalesce((select state->'participants' from public.enjaz_competitions where code=upper(trim(p_code))),'[]'::jsonb)) as old_rows(oldp)
    where not exists (select 1 from jsonb_array_elements(coalesce(p_state->'participants','[]'::jsonb)) as new_rows(newp) where newp->>'user_id'=oldp->>'user_id')
  ) then raise exception 'قائمة المشاركين غير صالحة'; end if;
  update public.enjaz_competitions set state=p_state,updated_at=now() where code=upper(trim(p_code));
  return true;
end; $$;

grant select on public.enjaz_competitions to authenticated;
grant execute on function public.enjaz_is_member(text) to authenticated;
grant execute on function public.enjaz_create_competition(text,text) to authenticated;
grant execute on function public.enjaz_join_competition(text,text) to authenticated;
grant execute on function public.enjaz_save_competition(text,jsonb) to authenticated;

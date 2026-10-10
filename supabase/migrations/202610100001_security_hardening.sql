-- Tighten permissions if the earlier starter migration was already applied.
begin;

create or replace function public.review_application(
  p_application_id uuid,
  p_new_status public.application_status,
  p_score integer default null,
  p_comment text default null,
  p_rubric jsonb default '{}'::jsonb
) returns public.applications
language plpgsql security definer set search_path = '' as $$
declare
  app public.applications;
  old_status public.application_status;
begin
  if coalesce(public.current_role()::text,'') not in ('reviewer','admin') then raise exception 'Reviewer access required'; end if;
  if public.current_role() = 'reviewer' and not public.is_assigned(p_application_id) then raise exception 'Application is not assigned to you'; end if;
  select * into app from public.applications where id=p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  old_status := app.status;
  if not (
    (old_status='submitted' and p_new_status='under_review') or
    (old_status='under_review' and p_new_status in ('needs_information','shortlisted','declined')) or
    (old_status='needs_information' and p_new_status='under_review') or
    (old_status='shortlisted' and p_new_status in ('approved','not_selected'))
  ) then raise exception 'Invalid status transition: % -> %', old_status, p_new_status; end if;
  if p_score is not null and p_score not between 0 and 100 then raise exception 'Score must be between 0 and 100'; end if;
  update public.applications set status=p_new_status, updated_at=now(),
    application_data=case when p_new_status='needs_information' then application_data || jsonb_build_object('clarification_request',coalesce(nullif(p_rubric->>'clarification_request',''),'Please provide one more detail so the committee can continue reviewing your application.')) else application_data end
    where id=p_application_id returning * into app;
  insert into public.reviews(application_id,reviewer_id,purpose_score,impact_score,readiness_score,committee_note,recommendation,updated_at)
  values (p_application_id,(select auth.uid()),nullif((p_rubric->>'purpose')::integer,0),nullif((p_rubric->>'impact')::integer,0),nullif((p_rubric->>'readiness')::integer,0),p_comment,case when p_new_status in ('needs_information','shortlisted','declined') then p_new_status else null end,now())
  on conflict(application_id,reviewer_id) do update set purpose_score=coalesce(excluded.purpose_score,public.reviews.purpose_score),impact_score=coalesce(excluded.impact_score,public.reviews.impact_score),readiness_score=coalesce(excluded.readiness_score,public.reviews.readiness_score),committee_note=coalesce(excluded.committee_note,public.reviews.committee_note),recommendation=coalesce(excluded.recommendation,public.reviews.recommendation),updated_at=now();
  insert into public.application_audit(application_id,actor_id,action,from_status,to_status,details)
  values(p_application_id,(select auth.uid()),'status_changed',old_status,p_new_status,jsonb_build_object('score',p_score,'comment',p_comment,'rubric',p_rubric));
  return app;
end $$;

create or replace function public.submit_application(p_application_id uuid) returns public.applications
language plpgsql security definer set search_path = '' as $$
declare
  app public.applications;
  old_status public.application_status;
begin
  select * into app from public.applications where id=p_application_id and student_id=(select auth.uid()) for update;
  if not found then raise exception 'Draft not found'; end if;
  if not exists(select 1 from public.scholarships s where s.id=app.scholarship_id and s.is_active and s.deadline >= now()) then raise exception 'This scholarship is closed or its deadline has passed'; end if;
  if app.status not in ('draft','needs_information') then raise exception 'Application cannot be submitted from this status'; end if;
  old_status := app.status;
  if coalesce(app.application_data->>'fullName','')='' or coalesce(app.application_data->>'email','')='' or coalesce(app.application_data->>'program','')='' or length(coalesce(app.application_data->>'essay',''))<80 then raise exception 'Complete required application fields before submitting'; end if;
  if not exists(select 1 from public.application_documents d where d.application_id=app.id and d.document_type='class_xii_marksheet') then raise exception 'A Class XII or previous-year marksheet is required'; end if;
  if not exists(select 1 from public.application_documents d where d.application_id=app.id and d.document_type='family_income_certificate') then raise exception 'A family income certificate is required'; end if;
  update public.applications set status='submitted',submitted_at=coalesce(submitted_at,now()),updated_at=now() where id=app.id returning * into app;
  insert into public.application_audit(application_id,actor_id,action,from_status,to_status) values(app.id,(select auth.uid()),'application_submitted',old_status,'submitted');
  return app;
end $$;

drop policy if exists "Reviewer writes own assigned review" on public.reviews;
drop policy if exists "Reviewer updates own assigned review" on public.reviews;
revoke insert, update, delete on public.reviews from public, anon, authenticated;
revoke update on public.applications from public, anon, authenticated;
grant update(application_data) on public.applications to authenticated;
revoke update on public.profiles from public, anon, authenticated;
grant update(full_name) on public.profiles to authenticated;
drop policy if exists "Audit visible to owner and assigned committee" on public.application_audit;
drop policy if exists "Audit visible to assigned committee" on public.application_audit;
create policy "Audit visible to assigned committee" on public.application_audit for select to authenticated using(public.current_role()='admin' or public.is_assigned(application_id));
drop policy if exists "Students remove documents from own editable application" on public.application_documents;
create policy "Students remove documents from own editable application" on public.application_documents for delete to authenticated using(
  exists(select 1 from public.applications a where a.id=application_id and a.student_id=(select auth.uid()) and a.status in ('draft','needs_information'))
);
revoke delete on public.application_documents from public, anon, authenticated;
grant delete on public.application_documents to authenticated;
grant select on public.profiles,public.scholarships,public.applications,public.reviewer_assignments,public.reviews,public.application_documents,public.application_audit to authenticated;
grant insert,update,delete on public.scholarships to authenticated;
grant insert on public.applications to authenticated;
grant insert,update,delete on public.reviewer_assignments to authenticated;
grant insert on public.application_documents to authenticated;

commit;

-- Scholarship portal baseline. Run in Supabase SQL editor or via Supabase CLI.
create extension if not exists pgcrypto;

create type public.portal_role as enum ('student','reviewer','admin');
create type public.application_status as enum ('draft','submitted','under_review','needs_information','shortlisted','declined','approved','not_selected');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  role public.portal_role not null default 'student',
  created_at timestamptz not null default now()
);
create table public.scholarships (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text not null default '',
  award_amount numeric(12,2) not null check (award_amount >= 0),
  deadline timestamptz not null,
  eligibility jsonb not null default '{}'::jsonb,
  required_documents text[] not null default array['class_xii_marksheet','family_income_certificate'],
  is_active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create table public.applications (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  scholarship_id uuid not null references public.scholarships(id),
  status public.application_status not null default 'draft',
  application_data jsonb not null default '{}'::jsonb,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(student_id, scholarship_id)
);
create table public.reviewer_assignments (
  application_id uuid not null references public.applications(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by uuid not null references public.profiles(id),
  assigned_at timestamptz not null default now(),
  primary key(application_id, reviewer_id)
);
create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id),
  purpose_score smallint check(purpose_score between 1 and 5),
  impact_score smallint check(impact_score between 1 and 5),
  readiness_score smallint check(readiness_score between 1 and 5),
  committee_note text,
  recommendation public.application_status check (recommendation in ('needs_information','shortlisted','declined')),
  updated_at timestamptz not null default now(),
  unique(application_id, reviewer_id)
);
create table public.application_documents (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.applications(id) on delete cascade,
  uploaded_by uuid not null references public.profiles(id),
  document_type text not null,
  object_path text not null unique,
  original_name text not null,
  mime_type text not null check (mime_type in ('application/pdf','image/jpeg','image/png')),
  size_bytes bigint not null check(size_bytes between 1 and 10485760),
  created_at timestamptz not null default now()
);
create table public.application_audit (
  id bigint generated always as identity primary key,
  application_id uuid not null references public.applications(id) on delete cascade,
  actor_id uuid not null references public.profiles(id),
  action text not null,
  from_status public.application_status,
  to_status public.application_status,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- New accounts are students by default. Elevate committee/admin roles only from a
-- trusted admin session or SQL editor, never from a browser-provided field.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id,full_name,role)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''), 'student')
  on conflict(id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();
create index applications_status_idx on public.applications(status, submitted_at desc);
create index reviewer_assignments_reviewer_idx on public.reviewer_assignments(reviewer_id);
create index audit_application_idx on public.application_audit(application_id, created_at desc);

create or replace function public.current_role() returns public.portal_role
language sql stable security definer set search_path = '' as $$
  select role from public.profiles where id = (select auth.uid())
$$;
create or replace function public.is_assigned(p_application_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.reviewer_assignments ra where ra.application_id=p_application_id and ra.reviewer_id=(select auth.uid()))
$$;

-- Status changes and decision records happen together in one transaction. Clients cannot directly update status.
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
declare app public.applications;
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

alter table public.profiles enable row level security;
alter table public.scholarships enable row level security;
alter table public.applications enable row level security;
alter table public.reviewer_assignments enable row level security;
alter table public.reviews enable row level security;
alter table public.application_documents enable row level security;
alter table public.application_audit enable row level security;

create policy "Profiles visible to self and assigned committee" on public.profiles for select to authenticated using (
  id=(select auth.uid()) or public.current_role()='admin' or exists(
    select 1 from public.reviewer_assignments ra join public.applications a on a.id=ra.application_id
    where ra.reviewer_id=(select auth.uid()) and a.student_id=profiles.id
  )
);
create policy "Users can update own profile" on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));
-- RLS controls rows; column grants prevent a user editing their own role.
revoke update on public.profiles from public, anon, authenticated;
grant update(full_name) on public.profiles to authenticated;
create policy "Active scholarships are readable" on public.scholarships for select to authenticated using(is_active or public.current_role()='admin');
create policy "Admins manage scholarships" on public.scholarships for all to authenticated using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "Students read own applications; assigned reviewers can read" on public.applications for select to authenticated using(
  student_id=(select auth.uid()) or public.current_role()='admin' or (public.current_role()='reviewer' and public.is_assigned(id))
);
create policy "Students create own drafts" on public.applications for insert to authenticated with check(student_id=(select auth.uid()) and status='draft');
create policy "Students update own drafts" on public.applications for update to authenticated using(student_id=(select auth.uid()) and status in ('draft','needs_information')) with check(student_id=(select auth.uid()) and status in ('draft','needs_information'));
-- Students may edit form data only. Status changes are performed by the checked RPC functions.
revoke update on public.applications from public, anon, authenticated;
grant update(application_data) on public.applications to authenticated;
create policy "Admins manage assignments" on public.reviewer_assignments for all to authenticated using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "Reviewers read own assignments" on public.reviewer_assignments for select to authenticated using(reviewer_id=(select auth.uid()) or public.current_role()='admin');
create policy "Committee reads reviews" on public.reviews for select to authenticated using(public.current_role()='admin' or public.is_assigned(application_id));
-- Review rows are written only inside review_application so every decision is audited atomically.
revoke insert, update, delete on public.reviews from public, anon, authenticated;
create policy "Authorized parties read document metadata" on public.application_documents for select to authenticated using(
  public.current_role()='admin' or exists(select 1 from public.applications a where a.id=application_id and a.student_id=(select auth.uid())) or public.is_assigned(application_id)
);
create policy "Students add documents to own draft" on public.application_documents for insert to authenticated with check(
  uploaded_by=(select auth.uid()) and exists(select 1 from public.applications a where a.id=application_id and a.student_id=(select auth.uid()) and a.status in ('draft','needs_information'))
);
create policy "Students remove documents from own editable application" on public.application_documents for delete to authenticated using(
  exists(select 1 from public.applications a where a.id=application_id and a.student_id=(select auth.uid()) and a.status in ('draft','needs_information'))
);
revoke delete on public.application_documents from public, anon, authenticated;
grant delete on public.application_documents to authenticated;
create policy "Audit visible to assigned committee" on public.application_audit for select to authenticated using(public.current_role()='admin' or public.is_assigned(application_id));

-- Private bucket; never make scholarship records public.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('scholarship-documents','scholarship-documents',false,10485760,array['application/pdf','image/jpeg','image/png'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['application/pdf','image/jpeg','image/png'];
create policy "Students upload to own application folder" on storage.objects for insert to authenticated with check(
  bucket_id='scholarship-documents' and (storage.foldername(name))[1]=(select auth.uid())::text and exists(
    select 1 from public.applications a where a.id::text=(storage.foldername(name))[2] and a.student_id=(select auth.uid()) and a.status in ('draft','needs_information')
  )
);
create policy "Student or assigned committee reads documents" on storage.objects for select to authenticated using(
  bucket_id='scholarship-documents' and exists(
    select 1 from public.application_documents d join public.applications a on a.id=d.application_id
    where d.object_path=name and (a.student_id=(select auth.uid()) or public.current_role()='admin' or public.is_assigned(a.id))
  )
);
create policy "Students delete own draft documents" on storage.objects for delete to authenticated using(
  bucket_id='scholarship-documents' and (storage.foldername(name))[1]=(select auth.uid())::text and exists(
    select 1 from public.applications a where a.id::text=(storage.foldername(name))[2] and a.student_id=(select auth.uid()) and a.status in ('draft','needs_information')
  )
);

-- Minimal fictional scholarship row used by the starter client.
insert into public.scholarships(id,title,description,award_amount,deadline,eligibility)
values('11111111-1111-4111-8111-111111111111','Aarohan Udaan Scholarship','Fictional college scholarship record for the demo. Eligibility and award are illustrative.',25000,'2026-10-20T23:59:59Z','{"level":"undergraduate","family_income_below_inr":500000,"previous_exam_min_percent":70,"demo_record":true}'::jsonb)
on conflict(id) do nothing;

grant execute on function public.submit_application(uuid) to authenticated;
grant execute on function public.review_application(uuid,public.application_status,integer,text,jsonb) to authenticated;
grant select on public.profiles,public.scholarships,public.applications,public.reviewer_assignments,public.reviews,public.application_documents,public.application_audit to authenticated;
grant insert,update,delete on public.scholarships to authenticated;
grant insert on public.applications to authenticated;
grant insert,update,delete on public.reviewer_assignments to authenticated;
grant insert on public.application_documents to authenticated;

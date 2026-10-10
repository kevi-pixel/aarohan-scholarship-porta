# Aarohan Scholarship Portal

An India-focused college scholarship portal built with React, Vite, and an optional Supabase backend. It includes student, committee, and administrator workflows, with a local fictional-data mode for demos.

## Indian college demo

- Indian names, college email addresses, courses, state, academic year, rupee amounts, and family income in rupees.
- The **Aarohan Udaan Scholarship** and its eligibility are clearly marked as fictional demo content.
- The **PM-USP Central Sector Scheme of Scholarship for College and University Students** listing is based on the official 2026–27 NSP listing and Ministry of Education guidelines. On the official listing, applications are open through **31 October 2026**. The stated award rates and eligibility are summarized from the Ministry guideline; students must confirm the latest notice before applying.
- Demo applications and reviews remain fictional and are saved only in this browser. The portal is not connected to the National Scholarship Portal.

## Screens

- **Student:** overview, scholarship directory, application form, status timeline.
- **Reviewer:** assigned application queue, student profile and statement, private document links, rubric, clarification, shortlist, recommendation, and final decision.
- **Admin:** create scholarships with eligibility and deadlines, review application summaries, and assign committee reviewers.

## Data model and actions

`profiles` (auth user + role) → `applications` (student + scholarship + form + status) → `application_documents` (private storage path) and `reviews` (rubric + committee note). `reviewer_assignments` links reviewers to application records. `application_audit` logs decisions. `scholarships` stores eligibility, award, deadline, and required documents.

| Screen | Main actions |
| --- | --- |
| Student overview | Resume application, check document list, open status |
| Scholarship directory | Compare the sample college award and official PM-USP scheme; follow the NSP link for government applications |
| Application | Save draft, choose document type, upload the marksheet + income certificate, validate, review, submit |
| Status | Follow submission, review, clarification, shortlist, and decision |
| Reviewer queue | Search/filter assigned applications and open a review |
| Review detail | Score the shared rubric, request information, shortlist, recommend not selected, approve or make final selection |
| Admin | Create a scholarship and assign a reviewer to an application |

## Status rules

```text
draft → submitted → under_review → needs_information → under_review
                              ├──→ shortlisted → approved
                              │               └→ not_selected
                              └──→ declined
```

When Supabase is configured, the portal uses Supabase Auth, PostgreSQL, and a private Storage bucket. Student drafts and submissions, reviewer decisions, administrator scholarship creation, and reviewer assignments use the database. Private document previews use 60-second signed links. Without Supabase settings, the portal runs in clearly labelled sample mode and stores only fictional demo data in this browser.

## Run locally

1. Install Node.js LTS from [nodejs.org](https://nodejs.org/en/download/) if needed.
2. In this project folder run `npm install`.
3. Run `npm run dev` and open the local URL shown in the terminal.
4. Use **Reset sample data** to restore the fictional records.

## Verified official reference

- [National Scholarship Portal: All Scholarships, AY 2026–27](https://scholarships.gov.in/All-Scholarships) — includes PM-USP CSSS and the 31 October 2026 application deadline.
- [Ministry of Education: PM-USP CSSS Guidelines](https://www.education.gov.in/sites/upload_files/mhrd/files/upload_document/PM_USP_CSSS_guidelines.pdf) — eligibility and award rates.

## Connect a Supabase project

1. Create a Supabase project and open its **SQL Editor**.
2. For a new database, run the SQL files in `supabase/migrations` in date order. If the baseline migration was already applied, run only `202610100001_security_hardening.sql` after it. Do not rerun the baseline on an existing database.
3. In Supabase **Project Settings → API**, copy the Project URL and publishable/anon key. Create `.env.local` in this folder using `.env.example` as a template. Use only the publishable/anon key in the browser; never put a service-role key in a `VITE_` variable.
4. In **Authentication → URL Configuration**, allow the local app URL `http://localhost:5173` as a redirect URL. Enable email sign-in.
5. Restart the dev server with `npm run dev`, open the URL it prints, and sign in with email. New accounts receive the student role automatically.
6. To enable the committee, create reviewer accounts through email sign-in, then use the SQL Editor to promote the intended trusted accounts. Example: `update public.profiles set role='admin' where id=(select id from auth.users where email='admin@example.edu');` Use `reviewer` for committee members. Do this only with accounts you control.

The connected application derives roles from `profiles`; it disables the sample role switcher. The database enforces ownership and assignments. Review decisions and status changes are written to `application_audit`. Student-visible clarification messages are stored on the application, while private committee notes remain restricted to the committee.

The Aarohan scholarship row in the migration is fictional demo content. Replace its award and eligibility with college-approved information before inviting applicants. Do not use real student records until the institution has reviewed privacy, retention, accessibility, and document-scanning requirements.

Do not use real student documents or personal information in sample mode. Review institutional privacy, retention, accessibility, and file-scanning requirements before production use.

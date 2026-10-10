const bucket = 'scholarship-documents';
const maxFileBytes = 10 * 1024 * 1024;
const allowedTypes = new Set(['application/pdf', 'image/jpeg', 'image/png']);

const emptyDraft = (user = {}) => ({
  fullName: user.full_name || '',
  email: user.email || '',
  studentId: '',
  state: 'Maharashtra',
  college: 'Aarohan University, Pune',
  program: '',
  year: '',
  gpa: '',
  household: '',
  income: '',
  essay: '',
});

function formatSize(bytes) {
  return bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
}

function mapDocument(row) {
  const kind = row.document_type === 'class_xii_marksheet' ? '12th marksheet'
    : row.document_type === 'family_income_certificate' ? 'Income certificate' : 'Supporting document';
  return { id: row.id, name: row.original_name, size: formatSize(row.size_bytes), kind, documentType: row.document_type, objectPath: row.object_path, mimeType: row.mime_type };
}

function mapApplication(row, scholarship, docs, reviews) {
  const data = row.application_data || {};
  const review = reviews.find(item => item.application_id === row.id);
  const name = data.fullName || data.email || 'Student applicant';
  const rubric = review ? [review.purpose_score, review.impact_score, review.readiness_score].filter(Number.isFinite) : [];
  return {
    id: row.id,
    name,
    initials: name.split(/\s+/).map(part => part[0]).join('').slice(0, 2).toUpperCase(),
    email: data.email || '',
    program: data.program || 'Course not added',
    year: data.year || '',
    scholarship: scholarship?.title || 'Scholarship application',
    scholarshipId: row.scholarship_id,
    submitted: row.submitted_at ? new Date(row.submitted_at).toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' }) : 'Draft',
    status: row.status,
    score: rubric.length ? Math.round(rubric.reduce((sum, value) => sum + value, 0) / 15 * 100) : null,
    gpa: data.gpa || '—',
    need: data.income ? `₹${Number(data.income).toLocaleString('en-IN')} / year` : 'Needs-based',
    essay: data.essay || '',
    clarificationRequest: data.clarification_request || (review?.recommendation === 'needs_information' ? review.committee_note : ''),
    clarificationResponse: data.clarification_response || '',
    reviewComment: review?.committee_note || '',
    documents: docs.filter(doc => doc.application_id === row.id).map(mapDocument),
    applicationData: data,
  };
}

export async function loadPortalData(client, user) {
  const profileResult = await client.from('profiles').select('role,full_name').eq('id', user.id).single();
  if (profileResult.error) throw profileResult.error;
  const role = profileResult.data.role;
  const [scholarshipsResult, applicationsResult] = await Promise.all([
    client.from('scholarships').select('*').order('created_at', { ascending: false }),
    client.from('applications').select('*').order('created_at', { ascending: false }),
  ]);
  if (scholarshipsResult.error) throw scholarshipsResult.error;
  if (applicationsResult.error) throw applicationsResult.error;
  let reviewers = [];
  let assignments = [];
  if (role === 'admin') {
    const [reviewersResult, assignmentsResult] = await Promise.all([
      client.from('profiles').select('id,full_name').eq('role', 'reviewer'),
      client.from('reviewer_assignments').select('application_id,reviewer_id'),
    ]);
    if (reviewersResult.error) throw reviewersResult.error;
    if (assignmentsResult.error) throw assignmentsResult.error;
    reviewers = reviewersResult.data || [];
    assignments = assignmentsResult.data || [];
  }
  const applications = applicationsResult.data || [];
  const ids = applications.map(app => app.id);
  let docs = [];
  let reviews = [];
  if (ids.length) {
    const docsResult = await client.from('application_documents').select('*').in('application_id', ids);
    if (docsResult.error) throw docsResult.error;
    docs = docsResult.data || [];
    if (role !== 'student') {
      const reviewsResult = await client.from('reviews').select('*').in('application_id', ids);
      if (reviewsResult.error) throw reviewsResult.error;
      reviews = reviewsResult.data || [];
    }
  }
  const scholarshipById = new Map((scholarshipsResult.data || []).map(item => [item.id, item]));
  const mapped = applications.map(row => mapApplication(row, scholarshipById.get(row.scholarship_id), docs, reviews));
  const mine = role === 'student' ? applications.find(row => row.status === 'draft' || row.status === 'needs_information') || applications[0] : null;
  const draft = mine ? { ...emptyDraft({ ...profileResult.data, email: user.email }), ...(mine.application_data || {}) } : emptyDraft({ ...profileResult.data, email: user.email });
  const myDocuments = mine ? docs.filter(doc => doc.application_id === mine.id).map(mapDocument) : [];
  return { role, profile: profileResult.data, scholarships: scholarshipsResult.data || [], applications: mapped, draft, draftId: mine?.id || null, draftStatus: mine?.status || 'draft', draftScholarshipId: mine?.scholarship_id || null, documents: myDocuments, reviewers, assignments };
}

export async function saveLiveDraft(client, user, scholarshipId, draft, existingId, currentStatus = 'draft') {
  if (!scholarshipId) throw new Error('No active scholarship is configured yet. Ask the portal administrator to publish one.');
  const values = {
    student_id: user.id,
    scholarship_id: scholarshipId,
    status: currentStatus === 'needs_information' ? 'needs_information' : 'draft',
    application_data: draft,
  };
  const result = existingId
    ? await client.from('applications').update({ application_data: draft }).eq('id', existingId).select('id').single()
    : await client.from('applications').insert(values).select('id').single();
  if (result.error) throw result.error;
  return result.data.id;
}

export async function uploadLiveDocuments(client, user, applicationId, files, documentType) {
  if (!applicationId) throw new Error('Save your draft before uploading documents.');
  if (!['class_xii_marksheet', 'family_income_certificate', 'supporting_document'].includes(documentType)) throw new Error('Choose a document type first.');
  const uploaded = [];
  for (const file of Array.from(files)) {
    if (file.size < 1 || file.size > maxFileBytes || !allowedTypes.has(file.type)) throw new Error('Use PDF, JPG, or PNG files up to 10 MB each.');
    const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
    const path = `${user.id}/${applicationId}/${crypto.randomUUID()}_${safeName}`;
    const storageResult = await client.storage.from(bucket).upload(path, file, { contentType: file.type, upsert: false });
    if (storageResult.error) throw storageResult.error;
    const metadataResult = await client.from('application_documents').insert({
      application_id: applicationId,
      uploaded_by: user.id,
      document_type: documentType,
      object_path: path,
      original_name: file.name,
      mime_type: file.type,
      size_bytes: file.size,
    }).select('*').single();
    if (metadataResult.error) {
      await client.storage.from(bucket).remove([path]);
      throw metadataResult.error;
    }
    uploaded.push(mapDocument(metadataResult.data));
  }
  return uploaded;
}

export async function getPrivateDocumentUrl(client, objectPath) {
  const result = await client.storage.from(bucket).createSignedUrl(objectPath, 60);
  if (result.error) throw result.error;
  return result.data.signedUrl;
}

export async function removeLiveDocument(client, document) {
  const storageResult = await client.storage.from(bucket).remove([document.object_path || document.objectPath]);
  if (storageResult.error) throw storageResult.error;
  const metadataResult = await client.from('application_documents').delete().eq('id', document.id);
  if (metadataResult.error) throw metadataResult.error;
}

export async function sendLiveClarification(client, applicationId, appData, response) {
  const saveResult = await client.from('applications').update({ application_data: { ...appData, clarification_response: response } }).eq('id', applicationId);
  if (saveResult.error) throw saveResult.error;
  const submitResult = await client.rpc('submit_application', { p_application_id: applicationId });
  if (submitResult.error) throw submitResult.error;
}

export async function reviewLiveApplication(client, applicationId, status, review) {
  const result = await client.rpc('review_application', {
    p_application_id: applicationId,
    p_new_status: status,
    p_score: review.score ?? null,
    p_comment: review.comment || null,
    p_rubric: { ...(review.rubric || {}), clarification_request: review.clarificationRequest || null },
  });
  if (result.error) throw result.error;
}

export async function createLiveScholarship(client, user, values) {
  const result = await client.from('scholarships').insert({
    title: values.title.trim(),
    description: values.description.trim(),
    award_amount: Number(values.award_amount),
    deadline: new Date(`${values.deadline}T23:59:59+05:30`).toISOString(),
    eligibility: {
      family_income_below_inr: Number(values.income_limit),
      previous_exam_min_percent: Number(values.min_percent),
    },
    required_documents: values.required_documents || ['class_xii_marksheet', 'family_income_certificate'],
    created_by: user.id,
  }).select('*').single();
  if (result.error) throw result.error;
  return result.data;
}

export async function assignLiveReviewer(client, user, applicationId, reviewerId) {
  const result = await client.from('reviewer_assignments').upsert({ application_id: applicationId, reviewer_id: reviewerId, assigned_by: user.id }, { onConflict: 'application_id,reviewer_id' });
  if (result.error) throw result.error;
}

const API_BASE = String((window.TRADE_PLAN_CONFIG || {}).apiBase || '/integrated').replace(/\/$/, '');
const AUTH_KEY = 'trade-plan.auth.v1';
const LEGACY_KEYS = { plans: 'trade-plan.records.v1', experiences: 'trade-plan.experiences.v1' };
const MAX_IMAGES = 5;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const timeframeLabels = { '3m': '3 分钟', '15m': '15 分钟', '1h': '1 小时', '4h': '4 小时', '1d': '1 天' };

let auth = loadAuth();
let plans = [];
let experiences = [];
const filters = { direction: 'all', completion: 'all', timeframe: 'all', query: '' };
let selectedImages = [];
let toastTimer;
let activeView = 'records';
let editingExperienceId = null;
let entering = false;

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function loadAuth() {
  try { const stored = JSON.parse(window.localStorage.getItem(AUTH_KEY) || 'null'); return stored && stored.token ? stored : null; } catch (error) { return null; }
}
function saveAuth(value) { auth = value; try { window.localStorage.setItem(AUTH_KEY, JSON.stringify(value)); } catch (error) { /* 本次会话仍有效 */ } }
function clearAuth() { auth = null; try { window.localStorage.removeItem(AUTH_KEY); } catch (error) { /* ignore */ } }

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
}
function richText(value) { return escapeHtml(value).replace(/\r?\n/g, '<br>'); }
function safeImageSource(value) {
  const source = String(value || '').trim();
  return /^(?:https?:\/\/|data:image\/)/i.test(source) ? source : '';
}
function money(value) { const number = Number(String(value ?? '').replace(/,/g, '')); return Number.isFinite(number) ? number : 0; }
function formatPrice(value) { return money(value).toLocaleString('en-US', { maximumFractionDigits: 8 }); }
function directionLabel(direction) { return direction === 'short' ? '空' : '多'; }
function statusLabel(status) { return status === 'done' ? '已做' : '未做'; }
function planCode(id) { return `TP-${String(id).padStart(3, '0')}`; }
function experienceCode(id) { return `EXP-${String(id).padStart(3, '0')}`; }
function timeLabel(iso) {
  const then = new Date(iso); if (Number.isNaN(then.getTime())) return '';
  const diff = Date.now() - then.getTime();
  if (diff < 60_000) return '刚刚';
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`;
  return `${then.getMonth() + 1} 月 ${String(then.getDate()).padStart(2, '0')} 日`;
}

async function api(path, { method = 'GET', body, anonymous = false } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (!anonymous && auth?.token) headers.Authorization = `Bearer ${auth.token}`;
  let response = await fetch(`${API_BASE}${path}`, { method, headers, credentials: 'include', body: body === undefined ? undefined : JSON.stringify(body) });
  if (response.status === 401 && !anonymous) {
    const refreshed = await refreshSession();
    if (!refreshed) { forceLogin(); throw new Error('登录已过期，请重新登录'); }
    headers.Authorization = `Bearer ${auth.token}`;
    response = await fetch(`${API_BASE}${path}`, { method, headers, credentials: 'include', body: body === undefined ? undefined : JSON.stringify(body) });
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || (payload.code !== undefined && payload.code !== 200)) throw new Error(payload.message || `请求失败（${response.status}）`);
  return payload.data;
}

async function refreshSession() {
  try {
    const response = await fetch(`${API_BASE}/v1/auth/refresh`, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || !payload.data?.token) return false;
    saveAuth({ ...(auth || {}), token: payload.data.token });
    return true;
  } catch (error) { return false; }
}

function showToast(message) {
  const toast = $('#toast'); toast.textContent = message; toast.classList.add('show'); clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 2800);
}

/* ---------- 登录 / 注册 / 会话 ---------- */

function showAuth() {
  $('#app-shell').hidden = true;
  $('#auth-screen').hidden = false;
  document.body.classList.remove('modal-open');
  window.setTimeout(() => $('#login-form input[name="email"]')?.focus(), 60);
}
function forceLogin() { clearAuth(); showAuth(); }

function setAuthError(message) {
  const box = $('#auth-error');
  box.hidden = !message;
  box.textContent = message || '';
}
function switchAuthTab(tab) {
  const login = tab === 'login';
  $('#tab-login').classList.toggle('active', login);
  $('#tab-register').classList.toggle('active', !login);
  $('#tab-login').setAttribute('aria-selected', String(login));
  $('#tab-register').setAttribute('aria-selected', String(!login));
  $('#login-form').hidden = !login;
  $('#register-form').hidden = login;
  setAuthError('');
}
function setBusy(button, busy, idleHtml) {
  button.disabled = busy;
  button.innerHTML = busy ? '处理中…' : idleHtml;
}

async function enterApp() {
  if (entering) return;
  entering = true;
  try {
    const [planRows, experienceRows] = await Promise.all([api('/v1/plan/list'), api('/v1/experience/list')]);
    plans = Array.isArray(planRows) ? planRows : [];
    experiences = Array.isArray(experienceRows) ? experienceRows : [];
    await migrateLegacyData();
    $('#account-email').textContent = auth?.email || '当前账号';
    $('#account-email').title = auth?.email || '';
    $('#auth-screen').hidden = true;
    $('#app-shell').hidden = false;
    renderMetrics(); renderRecords(); renderExperiences(); renderImagePreviews(); updateFormPreview();
    showView('records');
  } catch (error) {
    if (!auth) showAuth(); else showToast(error.message);
  } finally { entering = false; }
}

async function migrateLegacyData() {
  let legacyPlans = []; let legacyExperiences = [];
  try { legacyPlans = JSON.parse(window.localStorage.getItem(LEGACY_KEYS.plans) || '[]'); } catch (error) { legacyPlans = []; }
  try { legacyExperiences = JSON.parse(window.localStorage.getItem(LEGACY_KEYS.experiences) || '[]'); } catch (error) { legacyExperiences = []; }
  if (!Array.isArray(legacyPlans)) legacyPlans = [];
  if (!Array.isArray(legacyExperiences)) legacyExperiences = [];
  let migrated = 0;
  if (plans.length === 0 && legacyPlans.length) {
    for (const item of legacyPlans) {
      try {
        const created = await api('/v1/plan/create', { method: 'POST', body: {
          symbol: String(item.symbol || 'BTCUSDT'), direction: item.direction === 'short' ? 'short' : 'long',
          timeframe: timeframeLabels[item.timeframe] ? item.timeframe : '1h',
          entry: String(money(item.entry)), stop: String(money(item.stop)), target: String(money(item.target)), risk: String(money(item.risk)),
          thesis: String(item.thesis || ''), status: item.status === 'done' ? 'done' : 'undone',
          images: Array.isArray(item.images) ? item.images.slice(0, MAX_IMAGES) : [],
        } });
        plans.push(created); migrated += 1;
      } catch (error) { /* 单条失败不阻塞其余迁移 */ }
    }
  }
  if (experiences.length === 0 && legacyExperiences.length) {
    for (const item of legacyExperiences) {
      try {
        const created = await api('/v1/experience/create', { method: 'POST', body: { title: String(item.title || '未命名经验'), body: String(item.body || ''), images: [] } });
        experiences.push(created); migrated += 1;
      } catch (error) { /* 同上 */ }
    }
  }
  if (migrated) {
    try { window.localStorage.removeItem(LEGACY_KEYS.plans); window.localStorage.removeItem(LEGACY_KEYS.experiences); } catch (error) { /* ignore */ }
    showToast(`已将 ${migrated} 条本机历史记录同步到当前账号`);
  }
}

async function handleLogin(event) {
  event.preventDefault();
  const form = event.currentTarget; const button = $('#login-submit');
  setAuthError(''); setBusy(button, true, '登录 <span>↗</span>');
  try {
    const data = await api('/v1/auth/login', { method: 'POST', anonymous: true, body: { email: form.elements.email.value.trim(), password: form.elements.password.value } });
    saveAuth({ token: data.token, email: data.email || form.elements.email.value.trim() });
    form.reset();
    await enterApp();
    showToast('登录成功');
  } catch (error) { setAuthError(error.message); }
  finally { setBusy(button, false, '登录 <span>↗</span>'); }
}

async function handleRegister(event) {
  event.preventDefault();
  const form = event.currentTarget; const button = $('#register-submit');
  setAuthError('');
  if (!form.elements.agreed.checked) { setAuthError('请先阅读并同意用户协议与隐私政策'); return; }
  setBusy(button, true, '创建账号 <span>↗</span>');
  try {
    const email = form.elements.email.value.trim();
    await api('/v1/auth/register', { method: 'POST', anonymous: true, body: { email, password: form.elements.password.value, confirm_password: form.elements.confirm_password.value, agreed: true } });
    const data = await api('/v1/auth/login', { method: 'POST', anonymous: true, body: { email, password: form.elements.password.value } });
    saveAuth({ token: data.token, email: data.email || email });
    form.reset();
    await enterApp();
    showToast('账号已创建并登录');
  } catch (error) { setAuthError(error.message); }
  finally { setBusy(button, false, '创建账号 <span>↗</span>'); }
}

async function handleLogout() {
  try { await api('/v1/auth/logout', { method: 'POST', body: {} }); } catch (error) { /* 本地会话仍会清除 */ }
  clearAuth();
  plans = []; experiences = []; selectedImages = [];
  showAuth();
  showToast('已退出登录');
}

/* ---------- 视图与渲染 ---------- */

function showView(view) {
  activeView = ['records', 'new-plan', 'experiences'].includes(view) ? view : 'records';
  $$('.page-view').forEach((page) => { const active = page.id === `${activeView}-view`; page.hidden = !active; page.classList.toggle('active', active); });
  $$('.nav-item[data-view]').forEach((button) => button.classList.toggle('active', button.dataset.view === activeView));
  $('#page-title').textContent = activeView === 'new-plan' ? '新建计划' : activeView === 'experiences' ? '交易经验' : '计划记录';
  $('#records-top-tools').hidden = activeView !== 'records';
  if (activeView === 'new-plan') window.setTimeout(() => $('input[name="symbol"]')?.focus(), 60);
}

function getVisiblePlans() {
  const query = filters.query.trim().toLowerCase();
  return plans.filter((plan) => {
    const matchesDirection = filters.direction === 'all' || plan.direction === filters.direction;
    const matchesCompletion = filters.completion === 'all' || (filters.completion === 'done' && plan.status === 'done') || (filters.completion === 'undone' && plan.status !== 'done');
    const matchesTimeframe = filters.timeframe === 'all' || plan.timeframe === filters.timeframe;
    const matchesQuery = !query || [plan.symbol, planCode(plan.id), plan.thesis].some((value) => String(value || '').toLowerCase().includes(query));
    return matchesDirection && matchesCompletion && matchesTimeframe && matchesQuery;
  });
}

function renderMetrics() {
  const doneCount = plans.filter((plan) => plan.status === 'done').length;
  $('#metric-total').textContent = String(plans.length).padStart(2, '0');
  $('#metric-undone').textContent = String(plans.length - doneCount).padStart(2, '0');
  $('#metric-done').textContent = String(doneCount).padStart(2, '0');
}

function rewardRatio(plan) {
  const entry = money(plan.entry); const stop = money(plan.stop); const target = money(plan.target);
  const riskDistance = Math.abs(entry - stop);
  return riskDistance ? (Math.abs(target - entry) / riskDistance).toFixed(2) : '0.00';
}

function planRow(plan) {
  const directionClass = plan.direction === 'short' ? 'short' : '';
  const images = Array.isArray(plan.images) && plan.images.length ? `<em class="record-image-count">▧ ${plan.images.length}</em>` : '';
  return `<tr data-plan-id="${plan.id}"><td><span class="record-name">${escapeHtml(plan.symbol)}${images}<small>${escapeHtml(planCode(plan.id))} · ${escapeHtml(plan.thesis)}</small></span></td><td class="record-direction ${directionClass}">${directionLabel(plan.direction)}</td><td class="record-timeframe">${escapeHtml(timeframeLabels[plan.timeframe] || plan.timeframe)}</td><td class="record-levels"><span>${escapeHtml(formatPrice(plan.entry))}</span><i>/</i><span>${escapeHtml(formatPrice(plan.stop))}</span><i>/</i><span>${escapeHtml(formatPrice(plan.target))}</span></td><td class="record-risk">${escapeHtml(formatPrice(plan.risk))} USDT <b>· ${rewardRatio(plan)}R</b></td><td><button class="status-tag ${plan.status === 'done' ? 'done' : 'undone'}" data-toggle-status type="button" title="点击切换状态">${statusLabel(plan.status)}</button></td><td class="record-time">${escapeHtml(timeLabel(plan.updated_at))}</td><td class="record-actions"><button class="row-delete" data-delete-plan type="button">删除</button></td></tr>`;
}

function renderRecords() {
  const visible = getVisiblePlans();
  $('#records-body').innerHTML = visible.map(planRow).join('');
  $('#empty-state').hidden = visible.length > 0 || plans.length === 0;
  $('#empty-cta').hidden = plans.length > 0;
  $('#record-count').textContent = String(visible.length).padStart(2, '0');
}

function renderExperiences() {
  const list = $('#experience-list');
  $('#experience-count').textContent = String(experiences.length).padStart(2, '0');
  $('#experience-empty').hidden = experiences.length > 0;
  list.innerHTML = experiences.map((experience) => `<article class="experience-row"><div class="experience-row-meta"><span class="experience-index">${escapeHtml(experienceCode(experience.id))}</span><time>${escapeHtml(timeLabel(experience.created_at))}</time></div><div class="experience-row-body"><h3>${escapeHtml(experience.title)}</h3><p>${richText(experience.body)}</p></div><button class="experience-read-more" data-experience-id="${experience.id}" type="button">查看全文 <span>↗</span></button></article>`).join('');
}

function updateFormPreview() {
  const form = $('#plan-form');
  const symbol = (form.elements.symbol.value || 'BTCUSDT').trim().toUpperCase();
  const direction = form.elements.direction.value === 'short' ? '做空' : '做多';
  const entry = money(form.elements.entry.value); const stop = money(form.elements.stop.value); const target = money(form.elements.target.value);
  const riskDistance = Math.abs(entry - stop); const reward = riskDistance ? Math.abs(target - entry) / riskDistance : 0;
  $('#form-preview-title').textContent = `${symbol} · ${direction}`; $('#form-preview-ratio').textContent = `1 : ${reward.toFixed(2)}`;
}

function updateFilterButtons(group) { $$(`[data-filter-group="${group}"] [data-filter="${group}"]`).forEach((button) => button.classList.toggle('active', button.dataset.value === filters[group])); }

/* ---------- 计划 CRUD ---------- */

async function handlePlanSubmit(event) {
  event.preventDefault();
  const form = event.currentTarget; const button = $('#plan-submit');
  const entry = money(form.elements.entry.value); const stop = money(form.elements.stop.value);
  const target = money(form.elements.target.value); const risk = money(form.elements.risk.value);
  if (entry <= 0 || stop <= 0 || target <= 0 || risk <= 0) { showToast('价格与风险必须大于 0'); return; }
  if (entry === stop) { showToast('入场价与失效价不能相同'); return; }
  button.disabled = true;
  try {
    const created = await api('/v1/plan/create', { method: 'POST', body: {
      symbol: form.elements.symbol.value.trim().toUpperCase() || 'BTCUSDT',
      direction: form.elements.direction.value, timeframe: form.elements.timeframe.value,
      entry: String(entry), stop: String(stop), target: String(target), risk: String(risk),
      thesis: form.elements.thesis.value.trim(), status: 'undone',
      images: selectedImages.map((image) => image.dataUrl),
    } });
    plans = [created, ...plans];
    renderMetrics(); renderRecords(); resetPlanForm(); showView('records');
    showToast(`${created.symbol} 计划已保存到账号`);
  } catch (error) { showToast(error.message); }
  finally { button.disabled = false; }
}

async function togglePlanStatus(planId) {
  const plan = plans.find((item) => item.id === planId);
  if (!plan) return;
  const next = plan.status === 'done' ? 'undone' : 'done';
  const previous = plan.status;
  plan.status = next; renderMetrics(); renderRecords();
  try {
    const updated = await api(`/v1/plan/${planId}`, { method: 'PATCH', body: { status: next } });
    Object.assign(plan, updated); renderMetrics(); renderRecords();
    showToast(next === 'done' ? '已标记为已做' : '已标记为未做');
  } catch (error) {
    plan.status = previous; renderMetrics(); renderRecords(); showToast(error.message);
  }
}

async function deletePlan(planId, button) {
  if (!button.dataset.armed) {
    button.dataset.armed = '1'; button.textContent = '确认删除'; button.classList.add('armed');
    setTimeout(() => { if (button.isConnected) { delete button.dataset.armed; button.textContent = '删除'; button.classList.remove('armed'); } }, 2600);
    return;
  }
  const snapshot = plans;
  plans = plans.filter((item) => item.id !== planId); renderMetrics(); renderRecords();
  try {
    await api(`/v1/plan/${planId}`, { method: 'DELETE' });
    showToast('计划已删除');
  } catch (error) {
    plans = snapshot; renderMetrics(); renderRecords(); showToast(error.message);
  }
}

/* ---------- 图片 ---------- */

function imagePreviewMarkup(image, index) {
  const source = safeImageSource(typeof image === 'string' ? image : image.dataUrl);
  return `<figure class="image-preview"><img src="${escapeHtml(source)}" alt="计划图片 ${index + 1}" /><button type="button" data-remove-image="${index}" aria-label="移除图片">×</button></figure>`;
}
function renderImagePreviews() {
  $('#plan-image-preview').innerHTML = selectedImages.map(imagePreviewMarkup).join('');
  $$('#plan-image-preview [data-remove-image]').forEach((button) => button.addEventListener('click', () => { selectedImages.splice(Number(button.dataset.removeImage), 1); renderImagePreviews(); }));
}
function readImage(file) {
  return new Promise((resolve, reject) => {
    if (!file || !file.type.startsWith('image/')) return reject(new Error('请只添加图片文件'));
    if (file.size > MAX_IMAGE_BYTES) return reject(new Error('单张图片不能超过 4MB'));
    const reader = new FileReader(); reader.onload = () => resolve({ dataUrl: reader.result, name: file.name || 'pasted-image' }); reader.onerror = () => reject(new Error('图片读取失败')); reader.readAsDataURL(file);
  });
}
async function uploadImageViaApi(file) {
  const data = await api('/v1/experience/upload-url', { method: 'POST', body: { filename: file.name || 'pasted-image', content_type: file.type, size: file.size } });
  const uploadResponse = await fetch(data.url, { method: data.method || 'PUT', headers: data.headers || { 'Content-Type': file.type }, body: file });
  if (!uploadResponse.ok) throw new Error(`OSS 上传失败（${uploadResponse.status}）`);
  return { url: data.public_url, objectKey: data.object_key };
}
async function prepareImage(file) {
  const localImage = await readImage(file);
  try {
    const uploaded = await uploadImageViaApi(file);
    if (uploaded?.url) return { dataUrl: uploaded.url, name: file.name || 'uploaded-image' };
  } catch (error) { showToast('云端上传失败，已保留本地图片'); }
  return localImage;
}
async function addImages(files) {
  const remaining = MAX_IMAGES - selectedImages.length;
  if (remaining <= 0) { showToast('最多添加 5 张图片'); return; }
  const incoming = [...files].slice(0, remaining);
  if (files.length > remaining) showToast('最多添加 5 张图片，已截取前 5 张');
  for (const file of incoming) { try { selectedImages.push(await prepareImage(file)); } catch (error) { showToast(error.message); } }
  renderImagePreviews();
}
function resetPlanForm() { $('#plan-form').reset(); selectedImages = []; renderImagePreviews(); updateFormPreview(); }

/* ---------- 经验 CRUD ---------- */

function openExperienceModal(experienceId = null) {
  editingExperienceId = experienceId;
  const experience = experienceId ? experiences.find((item) => item.id === experienceId) : null;
  $('#experience-form').reset();
  $('#experience-modal-title').textContent = experience ? '编辑交易经验' : '记录交易经验';
  if (experience) { $('#experience-form input[name="title"]').value = experience.title; $('#experience-form textarea[name="body"]').value = experience.body; }
  const deleteButton = $('#delete-experience');
  deleteButton.hidden = !experience; delete deleteButton.dataset.armed; deleteButton.textContent = '删除'; deleteButton.classList.remove('armed');
  $('#experience-submit').innerHTML = experience ? '保存修改 <span>↗</span>' : '保存经验 <span>↗</span>';
  $('#experience-modal').hidden = false; document.body.classList.add('modal-open'); window.setTimeout(() => $('#experience-form input[name="title"]')?.focus(), 30);
}
function closeExperienceModal() { $('#experience-modal').hidden = true; document.body.classList.remove('modal-open'); $('#experience-form').reset(); editingExperienceId = null; }

async function handleExperienceSubmit(event) {
  event.preventDefault();
  const form = event.currentTarget; const button = $('#experience-submit');
  const title = form.elements.title.value.trim(); const body = form.elements.body.value.trim();
  if (!title || !body) return;
  button.disabled = true;
  try {
    if (editingExperienceId) {
      const updated = await api(`/v1/experience/${editingExperienceId}`, { method: 'PATCH', body: { title, body } });
      experiences = experiences.map((item) => item.id === editingExperienceId ? updated : item);
      showToast('交易经验已更新');
    } else {
      const created = await api('/v1/experience/create', { method: 'POST', body: { title, body, images: [] } });
      experiences = [created, ...experiences];
      showToast('交易经验已保存到账号');
    }
    renderExperiences(); closeExperienceModal(); showView('experiences');
  } catch (error) { showToast(error.message); }
  finally { button.disabled = false; }
}

async function deleteExperience(button) {
  if (!editingExperienceId) return;
  if (!button.dataset.armed) {
    button.dataset.armed = '1'; button.textContent = '确认删除'; button.classList.add('armed');
    setTimeout(() => { if (button.isConnected) { delete button.dataset.armed; button.textContent = '删除'; button.classList.remove('armed'); } }, 2600);
    return;
  }
  const id = editingExperienceId;
  const snapshot = experiences;
  experiences = experiences.filter((item) => item.id !== id);
  renderExperiences(); closeExperienceModal();
  try {
    await api(`/v1/experience/${id}`, { method: 'DELETE' });
    showToast('交易经验已删除');
  } catch (error) {
    experiences = snapshot; renderExperiences(); showToast(error.message);
  }
}

/* ---------- 事件绑定 ---------- */

function bindEvents() {
  $('#tab-login').addEventListener('click', () => switchAuthTab('login'));
  $('#tab-register').addEventListener('click', () => switchAuthTab('register'));
  $('#login-form').addEventListener('submit', handleLogin);
  $('#register-form').addEventListener('submit', handleRegister);
  $$('[data-toggle-password]').forEach((button) => button.addEventListener('click', () => {
    const input = button.parentElement.querySelector('input');
    const show = input.type === 'password';
    input.type = show ? 'text' : 'password';
    button.classList.toggle('revealed', show);
    button.setAttribute('aria-label', show ? '隐藏密码' : '显示密码');
  }));
  $('#open-terms').addEventListener('click', () => { $('#terms-modal').hidden = false; document.body.classList.add('modal-open'); });
  $('#close-terms').addEventListener('click', () => { $('#terms-modal').hidden = true; document.body.classList.remove('modal-open'); });
  $('#terms-modal').addEventListener('click', (event) => { if (event.target === event.currentTarget) { event.currentTarget.hidden = true; document.body.classList.remove('modal-open'); } });
  $('#logout-button').addEventListener('click', handleLogout);

  $$('.nav-item[data-view]').forEach((button) => button.addEventListener('click', () => showView(button.dataset.view)));
  $$('[data-view-target]').forEach((button) => button.addEventListener('click', () => showView(button.dataset.viewTarget)));
  $$('[data-filter]').forEach((button) => button.addEventListener('click', () => { const group = button.dataset.filter; filters[group] = button.dataset.value; updateFilterButtons(group); renderRecords(); }));
  $('#plan-search').addEventListener('input', (event) => { filters.query = event.currentTarget.value; renderRecords(); });
  $('#plan-form').addEventListener('input', updateFormPreview);
  $('#plan-form').addEventListener('submit', handlePlanSubmit);

  $('#records-body').addEventListener('click', (event) => {
    const row = event.target.closest('tr[data-plan-id]');
    if (!row) return;
    const planId = Number(row.dataset.planId);
    if (event.target.closest('[data-toggle-status]')) togglePlanStatus(planId);
    else if (event.target.closest('[data-delete-plan]')) deletePlan(planId, event.target.closest('[data-delete-plan]'));
  });

  const imageInput = $('#plan-image-input'); const imageDropzone = $('#plan-image-dropzone');
  imageInput.addEventListener('change', (event) => { addImages(event.target.files); event.target.value = ''; }); imageDropzone.addEventListener('click', () => imageInput.click());
  imageDropzone.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); imageInput.click(); } });
  imageDropzone.addEventListener('dragover', (event) => { event.preventDefault(); imageDropzone.classList.add('dragging'); }); imageDropzone.addEventListener('dragleave', () => imageDropzone.classList.remove('dragging'));
  imageDropzone.addEventListener('drop', (event) => { event.preventDefault(); imageDropzone.classList.remove('dragging'); addImages(event.dataTransfer.files); });
  document.addEventListener('paste', (event) => { if (activeView !== 'new-plan' || !event.clipboardData) return; const imageFiles = [...event.clipboardData.items].filter((item) => item.type.startsWith('image/')).map((item) => item.getAsFile()).filter(Boolean); if (imageFiles.length) { event.preventDefault(); addImages(imageFiles); } });

  $('#open-experience-modal').addEventListener('click', () => openExperienceModal()); $('#open-experience-empty').addEventListener('click', () => openExperienceModal()); $('#close-experience-modal').addEventListener('click', closeExperienceModal); $('#cancel-experience').addEventListener('click', closeExperienceModal);
  $('#experience-modal').addEventListener('click', (event) => { if (event.target === event.currentTarget) closeExperienceModal(); });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape') { if (!$('#experience-modal').hidden) closeExperienceModal(); if (!$('#terms-modal').hidden) { $('#terms-modal').hidden = true; document.body.classList.remove('modal-open'); } } });
  $('#experience-form').addEventListener('submit', handleExperienceSubmit);
  $('#delete-experience').addEventListener('click', (event) => deleteExperience(event.currentTarget));
  $('#experience-list').addEventListener('click', (event) => { const button = event.target.closest('[data-experience-id]'); if (button) openExperienceModal(Number(button.dataset.experienceId)); });
}

bindEvents();
if (auth) enterApp(); else showAuth();
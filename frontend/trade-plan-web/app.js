const initialPlans = [
  { id: 'TP-024', symbol: 'BTCUSDT', direction: 'long', timeframe: '1h', entry: '98,400', stop: '96,900', target: '103,800', risk: '120', reward: '3.60R', status: 'undone', thesis: '回踩 1H 需求区，等待收盘重新站上局部结构。', updated: '刚刚', images: [] },
  { id: 'TP-023', symbol: 'ETHUSDT', direction: 'short', timeframe: '4h', entry: '3,482', stop: '3,566', target: '3,214', risk: '86', reward: '3.19R', status: 'undone', thesis: '高周期阻力下方出现反转确认。', updated: '2 小时前', images: [] },
  { id: 'TP-022', symbol: 'SOLUSDT', direction: 'long', timeframe: '15m', entry: '178.60', stop: '174.20', target: '188.40', risk: '52', reward: '2.23R', status: 'undone', thesis: '等待波动收缩后突破。', updated: '昨天', images: [] },
  { id: 'TP-021', symbol: 'BNBUSDT', direction: 'long', timeframe: '1h', entry: '644.20', stop: '631.00', target: '674.00', risk: '64', reward: '2.26R', status: 'done', thesis: '趋势延续，按计划完成退出。', updated: '11 月 11 日', images: [] },
  { id: 'TP-020', symbol: 'XRPUSDT', direction: 'short', timeframe: '1d', entry: '2.41', stop: '2.56', target: '2.01', risk: '44', reward: '2.67R', status: 'done', thesis: '日线供应区附近的反转计划。', updated: '11 月 09 日', images: [] },
  { id: 'TP-019', symbol: 'LINKUSDT', direction: 'long', timeframe: '4h', entry: '16.82', stop: '16.10', target: '18.44', risk: '38', reward: '2.25R', status: 'undone', thesis: '等回到有效支撑再评估。', updated: '11 月 08 日', images: [] },
];

const initialExperiences = [
  { id: 'EXP-003', title: '先等结构确认，再考虑入场', body: '突破本身不是信号，收盘后的回踩和承接才是。没有确认时，宁可错过也不提前下注。', createdAt: '今天' },
  { id: 'EXP-002', title: '震荡区间里减少交易频率', body: '当高低点都没有被有效突破时，频繁换方向只会消耗风险额度。先画出边界，等价格走出区间。', createdAt: '11 月 11 日' },
  { id: 'EXP-001', title: '止损位置应该在逻辑失效处', body: '止损不是为了让单笔看起来更小，而是用来验证最初的判断。价格触发它时，说明这套逻辑已经失效。', createdAt: '11 月 08 日' },
];

const STORAGE_KEYS = { plans: 'trade-plan.records.v1', experiences: 'trade-plan.experiences.v1', auth: 'trade-plan.auth.v1' };
const MAX_IMAGES = 5;
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
const timeframeLabels = { '3m': '3 分钟', '15m': '15 分钟', '1h': '1 小时', '4h': '4 小时', '1d': '1 天' };
const tradePlanConfig = window.TRADE_PLAN_CONFIG || {};

let plans = loadCollection(STORAGE_KEYS.plans, initialPlans).map((plan) => ({ ...plan, images: Array.isArray(plan.images) ? plan.images.slice(0, MAX_IMAGES) : [] }));
let experiences = loadCollection(STORAGE_KEYS.experiences, initialExperiences);
const filters = { direction: 'all', completion: 'all', timeframe: 'all', query: '' };
let selectedImages = [];
let toastTimer;
let activeView = 'records';
let editingExperienceId = null;

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];

function loadCollection(key, fallback) {
  try {
    const stored = JSON.parse(window.localStorage.getItem(key) || 'null');
    return Array.isArray(stored) ? stored : fallback.map((item) => ({ ...item }));
  } catch (error) {
    return fallback.map((item) => ({ ...item }));
  }
}

function persist(key, value) {
  try { window.localStorage.setItem(key, JSON.stringify(value)); } catch (error) { showToast('本地存储空间不足，请减少图片后重试'); }
}

function directionLabel(direction) { return direction === 'short' ? '空' : '多'; }
function statusLabel(status) { return status === 'done' ? '已做' : '未做'; }
function statusClass(status) { return status === 'done' ? 'done' : 'undone'; }
function money(value) { const number = Number(String(value ?? '').replace(/,/g, '')); return Number.isFinite(number) ? number : 0; }
function formatPrice(value) { return money(value).toLocaleString('en-US', { maximumFractionDigits: 2 }); }

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[character]));
}

function richText(value) { return escapeHtml(value).replace(/\r?\n/g, '<br>'); }

function safeImageSource(value) {
  const source = String(value || '').trim();
  return /^(?:https?:\/\/|data:image\/)/i.test(source) ? source : '';
}

function uploadApiBase() { return String(tradePlanConfig.apiBase || '/integrated').replace(/\/$/, ''); }

function loadAuth() {
  try { const stored = JSON.parse(window.localStorage.getItem(STORAGE_KEYS.auth) || 'null'); return stored && stored.token ? stored : null; } catch (error) { return null; }
}
function saveAuth(auth) { try { window.localStorage.setItem(STORAGE_KEYS.auth, JSON.stringify(auth)); } catch (error) { /* 存储失败时仅本次会话有效 */ } }
function clearAuth() { try { window.localStorage.removeItem(STORAGE_KEYS.auth); } catch (error) { /* ignore */ } }

function uploadAccessToken() {
  if (typeof tradePlanConfig.getAccessToken === 'function') return String(tradePlanConfig.getAccessToken() || '');
  if (tradePlanConfig.accessToken) return String(tradePlanConfig.accessToken);
  return String(loadAuth()?.token || '');
}

async function refreshAccessToken() {
  const response = await fetch(`${uploadApiBase()}/v1/auth/refresh`, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: '{}' });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.data?.token) return null;
  const auth = { ...(loadAuth() || {}), token: payload.data.token };
  saveAuth(auth);
  return auth.token;
}

async function requestUploadUrl(file, token) {
  return fetch(`${uploadApiBase()}/v1/experience/upload-url`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ filename: file.name || 'pasted-image', content_type: file.type, size: file.size }),
  });
}

async function uploadImageViaApi(file) {
  let token = uploadAccessToken();
  if (!token) throw new Error('未登录云端图片');
  let response = await requestUploadUrl(file, token);
  if (response.status === 401) {
    token = await refreshAccessToken();
    if (!token) { clearAuth(); renderOssStatus(); throw new Error('登录已过期，请重新登录'); }
    response = await requestUploadUrl(file, token);
  }
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.data?.url) throw new Error(payload.message || 'OSS 签名地址获取失败');
  const uploadResponse = await fetch(payload.data.url, { method: payload.data.method || 'PUT', headers: payload.data.headers || { 'Content-Type': file.type }, body: file });
  if (!uploadResponse.ok) throw new Error(`OSS 上传失败（${uploadResponse.status}）`);
  return { url: payload.data.public_url, objectKey: payload.data.object_key };
}

function configuredUploadImage() {
  if (typeof tradePlanConfig.uploadImage === 'function') return tradePlanConfig.uploadImage;
  if (tradePlanConfig.enableOssUploads || uploadAccessToken()) return uploadImageViaApi;
  return null;
}

function renderOssStatus() {
  const auth = loadAuth();
  const text = $('#oss-status-text'); const button = $('#oss-login-open');
  if (!text || !button) return;
  if (auth) { text.textContent = `云端图片已登录：${auth.email || '当前账号'}，图片将直传阿里云 OSS`; button.textContent = '退出登录'; }
  else { text.textContent = '云端图片未登录，图片仅保存在本机'; button.textContent = '登录开启云端图片'; }
}

async function loginWithPassword(email, password) {
  const response = await fetch(`${uploadApiBase()}/v1/auth/login`, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email, password }) });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.data?.token) throw new Error(payload.message || '登录失败');
  saveAuth({ token: payload.data.token, email: payload.data.email || email });
  renderOssStatus();
}

function getVisiblePlans() {
  const query = filters.query.trim().toLowerCase();
  return plans.filter((plan) => {
    const matchesDirection = filters.direction === 'all' || plan.direction === filters.direction;
    const matchesCompletion = filters.completion === 'all' || (filters.completion === 'done' && plan.status === 'done') || (filters.completion === 'undone' && plan.status !== 'done');
    const matchesTimeframe = filters.timeframe === 'all' || plan.timeframe === filters.timeframe;
    const matchesQuery = !query || [plan.symbol, plan.id, plan.thesis].some((value) => String(value || '').toLowerCase().includes(query));
    return matchesDirection && matchesCompletion && matchesTimeframe && matchesQuery;
  });
}

function renderMetrics() {
  const doneCount = plans.filter((plan) => plan.status === 'done').length;
  $('#metric-total').textContent = String(plans.length).padStart(2, '0');
  $('#metric-undone').textContent = String(plans.length - doneCount).padStart(2, '0');
  $('#metric-done').textContent = String(doneCount).padStart(2, '0');
}

function planRow(plan) {
  const directionClass = plan.direction === 'short' ? 'short' : '';
  const images = Array.isArray(plan.images) && plan.images.length ? `<em class="record-image-count">▧ ${plan.images.length}</em>` : '';
  return `<tr><td><span class="record-name">${escapeHtml(plan.symbol)}${images}<small>${escapeHtml(plan.id)} · ${escapeHtml(plan.thesis)}</small></span></td><td class="record-direction ${directionClass}">${directionLabel(plan.direction)}</td><td class="record-timeframe">${escapeHtml(timeframeLabels[plan.timeframe] || plan.timeframe)}</td><td class="record-levels"><span>${escapeHtml(plan.entry)}</span><i>/</i><span>${escapeHtml(plan.stop)}</span><i>/</i><span>${escapeHtml(plan.target)}</span></td><td class="record-risk">${escapeHtml(plan.risk)} USDT <b>· ${escapeHtml(plan.reward)}</b></td><td><span class="status-tag ${statusClass(plan.status)}">${statusLabel(plan.status)}</span></td><td class="record-time">${escapeHtml(plan.updated)}</td></tr>`;
}

function renderRecords() {
  const visible = getVisiblePlans();
  $('#records-body').innerHTML = visible.map(planRow).join('');
  $('#empty-state').hidden = visible.length > 0;
  $('#record-count').textContent = String(visible.length).padStart(2, '0');
}

function renderExperiences() {
  const list = $('#experience-list');
  $('#experience-count').textContent = String(experiences.length).padStart(2, '0');
  $('#experience-empty').hidden = experiences.length > 0;
  list.innerHTML = experiences.map((experience) => `<article class="experience-row"><div class="experience-row-meta"><span class="experience-index">${escapeHtml(experience.id)}</span><time>${escapeHtml(experience.createdAt)}</time></div><div class="experience-row-body"><h3>${escapeHtml(experience.title)}</h3><p>${richText(experience.body)}</p></div><button class="experience-read-more" data-experience-id="${escapeHtml(experience.id)}" type="button">查看全文 <span>↗</span></button></article>`).join('');
}

function showToast(message) {
  const toast = $('#toast'); toast.textContent = message; toast.classList.add('show'); clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 2800);
}

function showView(view) {
  activeView = ['records', 'new-plan', 'experiences'].includes(view) ? view : 'records';
  $$('.page-view').forEach((page) => { const active = page.id === `${activeView}-view`; page.hidden = !active; page.classList.toggle('active', active); });
  $$('[data-view]').forEach((button) => button.classList.toggle('active', button.dataset.view === activeView));
  $('#page-title').textContent = activeView === 'new-plan' ? '新建计划' : activeView === 'experiences' ? '交易经验' : '计划记录';
  $('#records-top-tools').hidden = activeView !== 'records';
  if (activeView === 'new-plan') window.setTimeout(() => $('input[name="symbol"]')?.focus(), 60);
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

async function prepareImage(file) {
  const localImage = await readImage(file);
  const uploadImage = configuredUploadImage();
  if (typeof uploadImage !== 'function') return localImage;
  try {
    const uploaded = await uploadImage(file);
    if (uploaded?.url) return { dataUrl: uploaded.url, name: file.name || 'uploaded-image' };
  } catch (error) {
    showToast('OSS 上传失败，已保留本地图片');
  }
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
function openExperienceModal(experienceId = null) {
  editingExperienceId = experienceId;
  const experience = experienceId ? experiences.find((item) => item.id === experienceId) : null;
  $('#experience-form').reset();
  $('#experience-modal-title').textContent = experience ? '编辑交易经验' : '记录交易经验';
  if (experience) { $('#experience-form input[name="title"]').value = experience.title; $('#experience-form textarea[name="body"]').value = experience.body; }
  $('#experience-submit').innerHTML = experience ? '保存修改 <span>↗</span>' : '保存经验 <span>↗</span>';
  $('#experience-modal').hidden = false; document.body.classList.add('modal-open'); window.setTimeout(() => $('#experience-form input[name="title"]')?.focus(), 30);
}
function closeExperienceModal() { $('#experience-modal').hidden = true; document.body.classList.remove('modal-open'); $('#experience-form').reset(); editingExperienceId = null; $('#experience-submit').innerHTML = '保存经验 <span>↗</span>'; }

function bindEvents() {
  $$('[data-view]').forEach((button) => button.addEventListener('click', () => showView(button.dataset.view)));
  $$('[data-view-target]').forEach((button) => button.addEventListener('click', () => showView(button.dataset.viewTarget)));
  $$('[data-filter]').forEach((button) => button.addEventListener('click', () => { const group = button.dataset.filter; filters[group] = button.dataset.value; updateFilterButtons(group); renderRecords(); }));
  $('#plan-search').addEventListener('input', (event) => { filters.query = event.currentTarget.value; renderRecords(); });
  $('#plan-form').addEventListener('input', updateFormPreview);
  $('#plan-form').addEventListener('submit', (event) => {
    event.preventDefault(); const form = event.currentTarget; const symbol = form.elements.symbol.value.trim().toUpperCase() || 'BTCUSDT'; const ratio = $('#form-preview-ratio').textContent.replace('1 : ', '');
    const plan = { id: `TP-${String(25 + plans.length).padStart(3, '0')}`, symbol, direction: form.elements.direction.value, timeframe: form.elements.timeframe.value, entry: formatPrice(form.elements.entry.value), stop: formatPrice(form.elements.stop.value), target: formatPrice(form.elements.target.value), risk: formatPrice(form.elements.risk.value), reward: `${ratio}R`, status: 'undone', thesis: form.elements.thesis.value.trim() || '等待条件满足后再执行。', updated: '刚刚', images: selectedImages.map((image) => image.dataUrl) };
    plans = [plan, ...plans]; persist(STORAGE_KEYS.plans, plans); renderMetrics(); renderRecords(); resetPlanForm(); showView('records'); showToast(`${symbol} 计划已保存`);
  });

  const imageInput = $('#plan-image-input'); const imageDropzone = $('#plan-image-dropzone');
  imageInput.addEventListener('change', (event) => { addImages(event.target.files); event.target.value = ''; }); imageDropzone.addEventListener('click', () => imageInput.click());
  imageDropzone.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); imageInput.click(); } });
  imageDropzone.addEventListener('dragover', (event) => { event.preventDefault(); imageDropzone.classList.add('dragging'); }); imageDropzone.addEventListener('dragleave', () => imageDropzone.classList.remove('dragging'));
  imageDropzone.addEventListener('drop', (event) => { event.preventDefault(); imageDropzone.classList.remove('dragging'); addImages(event.dataTransfer.files); });
  document.addEventListener('paste', (event) => { if (activeView !== 'new-plan' || !event.clipboardData) return; const imageFiles = [...event.clipboardData.items].filter((item) => item.type.startsWith('image/')).map((item) => item.getAsFile()).filter(Boolean); if (imageFiles.length) { event.preventDefault(); addImages(imageFiles); } });

  $('#open-experience-modal').addEventListener('click', () => openExperienceModal()); $('#open-experience-empty').addEventListener('click', () => openExperienceModal()); $('#close-experience-modal').addEventListener('click', closeExperienceModal); $('#cancel-experience').addEventListener('click', closeExperienceModal);
  $('#experience-modal').addEventListener('click', (event) => { if (event.target === event.currentTarget) closeExperienceModal(); }); document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !$('#experience-modal').hidden) closeExperienceModal(); });
  $('#experience-form').addEventListener('submit', (event) => {
    event.preventDefault(); const form = event.currentTarget; const title = form.elements.title.value.trim(); const body = form.elements.body.value.trim(); if (!title || !body) return;
    if (editingExperienceId) {
      experiences = experiences.map((item) => item.id === editingExperienceId ? { ...item, title, body, createdAt: '刚刚' } : item);
      showToast('交易经验已更新');
    } else {
      const id = `EXP-${String(experiences.length + 1).padStart(3, '0')}`; experiences = [{ id, title, body, createdAt: '刚刚' }, ...experiences]; showToast('交易经验已保存');
    }
    persist(STORAGE_KEYS.experiences, experiences); renderExperiences(); closeExperienceModal(); showView('experiences');
  });
  $('#experience-list').addEventListener('click', (event) => { const button = event.target.closest('[data-experience-id]'); if (button) openExperienceModal(button.dataset.experienceId); });

  const loginModal = $('#login-modal');
  const openLoginModal = () => { $('#login-form').reset(); loginModal.hidden = false; document.body.classList.add('modal-open'); window.setTimeout(() => $('#login-form input[name="email"]')?.focus(), 30); };
  const closeLoginModal = () => { loginModal.hidden = true; document.body.classList.remove('modal-open'); };
  $('#oss-login-open').addEventListener('click', () => { if (loadAuth()) { clearAuth(); renderOssStatus(); showToast('已退出云端图片登录'); } else openLoginModal(); });
  $('#close-login-modal').addEventListener('click', closeLoginModal); $('#cancel-login').addEventListener('click', closeLoginModal);
  loginModal.addEventListener('click', (event) => { if (event.target === event.currentTarget) closeLoginModal(); });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !loginModal.hidden) closeLoginModal(); });
  $('#login-form').addEventListener('submit', async (event) => {
    event.preventDefault(); const form = event.currentTarget; const submit = $('#login-submit');
    submit.disabled = true;
    try { await loginWithPassword(form.elements.email.value.trim(), form.elements.password.value); closeLoginModal(); showToast('云端图片已开启'); }
    catch (error) { showToast(error.message); }
    finally { submit.disabled = false; }
  });
}

renderMetrics(); renderRecords(); renderExperiences(); bindEvents(); updateFormPreview(); renderImagePreviews(); renderOssStatus(); showView('records');

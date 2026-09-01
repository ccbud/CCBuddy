/* Skills Hub client state and backend-shape normalization. */
import { I18n } from '../../core/i18n.js';

const savedView = (() => { try { return localStorage.getItem('ccbud-skills-view') || 'list'; } catch (_) { return 'list'; } })();

export const skillsState = {
  page: 'library', detailId: '', detail: null, detailFile: '', detailContent: null, loaded: false, loading: false, error: '',
  skills: [], tools: [], status: {}, selected: new Set(),
  filters: { query: '', status: 'all', tag: 'all', sort: 'updated', view: savedView },
  add: { tab: 'git', localPath: '', candidates: [] },
  updates: { checked: 0, updated: 0, failed: 0, lastRun: 0, errors: [] },
};

const text = (value) => String(value == null ? '' : value);
const unique = (items) => [...new Set(items.filter(Boolean))];

export function normalizeSkill(raw) {
  raw = raw || {};
  const tags = Array.isArray(raw.tags) ? raw.tags.map((tag) => text(tag && tag.name != null ? tag.name : tag).trim()).filter(Boolean) : [];
  const targets = (Array.isArray(raw.targets) ? raw.targets : []).map((target) => ({
    key: text(target.key || target.tool), path: text(target.path || target.target_path),
    status: text(target.status || 'synced').toLowerCase(), mode: text(target.sync_mode || target.mode || 'auto'),
  }));
  return {
    ...raw, id: text(raw.id || raw.path || raw.name), name: text(raw.name || raw.id),
    description: text(raw.description), path: text(raw.path || raw.central_path),
    sourceType: text(raw.source_type || 'local').toLowerCase(), sourceRef: text(raw.source_ref),
    updatedAt: Number(raw.updated_at || raw.updatedAt || 0), tags: unique(tags), targets,
    status: text(raw.status || (targets.length ? 'synced' : 'local')).toLowerCase(),
  };
}

export function normalizeTool(raw) {
  raw = raw || {};
  return {
    ...raw, key: text(raw.key || raw.id), label: text(raw.label || raw.name || raw.key),
    path: text(raw.path || raw.skills_dir), detected: raw.detected !== false && raw.installed !== false,
    enabled: raw.enabled !== false, syncMode: text(raw.sync_mode || 'auto'),
  };
}

export function setSnapshot({ skills, tools, status }) {
  skillsState.skills = (Array.isArray(skills) ? skills : []).map(normalizeSkill);
  skillsState.tools = (Array.isArray(tools) ? tools : (tools && tools.tools) || []).map(normalizeTool);
  skillsState.status = status || {};
  reconcileSelection();
  skillsState.loaded = true;
}

export function syncState(skill) {
  const targets = skill.targets || [];
  const issue = (value) => /missing|invalid|error|broken|fail|unavailable/.test(text(value).toLowerCase());
  if (issue(skill.status)) return 'issue';
  if (!targets.length) return 'unsynced';
  if (targets.some((target) => issue(target.status))) return 'issue';
  if (targets.some((target) => !/sync|ok|healthy/.test(target.status))) return 'partial';
  return 'synced';
}

export function sourceUnavailable(skill) {
  return /missing|invalid|unavailable/.test(text(skill?.status).toLowerCase());
}

export function canUpdate(skill) {
  const type = text(skill?.sourceType || skill?.source_type).toLowerCase();
  const clean = (value) => text(value).replace(/[\\/]+$/, '');
  const source = clean(skill?.sourceRef || skill?.source_ref), managed = clean(skill?.path || skill?.central_path);
  if (type.includes('git')) return Boolean(source);
  return type === 'local' && Boolean(source) && source !== managed;
}

export function visibleSkills() {
  const { query, status, tag, sort } = skillsState.filters;
  const q = query.trim().toLocaleLowerCase();
  const list = skillsState.skills.filter((skill) => {
    const haystack = [skill.name, skill.description, skill.sourceRef, ...skill.tags].join('\n').toLocaleLowerCase();
    if (q && !haystack.includes(q)) return false;
    if (status !== 'all' && syncState(skill) !== status) return false;
    if (tag === '__untagged__' && skill.tags.length) return false;
    if (tag !== 'all' && tag !== '__untagged__' && !skill.tags.includes(tag)) return false;
    return true;
  });
  return list.sort((a, b) => sort === 'name'
    ? a.name.localeCompare(b.name) : sort === 'source'
      ? a.sourceType.localeCompare(b.sourceType) : b.updatedAt - a.updatedAt);
}

export function reconcileSelection(list = visibleSkills()) {
  const visibleIds = new Set(list.map((skill) => skill.id));
  skillsState.selected.forEach((id) => { if (!visibleIds.has(id)) skillsState.selected.delete(id); });
  return list;
}

export function allTags() {
  const counts = new Map();
  skillsState.skills.forEach((skill) => skill.tags.forEach((tag) => counts.set(tag, (counts.get(tag) || 0) + 1)));
  return [...counts].map(([name, count]) => ({ name, count })).sort((a, b) => a.name.localeCompare(b.name));
}

export function formatDate(value) {
  if (!value) return '—';
  const date = new Date(value < 1e12 ? value * 1000 : value);
  return Number.isNaN(date.getTime()) ? '—' : new Intl.DateTimeFormat(I18n.localeTag, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
}

export function formatSize(bytes) {
  const n = Number(bytes || 0);
  return n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`;
}

export function rememberView(value) {
  skillsState.filters.view = value;
  try { localStorage.setItem('ccbud-skills-view', value); } catch (_) {}
}
